//! The agent's seams to the rest of the harness. Each is a small vtable
//! so the loop compiles and tests without the real implementations:
//! providers (F04 hub), tools (F06 registry), permissions (E16), context
//! assembly (F07), the session log (F08) and hooks (F09).

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("../provider/Provider.zig");
const request = @import("../provider/request.zig");
const registry = @import("../models/registry.zig");
const hub = @import("../provider/hub.zig");
const scheduler = @import("scheduler.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Finds the provider serving a model.
pub const Providers = struct {
    ctx: *anyopaque,
    get_fn: *const fn (ctx: *anyopaque, model: *const registry.ModelInfo) ?Provider,

    pub fn get(p: Providers, model: *const registry.ModelInfo) ?Provider {
        return p.get_fn(p.ctx, model);
    }

    /// Always the same provider (tests, single-provider CLI runs).
    pub fn fixed(p: *const Provider) Providers {
        return .{ .ctx = @constCast(p), .get_fn = struct {
            fn f(ctx: *anyopaque, _: *const registry.ModelInfo) ?Provider {
                const pp: *const Provider = @ptrCast(@alignCast(ctx));
                return pp.*;
            }
        }.f };
    }

    /// Through the ProviderHub (`forModel`).
    pub fn fromHub(h: *hub.ProviderHub) Providers {
        return .{ .ctx = h, .get_fn = struct {
            fn f(ctx: *anyopaque, m: *const registry.ModelInfo) ?Provider {
                const hh: *hub.ProviderHub = @ptrCast(@alignCast(ctx));
                return hh.forModel(m);
            }
        }.f };
    }
};

/// The tools an agent may call.
pub const Tools = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        list: *const fn (ctx: *anyopaque) []const proto.ToolSpec,
        /// Resources a call touches (for scheduling); null uses defaults.
        resources: ?*const fn (ctx: *anyopaque, spec: *const proto.ToolSpec, input: std.json.Value, arena: Allocator) []const scheduler.Resource = null,
        /// Looks a tool up without rebuilding the list; null searches `list`.
        find: ?*const fn (ctx: *anyopaque, name: []const u8) ?*const proto.ToolSpec = null,
    };

    pub fn list(t: Tools) []const proto.ToolSpec {
        return t.vtable.list(t.ctx);
    }

    pub fn find(t: Tools, name: []const u8) ?*const proto.ToolSpec {
        if (t.vtable.find) |f| return f(t.ctx, name);
        for (t.list()) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    pub fn resources(t: Tools, spec: *const proto.ToolSpec, input: std.json.Value, arena: Allocator) []const scheduler.Resource {
        const f = t.vtable.resources orelse return defaultResources(spec, input, arena);
        return f(t.ctx, spec, input, arena);
    }

    /// No tools.
    pub const none: Tools = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .vtable = &.{ .list = struct {
        fn f(_: *anyopaque) []const proto.ToolSpec {
            return &.{};
        }
    }.f } };
};

/// A fixed tool list.
pub const StaticTools = struct {
    specs: []const proto.ToolSpec,

    pub fn tools(s: *const StaticTools) Tools {
        return .{ .ctx = @constCast(s), .vtable = &.{ .list = list } };
    }

    fn list(ctx: *anyopaque) []const proto.ToolSpec {
        const s: *const StaticTools = @ptrCast(@alignCast(ctx));
        return s.specs;
    }
};

/// Tools lock the paths in their `path`, `file_path`, `file`, `uri` or
/// `paths` inputs; commands use terminal 0; mutating SCM tools (exported
/// by the `scm` extension) use `.scm`; other mutating tools are
/// workspace-global.
pub fn defaultResources(spec: *const proto.ToolSpec, input: std.json.Value, arena: Allocator) []const scheduler.Resource {
    const e = spec.effectiveEffects();
    if (e.executes) return single(arena, .{ .terminal = 0 });
    if (!e.read_only and spec.origin == .extension and std.mem.eql(u8, spec.origin.extension, "scm")) return single(arena, .scm);
    if (input == .object) {
        for ([_][]const u8{ "path", "file_path", "file", "uri" }) |k| if (input.object.get(k)) |v| if (v == .string) return single(arena, .{ .path = v.string });
        if (input.object.get("paths")) |v| if (v == .array and v.array.items.len > 0) {
            const out = arena.alloc(scheduler.Resource, v.array.items.len) catch return single(arena, .workspace_global);
            for (v.array.items, out) |x, *r| r.* = if (x == .string) .{ .path = x.string } else .workspace_global;
            return out;
        };
    }
    return if (e.read_only) &.{} else single(arena, .workspace_global);
}

fn single(arena: Allocator, r: scheduler.Resource) []const scheduler.Resource {
    const out = arena.alloc(scheduler.Resource, 1) catch return if (r == .workspace_global) &.{} else &.{.workspace_global};
    out[0] = r;
    return out;
}

pub const Decision = union(enum) {
    allow,
    deny: []const u8,
    /// Allowed with the input the user edited in the approval (JSON).
    allow_edited: []const u8,
};

/// What the `PreToolUse` hooks decided, for the permission check.
pub const Hint = enum {
    none,
    /// Skip the prompt; deny rules still apply.
    hook_allow,
    /// Prompt even where the rules would allow.
    hook_ask,
};

/// Decides whether a tool call may run; may block on an approval.
pub const Permission = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, io: Io, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8) Io.Cancelable!Decision,
    /// `check` with the hooks' hint; null calls `check`, so a hook allow
    /// still prompts where the rules say so and a hook ask does not force one.
    check_hinted: ?*const fn (ctx: *anyopaque, io: Io, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8, hint: Hint) Io.Cancelable!Decision = null,

    pub fn decide(p: Permission, io: Io, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8, hint: Hint) Io.Cancelable!Decision {
        if (p.check_hinted) |f| return f(p.ctx, io, agent, spec, input_json, hint);
        return p.check(p.ctx, io, agent, spec, input_json);
    }

    pub const allow_all: Permission = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .check = struct {
        fn f(_: *anyopaque, _: Io, _: proto.AgentRef, _: *const proto.ToolSpec, _: []const u8) Io.Cancelable!Decision {
            return .allow;
        }
    }.f };
};

/// What the context assembler sees.
pub const ContextView = struct {
    agent: proto.AgentRef,
    model: *const registry.ModelInfo,
    profile: registry.Profile,
    system_append: ?[]const u8,
    cwd: []const u8,
    transcript: []const proto.Message,
    tools: []const proto.ToolSpec,
    max_output_tokens: u32,
    /// Index of `transcript[0]` in the agent's full transcript (non-zero
    /// after a compaction moved the head).
    head: u32 = 0,
};

/// Builds the request for the next model call.
pub const ContextBuilder = struct {
    ctx: *anyopaque,
    build: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, view: *const ContextView) anyerror!request.Request,
    /// The transcript changed from message `from` on (compaction, rewind,
    /// resume): state kept per transcript index must be dropped.
    forget: ?*const fn (ctx: *anyopaque, from: u32) void = null,

    /// System text from `system_append`, the whole transcript, every tool.
    pub const basic: ContextBuilder = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .build = basicBuild };
};

fn basicBuild(_: *anyopaque, _: Io, arena: Allocator, v: *const ContextView) anyerror!request.Request {
    var decls: std.ArrayList(request.ToolDecl) = .empty;
    for (v.tools) |*t| if (request.declFor(t, v.model.provider)) |d| try decls.append(arena, d);
    const sys: []const request.SystemPart = if (v.system_append) |s| blk: {
        const p = try arena.alloc(request.SystemPart, 1);
        p[0] = .{ .text = s };
        break :blk p;
    } else &.{};
    return .{
        .model = v.model.id,
        .system = sys,
        .messages = v.transcript,
        .tools = decls.items,
        .max_output_tokens = v.max_output_tokens,
        .thinking = v.profile.thinking,
        .effort = v.profile.effort,
        .temperature = v.profile.temperature,
    };
}

/// E12.F04 `Checkpoints.create(origin, turn, label)`: snapshots the
/// workspace at the start of a user turn. Never fails; under 1 ms.
pub const Checkpoints = struct {
    ctx: *anyopaque,
    create: *const fn (ctx: *anyopaque, io: Io, origin: proto.AgentRef, turn: u32, label: []const u8) u64,
};

/// Runs when an agent turn ends, however it ended (E12 commits the turn's
/// changeset).
pub const TurnEnd = struct {
    ctx: *anyopaque,
    finished: *const fn (ctx: *anyopaque, io: Io, agent: proto.AgentRef, turn: u32) void,
};

/// The history after a compaction.
pub const CompactedHistory = struct {
    messages: []const proto.Message,
    tokens_before: u64 = 0,
    tokens_after: u64 = 0,
    /// The summarizer model.
    model: []const u8 = "",
    /// The summarizer failed and old tool results were cleared instead.
    fallback: bool = false,
};

/// Transcript compaction (F07.S03): before a request whose input crosses
/// the threshold, and after the context builder or the provider reports
/// that the conversation no longer fits.
pub const Compaction = struct {
    ctx: *anyopaque,
    should_compact: *const fn (ctx: *anyopaque, est_input_tokens: u64, window: u32) bool,
    /// `base` is the request the agent would send (system prompt, tools);
    /// the result is allocated in `arena` and copied by the loop.
    compact: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, base: *const request.Request, history: []const proto.Message, overflow: bool) anyerror!CompactedHistory,
    /// `/compact [focus]`; `compact` (as an auto compaction) when null.
    manual: ?*const fn (ctx: *anyopaque, io: Io, arena: Allocator, base: *const request.Request, history: []const proto.Message, focus: ?[]const u8) anyerror!CompactedHistory = null,
};

/// A compaction as recorded in the session log.
pub const CompactionInfo = struct {
    /// The first message of the new history.
    head_seq: u64,
    trigger: []const u8,
    tokens_before: u64,
    tokens_after: u64,
    model: []const u8,
};

/// Receives committed messages (F08 writes them to the session JSONL).
pub const SessionLog = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        message: *const fn (ctx: *anyopaque, io: Io, agent: proto.AgentRef, seq: u64, m: *const proto.Message) anyerror!void,
        /// Durability point at the end of a turn.
        sync: *const fn (ctx: *anyopaque, io: Io) anyerror!void,
        /// A compaction; the new history follows as messages.
        compaction: ?*const fn (ctx: *anyopaque, io: Io, agent: proto.AgentRef, seq: u64, info: CompactionInfo) anyerror!void = null,
    };
};

pub const PromptDecision = union(enum) {
    allow,
    block: []const u8,
    /// Extra context appended to the prompt.
    add_context: []const u8,
};

pub const StopDecision = union(enum) {
    allow,
    /// Keep going; the reason becomes a user message.
    block: []const u8,
};

/// A `PreToolUse` outcome.
pub const PreToolDecision = struct {
    decision: enum { none, allow, deny, ask } = .none,
    reason: []const u8 = "",
    /// Replaces the input (JSON); validated again.
    updated_input_json: ?[]const u8 = null,
};

/// A `PostToolUse` / `PostToolUseFailure` outcome.
pub const PostToolDecision = struct {
    /// Appended to the output as a text part.
    additional_context: ?[]const u8 = null,
    /// Replaces the output.
    updated_output: ?proto.ToolOutput = null,
};

/// `UserPromptSubmit`, `Stop`, `PreToolUse` and `PostToolUse` hooks (F09).
/// A hook that fails is skipped: hooks never block on their own errors.
pub const Hooks = struct {
    ctx: *anyopaque,
    prompt_submit: ?*const fn (ctx: *anyopaque, io: Io, arena: Allocator, text: []const u8) anyerror!PromptDecision = null,
    stop: ?*const fn (ctx: *anyopaque, io: Io, arena: Allocator, last: *const proto.Message) anyerror!StopDecision = null,
    pre_tool_use: ?*const fn (ctx: *anyopaque, io: Io, arena: Allocator, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8) anyerror!PreToolDecision = null,
    /// `failed` selects `PostToolUseFailure` (the output is an error).
    post_tool_use: ?*const fn (ctx: *anyopaque, io: Io, arena: Allocator, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8, output: *const proto.ToolOutput, failed: bool) anyerror!PostToolDecision = null,
};

/// One decision about a tool call, for the E16 audit log and the bus.
pub const ToolDecision = struct {
    id: []const u8,
    tool: []const u8,
    stage: enum { validation, pre_hook, permission, post_hook, bound },
    outcome: enum { allow, deny, ask, edit, replace, context, truncate },
    reason: []const u8 = "",
};

/// E16's audit sink: every tool decision, who made it and why.
pub const Audit = struct {
    ctx: *anyopaque,
    record: *const fn (ctx: *anyopaque, io: Io, agent: proto.AgentRef, d: ToolDecision) void,
};

test "default resources" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const S = struct {
        fn call(_: *anyopaque, _: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
            return error.Failed;
        }
    };
    var d: u8 = 0;
    const w: proto.ToolSpec = .{ .name = "edit", .description = "", .input_schema_json = "{}", .read_only = false, .handler = .{ .ctx = &d, .call = S.call } };
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"src/a.zig\"}", .{});
    try std.testing.expectEqualStrings("src/a.zig", defaultResources(&w, input, a)[0].path);
    try std.testing.expect(defaultResources(&w, .null, a)[0] == .workspace_global);
    var r = w;
    r.read_only = true;
    try std.testing.expectEqual(@as(usize, 0), defaultResources(&r, .null, a).len);
    // The resources extraction table.
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        .{ .input = "{\"file\":\"a.zig\"}", .want = "path:a.zig" },
        .{ .input = "{\"uri\":\"file:///w/b.zig\"}", .want = "path:file:///w/b.zig" },
        .{ .input = "{\"file_path\":\"c.zig\"}", .want = "path:c.zig" },
        .{ .input = "{\"paths\":[\"d.zig\",\"e.zig\"]}", .want = "path:d.zig path:e.zig" },
        .{ .input = "{\"query\":\"x\"}", .want = "workspace_global" },
    };
    for (cases) |c| {
        const in = try std.json.parseFromSliceLeaky(std.json.Value, a, c.input, .{});
        var got: std.ArrayList(u8) = .empty;
        for (defaultResources(&w, in, a), 0..) |res, i| {
            if (i > 0) try got.append(a, ' ');
            switch (res) {
                .path => |p| try got.print(a, "path:{s}", .{p}),
                else => try got.appendSlice(a, @tagName(res)),
            }
        }
        try std.testing.expectEqualStrings(c.want, got.items);
    }
    var scm = w;
    scm.origin = .{ .extension = "scm" };
    try std.testing.expect(defaultResources(&scm, .null, a)[0] == .scm);
}
