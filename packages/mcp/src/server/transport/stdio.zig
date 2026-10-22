//! The stdio server transport (E11.F05.S02.T01, STDIO): NDJSON requests on
//! stdin, only MCP messages on stdout (`std.log` already writes to
//! stderr), and a graceful exit at stdin EOF: running calls get
//! `drain_timeout` to finish, then are canceled.

const std = @import("std");
const Io = std.Io;
const Server = @import("../Server.zig");

pub const StdioServerOptions = struct {
    stdin: Io.File,
    stdout: Io.File,
    /// The longest message accepted.
    max_message_bytes: usize = 16 * 1024 * 1024,
    drain_timeout: Io.Duration = .fromSeconds(2),
};

/// Serves `s` on stdin/stdout until stdin ends. Blocks.
pub fn serveStdio(s: *Server, opts: StdioServerOptions) !void {
    var out: FileSink = .{ .io = s.io, .file = opts.stdout };
    const buf = try s.gpa.alloc(u8, opts.max_message_bytes);
    defer s.gpa.free(buf);
    var r = opts.stdin.readerStreaming(s.io, buf);
    return serveStream(s, &r.interface, out.sink(), opts.drain_timeout);
}

/// Serves `s` on any NDJSON reader and message sink until `in` ends.
pub fn serveStream(s: *Server, in: *Io.Reader, out: Server.Sink, drain_timeout: Io.Duration) !void {
    const conn = try s.connect(out, null);
    defer s.disconnect(conn);
    while (true) {
        const line = in.takeDelimiter('\n') catch |err| switch (err) {
            // A message longer than the buffer: skip to the next line.
            error.StreamTooLong => {
                _ = in.discardDelimiterInclusive('\n') catch break;
                continue;
            },
            else => break,
        } orelse break;
        const msg = std.mem.trimEnd(u8, line, "\r");
        if (msg.len == 0) continue;
        conn.receive(msg);
    }
    drain(s, conn, drain_timeout);
}

/// Waits for `conn`'s running calls, up to `timeout`.
fn drain(s: *Server, conn: *Server.Conn, timeout: Io.Duration) void {
    const deadline = Io.Timestamp.now(s.io, .awake).addDuration(timeout);
    while (Io.Timestamp.now(s.io, .awake).nanoseconds < deadline.nanoseconds) {
        conn.mutex.lockUncancelable(s.io);
        const busy = conn.inflight.items.len > 0;
        conn.mutex.unlock(s.io);
        if (!busy) return;
        s.io.sleep(.fromMilliseconds(5), .awake) catch return;
    }
}

const FileSink = struct {
    io: Io,
    file: Io.File,
    mutex: Io.Mutex = .init,

    fn sink(f: *FileSink) Server.Sink {
        return .{ .ctx = f, .send = send };
    }

    fn send(ctx: ?*anyopaque, body: []const u8) void {
        const f: *FileSink = @ptrCast(@alignCast(ctx.?));
        f.mutex.lockUncancelable(f.io);
        defer f.mutex.unlock(f.io);
        f.file.writeStreamingAll(f.io, body) catch return;
        f.file.writeStreamingAll(f.io, "\n") catch return;
    }
};
