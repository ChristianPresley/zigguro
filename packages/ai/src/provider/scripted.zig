//! `ScriptedProvider`: a deterministic provider for tests. Each call to
//! `stream` plays the next scripted turn: events are emitted (and folded
//! into the response), `delay_ms` sleeps cancellably, `fail` returns an
//! error, and `expect_request` checks the request. Every request is
//! deep-copied for later assertions. See `packages/ai/docs/testing.md`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("Provider.zig");
const request = @import("request.zig");
const events = @import("events.zig");
const Capabilities = @import("capabilities.zig").Capabilities;
const MessageAssembler = @import("assembler.zig").MessageAssembler;

const Allocator = std.mem.Allocator;

/// Scripted test provider.
pub const ScriptedProvider = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    turns: []const []const Step,
    caps: Capabilities,
    next_turn: usize = 0,
    recorded: std.ArrayList(request.Request) = .empty,
    mutex: std.Io.Mutex = .init,
    /// Tokens reported by `count_tokens` (per message, plus 1 per system part).
    tokens_per_message: u64 = 10,

    /// One scripted action.
    pub const Step = union(enum) {
        event: events.StreamEvent,
        delay_ms: u32,
        fail: Provider.StreamError,
        expect_request: *const fn (*const request.Request) bool,
    };

    /// Creates a provider playing `turns` in order (borrowed, must outlive it).
    pub fn init(gpa: Allocator, turns: []const []const Step, caps: Capabilities) !*ScriptedProvider {
        const s = try gpa.create(ScriptedProvider);
        s.* = .{ .gpa = gpa, .arena = .init(gpa), .turns = turns, .caps = caps };
        return s;
    }

    /// Frees the provider and recorded requests.
    pub fn destroy(s: *ScriptedProvider) void {
        s.arena.deinit();
        s.gpa.destroy(s);
    }

    /// The `Provider` view; `deinit` destroys `s`.
    pub fn provider(s: *ScriptedProvider) Provider {
        return .{ .ptr = s, .vtable = &vtable, .id = .scripted, .caps = s.caps };
    }

    /// Requests received so far, in order.
    pub fn requests(s: *const ScriptedProvider) []const request.Request {
        return s.recorded.items;
    }

    /// Turns not yet played.
    pub fn remaining(s: *const ScriptedProvider) usize {
        return s.turns.len - s.next_turn;
    }

    const vtable: Provider.VTable = .{ .stream = stream, .count_tokens = countTokens, .deinit = deinitErased };

    fn deinitErased(ptr: *anyopaque) void {
        const s: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        s.destroy();
    }

    fn countTokens(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request) Provider.CountError!u64 {
        _ = io;
        _ = arena;
        const s: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        return s.tokens_per_message * req.messages.len + req.system.len;
    }

    fn stream(ptr: *anyopaque, io: std.Io, arena: Allocator, req: *const request.Request, sink: events.EventSink) Provider.StreamError!request.Response {
        const s: *ScriptedProvider = @ptrCast(@alignCast(ptr));
        const turn = blk: {
            try s.mutex.lock(io);
            defer s.mutex.unlock(io);
            s.recorded.append(s.arena.allocator(), try cloneRequest(s.arena.allocator(), req.*)) catch return error.OutOfMemory;
            if (s.next_turn >= s.turns.len) return error.Protocol;
            s.next_turn += 1;
            break :blk s.turns[s.next_turn - 1];
        };
        var asm_: MessageAssembler = .init(arena);
        asm_.origin = .scripted;
        for (turn) |step| {
            try io.checkCancel();
            switch (step) {
                .event => |ev| {
                    asm_.feed(ev) catch |e| return switch (e) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.Protocol,
                    };
                    sink.send(ev);
                },
                .delay_ms => |ms| try io.sleep(.fromMilliseconds(ms), .awake),
                .fail => |e| return e,
                .expect_request => |f| if (!f(req)) return error.InvalidRequest,
            }
        }
        const msg = asm_.finish() catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Protocol,
        };
        return .{ .message = msg, .stop = asm_.stop orelse .end_turn, .usage = asm_.usage, .request_id = asm_.id, .rate_limit = asm_.rate_limit };
    }
};

/// Deep-copies `req` into `arena`.
pub fn cloneRequest(arena: Allocator, req: request.Request) Allocator.Error!request.Request {
    var r = req;
    r.model = try arena.dupe(u8, req.model);
    const sys = try arena.alloc(request.SystemPart, req.system.len);
    for (req.system, sys) |p, *o| o.* = .{ .text = try arena.dupe(u8, p.text), .cache_break = p.cache_break, .stable = p.stable };
    r.system = sys;
    const msgs = try arena.alloc(proto.Message, req.messages.len);
    for (req.messages, msgs) |m, *o| o.* = try proto.json.cloneMessage(arena, m);
    r.messages = msgs;
    const tools = try arena.alloc(request.ToolDecl, req.tools.len);
    for (req.tools, tools) |t, *o| {
        o.* = t;
        o.name = try arena.dupe(u8, t.name);
        o.description = try arena.dupe(u8, t.description);
        o.input_schema_json = try arena.dupe(u8, t.input_schema_json);
    }
    r.tools = tools;
    if (req.tool_choice == .tool) r.tool_choice = .{ .tool = try arena.dupe(u8, req.tool_choice.tool) };
    r.cache.message_breaks = try arena.dupe(u32, req.cache.message_breaks);
    r.stop_sequences = &.{};
    r.extra_headers = &.{};
    if (req.api_key) |k| r.api_key = try arena.dupe(u8, k);
    if (req.output_schema_json) |o| r.output_schema_json = try arena.dupe(u8, o);
    if (req.extra_body_json) |o| r.extra_body_json = try arena.dupe(u8, o);
    r.metadata_user_id = null;
    return r;
}

/// Helpers to write scripts tersely.
pub const script = struct {
    /// Events for a complete text-only assistant turn.
    pub fn text(comptime s: []const u8) []const ScriptedProvider.Step {
        return comptime &.{
            .{ .event = .{ .message_start = .{ .id = "msg_scripted", .model = "scripted" } } },
            .{ .event = .{ .block_start = .{ .index = 0, .kind = .text } } },
            .{ .event = .{ .text_delta = .{ .index = 0, .text = s } } },
            .{ .event = .{ .block_stop = .{ .index = 0 } } },
            .{ .event = .{ .usage = .{ .input = 10, .output = 5 } } },
            .{ .event = .{ .stop = .end_turn } },
        };
    }

    /// One complete tool call: `.{ id, name, input_json }`.
    pub const Call = struct { []const u8, []const u8, []const u8 };

    /// Events for an assistant turn calling `calls` in parallel.
    pub fn tools(comptime calls: []const Call) []const ScriptedProvider.Step {
        return comptime blk: {
            var steps: []const ScriptedProvider.Step = &.{.{ .event = .{ .message_start = .{ .id = "msg_scripted", .model = "scripted" } } }};
            for (calls, 0..) |c, i| {
                steps = steps ++ &[_]ScriptedProvider.Step{
                    .{ .event = .{ .block_start = .{ .index = i, .kind = .tool_use, .tool_id = c[0], .tool_name = c[1] } } },
                    .{ .event = .{ .tool_input_delta = .{ .index = i, .partial_json = c[2] } } },
                    .{ .event = .{ .block_stop = .{ .index = i } } },
                };
            }
            break :blk steps ++ &[_]ScriptedProvider.Step{
                .{ .event = .{ .usage = .{ .input = 10, .output = 5 } } },
                .{ .event = .{ .stop = .tool_use } },
            };
        };
    }
};

const testing = std.testing;

test "scripted_records_requests" {
    const turns = [_][]const ScriptedProvider.Step{script.text("hello")};
    const s = try ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const msgs = [_]proto.Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "hi" } }} }};
    const resp = try p.stream(testing.io, arena.allocator(), &.{ .model = "m", .messages = &msgs }, .discard);
    try testing.expectEqualStrings("hello", resp.message.content[0].text.text);
    try testing.expectEqual(proto.StopReason.end_turn, resp.stop);
    try testing.expectEqual(@as(usize, 1), s.requests().len);
    try testing.expectEqualStrings("hi", s.requests()[0].messages[0].content[0].text.text);
    try testing.expectEqual(@as(u64, 10), try p.countTokens(testing.io, arena.allocator(), &.{ .model = "m", .messages = &msgs }));
    // Script exhausted.
    try testing.expectError(error.Protocol, p.stream(testing.io, arena.allocator(), &.{ .model = "m", .messages = &msgs }, .discard));
}

test "scripted parallel tools and failures" {
    const turns = [_][]const ScriptedProvider.Step{
        script.tools(&.{ .{ "a", "read", "{\"p\":1}" }, .{ "b", "read", "{\"p\":2}" }, .{ "c", "grep", "{}" } }),
        &.{ .{ .delay_ms = 1 }, .{ .fail = error.Overloaded } },
    };
    const s = try ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: request.Request = .{ .model = "m", .messages = &.{} };
    const r = try p.stream(testing.io, arena.allocator(), &req, .discard);
    try testing.expectEqual(@as(usize, 3), r.message.toolUseCount());
    try testing.expectEqualStrings("{\"p\":2}", r.message.content[1].tool_use.input_json);
    try testing.expectError(error.Overloaded, p.stream(testing.io, arena.allocator(), &req, .discard));
}

test "scripted_cancel_between_steps" {
    const turns = [_][]const ScriptedProvider.Step{&.{ .{ .delay_ms = 10_000 }, .{ .event = .ping } }};
    const s = try ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const io = testing.io;
    const req: request.Request = .{ .model = "m", .messages = &.{} };
    const Run = struct {
        fn run(pp: Provider, ii: std.Io, a: Allocator, rq: *const request.Request) Provider.StreamError!request.Response {
            return pp.stream(ii, a, rq, .discard);
        }
    };
    var fut = try io.concurrent(Run.run, .{ p, io, arena.allocator(), &req });
    try io.sleep(.fromMilliseconds(5), .awake);
    const t0 = std.Io.Timestamp.now(io, .awake);
    try testing.expectError(error.Canceled, fut.cancel(io));
    const took = t0.untilNow(io, .awake).toMilliseconds();
    try testing.expect(took < 50);
}
