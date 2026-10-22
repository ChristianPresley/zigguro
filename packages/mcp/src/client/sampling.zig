//! Headless sampling model (E11.F03.S03.T02): checks a server's
//! `sampling/createMessage` request before the host shows it, and the
//! executor's answer before it goes back (SAMPLING, deprecated in
//! 2026-07-28; the UI says so).
//!
//! A request is checked for: a positive `maxTokens`; at least one message;
//! `tool_use` only from the assistant and `tool_result` only from the
//! user; a message with a `tool_result` holding nothing else; every
//! `tool_use` answered by a `tool_result` in the next message, and every
//! `tool_result` answering one; `tools` / `toolChoice` only when we
//! declared `sampling.tools`; `includeContext` other than `none` only when
//! we declared `sampling.context` (never by default). Each problem is one
//! human-readable issue; a request with issues is declined.
//!
//! The executor (an E10 adapter in the host) maps `modelPreferences` to a
//! model, respects `maxTokens`, and may drop `systemPrompt` when the user
//! strips it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol/root.zig");
const request = @import("request.zig");

const M = protocol.messages;
const C = protocol.content;
const CancelToken = request.CancelToken;

pub const SamplingModel = struct {
    req: M.CreateMessageParams,
    /// Empty when the request may be shown to the user.
    issues: []const []const u8,

    /// Checks `p`; issues are allocated in `a` (an arena). The model
    /// borrows `p`.
    pub fn fromRequest(a: Allocator, p: M.CreateMessageParams, declared_tools: bool, declared_context: bool) Allocator.Error!SamplingModel {
        var issues: std.ArrayList([]const u8) = .empty;
        if (p.max_tokens <= 0) try issues.append(a, "maxTokens must be positive");
        if (p.messages.len == 0) try issues.append(a, "messages is empty");
        if (!declared_tools) {
            if (p.tools != null) try issues.append(a, "tools given but sampling.tools was not declared");
            if (p.tool_choice != null) try issues.append(a, "toolChoice given but sampling.tools was not declared");
        }
        if (p.include_context) |ic| {
            if (!std.mem.eql(u8, ic, "none") and !declared_context)
                try issues.append(a, try std.fmt.allocPrint(a, "includeContext \"{s}\" needs sampling.context, which was not declared", .{ic}));
        }

        for (p.messages, 0..) |msg, i| {
            var results: usize = 0;
            for (msg.content.items) |b| switch (b) {
                .tool_use => |u| {
                    if (msg.role != .assistant) try issues.append(a, try std.fmt.allocPrint(a, "message {d}: tool_use from the user", .{i}));
                    if (!answered(p.messages, i, u.id))
                        try issues.append(a, try std.fmt.allocPrint(a, "message {d}: tool_use \"{s}\" has no tool_result in the next message", .{ i, u.id }));
                },
                .tool_result => |r| {
                    results += 1;
                    if (msg.role != .user) try issues.append(a, try std.fmt.allocPrint(a, "message {d}: tool_result from the assistant", .{i}));
                    if (i == 0 or !usedIn(p.messages[i - 1], r.tool_use_id))
                        try issues.append(a, try std.fmt.allocPrint(a, "message {d}: tool_result \"{s}\" answers no tool_use", .{ i, r.tool_use_id }));
                },
                else => {},
            };
            if (results > 0 and results != msg.content.items.len)
                try issues.append(a, try std.fmt.allocPrint(a, "message {d}: tool_result mixed with other content", .{i}));
        }
        return .{ .req = p, .issues = issues.items };
    }

    /// Problems with the executor's answer (empty when it may be sent),
    /// allocated in `a`.
    pub fn validateResult(m: *const SamplingModel, a: Allocator, r: M.CreateMessageResult) Allocator.Error![]const []const u8 {
        var issues: std.ArrayList([]const u8) = .empty;
        if (r.model.len == 0) try issues.append(a, "result has no model");
        if (r.stop_reason == null) try issues.append(a, "result has no stopReason");
        if (r.role != .assistant) try issues.append(a, "result role must be assistant");
        if (r.content.items.len == 0) try issues.append(a, "result has no content");
        var uses: usize = 0;
        for (r.content.items) |b| switch (b) {
            .tool_use => |u| {
                uses += 1;
                if (!m.offers(u.name)) try issues.append(a, try std.fmt.allocPrint(a, "result uses tool \"{s}\", which was not offered", .{u.name}));
            },
            .tool_result => try issues.append(a, "result contains a tool_result"),
            else => {},
        };
        const mode: M.ToolChoice.Mode = if (m.req.tool_choice) |tc| tc.mode orelse .auto else .auto;
        if (uses > 0 and mode == .none) try issues.append(a, "result uses a tool but toolChoice is none");
        if (uses == 0 and mode == .required and m.req.tools != null) try issues.append(a, "toolChoice is required but the result uses no tool");
        if (r.stop_reason) |sr| {
            if (std.mem.eql(u8, sr, "toolUse") and uses == 0) try issues.append(a, "stopReason toolUse without a tool_use");
        }
        return issues.items;
    }

    fn offers(m: *const SamplingModel, name: []const u8) bool {
        for (m.req.tools orelse return false) |t| if (std.mem.eql(u8, t.name, name)) return true;
        return false;
    }
};

/// Whether message `i + 1` holds a `tool_result` for `id`.
fn answered(msgs: []const M.SamplingMessage, i: usize, id: []const u8) bool {
    if (i + 1 >= msgs.len) return false;
    for (msgs[i + 1].content.items) |b| switch (b) {
        .tool_result => |r| if (std.mem.eql(u8, r.tool_use_id, id)) return true,
        else => {},
    };
    return false;
}

fn usedIn(msg: M.SamplingMessage, id: []const u8) bool {
    for (msg.content.items) |b| switch (b) {
        .tool_use => |u| if (std.mem.eql(u8, u.id, id)) return true,
        else => {},
    };
    return false;
}

/// Runs an approved request on a model. Implemented by the host's E10
/// adapter; the result is allocated in `arena`.
pub const SamplingExecutor = struct {
    ctx: ?*anyopaque,
    run: *const fn (ctx: ?*anyopaque, req: M.CreateMessageParams, cancel: *CancelToken, arena: Allocator) anyerror!M.CreateMessageResult,
};

const testing = std.testing;

fn modelOf(a: Allocator, json: []const u8, tools: bool, context: bool) !SamplingModel {
    const p = try protocol.codec.decodeBytes(M.CreateMessageParams, a, json, .{});
    return SamplingModel.fromRequest(a, p, tools, context);
}

fn expectIssue(issues: []const []const u8, needle: []const u8) !void {
    for (issues) |i| if (std.mem.indexOf(u8, i, needle) != null) return;
    std.debug.print("no issue matching \"{s}\" in {d} issues\n", .{ needle, issues.len });
    return error.TestExpectedIssue;
}

test "sampling: SAMPLING examples are valid" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try modelOf(a,
        \\{"messages":[{"role":"user","content":{"type":"text","text":"What is the capital of France?"}}],
        \\ "modelPreferences":{"hints":[{"name":"claude-3-sonnet"}],"intelligencePriority":0.8,"speedPriority":0.5},
        \\ "systemPrompt":"You are a helpful assistant.","maxTokens":100}
    , false, false);
    try testing.expectEqual(@as(usize, 0), m.issues.len);
    const r = try protocol.codec.decodeBytes(M.CreateMessageResult, a,
        \\{"role":"assistant","content":{"type":"text","text":"The capital of France is Paris."},
        \\ "model":"claude-3-sonnet-20240307","stopReason":"endTurn"}
    , .{});
    try testing.expectEqual(@as(usize, 0), (try m.validateResult(a, r)).len);

    // A tool loop: the assistant called a tool, the user answers it.
    const t = try modelOf(a,
        \\{"messages":[
        \\  {"role":"user","content":{"type":"text","text":"Weather in Paris and London?"}},
        \\  {"role":"assistant","content":[
        \\    {"type":"tool_use","id":"call_abc123","name":"get_weather","input":{"city":"Paris"}},
        \\    {"type":"tool_use","id":"call_def456","name":"get_weather","input":{"city":"London"}}]},
        \\  {"role":"user","content":[
        \\    {"type":"tool_result","toolUseId":"call_abc123","content":[{"type":"text","text":"18°C"}]},
        \\    {"type":"tool_result","toolUseId":"call_def456","content":[{"type":"text","text":"15°C"}]}]}],
        \\ "tools":[{"name":"get_weather","description":"Get weather","inputSchema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}],
        \\ "toolChoice":{"mode":"auto"},"maxTokens":1000}
    , true, false);
    try testing.expectEqual(@as(usize, 0), t.issues.len);
    const tr = try protocol.codec.decodeBytes(M.CreateMessageResult, a,
        \\{"role":"assistant","content":[{"type":"tool_use","id":"call_x","name":"get_weather","input":{"city":"Rome"}}],
        \\ "model":"claude-3-sonnet-20240307","stopReason":"toolUse"}
    , .{});
    try testing.expectEqual(@as(usize, 0), (try t.validateResult(a, tr)).len);
}

test "sampling: tool_result mixed content rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try modelOf(a,
        \\{"messages":[
        \\  {"role":"assistant","content":[{"type":"tool_use","id":"c1","name":"w","input":{}}]},
        \\  {"role":"user","content":[{"type":"tool_result","toolUseId":"c1","content":[]},{"type":"text","text":"and also"}]}],
        \\ "tools":[{"name":"w","inputSchema":{"type":"object"}}],"maxTokens":10}
    , true, false);
    try testing.expectEqual(@as(usize, 1), m.issues.len);
    try expectIssue(m.issues, "mixed");
}

test "sampling: unmatched tool_use rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try modelOf(a,
        \\{"messages":[
        \\  {"role":"assistant","content":[{"type":"tool_use","id":"c1","name":"w","input":{}},{"type":"tool_use","id":"c2","name":"w","input":{}}]},
        \\  {"role":"user","content":[{"type":"tool_result","toolUseId":"c1"},{"type":"tool_result","toolUseId":"c9"}]}],
        \\ "tools":[{"name":"w","inputSchema":{"type":"object"}}],"maxTokens":10}
    , true, false);
    try expectIssue(m.issues, "\"c2\" has no tool_result");
    try expectIssue(m.issues, "\"c9\" answers no tool_use");

    // tool_use from the user is not allowed either.
    const u = try modelOf(a,
        \\{"messages":[{"role":"user","content":[{"type":"tool_use","id":"c1","name":"w","input":{}}]}],"maxTokens":10}
    , true, false);
    try expectIssue(u.issues, "tool_use from the user");
}

test "sampling: tools without declared capability rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\{"messages":[{"role":"user","content":{"type":"text","text":"hi"}}],
        \\ "tools":[{"name":"w","inputSchema":{"type":"object"}}],"toolChoice":{"mode":"required"},
        \\ "includeContext":"thisServer","maxTokens":0}
    ;
    const m = try modelOf(a, src, false, false);
    try expectIssue(m.issues, "tools given");
    try expectIssue(m.issues, "toolChoice given");
    try expectIssue(m.issues, "includeContext \"thisServer\"");
    try expectIssue(m.issues, "maxTokens");
    const ok = try modelOf(a, src, true, true);
    try testing.expectEqual(@as(usize, 1), ok.issues.len);

    const none = try modelOf(a,
        \\{"messages":[{"role":"user","content":{"type":"text","text":"hi"}}],"includeContext":"none","maxTokens":5}
    , false, false);
    try testing.expectEqual(@as(usize, 0), none.issues.len);
}

test "sampling: result missing model rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try modelOf(a,
        \\{"messages":[{"role":"user","content":{"type":"text","text":"hi"}}],"maxTokens":5}
    , false, false);
    // The wire form without `model` does not decode at all.
    try testing.expectError(error.MissingField, protocol.codec.decodeBytes(M.CreateMessageResult, a,
        \\{"role":"assistant","content":{"type":"text","text":"x"},"stopReason":"endTurn"}
    , .{}));
    // An executor's empty model, missing stop reason, or a tool it was
    // not offered.
    const r: M.CreateMessageResult = .{
        .role = .assistant,
        .content = .{ .items = &.{.{ .tool_use = .{ .id = "c", .name = "rm", .input = .null } }} },
        .model = "",
    };
    const issues = try m.validateResult(a, r);
    try expectIssue(issues, "no model");
    try expectIssue(issues, "no stopReason");
    try expectIssue(issues, "\"rm\", which was not offered");
}
