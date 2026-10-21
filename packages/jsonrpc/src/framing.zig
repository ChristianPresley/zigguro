//! Message framing over `std.Io.Reader` / `std.Io.Writer`.
//!
//! - Content-Length (LSP, DAP): `Content-Length: N\r\n\r\n` then N body bytes.
//!   DAP bodies are DAP JSON, not JSON-RPC; E07 must not feed them to
//!   `message.zig`.
//! - NDJSON (MCP stdio): one JSON value per line, no embedded newlines.
//!
//! Readers return a body slice valid until the next `next` call: a zero-copy
//! slice of the reader's buffer when the body fits, otherwise the reader's
//! scratch list. `MessageTooLarge`, `BadContentLength`, `MissingContentLength`
//! and `UnsupportedCharset` leave the stream positioned at the next frame;
//! the other errors are fatal for the stream (`isFatal`). Writers flush after
//! every message because both peers may block on read.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Error = error{
    HeaderTooLong,
    MissingContentLength,
    BadContentLength,
    UnsupportedCharset,
    MessageTooLarge,
    EmbeddedNewline,
    EndOfStream,
    ReadFailed,
    WriteFailed,
    OutOfMemory,
};

/// Limits for both framings.
pub const Options = struct {
    max_message_bytes: usize = 64 << 20,
    max_header_bytes: usize = 8 << 10,
};

/// Which framing a stream uses.
pub const Framing = enum { content_length, ndjson };

/// True when the stream cannot continue after `err`.
pub fn isFatal(err: Error) bool {
    return switch (err) {
        error.MessageTooLarge, error.BadContentLength, error.MissingContentLength, error.UnsupportedCharset, error.EmbeddedNewline => false,
        else => true,
    };
}

/// Reads `Content-Length` framed messages.
pub const ContentLengthReader = struct {
    r: *Reader,
    opts: Options,
    scratch: std.ArrayList(u8) = .empty,

    pub fn init(r: *Reader, opts: Options) ContentLengthReader {
        return .{ .r = r, .opts = opts };
    }

    pub fn deinit(self: *ContentLengthReader, gpa: Allocator) void {
        self.scratch.deinit(gpa);
    }

    /// Returns the next body; valid until the next call. Uses the reader's
    /// buffer when the body fits, else `scratch` (grown with `gpa`).
    pub fn next(self: *ContentLengthReader, gpa: Allocator) Error![]const u8 {
        var header_bytes: usize = 0;
        var len: ?usize = null;
        var deferred: ?Error = null;
        var seen_header = false;
        while (true) {
            const raw = self.r.takeDelimiterInclusive('\n') catch |err| return switch (err) {
                error.StreamTooLong => error.HeaderTooLong,
                error.EndOfStream => error.EndOfStream,
                error.ReadFailed => error.ReadFailed,
            };
            header_bytes += raw.len;
            if (header_bytes > self.opts.max_header_bytes) return error.HeaderTooLong;
            const line = std.mem.trimEnd(u8, raw, "\r\n");
            if (line.len == 0) {
                // Tolerate stray blank lines between frames.
                if (!seen_header) continue;
                break;
            }
            seen_header = true;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                len = std.fmt.parseInt(usize, value, 10) catch {
                    deferred = error.BadContentLength;
                    continue;
                };
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                if (!charsetOk(value)) deferred = error.UnsupportedCharset;
            }
        }
        const n = len orelse return deferred orelse error.MissingContentLength;
        if (n > self.opts.max_message_bytes) {
            try self.discard(n);
            return error.MessageTooLarge;
        }
        if (deferred) |e| {
            try self.discard(n);
            return e;
        }
        if (n <= self.r.buffer.len) return self.r.take(n) catch |err| mapRead(err);
        self.scratch.clearRetainingCapacity();
        try self.scratch.resize(gpa, n);
        self.r.readSliceAll(self.scratch.items) catch |err| return mapRead(err);
        return self.scratch.items;
    }

    fn discard(self: *ContentLengthReader, n: usize) Error!void {
        self.r.discardAll(n) catch |err| return mapRead(err);
    }
};

fn mapRead(err: Reader.Error) Error {
    return switch (err) {
        error.EndOfStream => error.EndOfStream,
        error.ReadFailed => error.ReadFailed,
    };
}

/// Accepts a `Content-Type` value whose charset, if any, is UTF-8.
fn charsetOk(value: []const u8) bool {
    var params = std.mem.splitScalar(u8, value, ';');
    _ = params.next();
    while (params.next()) |p| {
        const t = std.mem.trim(u8, p, " \t");
        const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, t[0..eq], " \t"), "charset")) continue;
        const cs = std.mem.trim(u8, t[eq + 1 ..], " \t\"");
        return std.ascii.eqlIgnoreCase(cs, "utf-8") or std.ascii.eqlIgnoreCase(cs, "utf8");
    }
    return true;
}

/// Writes `Content-Length: N\r\n\r\n` + `body`, then flushes.
pub fn writeContentLength(w: *Writer, body: []const u8) Error!void {
    w.print("Content-Length: {d}\r\n\r\n", .{body.len}) catch return error.WriteFailed;
    w.writeAll(body) catch return error.WriteFailed;
    w.flush() catch return error.WriteFailed;
}

/// Reads newline-delimited messages. CRLF endings and blank lines are
/// accepted; the last line may end at EOF without a newline.
pub const NdjsonReader = struct {
    r: *Reader,
    opts: Options,
    scratch: std.ArrayList(u8) = .empty,

    pub fn init(r: *Reader, opts: Options) NdjsonReader {
        return .{ .r = r, .opts = opts };
    }

    pub fn deinit(self: *NdjsonReader, gpa: Allocator) void {
        self.scratch.deinit(gpa);
    }

    /// Returns the next non-blank line without its line ending; valid until
    /// the next call.
    pub fn next(self: *NdjsonReader, gpa: Allocator) Error![]const u8 {
        while (true) {
            const line = self.r.takeDelimiter('\n') catch |err| switch (err) {
                error.ReadFailed => return error.ReadFailed,
                error.StreamTooLong => try self.longLine(gpa),
            } orelse return error.EndOfStream;
            if (line.len > self.opts.max_message_bytes) return error.MessageTooLarge;
            const body = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.trim(u8, body, " \t").len == 0) continue;
            return body;
        }
    }

    /// Streams a line longer than the reader buffer into `scratch`.
    fn longLine(self: *NdjsonReader, gpa: Allocator) Error!?[]u8 {
        self.scratch.clearRetainingCapacity();
        var too_large = false;
        var any = false;
        while (true) {
            const avail = self.r.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
            };
            any = true;
            const nl = std.mem.indexOfScalar(u8, avail, '\n');
            const part = avail[0 .. nl orelse avail.len];
            if (!too_large and self.scratch.items.len + part.len > self.opts.max_message_bytes) {
                too_large = true;
                self.scratch.clearRetainingCapacity();
            }
            if (!too_large) try self.scratch.appendSlice(gpa, part);
            self.r.toss(if (nl) |i| i + 1 else avail.len);
            if (nl != null) break;
        }
        if (too_large) return error.MessageTooLarge;
        if (!any) return null;
        return self.scratch.items;
    }
};

/// Writes `body` + `\n`, then flushes. `body` must not contain a newline
/// (`std.json.Stringify` with `.minified` whitespace never emits one).
pub fn writeNdjson(w: *Writer, body: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, body, '\n') != null) return error.EmbeddedNewline;
    w.writeAll(body) catch return error.WriteFailed;
    w.writeByte('\n') catch return error.WriteFailed;
    w.flush() catch return error.WriteFailed;
}

/// Either framing behind one type, for the Endpoint.
pub const FrameReader = union(Framing) {
    content_length: ContentLengthReader,
    ndjson: NdjsonReader,

    pub fn init(framing: Framing, r: *Reader, opts: Options) FrameReader {
        return switch (framing) {
            .content_length => .{ .content_length = .init(r, opts) },
            .ndjson => .{ .ndjson = .init(r, opts) },
        };
    }

    pub fn next(self: *FrameReader, gpa: Allocator) Error![]const u8 {
        return switch (self.*) {
            inline else => |*f| f.next(gpa),
        };
    }

    pub fn deinit(self: *FrameReader, gpa: Allocator) void {
        switch (self.*) {
            inline else => |*f| f.deinit(gpa),
        }
    }
};

/// Writes one frame in `framing`, then flushes.
pub fn writeFrame(framing: Framing, w: *Writer, body: []const u8) Error!void {
    try writeFrameUnflushed(framing, w, body);
    w.flush() catch return error.WriteFailed;
}

/// Writes one frame without flushing, so a writer loop can batch frames and
/// flush once.
pub fn writeFrameUnflushed(framing: Framing, w: *Writer, body: []const u8) Error!void {
    switch (framing) {
        .content_length => w.print("Content-Length: {d}\r\n\r\n", .{body.len}) catch return error.WriteFailed,
        .ndjson => if (std.mem.indexOfScalar(u8, body, '\n') != null) return error.EmbeddedNewline,
    }
    w.writeAll(body) catch return error.WriteFailed;
    if (framing == .ndjson) w.writeByte('\n') catch return error.WriteFailed;
}

const testing = std.testing;

fn clAll(input: []const u8, opts: Options, out: *std.ArrayList(u8)) !void {
    var r: Reader = .fixed(input);
    var cl: ContentLengthReader = .init(&r, opts);
    defer cl.deinit(testing.allocator);
    while (true) {
        const body = cl.next(testing.allocator) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| {
                try out.print(testing.allocator, "!{s}|", .{@errorName(e)});
                if (isFatal(e)) return;
                continue;
            },
        };
        try out.print(testing.allocator, "{s}|", .{body});
    }
}

fn expectCl(input: []const u8, opts: Options, expected: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try clAll(input, opts, &out);
    try testing.expectEqualStrings(expected, out.items);
}

test "cl: single frame" {
    try expectCl("Content-Length: 2\r\n\r\n{}", .{}, "{}|");
}

test "cl: two frames back to back" {
    try expectCl("Content-Length: 2\r\n\r\n{}Content-Length: 3\r\n\r\n[1]", .{}, "{}|[1]|");
}

test "cl: case-insensitive header" {
    try expectCl("content-LENGTH:5\r\nX-Other: y\r\n\r\nhello", .{}, "hello|");
}

test "cl: utf8 charset alias accepted" {
    try expectCl("Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=utf8\r\n\r\n{}", .{}, "{}|");
    try expectCl("Content-Length: 2\r\nContent-Type: application/vscode-jsonrpc; charset=\"UTF-8\"\r\n\r\n{}", .{}, "{}|");
}

test "cl: latin1 rejected" {
    try expectCl("Content-Length: 2\r\nContent-Type: x; charset=latin1\r\n\r\n{}Content-Length: 1\r\n\r\n1", .{}, "!UnsupportedCharset|1|");
}

test "cl: missing length" {
    try expectCl("X-Foo: 1\r\n\r\n", .{}, "!MissingContentLength|");
    try expectCl("Content-Length: x\r\n\r\n", .{}, "!BadContentLength|");
}

test "cl: too large skips body then next frame ok" {
    try expectCl("Content-Length: 10\r\n\r\n0123456789Content-Length: 2\r\n\r\nok", .{ .max_message_bytes = 5 }, "!MessageTooLarge|ok|");
}

test "cl: header too long" {
    try expectCl("Content-Length: 2\r\nX: " ++ "a" ** 64 ++ "\r\n\r\n{}", .{ .max_header_bytes = 32 }, "!HeaderTooLong|");
}

test "cl: body larger than reader buffer" {
    const gpa = testing.allocator;
    const body = "x" ** 300;
    const input = "Content-Length: 300\r\n\r\n" ++ body ++ "Content-Length: 1\r\n\r\ny";
    var src: Reader = .fixed(input);
    var buf: [64]u8 = undefined;
    var lim = src.limited(.unlimited, &buf);
    var cl: ContentLengthReader = .init(&lim.interface, .{});
    defer cl.deinit(gpa);
    try testing.expectEqualStrings(body, try cl.next(gpa));
    try testing.expectEqualStrings("y", try cl.next(gpa));
    try testing.expectError(error.EndOfStream, cl.next(gpa));
}

test "cl: writer bytes" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeContentLength(&aw.writer, "{\"jsonrpc\":\"2.0\"}");
    try testing.expectEqualStrings("Content-Length: 17\r\n\r\n{\"jsonrpc\":\"2.0\"}", aw.written());
}

fn ndAll(r: *Reader, opts: Options, out: *std.ArrayList(u8)) !void {
    var nd: NdjsonReader = .init(r, opts);
    defer nd.deinit(testing.allocator);
    while (true) {
        const body = nd.next(testing.allocator) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| {
                try out.print(testing.allocator, "!{s}|", .{@errorName(e)});
                if (isFatal(e)) return;
                continue;
            },
        };
        try out.print(testing.allocator, "{s}|", .{body});
    }
}

fn expectNd(input: []const u8, opts: Options, expected: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var r: Reader = .fixed(input);
    try ndAll(&r, opts, &out);
    try testing.expectEqualStrings(expected, out.items);
}

test "nd: crlf stripped" {
    try expectNd("{\"a\":1}\r\n{}\n", .{}, "{\"a\":1}|{}|");
}

test "nd: blank lines skipped" {
    try expectNd("\n\r\n  \n{}\n\n", .{}, "{}|");
}

test "nd: long line > buffer" {
    const line = "y" ** 200;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var src: Reader = .fixed(line ++ "\n{}\n" ++ "z" ** 100 ++ "\n" ++ line);
    var buf: [32]u8 = undefined;
    var lim = src.limited(.unlimited, &buf);
    try ndAll(&lim.interface, .{ .max_message_bytes = 150 }, &out);
    try testing.expectEqualStrings("!MessageTooLarge|{}|" ++ "z" ** 100 ++ "|!MessageTooLarge|", out.items);
}

test "nd: EOF without newline returns last message" {
    try expectNd("{}\n[1]", .{}, "{}|[1]|");
}

test "nd: writer rejects embedded newline" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeNdjson(&aw.writer, "{\"a\":1}");
    try testing.expectError(error.EmbeddedNewline, writeNdjson(&aw.writer, "{\n}"));
    try testing.expectEqualStrings("{\"a\":1}\n", aw.written());
}

test "fuzz: content length reader" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var input: [1024]u8 = undefined;
            const n = s.slice(&input);
            var src: Reader = .fixed(input[0..n]);
            var buf: [64]u8 = undefined;
            var lim = src.limited(.unlimited, &buf);
            const opts: Options = .{ .max_message_bytes = 256, .max_header_bytes = 128 };
            var cl: ContentLengthReader = .init(&lim.interface, opts);
            defer cl.deinit(testing.allocator);
            for (0..64) |_| {
                const body = cl.next(testing.allocator) catch |err| if (isFatal(err)) break else continue;
                try testing.expect(body.len <= opts.max_message_bytes);
            }
            try testing.expect(cl.scratch.capacity <= opts.max_message_bytes * 2);
        }
    }.one, .{});
}

test "fuzz: ndjson reader" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var input: [1024]u8 = undefined;
            const n = s.slice(&input);
            var src: Reader = .fixed(input[0..n]);
            var buf: [64]u8 = undefined;
            var lim = src.limited(.unlimited, &buf);
            const opts: Options = .{ .max_message_bytes = 256 };
            var nd: NdjsonReader = .init(&lim.interface, opts);
            defer nd.deinit(testing.allocator);
            for (0..1100) |_| {
                const body = nd.next(testing.allocator) catch |err| if (isFatal(err)) break else continue;
                try testing.expect(body.len <= opts.max_message_bytes);
                try testing.expect(std.mem.indexOfScalar(u8, body, '\n') == null);
            }
            try testing.expect(nd.scratch.capacity <= opts.max_message_bytes * 2);
        }
    }.one, .{});
}
