//! `fake_dap_adapter`: a scripted debug adapter for tests (built only by
//! the test step). Scripts use the shared engine (`zg_lsp.testing.script`)
//! with DAP framing; see there for the syntax, including `< reverse`,
//! `> response <command>` and `seq-check off`.
//!
//! ```
//! fake_dap_adapter --script <file> [--tcp <port>] [--workspace <dir>]
//! ```
//!
//! - `--tcp`: listen on 127.0.0.1:<port> (0 picks a free port), print
//!   `listening <port>` on stdout once ready, and serve the first
//!   connection. Without it the adapter talks over stdin/stdout.
//!
//! Exit status: the script's, 99 on a mismatch or a client seq
//! regression, 2 on bad usage, 98 on an I/O or protocol error.

const std = @import("std");
const zg_lsp = @import("zg_lsp");
const script_mod = zg_lsp.testing.script;

fn usage() u8 {
    std.debug.print("usage: fake_dap_adapter --script <file> [--tcp <port>] [--workspace <dir>]\n", .{});
    return 2;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    var script_path: ?[]const u8 = null;
    var tcp: ?u16 = null;
    var workspace: []const u8 = "";
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 == argv.len) return usage();
        const a = argv[i];
        const v = argv[i + 1];
        if (std.mem.eql(u8, a, "--script")) {
            script_path = v;
        } else if (std.mem.eql(u8, a, "--tcp")) {
            tcp = std.fmt.parseInt(u16, v, 10) catch return usage();
        } else if (std.mem.eql(u8, a, "--workspace")) {
            workspace = v;
        } else return usage();
    }
    const path = script_path orelse return usage();

    var err_buf: [4096]u8 = undefined;
    var err_w = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const diag = &err_w.interface;

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20));
    var pd: script_mod.ParseDiag = .{};
    var script = script_mod.Script.parse(init.gpa, text, &pd) catch |err| {
        try diag.print("{s}:{d}: {s} ({t})\n", .{ path, pd.line, pd.msg, err });
        try diag.flush();
        return 2;
    };
    defer script.deinit();

    var in_buf: [64 << 10]u8 = undefined;
    var out_buf: [64 << 10]u8 = undefined;
    const opts: script_mod.PeerOptions = .{ .framing = .dap, .workspace = workspace, .diag = diag };
    if (tcp) |port| {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        var server = try addr.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);
        var line_buf: [64]u8 = undefined;
        var out_w = std.Io.File.stdout().writerStreaming(io, &line_buf);
        try out_w.interface.print("listening {d}\n", .{server.socket.address.getPort()});
        try out_w.interface.flush();
        const stream = try server.accept(io);
        defer stream.close(io);
        var r = stream.reader(io, &in_buf);
        var w = stream.writer(io, &out_buf);
        return serve(io, init.gpa, &script, &r.interface, &w.interface, opts);
    }
    var r = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var w = std.Io.File.stdout().writerStreaming(io, &out_buf);
    return serve(io, init.gpa, &script, &r.interface, &w.interface, opts);
}

fn serve(io: std.Io, gpa: std.mem.Allocator, script: *const script_mod.Script, in: *std.Io.Reader, out: *std.Io.Writer, opts: script_mod.PeerOptions) u8 {
    const status = script_mod.runPeer(io, gpa, script, in, out, opts) catch |err| {
        if (opts.diag) |d| {
            d.print("fake_dap_adapter: {t}\n", .{err}) catch {};
            d.flush() catch {};
        }
        return 98;
    };
    out.flush() catch {};
    return status;
}
