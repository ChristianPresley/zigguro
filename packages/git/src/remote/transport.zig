//! Connections to a git server's upload-pack or receive-pack (E09.F08).
//!
//! A `Connection` is a pair of streams plus `endRequest`. Over a pipe or
//! SSH channel the streams are the process's stdout and stdin and
//! `endRequest` only flushes; over smart HTTP (stateless) each request
//! is buffered and sent as one POST when `endRequest` is called, and the
//! reader then returns its response. Before the first request the reader
//! returns the server's advertisement (protocol v2 capabilities, or the
//! v0 ref advertisement for receive-pack).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Service = enum {
    upload_pack,
    receive_pack,

    pub fn name(s: Service) []const u8 {
        return switch (s) {
            .upload_pack => "git-upload-pack",
            .receive_pack => "git-receive-pack",
        };
    }
};

pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reader: *const fn (ptr: *anyopaque) *Io.Reader,
        writer: *const fn (ptr: *anyopaque) *Io.Writer,
        end_request: *const fn (ptr: *anyopaque) anyerror!void,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn reader(c: Connection) *Io.Reader {
        return c.vtable.reader(c.ptr);
    }

    pub fn writer(c: Connection) *Io.Writer {
        return c.vtable.writer(c.ptr);
    }

    /// Sends what was written as one request.
    pub fn endRequest(c: Connection) !void {
        return c.vtable.end_request(c.ptr);
    }

    pub fn close(c: Connection) void {
        c.vtable.close(c.ptr);
    }
};

/// Buffer size for connection readers: one whole pkt-line must fit.
pub const read_buffer_len = @import("../proto/pktline.zig").max_pkt + 4096;

/// A server run as a local process speaking on its stdin and stdout:
/// `git upload-pack <dir>` for tests, or an `ext::` command.
pub const Process = struct {
    gpa: Allocator,
    io: Io,
    child: std.process.Child,
    stdin: ?Io.File,
    stdout: Io.File,
    rbuf: []u8,
    wbuf: [64 * 1024]u8 = undefined,
    file_reader: Io.File.Reader,
    file_writer: Io.File.Writer,

    pub fn spawn(gpa: Allocator, io: Io, argv: []const []const u8, cwd: ?[]const u8, env: ?*const std.process.Environ.Map) !*Process {
        const p = try gpa.create(Process);
        errdefer gpa.destroy(p);
        p.rbuf = try gpa.alloc(u8, read_buffer_len);
        errdefer gpa.free(p.rbuf);
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = if (cwd) |c| .{ .path = c } else .inherit,
            .environ_map = env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
            .create_no_window = true,
        });
        p.* = .{
            .gpa = gpa,
            .io = io,
            .child = child,
            .stdin = child.stdin,
            .stdout = child.stdout.?,
            .rbuf = p.rbuf,
            .file_reader = undefined,
            .file_writer = undefined,
        };
        p.child.stdin = null;
        p.child.stdout = null;
        _ = &child;
        p.file_reader = p.stdout.readerStreaming(io, p.rbuf);
        p.file_writer = p.stdin.?.writerStreaming(io, &p.wbuf);
        return p;
    }

    pub fn connection(p: *Process) Connection {
        return .{ .ptr = p, .vtable = &.{ .reader = reader, .writer = writer, .end_request = endRequest, .close = close } };
    }

    fn reader(ptr: *anyopaque) *Io.Reader {
        const p: *Process = @ptrCast(@alignCast(ptr));
        return &p.file_reader.interface;
    }

    fn writer(ptr: *anyopaque) *Io.Writer {
        const p: *Process = @ptrCast(@alignCast(ptr));
        return &p.file_writer.interface;
    }

    fn endRequest(ptr: *anyopaque) anyerror!void {
        const p: *Process = @ptrCast(@alignCast(ptr));
        try p.file_writer.interface.flush();
    }

    fn close(ptr: *anyopaque) void {
        const p: *Process = @ptrCast(@alignCast(ptr));
        if (p.stdin) |f| f.close(p.io);
        p.stdin = null;
        p.stdout.close(p.io);
        _ = p.child.wait(p.io) catch {};
        p.gpa.free(p.rbuf);
        p.gpa.destroy(p);
    }
};
