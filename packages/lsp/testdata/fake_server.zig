//! `fake_lsp_server`: a scripted language server for tests (built only by
//! the test step; see `zg_lsp.testing.script` for the script syntax).
//!
//! ```
//! fake_lsp_server [--script <file>] [--echo] [--dap] [--workspace <dir>]
//!                 [--port <n>] [--stderr-noise <bytes>] [--spawn-grandchild]
//! fake_lsp_server --sleep
//! ```
//!
//! - `--script`: play the script on stdin/stdout (or the `--port` socket).
//! - `--echo`: no script; answer every request with its params as the
//!   result, end with status 0 on `exit`, or with the status in
//!   `{"code": n}` on the `test/exit` notification.
//! - `--dap`: DAP framing instead of LSP.
//! - `--port`: listen on 127.0.0.1:<n> and serve the first connection.
//! - `--stderr-noise`: before serving, write that many bytes of numbered
//!   lines to stderr, then `noise done`.
//! - `--spawn-grandchild`: start `fake_lsp_server --sleep` in the same
//!   process group and print `grandchild <pid>` to stderr.
//! - `--sleep`: sleep until killed.
//!
//! Exit status: the script's, 99 on a mismatch, 2 on bad usage, 98 on an
//! I/O or protocol error.

const std = @import("std");
const zg_lsp = @import("zg_lsp");
const zg_jsonrpc = @import("zg_jsonrpc");
const script_mod = zg_lsp.testing.script;

const Args = struct {
    script: ?[]const u8 = null,
    echo: bool = false,
    dap: bool = false,
    workspace: []const u8 = "",
    port: ?u16 = null,
    stderr_noise: usize = 0,
    spawn_grandchild: bool = false,
    sleep: bool = false,
};

fn usage() u8 {
    std.debug.print("usage: fake_lsp_server [--script <file>] [--echo] [--dap] [--workspace <dir>] [--port <n>] [--stderr-noise <bytes>] [--spawn-grandchild] | --sleep\n", .{});
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    var args: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const needs_value = std.mem.eql(u8, a, "--script") or std.mem.eql(u8, a, "--workspace") or
            std.mem.eql(u8, a, "--port") or std.mem.eql(u8, a, "--stderr-noise");
        if (needs_value) {
            i += 1;
            if (i == argv.len) return usage();
            const v = argv[i];
            if (std.mem.eql(u8, a, "--script")) args.script = v;
            if (std.mem.eql(u8, a, "--workspace")) args.workspace = v;
            if (std.mem.eql(u8, a, "--port")) args.port = std.fmt.parseInt(u16, v, 10) catch return usage();
            if (std.mem.eql(u8, a, "--stderr-noise")) args.stderr_noise = std.fmt.parseInt(usize, v, 10) catch return usage();
        } else if (std.mem.eql(u8, a, "--echo")) {
            args.echo = true;
        } else if (std.mem.eql(u8, a, "--dap")) {
            args.dap = true;
        } else if (std.mem.eql(u8, a, "--spawn-grandchild")) {
            args.spawn_grandchild = true;
        } else if (std.mem.eql(u8, a, "--sleep")) {
            args.sleep = true;
        } else return usage();
    }

    if (args.sleep) while (true) try io.sleep(.fromSeconds(3600), .awake);
    if (args.script == null and !args.echo) return usage();

    var err_buf: [4096]u8 = undefined;
    var err_w = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const diag = &err_w.interface;

    if (args.spawn_grandchild) {
        const gc = try std.process.spawn(io, .{
            .argv = &.{ argv[0], "--sleep" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        // Windows has no pid here, only the process handle.
        const id = if (@import("builtin").os.tag == .windows) @intFromPtr(gc.id.?) else gc.id.?;
        try diag.print("grandchild {d}\n", .{id});
        try diag.flush();
    }

    if (args.stderr_noise > 0) {
        var written: usize = 0;
        var n: usize = 0;
        while (written < args.stderr_noise) : (n += 1) {
            var line_buf: [64]u8 = undefined;
            const line = try std.fmt.bufPrint(&line_buf, "stderr noise line {d:0>8}\n", .{n});
            try diag.writeAll(line);
            written += line.len;
        }
        try diag.writeAll("noise done\n");
        try diag.flush();
    }

    var script: ?script_mod.Script = null;
    defer if (script) |*s| s.deinit();
    if (args.script) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
        var pd: script_mod.ParseDiag = .{};
        script = script_mod.Script.parse(init.gpa, text, &pd) catch |err| {
            try diag.print("{s}:{d}: {s} ({t})\n", .{ path, pd.line, pd.msg, err });
            try diag.flush();
            return 2;
        };
    }

    var in_buf: [64 << 10]u8 = undefined;
    var out_buf: [64 << 10]u8 = undefined;
    if (args.port) |port| {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        var server = try addr.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);
        const stream = try server.accept(io);
        defer stream.close(io);
        var r = stream.reader(io, &in_buf);
        var w = stream.writer(io, &out_buf);
        return serve(io, init.gpa, args, if (script) |*s| s else null, &r.interface, &w.interface, diag);
    }
    var r = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
    return serve(io, init.gpa, args, if (script) |*s| s else null, &r.interface, &w.interface, diag);
}

fn serve(io: std.Io, gpa: std.mem.Allocator, args: Args, script: ?*const script_mod.Script, in: *std.Io.Reader, out: *std.Io.Writer, diag: *std.Io.Writer) u8 {
    const status = if (script) |s|
        script_mod.runPeer(io, gpa, s, in, out, .{
            .framing = if (args.dap) .dap else .lsp,
            .workspace = args.workspace,
            .diag = diag,
        })
    else
        echo(gpa, in, out);
    return status catch |err| {
        diag.print("fake_lsp_server: {t}\n", .{err}) catch {};
        diag.flush() catch {};
        return 98;
    };
}

/// `--echo` mode (LSP framing only).
fn echo(gpa: std.mem.Allocator, in: *std.Io.Reader, out: *std.Io.Writer) !u8 {
    var frames = zg_jsonrpc.framing.ContentLengthReader.init(in, .{});
    defer frames.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    while (true) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const body = frames.next(gpa) catch |err| switch (err) {
            error.EndOfStream => return 0,
            else => return err,
        };
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        if (v != .object) return error.InvalidMessage;
        const method = v.object.get("method") orelse continue;
        if (method != .string) return error.InvalidMessage;
        const params = v.object.get("params") orelse std.json.Value.null;
        if (v.object.get("id")) |id| {
            var aw: std.Io.Writer.Allocating = .init(a);
            try zg_jsonrpc.message.writeResult(&aw.writer, try idOf(id), params);
            try zg_jsonrpc.framing.writeContentLength(out, aw.written());
        } else if (std.mem.eql(u8, method.string, "exit")) {
            return 0;
        } else if (std.mem.eql(u8, method.string, "test/exit")) {
            const code = if (params == .object) params.object.get("code") else null;
            return if (code) |c| (if (c == .integer) @intCast(c.integer) else 0) else 0;
        }
    }
}

fn idOf(v: std.json.Value) !zg_jsonrpc.message.Id {
    return switch (v) {
        .integer => |n| .{ .int = n },
        .string => |s| .{ .str = s },
        else => error.InvalidMessage,
    };
}
