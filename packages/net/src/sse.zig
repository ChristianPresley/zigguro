//! An incremental parser for `text/event-stream` (WHATWG HTML, "Server-sent
//! events", event stream interpretation).
//!
//! Feed it chunks with arbitrary boundaries; it calls `sink.onEvent` for
//! every dispatched event. Buffers are reused across events, so after warmup
//! parsing allocates nothing. Event slices are valid only during the
//! callback.
//!
//! `lastEventId` follows the spec (it persists across events) but MCP
//! 2026-07-28 removed SSE resumability, so E11 must not rely on reconnecting
//! with `Last-Event-ID`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Event = struct {
    /// The event type; `message` when the stream gave none.
    type: []const u8,
    data: []const u8,
    /// The last event id seen on the stream, if any.
    id: ?[]const u8,
    /// A `retry` value given in this event's block.
    retry_ms: ?u64,
};

pub const Options = struct { max_event_bytes: usize = 16 << 20 };

pub const Error = error{ EventTooLarge, OutOfMemory };

const bom = "\xEF\xBB\xBF";

pub const Parser = struct {
    gpa: Allocator,
    opts: Options,
    line: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    event_type: std.ArrayList(u8) = .empty,
    last_id: std.ArrayList(u8) = .empty,
    retry: ?u64 = null,
    reconnection_ms: ?u64 = null,
    bom_pos: u2 = 0,
    bom_done: bool = false,
    pending_cr: bool = false,

    pub fn init(gpa: Allocator, opts: Options) Parser {
        return .{ .gpa = gpa, .opts = opts };
    }

    pub fn deinit(self: *Parser) void {
        self.line.deinit(self.gpa);
        self.data.deinit(self.gpa);
        self.event_type.deinit(self.gpa);
        self.last_id.deinit(self.gpa);
        self.* = undefined;
    }

    /// Parses `chunk`. `sink` is any value with
    /// `fn onEvent(self, Event) anyerror!void` (usually a pointer).
    pub fn feed(self: *Parser, chunk: []const u8, sink: anytype) !void {
        var rest = chunk;
        // One leading U+FEFF is stripped, even when split across chunks.
        while (!self.bom_done and rest.len > 0) {
            if (rest[0] == bom[self.bom_pos]) {
                rest = rest[1..];
                if (self.bom_pos == 2) self.bom_done = true else self.bom_pos += 1;
            } else {
                self.bom_done = true;
                const partial = bom[0..self.bom_pos];
                if (partial.len > 0) try self.process(partial, sink);
            }
        }
        if (rest.len == 0) return;
        if (self.pending_cr) {
            self.pending_cr = false;
            if (rest[0] == '\n') rest = rest[1..];
        }
        try self.process(rest, sink);
    }

    /// End of stream: an incomplete event is discarded (per spec).
    pub fn finish(self: *Parser) void {
        self.line.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
        self.event_type.clearRetainingCapacity();
        self.retry = null;
        self.pending_cr = false;
    }

    /// The last event id buffer; persists across events.
    pub fn lastEventId(self: *const Parser) []const u8 {
        return self.last_id.items;
    }

    /// The most recent valid `retry` value on the stream.
    pub fn reconnectionTime(self: *const Parser) ?u64 {
        return self.reconnection_ms;
    }

    fn process(self: *Parser, bytes: []const u8, sink: anytype) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            const j = findEol(bytes, i) orelse {
                if (self.line.items.len + bytes.len - i > self.opts.max_event_bytes) return error.EventTooLarge;
                try self.line.appendSlice(self.gpa, bytes[i..]);
                return;
            };
            if (self.line.items.len > 0) {
                if (self.line.items.len + j - i > self.opts.max_event_bytes) return error.EventTooLarge;
                try self.line.appendSlice(self.gpa, bytes[i..j]);
                try self.processLine(self.line.items, sink);
                self.line.clearRetainingCapacity();
            } else {
                try self.processLine(bytes[i..j], sink);
            }
            if (bytes[j] == '\r') {
                if (j + 1 == bytes.len) {
                    self.pending_cr = true;
                    return;
                }
                i = if (bytes[j + 1] == '\n') j + 2 else j + 1;
            } else {
                i = j + 1;
            }
        }
    }

    fn processLine(self: *Parser, line: []const u8, sink: anytype) !void {
        if (line.len == 0) return self.dispatch(sink);
        if (line[0] == ':') return;
        var field = line;
        var value: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, ':')) |c| {
            field = line[0..c];
            value = line[c + 1 ..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
        }
        if (std.mem.eql(u8, field, "data")) {
            if (self.data.items.len + self.event_type.items.len + value.len + 1 > self.opts.max_event_bytes) return error.EventTooLarge;
            try self.data.ensureUnusedCapacity(self.gpa, value.len + 1);
            self.data.appendSliceAssumeCapacity(value);
            self.data.appendAssumeCapacity('\n');
        } else if (std.mem.eql(u8, field, "event")) {
            self.event_type.clearRetainingCapacity();
            try self.event_type.appendSlice(self.gpa, value);
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.indexOfScalar(u8, value, 0) == null) {
                self.last_id.clearRetainingCapacity();
                try self.last_id.appendSlice(self.gpa, value);
            }
        } else if (std.mem.eql(u8, field, "retry")) {
            if (value.len > 0 and allDigits(value)) {
                if (std.fmt.parseInt(u64, value, 10)) |ms| {
                    self.retry = ms;
                    self.reconnection_ms = ms;
                } else |_| {}
            }
        }
    }

    fn dispatch(self: *Parser, sink: anytype) !void {
        defer {
            self.data.clearRetainingCapacity();
            self.event_type.clearRetainingCapacity();
            self.retry = null;
        }
        if (self.data.items.len == 0) return;
        const ev: Event = .{
            .type = if (self.event_type.items.len > 0) self.event_type.items else "message",
            .data = self.data.items[0 .. self.data.items.len - 1],
            .id = if (self.last_id.items.len > 0) self.last_id.items else null,
            .retry_ms = self.retry,
        };
        try sink.onEvent(ev);
    }
};

fn allDigits(s: []const u8) bool {
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// The index of the first CR or LF at or after `start`.
fn findEol(s: []const u8, start: usize) ?usize {
    const V = @Vector(32, u8);
    var i = start;
    while (i + 32 <= s.len) : (i += 32) {
        const v: V = s[i..][0..32].*;
        const hit = (v == @as(V, @splat('\n'))) | (v == @as(V, @splat('\r')));
        const mask: u32 = @bitCast(hit);
        if (mask != 0) return i + @ctz(mask);
    }
    while (i < s.len) : (i += 1) {
        if (s[i] == '\n' or s[i] == '\r') return i;
    }
    return null;
}

const testing = std.testing;

/// Records events as `type|data|id|retry;` for comparisons.
const Recorder = struct {
    out: std.ArrayList(u8) = .empty,
    count: usize = 0,

    fn onEvent(self: *Recorder, ev: Event) !void {
        self.count += 1;
        try self.out.print(testing.allocator, "{s}|{s}|{s}|", .{ ev.type, ev.data, ev.id orelse "-" });
        if (ev.retry_ms) |r| try self.out.print(testing.allocator, "{d}", .{r});
        try self.out.append(testing.allocator, ';');
    }

    fn deinit(self: *Recorder) void {
        self.out.deinit(testing.allocator);
    }
};

fn expectEvents(input: []const u8, expected: []const u8) !void {
    var p: Parser = .init(testing.allocator, .{});
    defer p.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    try p.feed(input, &rec);
    p.finish();
    try testing.expectEqualStrings(expected, rec.out.items);
    // Byte-at-a-time feeding must give the same events.
    var p2: Parser = .init(testing.allocator, .{});
    defer p2.deinit();
    var rec2: Recorder = .{};
    defer rec2.deinit();
    for (0..input.len) |i| try p2.feed(input[i..][0..1], &rec2);
    p2.finish();
    try testing.expectEqualStrings(expected, rec2.out.items);
}

test "sse: stock example (multi-line data)" {
    try expectEvents("data: YHOO\ndata: +2\ndata: 10\n\n", "message|YHOO\n+2\n10|-|;");
}

test "sse: comments and ids" {
    try expectEvents(
        ": test stream\n\ndata: first event\nid: 1\n\ndata:second event\nid\n\ndata:  third event\n\n",
        "message|first event|1|;message|second event|-|;message| third event|-|;",
    );
}

test "sse: empty data fields" {
    try expectEvents("data\n\ndata\ndata\n\ndata:\n", "message||-|;message|\n|-|;");
}

test "sse: space after colon is optional" {
    try expectEvents("data:test\n\ndata: test\n\n", "message|test|-|;message|test|-|;");
}

test "sse: event type, id with NUL ignored, retry" {
    try expectEvents("event: add\nid: 7\nretry: 1500\ndata: x\n\nid: a\x00b\nretry: 12x\ndata: y\n\n", "add|x|7|1500;message|y|7|;");
}

test "sse: incomplete event at EOF discarded" {
    try expectEvents("data: done\n\ndata: partial", "message|done|-|;");
}

test "sse: blank block without data dispatches nothing" {
    try expectEvents("event: ping\n\n: keepalive\n\n", "");
}

test "sse: BOM split across chunks" {
    var p: Parser = .init(testing.allocator, .{});
    defer p.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    try p.feed("\xEF", &rec);
    try p.feed("\xBB", &rec);
    try p.feed("\xBFdata: a\n\n\xEF\xBB\xBFdata: b\n\n", &rec);
    // Only the first BOM is stripped; the second starts a field name.
    try testing.expectEqualStrings("message|a|-|;", rec.out.items);
}

test "sse: CR, LF and CRLF line endings split across chunks" {
    var p: Parser = .init(testing.allocator, .{});
    defer p.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    try p.feed("data: a\r", &rec);
    try p.feed("\ndata: b\r", &rec);
    try p.feed("\r", &rec);
    try p.feed("data: c\n\r\n", &rec);
    try testing.expectEqualStrings("message|a\nb|-|;message|c|-|;", rec.out.items);
}

test "sse: event too large" {
    var p: Parser = .init(testing.allocator, .{ .max_event_bytes = 16 });
    defer p.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    try testing.expectError(error.EventTooLarge, p.feed("data: 0123456789abcdef\n", &rec));
}

test "sse: Anthropic streaming fixture" {
    const fixture = @embedFile("testdata/anthropic_stream.txt");
    var p: Parser = .init(testing.allocator, .{});
    defer p.deinit();
    const Types = struct {
        names: std.ArrayList(u8) = .empty,
        fn onEvent(self: *@This(), ev: Event) !void {
            try self.names.print(testing.allocator, "{s},", .{ev.type});
            if (std.mem.eql(u8, ev.type, "content_block_delta")) {
                try testing.expect(std.mem.indexOf(u8, ev.data, "\"text_delta\"") != null);
            }
        }
    };
    var t: Types = .{};
    defer t.names.deinit(testing.allocator);
    try p.feed(fixture, &t);
    p.finish();
    try testing.expectEqualStrings(
        "message_start,content_block_start,ping,content_block_delta,content_block_delta,content_block_stop,message_delta,message_stop,",
        t.names.items,
    );
}

test "sse: zero allocations per event after warmup" {
    var counting: @import("zg_core").alloc.CountingAllocator = .init(testing.allocator);
    var p: Parser = .init(counting.allocator(), .{});
    defer p.deinit();
    var rec: struct {
        n: usize = 0,
        fn onEvent(self: *@This(), _: Event) !void {
            self.n += 1;
        }
    } = .{};
    try p.feed("event: x\nid: 1\ndata: warm up the buffers\n\n", &rec);
    const before = counting.allocs.load(.monotonic);
    for (0..100) |_| try p.feed("event: x\nid: 2\ndata: hello\ndata: world\n\n", &rec);
    try testing.expectEqual(before, counting.allocs.load(.monotonic));
    try testing.expectEqual(@as(usize, 101), rec.n);
}

test "fuzz: sse parser" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var chunks: [8][]const u8 = undefined;
            const parts = @import("zg_core").testkit.fuzz.chunked(s, input, 8, &chunks);
            const opts: Options = .{ .max_event_bytes = 256 };
            var whole: Parser = .init(testing.allocator, opts);
            defer whole.deinit();
            var split: Parser = .init(testing.allocator, opts);
            defer split.deinit();
            var a: Recorder = .{};
            defer a.deinit();
            var b: Recorder = .{};
            defer b.deinit();
            const ra = whole.feed(input, &a);
            var rb: anyerror!void = {};
            for (parts) |part| {
                rb = split.feed(part, &b);
                if (rb) |_| {} else |_| break;
            }
            // Random chunking yields identical events (unless a limit tripped).
            if (ra) |_| {
                if (rb) |_| try testing.expectEqualStrings(a.out.items, b.out.items) else |_| {}
            } else |_| {}
            try testing.expect(whole.data.capacity <= 4 * opts.max_event_bytes);
        }
    }.one, .{});
}
