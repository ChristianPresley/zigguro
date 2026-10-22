//! A tiny MCP-ish stdio server for transport tests. Reads NDJSON requests
//! from stdin and acts on the method:
//!
//! - `initialize`: a legacy (2025-06-18) server; `server/discover` and any
//!   other unknown method get `-32601`.
//! - `ping`: answers `{}`.
//! - `echo`: answers `{"echo": <params>}`.
//! - `slow`: never answers (cancellation tests).
//! - `stderr`: writes `params.bytes` bytes of `x` (in lines) to stderr, then
//!   answers `{}`.
//! - `big`: answers with a result string of `params.bytes` bytes.
//! - `spawn`: starts a grandchild (this program with `--sleep`) and answers
//!   `{"pid": <pid>}`.
//! - `crash`: exits with status 3.
//! - `notifications/cancelled`: writes `cancelled <requestId>` to stderr.
//! - `ask`: sends a `ping` request to the client first, then answers once
//!   the client's reply arrives.
//!
//! Flags: `--crash-on-start` (stderr "boom", exit 2), `--ignore-term`
//! (ignore SIGTERM and stdin EOF), `--sleep` (sleep forever; the grandchild).

const std = @import("std");
const Io = std.Io;
const Value = std.json.Value;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    const self_path = args.next() orelse "echo_server";
    var ignore_term = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--crash-on-start")) {
            try Io.File.stderr().writeStreamingAll(io, "boom: crashing on start\n");
            return 2;
        }
        if (std.mem.eql(u8, a, "--sleep")) {
            while (true) try io.sleep(.fromSeconds(3600), .awake);
        }
        if (std.mem.eql(u8, a, "--ignore-term")) {
            ignore_term = true;
            if (@import("builtin").os.tag == .windows) continue;
            const act: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(.TERM, &act, null);
        }
    }

    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var in = Io.File.stdin().readerStreaming(io, &in_buf);
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;
    var pending_ask: ?[]u8 = null;
    defer if (pending_ask) |p| gpa.free(p);

    while (true) {
        const maybe_line = in.interface.takeDelimiter('\n') catch return 1;
        const line = maybe_line orelse {
            // A stubborn server: outlive stdin EOF so close must escalate.
            if (ignore_term) while (true) try io.sleep(.fromSeconds(3600), .awake);
            return 0;
        };
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const msg = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch continue;
        if (msg != .object) continue;
        const o = msg.object;
        const id = o.get("id");
        const method = if (o.get("method")) |m| m.string else {
            // A reply to our `ping`: answer the pending `ask`.
            if (pending_ask) |p| {
                try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"asked\":true}}}}\n", .{p});
                try w.flush();
                gpa.free(p);
                pending_ask = null;
            }
            continue;
        };
        const params = o.get("params") orelse Value{ .null = {} };
        const id_json = if (id) |i| try std.json.Stringify.valueAlloc(a, i, .{}) else "null";
        if (std.mem.eql(u8, method, "notifications/cancelled")) {
            const rid = try std.json.Stringify.valueAlloc(a, params.object.get("requestId").?, .{});
            var ebuf: [128]u8 = undefined;
            try Io.File.stderr().writeStreamingAll(io, try std.fmt.bufPrint(&ebuf, "cancelled {s}\n", .{rid}));
            continue;
        }
        if (id == null) continue;
        if (std.mem.eql(u8, method, "echo")) {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"echo\":{f}}}}}\n", .{ id_json, std.json.fmt(params, .{}) });
        } else if (std.mem.eql(u8, method, "initialize")) {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{}},\"serverInfo\":{{\"name\":\"echo\",\"version\":\"1\"}}}}}}\n", .{id_json});
        } else if (std.mem.eql(u8, method, "ping")) {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}\n", .{id_json});
        } else if (std.mem.eql(u8, method, "slow")) {
            continue;
        } else if (std.mem.eql(u8, method, "crash")) {
            return 3;
        } else if (std.mem.eql(u8, method, "stderr")) {
            const n: usize = @intCast(params.object.get("bytes").?.integer);
            var chunk: [100]u8 = undefined;
            @memset(chunk[0..99], 'x');
            chunk[99] = '\n';
            var left = n;
            const err = Io.File.stderr();
            while (left > 0) {
                const k = @min(left, chunk.len);
                try err.writeStreamingAll(io, chunk[chunk.len - k ..]);
                left -= k;
            }
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}\n", .{id_json});
        } else if (std.mem.eql(u8, method, "big")) {
            const n: usize = @intCast(params.object.get("bytes").?.integer);
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":\"", .{id_json});
            try w.splatByteAll('y', n);
            try w.writeAll("\"}\n");
        } else if (std.mem.eql(u8, method, "spawn")) {
            const child = try std.process.spawn(io, .{
                .argv = &.{ self_path, "--sleep" },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"pid\":{d}}}}}\n", .{ id_json, if (@import("builtin").os.tag == .windows) 0 else child.id.? });
        } else if (std.mem.eql(u8, method, "ask")) {
            pending_ask = try gpa.dupe(u8, id_json);
            try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":\"srv-1\",\"method\":\"ping\"}\n");
        } else {
            try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"Method not found\"}}}}\n", .{id_json});
        }
        try w.flush();
    }
}
