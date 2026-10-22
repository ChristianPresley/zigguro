//! Prompt-cache planning checks and a simulator of Anthropic's documented
//! caching semantics (E10.F02.S02.T01): prefixes cached in the order tools →
//! system → messages, a prefix hash per breakpoint, 20-block lookback, TTLs
//! and a per-model minimum cacheable length. Used to test context assembly
//! (F07) and to estimate hit rates offline.

const std = @import("std");
const proto = @import("zg_ai_proto");
const request = @import("../request.zig");
const encode = @import("encode.zig");

const Allocator = std.mem.Allocator;
const Request = request.Request;

/// Plan validation failures.
pub const PlanError = error{ TooManyCacheBreakpoints, BreakpointOutOfRange, BreakpointOnEmptyMessage };

/// Checks a request's breakpoints: at most 4, and every target exists.
pub fn validatePlan(req: *const Request) PlanError!void {
    if (encode.breakpointCount(req) > encode.max_breakpoints) return error.TooManyCacheBreakpoints;
    for (req.cache.message_breaks) |i| {
        if (i >= req.messages.len) return error.BreakpointOutOfRange;
        if (req.messages[i].content.len == 0) return error.BreakpointOnEmptyMessage;
    }
}

/// Estimates tokens of a byte span (F04's `TokenEstimator` plugs in here).
pub const Estimator = *const fn (bytes: []const u8) u64;

/// Roughly 4 bytes per token.
pub fn bytesOver4(bytes: []const u8) u64 {
    return (bytes.len + 3) / 4;
}

/// Simulated usage of one request.
pub const SimUsage = struct { read: u64 = 0, write_5m: u64 = 0, write_1h: u64 = 0, uncached: u64 = 0 };

/// Documented lookback window, in blocks, for each breakpoint.
pub const lookback_blocks = 20;

/// The simulator.
pub const CacheSim = struct {
    gpa: Allocator,
    /// Minimum cacheable prefix length for the model.
    min_tokens: u64 = 1024,
    est: Estimator = bytesOver4,
    entries: std.AutoHashMapUnmanaged(u64, Entry) = .empty,

    const Entry = struct { expires_ms: i64, tokens: u64, ttl: request.CacheTtl };

    /// Frees the cache table.
    pub fn deinit(s: *CacheSim) void {
        s.entries.deinit(s.gpa);
    }

    /// Simulates sending `req` at `now_ms` and returns the usage split.
    pub fn observe(s: *CacheSim, req: *const Request, now_ms: i64) !SimUsage {
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        // Block boundaries in prefix order with cumulative hash and tokens.
        const Boundary = struct { hash: u64, tokens: u64, brk: bool };
        var bounds: std.ArrayList(Boundary) = .empty;
        var h: std.hash.Wyhash = .init(0);
        var tokens: u64 = 0;
        const add = struct {
            fn f(hh: *std.hash.Wyhash, t: *u64, e: Estimator, bytes: []const u8) void {
                hh.update(bytes);
                hh.update(&.{0});
                t.* += e(bytes);
            }
        }.f;
        for (req.tools) |t| {
            add(&h, &tokens, s.est, t.name);
            add(&h, &tokens, s.est, t.description);
            add(&h, &tokens, s.est, t.input_schema_json);
            try bounds.append(a, .{ .hash = h.final(), .tokens = tokens, .brk = t.cache_break });
        }
        // tool_choice changes invalidate system and messages.
        h.update(@tagName(req.tool_choice));
        for (req.system) |p| {
            add(&h, &tokens, s.est, p.text);
            try bounds.append(a, .{ .hash = h.final(), .tokens = tokens, .brk = p.cache_break });
        }
        // Thinking changes invalidate messages.
        h.update(@tagName(req.thinking));
        for (req.messages, 0..) |m, mi| {
            const brk_msg = for (req.cache.message_breaks) |b| {
                if (b == mi) break true;
            } else false;
            for (m.content, 0..) |b, bi| {
                const enc = try blockBytes(a, b);
                add(&h, &tokens, s.est, enc);
                try bounds.append(a, .{ .hash = h.final(), .tokens = tokens, .brk = brk_msg and bi == m.content.len - 1 });
            }
        }
        var u: SimUsage = .{};
        var covered: u64 = 0;
        for (bounds.items, 0..) |bd, i| {
            if (!bd.brk) continue;
            // Read: the longest live entry within the lookback window.
            var hit: u64 = 0;
            var j: usize = i + 1;
            var looked: usize = 0;
            while (j > 0 and looked <= lookback_blocks) : (looked += 1) {
                j -= 1;
                if (s.entries.getPtr(bounds.items[j].hash)) |e| if (e.expires_ms > now_ms) {
                    hit = bounds.items[j].tokens;
                    e.expires_ms = now_ms + ttlMs(e.ttl); // refreshed on use
                    break;
                };
            }
            if (bd.tokens < s.min_tokens) continue; // too short to cache
            if (hit > covered) {
                u.read += hit - covered;
                covered = hit;
            }
            if (bd.tokens > covered) {
                const w = bd.tokens - covered;
                if (req.cache.ttl == .h1) u.write_1h += w else u.write_5m += w;
                covered = bd.tokens;
            }
            try s.entries.put(s.gpa, bd.hash, .{ .expires_ms = now_ms + ttlMs(req.cache.ttl), .tokens = bd.tokens, .ttl = req.cache.ttl });
        }
        u.uncached = tokens - covered;
        return u;
    }
};

fn ttlMs(t: request.CacheTtl) i64 {
    return switch (t) {
        .m5 => 5 * 60 * 1000,
        .h1 => 60 * 60 * 1000,
    };
}

fn blockBytes(a: Allocator, b: proto.ContentBlock) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var st: std.json.Stringify = .{ .writer = &out.writer };
    proto.json.writeBlock(&st, b) catch return error.OutOfMemory;
    return out.written();
}

const testing = std.testing;

fn bigText(comptime n: usize) []const u8 {
    return "x" ** n;
}

test "validate_plan_table" {
    const msgs = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = .{ .text = "a" } }} },
        .{ .role = .assistant, .content = &.{} },
    };
    const sys2 = [_]request.SystemPart{ .{ .text = "a", .cache_break = true }, .{ .text = "b", .cache_break = true } };
    const tools1 = [_]request.ToolDecl{.{ .name = "t", .description = "", .input_schema_json = "{}", .cache_break = true }};
    const Case = struct { req: Request, want: ?PlanError };
    const cases = [_]Case{
        .{ .req = .{ .model = "m", .messages = &msgs }, .want = null },
        .{ .req = .{ .model = "m", .messages = &msgs, .cache = .{ .message_breaks = &.{0} } }, .want = null },
        .{ .req = .{ .model = "m", .messages = &msgs, .system = &sys2, .tools = &tools1, .cache = .{ .message_breaks = &.{0} } }, .want = null },
        .{ .req = .{ .model = "m", .messages = &msgs, .system = &sys2, .tools = &tools1, .cache = .{ .message_breaks = &.{ 0, 0 } } }, .want = error.TooManyCacheBreakpoints },
        .{ .req = .{ .model = "m", .messages = &msgs, .cache = .{ .message_breaks = &.{5} } }, .want = error.BreakpointOutOfRange },
        .{ .req = .{ .model = "m", .messages = &msgs, .cache = .{ .message_breaks = &.{1} } }, .want = error.BreakpointOnEmptyMessage },
        .{ .req = .{ .model = "m", .messages = &msgs, .system = &sys2 }, .want = null },
        .{ .req = .{ .model = "m", .messages = &msgs, .tools = &tools1, .cache = .{ .ttl = .h1, .message_breaks = &.{0} } }, .want = null },
    };
    for (cases) |c| {
        if (c.want) |w| try testing.expectError(w, validatePlan(&c.req)) else try validatePlan(&c.req);
    }
}

test "sim_hierarchy_invalidation" {
    var sim: CacheSim = .{ .gpa = testing.allocator, .min_tokens = 100 };
    defer sim.deinit();
    const sys = [_]request.SystemPart{.{ .text = bigText(2000), .cache_break = true }};
    const msgs = [_]proto.Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "hi" } }} }};
    var tools = [_]request.ToolDecl{.{ .name = "t", .description = "one", .input_schema_json = "{}" }};
    const req: Request = .{ .model = "m", .messages = &msgs, .system = &sys, .tools = &tools };
    const r1 = try sim.observe(&req, 0);
    try testing.expect(r1.read == 0 and r1.write_5m > 0);
    const r2 = try sim.observe(&req, 1000);
    try testing.expectEqual(r1.write_5m, r2.read);
    tools[0].description = "two";
    const r3 = try sim.observe(&req, 2000);
    try testing.expectEqual(@as(u64, 0), r3.read);
    // Expired after 5 minutes without use.
    const r4 = try sim.observe(&req, 2000 + 6 * 60 * 1000);
    try testing.expectEqual(@as(u64, 0), r4.read);
}

test "sim_min_tokens" {
    var sim: CacheSim = .{ .gpa = testing.allocator, .min_tokens = 1024 };
    defer sim.deinit();
    const sys = [_]request.SystemPart{.{ .text = bigText(400), .cache_break = true }};
    const req: Request = .{ .model = "m", .messages = &.{}, .system = &sys };
    _ = try sim.observe(&req, 0);
    const u = try sim.observe(&req, 1);
    try testing.expectEqual(@as(u64, 0), u.read);
    try testing.expectEqual(@as(u64, 100), u.uncached);
}

test "sim_lookback_20" {
    var sim: CacheSim = .{ .gpa = testing.allocator, .min_tokens = 10 };
    defer sim.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msgs: std.ArrayList(proto.Message) = .empty;
    for (0..40) |i| try msgs.append(a, .{ .role = if (i % 2 == 0) .user else .assistant, .content = &.{.{ .text = .{ .text = bigText(200) } }} });
    // Cache at message 4, then ask with a breakpoint 15 and 30 blocks later.
    _ = try sim.observe(&.{ .model = "m", .messages = msgs.items[0..5], .cache = .{ .message_breaks = &.{4} } }, 0);
    const near = try sim.observe(&.{ .model = "m", .messages = msgs.items[0..20], .cache = .{ .message_breaks = &.{19} } }, 1);
    try testing.expect(near.read > 0);
    var sim2: CacheSim = .{ .gpa = testing.allocator, .min_tokens = 10 };
    defer sim2.deinit();
    _ = try sim2.observe(&.{ .model = "m", .messages = msgs.items[0..5], .cache = .{ .message_breaks = &.{4} } }, 0);
    const far = try sim2.observe(&.{ .model = "m", .messages = msgs.items[0..35], .cache = .{ .message_breaks = &.{34} } }, 1);
    try testing.expectEqual(@as(u64, 0), far.read);
}

test "sim_30_turn_session_hit_rate" {
    var sim: CacheSim = .{ .gpa = testing.allocator, .min_tokens = 1024 };
    defer sim.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sys = [_]request.SystemPart{.{ .text = bigText(16_000), .cache_break = true }};
    const tools = [_]request.ToolDecl{.{ .name = "read_file", .description = bigText(2000), .input_schema_json = "{}", .cache_break = true }};
    var msgs: std.ArrayList(proto.Message) = .empty;
    var read: u64 = 0;
    var total: u64 = 0;
    for (0..30) |turn| {
        try msgs.append(a, .{ .role = .user, .content = &.{.{ .text = .{ .text = bigText(800) } }} });
        // Fixed plan: breakpoint on the newest message (lookback finds the last one).
        const brk = try a.dupe(u32, &.{@intCast(msgs.items.len - 1)});
        const u = try sim.observe(&.{ .model = "m", .messages = msgs.items, .system = &sys, .tools = &tools, .cache = .{ .message_breaks = brk } }, @intCast(turn * 20_000));
        if (turn > 0) {
            read += u.read;
            total += u.read + u.write_5m + u.uncached;
        }
        try msgs.append(a, .{ .role = .assistant, .content = &.{.{ .text = .{ .text = bigText(600) } }} });
    }
    try testing.expect(read * 100 / total >= 90);
}
