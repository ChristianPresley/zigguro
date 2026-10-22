//! Hook input and output (E10.F09.S03.T01), compatible with Claude Code:
//! the JSON a hook reads on stdin, what its exit code and stdout mean, and
//! how the outcomes of hooks that ran in parallel combine.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const HookEvent = enum {
    SessionStart,
    SessionEnd,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    PostToolUseFailure,
    PermissionRequest,
    Stop,
    SubagentStart,
    SubagentStop,
    PreCompact,
    PostCompact,
    Notification,

    /// Exit code 2 blocks these; on the others stderr goes to the model.
    pub fn blockable(e: HookEvent) bool {
        return switch (e) {
            .PreToolUse, .UserPromptSubmit, .Stop, .SubagentStop, .PreCompact, .PermissionRequest => true,
            else => false,
        };
    }

    /// Plain stdout on exit 0 becomes context for these.
    pub fn plainStdoutIsContext(e: HookEvent) bool {
        return e == .UserPromptSubmit or e == .SessionStart;
    }
};

/// What a hook reads on stdin. Null fields are left out; `*_json` fields
/// are JSON text written as values.
pub const Input = struct {
    session_id: []const u8 = "",
    transcript_path: ?[]const u8 = null,
    cwd: []const u8 = ".",
    permission_mode: []const u8 = "default",
    agent_id: ?[]const u8 = null,
    agent_type: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_input_json: ?[]const u8 = null,
    tool_use_id: ?[]const u8 = null,
    tool_response_json: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    /// SessionStart: startup, resume, compact or fork.
    source: ?[]const u8 = null,
    /// PreCompact / PostCompact: manual or auto.
    trigger: ?[]const u8 = null,
    stop_hook_active: ?bool = null,
    message: ?[]const u8 = null,
};

/// The JSON object written to the hook's stdin.
pub fn encodeInput(a: Allocator, event: HookEvent, in: Input) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    encode(&out.writer, event, in) catch return error.OutOfMemory;
    return out.written();
}

fn encode(w: *std.Io.Writer, event: HookEvent, in: Input) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "session_id", in.session_id);
    if (in.transcript_path) |p| try field(&s, "transcript_path", p);
    try field(&s, "cwd", in.cwd);
    try field(&s, "permission_mode", in.permission_mode);
    try field(&s, "hook_event_name", @tagName(event));
    if (in.agent_id) |v| try field(&s, "agent_id", v);
    if (in.agent_type) |v| try field(&s, "agent_type", v);
    if (in.tool_name) |v| try field(&s, "tool_name", v);
    if (in.tool_input_json) |v| try raw(&s, "tool_input", v);
    if (in.tool_use_id) |v| try field(&s, "tool_use_id", v);
    if (in.tool_response_json) |v| try raw(&s, "tool_response", v);
    if (in.prompt) |v| try field(&s, "prompt", v);
    if (in.source) |v| try field(&s, "source", v);
    if (in.trigger) |v| try field(&s, "trigger", v);
    if (in.stop_hook_active) |v| try field(&s, "stop_hook_active", v);
    if (in.message) |v| try field(&s, "message", v);
    try s.endObject();
}

fn field(s: *std.json.Stringify, name: []const u8, v: anytype) std.Io.Writer.Error!void {
    try s.objectField(name);
    try s.write(v);
}

fn raw(s: *std.json.Stringify, name: []const u8, json_text: []const u8) std.Io.Writer.Error!void {
    try s.objectField(name);
    try s.beginWriteRaw();
    try s.writer.writeAll(if (json_text.len == 0) "null" else json_text);
    s.endWriteRaw();
}

pub const Permission = enum { allow, deny, ask };

/// What hooks decided. Slices live in the run's arena.
pub const Outcome = struct {
    /// Blocks the action (deny the tool, reject the prompt, keep going on
    /// Stop); the reason goes to the model.
    block: ?[]const u8 = null,
    permission: ?Permission = null,
    permission_reason: ?[]const u8 = null,
    updated_input_json: ?[]const u8 = null,
    additional_context: ?[]const u8 = null,
    updated_tool_output: ?[]const u8 = null,
    /// `continue: false`: stop the agent, with this reason.
    stop_all: ?[]const u8 = null,
    /// Shown to the user.
    system_message: ?[]const u8 = null,
    /// Non-blocking failures, for the transcript.
    notices: []const []const u8 = &.{},
};

/// How one hook process ended.
pub const Result = struct {
    /// Null when the hook was killed (timeout) or could not start.
    exit: ?u8,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    timed_out: bool = false,
    /// Why it did not run, when it did not.
    spawn_error: ?[]const u8 = null,
};

pub const OnFailure = enum { @"continue", block };

/// What one hook's result means for `event`.
pub fn interpret(a: Allocator, event: HookEvent, label: []const u8, on_failure: OnFailure, r: Result) Allocator.Error!Outcome {
    const err_text = std.mem.trim(u8, r.stderr, " \t\r\n");
    const code = r.exit orelse {
        const why = if (r.timed_out) "timed out" else r.spawn_error orelse "was killed";
        return failure(a, event, on_failure, try std.fmt.allocPrint(a, "hook {s} {s}", .{ label, why }));
    };
    if (code == 2) {
        const reason = if (err_text.len > 0) err_text else try std.fmt.allocPrint(a, "blocked by hook {s}", .{label});
        if (event.blockable()) return .{ .block = reason };
        return .{ .additional_context = reason };
    }
    if (code != 0) {
        const msg = if (err_text.len > 0)
            try std.fmt.allocPrint(a, "hook {s} failed (exit {d}): {s}", .{ label, code, err_text })
        else
            try std.fmt.allocPrint(a, "hook {s} failed (exit {d})", .{ label, code });
        return failure(a, event, on_failure, msg);
    }
    const out = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (out.len > 0 and out[0] == '{') {
        if (std.json.parseFromSliceLeaky(std.json.Value, a, out, .{})) |v| {
            if (v == .object) return fromJson(a, event, v.object);
        } else |_| {}
    }
    if (out.len > 0 and event.plainStdoutIsContext()) return .{ .additional_context = out };
    return .{};
}

fn failure(a: Allocator, event: HookEvent, on_failure: OnFailure, msg: []const u8) Allocator.Error!Outcome {
    if (on_failure == .block and event.blockable()) return .{ .block = msg };
    const notes = try a.alloc([]const u8, 1);
    notes[0] = msg;
    return .{ .notices = notes };
}

fn fromJson(a: Allocator, event: HookEvent, obj: std.json.ObjectMap) Allocator.Error!Outcome {
    var o: Outcome = .{};
    if (obj.get("continue")) |c| if (c == .bool and !c.bool) {
        o.stop_all = str(obj, "stopReason") orelse "stopped by a hook";
    };
    if (str(obj, "systemMessage")) |m| o.system_message = m;
    if (str(obj, "decision")) |d| {
        const reason = str(obj, "reason") orelse "blocked by a hook";
        if (std.mem.eql(u8, d, "block")) {
            if (event.blockable()) o.block = reason else o.additional_context = reason;
        } else if (std.mem.eql(u8, d, "approve") and event == .PreToolUse) {
            o.permission = .allow;
            o.permission_reason = str(obj, "reason");
        }
    }
    if (obj.get("hookSpecificOutput")) |h| if (h == .object) {
        const ho = h.object;
        if (str(ho, "permissionDecision")) |p| {
            o.permission = std.meta.stringToEnum(Permission, p) orelse o.permission;
            o.permission_reason = str(ho, "permissionDecisionReason") orelse o.permission_reason;
        }
        // PermissionRequest: {"decision": {"behavior": "allow" | "deny"}}.
        if (ho.get("decision")) |d| if (d == .object) if (str(d.object, "behavior")) |b| {
            o.permission = std.meta.stringToEnum(Permission, b) orelse o.permission;
            o.permission_reason = str(d.object, "message") orelse o.permission_reason;
        };
        if (ho.get("updatedInput")) |u| if (u == .object) {
            o.updated_input_json = try jsonText(a, u);
        };
        if (str(ho, "additionalContext")) |c| o.additional_context = if (o.additional_context) |prev|
            try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ prev, c })
        else
            c;
        if (ho.get("updatedToolOutput")) |u| o.updated_tool_output = if (u == .string) u.string else try jsonText(a, u);
    };
    return o;
}

fn jsonText(a: Allocator, v: std.json.Value) Allocator.Error![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{}) catch error.OutOfMemory;
}

fn str(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Combines parallel hooks' outcomes, in config order: deny beats ask
/// beats allow, block reasons and contexts join, the first updated input
/// wins (a notice says so when there were several).
pub fn merge(a: Allocator, outs: []const Outcome) Allocator.Error!Outcome {
    var o: Outcome = .{};
    var blocks: std.ArrayList(u8) = .empty;
    var ctx: std.ArrayList(u8) = .empty;
    var sys: std.ArrayList(u8) = .empty;
    var notices: std.ArrayList([]const u8) = .empty;
    var inputs: u32 = 0;
    for (outs) |x| {
        if (x.block) |b| try joinTo(a, &blocks, "\n", b);
        if (x.additional_context) |c| try joinTo(a, &ctx, "\n\n", c);
        if (x.system_message) |m| try joinTo(a, &sys, "\n", m);
        if (x.permission) |p| if (o.permission == null or rank(p) > rank(o.permission.?)) {
            o.permission = p;
            o.permission_reason = x.permission_reason;
        };
        if (x.updated_input_json) |u| {
            inputs += 1;
            if (o.updated_input_json == null) o.updated_input_json = u;
        }
        if (o.updated_tool_output == null) o.updated_tool_output = x.updated_tool_output;
        if (o.stop_all == null) o.stop_all = x.stop_all;
        try notices.appendSlice(a, x.notices);
    }
    if (inputs > 1) try notices.append(a, try std.fmt.allocPrint(a, "{d} hooks changed the tool input; the first one's change was used", .{inputs}));
    if (blocks.items.len > 0) o.block = blocks.items;
    if (ctx.items.len > 0) o.additional_context = ctx.items;
    if (sys.items.len > 0) o.system_message = sys.items;
    o.notices = notices.items;
    return o;
}

fn rank(p: Permission) u8 {
    return switch (p) {
        .allow => 0,
        .ask => 1,
        .deny => 2,
    };
}

fn joinTo(a: Allocator, list: *std.ArrayList(u8), sep: []const u8, s: []const u8) Allocator.Error!void {
    if (list.items.len > 0) try list.appendSlice(a, sep);
    try list.appendSlice(a, s);
}

test "input json" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const j = try encodeInput(arena.allocator(), .PreToolUse, .{ .session_id = "S", .cwd = "/w", .tool_name = "run_command", .tool_input_json = "{\"command\":\"ls\"}", .tool_use_id = "t1" });
    try std.testing.expectEqualStrings("{\"session_id\":\"S\",\"cwd\":\"/w\",\"permission_mode\":\"default\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"run_command\",\"tool_input\":{\"command\":\"ls\"},\"tool_use_id\":\"t1\"}", j);
}
