//! Test transports for JSON-RPC peers (used by E07 and E11 tests too).
//!
//! - `PipePair`: two in-memory byte channels on `std.Io.Queue(u8)`, exposed
//!   as `std.Io.Reader` / `std.Io.Writer`. Side a reads what side b writes
//!   and vice versa. Reads block until data arrives or the writing side
//!   closes (then `EndOfStream`); writes block while the channel is full.
//! - `ScriptedPeer`: plays a golden script against one side of a pipe:
//!   `> {json}` sends a frame, `< {json}` expects the next frame to equal it.
//!   Blank lines and lines starting with `#` are ignored.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const framing = @import("framing.zig");

/// One direction of a pipe.
const Channel = struct {
    queue: Io.Queue(u8),
    storage: []u8,
};

const PipeReader = struct {
    interface: Io.Reader,
    io: Io,
    chan: *Channel,

    const vtable: Io.Reader.VTable = .{ .stream = stream };

    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *PipeReader = @fieldParentPtr("interface", r);
        if (r.end == r.buffer.len) {
            if (r.seek == 0) {
                // The buffer is full: hand bytes to `w` directly.
                var tmp: [256]u8 = undefined;
                const dst = limit.slice(&tmp);
                if (dst.len == 0) return 0;
                const n = try self.get(dst);
                try w.writeAll(dst[0..n]);
                return n;
            }
            const live = r.buffer[r.seek..r.end];
            @memmove(r.buffer[0..live.len], live);
            r.end = live.len;
            r.seek = 0;
        }
        r.end += try self.get(r.buffer[r.end..]);
        return 0;
    }

    fn get(self: *PipeReader, dst: []u8) Io.Reader.StreamError!usize {
        return self.chan.queue.get(self.io, dst, 1) catch |err| switch (err) {
            error.Closed => error.EndOfStream,
            error.Canceled => error.ReadFailed,
        };
    }
};

const PipeWriter = struct {
    interface: Io.Writer,
    io: Io,
    chan: *Channel,

    const vtable: Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *PipeWriter = @fieldParentPtr("interface", w);
        try self.put(w.buffer[0..w.end]);
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            try self.put(d);
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.put(last);
            n += last.len;
        }
        return n;
    }

    fn put(self: *PipeWriter, bytes: []const u8) Io.Writer.Error!void {
        if (bytes.len == 0) return;
        self.chan.queue.putAll(self.io, bytes) catch return error.WriteFailed;
    }
};

/// Two connected in-memory byte streams.
pub const PipePair = struct {
    a_reader: *Io.Reader,
    a_writer: *Io.Writer,
    b_reader: *Io.Reader,
    b_writer: *Io.Writer,

    gpa: Allocator,
    io: Io,
    ab: Channel,
    ba: Channel,
    ar: PipeReader,
    aw: PipeWriter,
    br: PipeReader,
    bw: PipeWriter,
    bufs: [4][4096]u8,

    /// A pair whose channels each hold `capacity` bytes.
    pub fn init(gpa: Allocator, io: Io, capacity: usize) !*PipePair {
        const p = try gpa.create(PipePair);
        errdefer gpa.destroy(p);
        const ab = try gpa.alloc(u8, capacity);
        errdefer gpa.free(ab);
        const ba = try gpa.alloc(u8, capacity);
        p.gpa = gpa;
        p.io = io;
        p.ab = .{ .queue = .init(ab), .storage = ab };
        p.ba = .{ .queue = .init(ba), .storage = ba };
        p.ar = .{ .interface = .{ .vtable = &PipeReader.vtable, .buffer = &p.bufs[0], .seek = 0, .end = 0 }, .io = io, .chan = &p.ba };
        p.br = .{ .interface = .{ .vtable = &PipeReader.vtable, .buffer = &p.bufs[1], .seek = 0, .end = 0 }, .io = io, .chan = &p.ab };
        p.aw = .{ .interface = .{ .vtable = &PipeWriter.vtable, .buffer = &p.bufs[2] }, .io = io, .chan = &p.ab };
        p.bw = .{ .interface = .{ .vtable = &PipeWriter.vtable, .buffer = &p.bufs[3] }, .io = io, .chan = &p.ba };
        p.a_reader = &p.ar.interface;
        p.b_reader = &p.br.interface;
        p.a_writer = &p.aw.interface;
        p.b_writer = &p.bw.interface;
        return p;
    }

    /// Side a stops writing: side b reads `EndOfStream` after the buffered bytes.
    pub fn closeA(p: *PipePair) void {
        p.ab.queue.close(p.io);
    }

    /// Side b stops writing.
    pub fn closeB(p: *PipePair) void {
        p.ba.queue.close(p.io);
    }

    pub fn deinit(p: *PipePair) void {
        p.gpa.free(p.ab.storage);
        p.gpa.free(p.ba.storage);
        p.gpa.destroy(p);
    }
};

/// Plays a golden script against a peer.
pub const ScriptedPeer = struct {
    gpa: Allocator,
    reader: framing.FrameReader,
    writer: *Io.Writer,
    framing: framing.Framing,
    /// Set on mismatch: the line number and what arrived instead.
    failure: ?struct { line: usize, got: []u8 } = null,

    pub fn init(gpa: Allocator, f: framing.Framing, r: *Io.Reader, w: *Io.Writer) ScriptedPeer {
        return .{ .gpa = gpa, .reader = .init(f, r, .{}), .writer = w, .framing = f };
    }

    pub fn deinit(self: *ScriptedPeer) void {
        self.reader.deinit(self.gpa);
        if (self.failure) |f| self.gpa.free(f.got);
    }

    /// Runs `script`; returns `error.ScriptMismatch` (see `failure`) when an
    /// expected frame differs.
    pub fn run(self: *ScriptedPeer, script: []const u8) !void {
        var lines = std.mem.splitScalar(u8, script, '\n');
        var n: usize = 0;
        while (lines.next()) |raw| {
            n += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line.len < 2 or line[1] != ' ') return error.BadScript;
            const json = line[2..];
            switch (line[0]) {
                '>' => try framing.writeFrame(self.framing, self.writer, json),
                '<' => {
                    const got = try self.reader.next(self.gpa);
                    if (!std.mem.eql(u8, got, json)) {
                        self.failure = .{ .line = n, .got = try self.gpa.dupe(u8, got) };
                        return error.ScriptMismatch;
                    }
                },
                else => return error.BadScript,
            }
        }
    }
};

test "pipe: bytes flow both ways and close ends the stream" {
    const gpa = std.testing.allocator;
    const p = try PipePair.init(gpa, std.testing.io, 64);
    defer p.deinit();
    try p.a_writer.writeAll("hello\n");
    try p.a_writer.flush();
    try std.testing.expectEqualStrings("hello", (try p.b_reader.takeDelimiter('\n')).?);
    try p.b_writer.writeAll("x");
    try p.b_writer.flush();
    p.closeB();
    try std.testing.expectEqualStrings("x", (try p.a_reader.takeDelimiter('\n')).?);
    try std.testing.expect(try p.a_reader.takeDelimiter('\n') == null);
}

test "pipe: frames larger than the channel and the reader buffer" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const p = try PipePair.init(gpa, io, 128);
    defer p.deinit();
    const body = try gpa.alloc(u8, 10_000);
    defer gpa.free(body);
    @memset(body, 'q');
    const Writer = struct {
        fn run(w: *Io.Writer, b: []const u8, pp: *PipePair) Io.Cancelable!void {
            framing.writeContentLength(w, b) catch {};
            pp.closeA();
        }
    };
    var fut = try io.concurrent(Writer.run, .{ p.a_writer, body, p });
    defer fut.cancel(io) catch {};
    var cl: framing.ContentLengthReader = .init(p.b_reader, .{});
    defer cl.deinit(gpa);
    try std.testing.expectEqualSlices(u8, body, try cl.next(gpa));
    try std.testing.expectError(error.EndOfStream, cl.next(gpa));
}

test "scripted peer: send and expect" {
    const gpa = std.testing.allocator;
    const p = try PipePair.init(gpa, std.testing.io, 4096);
    defer p.deinit();
    var peer: ScriptedPeer = .init(gpa, .ndjson, p.b_reader, p.b_writer);
    defer peer.deinit();
    try framing.writeNdjson(p.a_writer, "{\"a\":1}");
    try peer.run(
        \\# comment
        \\< {"a":1}
        \\> {"b":2}
    );
    var nd: framing.NdjsonReader = .init(p.a_reader, .{});
    defer nd.deinit(gpa);
    try std.testing.expectEqualStrings("{\"b\":2}", try nd.next(gpa));
    try framing.writeNdjson(p.a_writer, "{\"a\":3}");
    try std.testing.expectError(error.ScriptMismatch, peer.run("< {\"a\":1}"));
    try std.testing.expectEqualStrings("{\"a\":3}", peer.failure.?.got);
}
