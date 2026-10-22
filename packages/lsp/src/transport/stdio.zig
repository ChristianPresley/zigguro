//! A transport over a child process's stdin (we write) and stdout (we
//! read). The pipes are not seekable, so it uses the streaming reader and
//! writer of `std.Io.File`.

const std = @import("std");
const Io = std.Io;
const Transport = @import("Transport.zig");

/// Owns the two pipe ends.
pub const StdioTransport = struct {
    transport: Transport,
    gpa: std.mem.Allocator,
    io: Io,
    stdin: ?Io.File,
    stdout: Io.File,
    mutex: Io.Mutex = .init,
    r: Io.File.Reader,
    w: Io.File.Writer,
    read_buf: [Transport.buffer_size]u8,
    write_buf: [Transport.buffer_size]u8,

    const vtable: Transport.VTable = .{ .close = closeImpl, .deinit = deinitImpl };

    /// Takes ownership of `stdin` (the child's input, our write end) and
    /// `stdout` (the child's output, our read end).
    pub fn create(gpa: std.mem.Allocator, io: Io, stdin: Io.File, stdout: Io.File) !*StdioTransport {
        const s = try gpa.create(StdioTransport);
        s.* = .{
            .transport = undefined,
            .gpa = gpa,
            .io = io,
            .stdin = stdin,
            .stdout = stdout,
            .r = undefined,
            .w = undefined,
            .read_buf = undefined,
            .write_buf = undefined,
        };
        s.r = stdout.readerStreaming(io, &s.read_buf);
        s.w = stdin.writerStreaming(io, &s.write_buf);
        s.transport = .{ .reader = &s.r.interface, .writer = &s.w.interface, .vtable = &vtable };
        return s;
    }

    fn closeImpl(t: *Transport) void {
        const s: *StdioTransport = @alignCast(@fieldParentPtr("transport", t));
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        if (s.stdin) |f| {
            f.close(s.io);
            s.stdin = null;
        }
    }

    fn deinitImpl(t: *Transport) void {
        closeImpl(t);
        const s: *StdioTransport = @alignCast(@fieldParentPtr("transport", t));
        s.stdout.close(s.io);
        s.gpa.destroy(s);
    }
};
