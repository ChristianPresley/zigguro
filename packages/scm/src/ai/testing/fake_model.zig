//! A scripted `ModelPort` for tests: each call replays the script's
//! chunks into the sink (malformed JSON included, the fake does not
//! check), and a `Collector` sink gathers what arrives.

const std = @import("std");
const ports = @import("../ports.zig");
const Allocator = std.mem.Allocator;

pub const Chunk = union(enum) {
    text: []const u8,
    json: []const u8,
    /// Ends the call; without one the script ends with `.end`.
    done: ports.StopReason,
    /// Ends the call with an error.
    fail: []const u8,
    /// `complete` itself returns this error (the call never starts).
    refuse: void,
};

pub const FakeModel = struct {
    gpa: Allocator,
    script: []const Chunk,
    /// Number of calls so far.
    calls: usize = 0,
    /// Copies of the requests' system prompts and last messages.
    systems: std.ArrayList([]u8) = .empty,
    prompts: std.ArrayList([]u8) = .empty,
    /// Schemas asked for, null when the request had none.
    schemas: std.ArrayList(?[]u8) = .empty,

    pub fn init(gpa: Allocator, script: []const Chunk) FakeModel {
        return .{ .gpa = gpa, .script = script };
    }

    pub fn deinit(f: *FakeModel) void {
        for (f.systems.items) |s| f.gpa.free(s);
        for (f.prompts.items) |s| f.gpa.free(s);
        for (f.schemas.items) |s| if (s) |x| f.gpa.free(x);
        f.systems.deinit(f.gpa);
        f.prompts.deinit(f.gpa);
        f.schemas.deinit(f.gpa);
    }

    pub fn port(f: *FakeModel) ports.ModelPort {
        return .{ .ctx = f, .complete = complete };
    }

    fn complete(ctx: *anyopaque, req: *const ports.AiRequest, sink: *ports.AiSink) anyerror!void {
        const f: *FakeModel = @ptrCast(@alignCast(ctx));
        f.calls += 1;
        try f.systems.append(f.gpa, try f.gpa.dupe(u8, req.system));
        const last = if (req.messages.len == 0) "" else req.messages[req.messages.len - 1].text;
        try f.prompts.append(f.gpa, try f.gpa.dupe(u8, last));
        try f.schemas.append(f.gpa, if (req.json_schema) |s| try f.gpa.dupe(u8, s) else null);
        var out: ports.Usage = .{ .input_tokens = @intCast(@min(std.math.maxInt(u32), (req.system.len + last.len) / 4)) };
        for (f.script) |c| {
            if (req.cancelled()) return sink.done(.cancelled, out);
            switch (c) {
                .text => |t| {
                    out.output_tokens += @intCast(t.len / 4 + 1);
                    sink.text(t);
                },
                .json => |j| {
                    out.output_tokens += @intCast(j.len / 4 + 1);
                    sink.json(j);
                },
                .done => |r| return sink.done(r, out),
                .fail => |m| return sink.fail(m),
                .refuse => return error.ModelUnavailable,
            }
        }
        sink.done(.end, out);
    }
};

/// A sink that keeps everything it receives.
pub const Collector = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    json: std.ArrayList(u8) = .empty,
    /// Chunks received, text and JSON together.
    chunks: usize = 0,
    stop: ?ports.StopReason = null,
    usage: ports.Usage = .{},
    err: ?[]u8 = null,
    /// Set by any callback after the call finished (a port bug).
    late: bool = false,
    oom: bool = false,

    pub fn init(gpa: Allocator) Collector {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Collector) void {
        c.text.deinit(c.gpa);
        c.json.deinit(c.gpa);
        if (c.err) |e| c.gpa.free(e);
    }

    pub fn finished(c: *const Collector) bool {
        return c.stop != null or c.err != null;
    }

    pub fn sink(c: *Collector) ports.AiSink {
        return .{ .ctx = c, .onText = onText, .onJson = onJson, .onDone = onDone, .onError = onError };
    }

    fn of(ctx: *anyopaque) *Collector {
        const c: *Collector = @ptrCast(@alignCast(ctx));
        if (c.finished()) c.late = true;
        return c;
    }

    fn onText(ctx: *anyopaque, chunk: []const u8) void {
        const c = of(ctx);
        c.chunks += 1;
        c.text.appendSlice(c.gpa, chunk) catch {
            c.oom = true;
        };
    }

    fn onJson(ctx: *anyopaque, chunk: []const u8) void {
        const c = of(ctx);
        c.chunks += 1;
        c.json.appendSlice(c.gpa, chunk) catch {
            c.oom = true;
        };
    }

    fn onDone(ctx: *anyopaque, reason: ports.StopReason, usage: ports.Usage) void {
        const c = of(ctx);
        c.stop = reason;
        c.usage = usage;
    }

    fn onError(ctx: *anyopaque, message: []const u8) void {
        const c = of(ctx);
        c.err = c.gpa.dupe(u8, message) catch blk: {
            c.oom = true;
            break :blk null;
        };
    }
};

const testing = std.testing;

test "fake model: replays text, JSON, errors and cancellation" {
    const gpa = testing.allocator;
    const msgs = [_]ports.AiMessage{.{ .role = .user, .text = "describe this" }};
    var req: ports.AiRequest = .{ .system = "sys", .messages = &msgs, .json_schema = "{}", .max_input_tokens = 100 };

    var m = FakeModel.init(gpa, &.{ .{ .text = "Fix " }, .{ .text = "the parser" }, .{ .json = "{\"subject\":" }, .{ .json = "\"x\"" } });
    defer m.deinit();
    var c = Collector.init(gpa);
    defer c.deinit();
    var s = c.sink();
    try m.port().call(&req, &s);
    try testing.expectEqualStrings("Fix the parser", c.text.items);
    try testing.expectEqualStrings("{\"subject\":\"x\"", c.json.items); // malformed on purpose
    try testing.expectEqual(ports.StopReason.end, c.stop.?);
    try testing.expectEqual(@as(usize, 4), c.chunks);
    try testing.expectEqualStrings("describe this", m.prompts.items[0]);
    try testing.expectEqualStrings("{}", m.schemas.items[0].?);

    var bad = FakeModel.init(gpa, &.{ .{ .text = "par" }, .{ .fail = "overloaded" }, .{ .text = "never" } });
    defer bad.deinit();
    var c2 = Collector.init(gpa);
    defer c2.deinit();
    var s2 = c2.sink();
    try bad.port().call(&req, &s2);
    try testing.expectEqualStrings("overloaded", c2.err.?);
    try testing.expectEqualStrings("par", c2.text.items);
    try testing.expect(!c2.late);

    var flag: std.atomic.Value(bool) = .init(true);
    req.cancel = &flag;
    var c3 = Collector.init(gpa);
    defer c3.deinit();
    var s3 = c3.sink();
    try m.port().call(&req, &s3);
    try testing.expectEqual(ports.StopReason.cancelled, c3.stop.?);
    try testing.expectEqual(@as(usize, 0), c3.chunks);

    req.cancel = null;
    var refusing = FakeModel.init(gpa, &.{.refuse});
    defer refusing.deinit();
    try testing.expectError(error.ModelUnavailable, refusing.port().call(&req, &s3));
}
