//! `Compactor`: replaces history with a structured summary and re-injects
//! durable context (E10.F07.S03.T01), automatically near the window or on
//! `/compact [focus]`, plus range summaries used by rewind (F08).
//!
//! The summarization request reuses the next normal request (same tools
//! and system prompt, so the cached prefix is read, not rewritten) with
//! the instruction appended as a final user message, tools disabled and
//! output capped at 8k tokens. The new head is a synthetic user message
//! (`[Conversation compacted. Summary follows.]` plus the summary) and a
//! re-injection block: memory and unscoped rules re-read from disk, the
//! plan, the skills index, the todos, up to five recently touched files
//! (5k tokens each, else a reference) and running background work.
//!
//! The caller keeps the old messages (the session file holds them for
//! rewind and search), appends a `compaction` record and moves the head.
//! If summarization fails, old tool results are cleared instead and a
//! warning is returned: user messages are never lost.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("../provider/Provider.zig");
const request = @import("../provider/request.zig");
const registry = @import("../models/registry.zig");
const asm_mod = @import("assembler.zig");
const memory = @import("memory.zig");
const deps = @import("../loop/deps.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The summarization instructions.
pub const prompt = @embedFile("compact_prompt.md");

/// Why compaction runs.
pub const Trigger = enum { auto_threshold, manual, window_overflow, idle };

/// `ai.compaction.*` settings.
pub const Config = struct {
    /// Percent of the context window that triggers auto-compaction.
    threshold_pct: u8 = 80,
    max_summary_tokens: u32 = 8192,
    recent_files: u8 = 5,
    file_token_cap: u32 = 5000,
    /// Tool results kept when falling back to clearing.
    keep_tool_results: u32 = 3,
    /// `ai.compaction.onIdleResume` (P2).
    on_idle_resume: bool = false,
};

/// A file the agent read or edited recently (ReadTracker).
pub const RecentFile = struct { path: []const u8, text: ?[]const u8 };

/// Durable context to re-inject after the summary.
pub const Reinject = struct {
    memory: ?*const memory.MemorySet = null,
    plan: ?[]const u8 = null,
    skills: []const asm_mod.SkillSummary = &.{},
    todos: []const asm_mod.Todo = &.{},
    /// Most recent first.
    recent_files: []const RecentFile = &.{},
    /// Running background commands and subagents, one line each.
    background: []const []const u8 = &.{},
};

/// A `PreCompact` hook's answer.
pub const PreDecision = enum { allow, block };

/// `PreCompact` / `PostCompact` hooks (F09; null OK).
pub const Hooks = struct {
    ctx: *anyopaque,
    /// `.block` (exit code 2) stops auto-compaction; manual runs ignore it.
    pre: ?*const fn (ctx: *anyopaque, io: Io, trigger: Trigger, focus: ?[]const u8) anyerror!PreDecision = null,
    post: ?*const fn (ctx: *anyopaque, io: Io, trigger: Trigger, summary: []const u8) anyerror!void = null,
};

/// What to summarize. `from`/`to` are message indices into `history`.
pub const Job = struct {
    trigger: Trigger,
    focus: ?[]const u8 = null,
    range: ?struct { from: ?u32 = null, to: ?u32 = null } = null,
};

pub const CompactionResult = struct {
    /// The new history (summary head, re-injection, and kept messages).
    messages: []const proto.Message,
    summary: []const u8,
    tokens_before: u64,
    tokens_after: u64,
    model: []const u8,
    /// Summarization failed and old tool results were cleared instead.
    fallback: bool = false,
    warning: ?[]const u8 = null,
};

pub const Compactor = struct {
    cfg: Config = .{},
    provider: Provider,
    /// The `compaction` role model.
    model: *const registry.ModelInfo,
    hooks: ?Hooks = null,

    /// The trigger when `used_tokens` crossed the threshold, else null.
    pub fn shouldCompact(c: *const Compactor, used_tokens: u64, window: u32) ?Trigger {
        if (window == 0) return null;
        if (used_tokens * 100 >= @as(u64, window) * c.cfg.threshold_pct) return .auto_threshold;
        return null;
    }

    /// Runs one compaction. `base` is the request the agent would send next
    /// (its tools and system prompt are reused); `history` is the active
    /// history. Returns `error.Blocked` when a PreCompact hook blocks an
    /// automatic run.
    pub fn compact(c: *Compactor, io: Io, arena: Allocator, base: *const request.Request, history: []const proto.Message, re: Reinject, job: Job) !CompactionResult {
        if (c.hooks) |h| if (h.pre) |f| if (job.trigger != .manual) {
            if (try f(h.ctx, io, job.trigger, job.focus) == .block) return error.Blocked;
        };
        const lo: usize = if (job.range) |r| r.from orelse 0 else 0;
        const hi: usize = if (job.range) |r| if (r.to) |t| @min(t + 1, history.len) else history.len else history.len;
        if (lo >= hi) return error.NothingToCompact;
        const before = estimate(history);

        // The summarization request: the history up to `hi`, then the
        // instruction (with the focus).
        var instr: std.ArrayList(u8) = .empty;
        try instr.appendSlice(arena, prompt);
        if (lo > 0) try instr.print(arena, "\nSummarize only the conversation from message {d} on; earlier messages stay as they are.\n", .{lo + 1});
        if (job.focus) |f| try instr.print(arena, "\nFocus the summary on: {s}\n", .{f});
        const msgs = try arena.alloc(proto.Message, hi + 1);
        @memcpy(msgs[0..hi], history[0..hi]);
        const iblocks = try arena.alloc(proto.ContentBlock, 1);
        iblocks[0] = .{ .text = .{ .text = instr.items } };
        msgs[hi] = .{ .role = .user, .content = iblocks, .meta = .{ .synthetic = true } };
        var req = base.*;
        req.model = c.model.id;
        req.messages = try mergeTrailingUser(arena, msgs);
        req.tool_choice = .none;
        req.max_output_tokens = @min(c.cfg.max_summary_tokens, c.model.max_output);
        req.output_schema_json = null;

        const summary: ?[]const u8 = blk: {
            const resp = c.provider.stream(io, arena, &req, .discard) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                else => break :blk null,
            };
            const t = try resp.message.text(arena);
            if (std.mem.trim(u8, t, " \n").len == 0) break :blk null;
            break :blk t;
        };

        const s = summary orelse {
            const cleared = try clearOld(arena, history, c.cfg.keep_tool_results);
            return .{ .messages = cleared, .summary = "", .tokens_before = before, .tokens_after = estimate(cleared), .model = c.model.id, .fallback = true, .warning = "compaction failed; old tool results were cleared instead" };
        };

        var out: std.ArrayList(proto.Message) = .empty;
        try out.appendSlice(arena, history[0..lo]);
        const head = try arena.alloc(proto.ContentBlock, 2);
        head[0] = .{ .text = .{ .text = asm_mod.compaction_marker } };
        head[1] = .{ .text = .{ .text = s } };
        try out.append(arena, .{ .role = .user, .content = head, .meta = .{ .synthetic = true } });
        const rtext = try c.reinjection(arena, re);
        if (rtext.len > 0) {
            // An assistant acknowledgement keeps roles alternating.
            const ack = try arena.alloc(proto.ContentBlock, 1);
            ack[0] = .{ .text = .{ .text = "Understood. I have the summary and will continue from it." } };
            try out.append(arena, .{ .role = .assistant, .content = ack, .meta = .{ .synthetic = true } });
            const rb = try arena.alloc(proto.ContentBlock, 1);
            rb[0] = .{ .text = .{ .text = rtext } };
            try out.append(arena, .{ .role = .user, .content = rb, .meta = .{ .synthetic = true } });
        }
        try out.appendSlice(arena, history[hi..]);
        if (c.hooks) |h| if (h.post) |f| f(h.ctx, io, job.trigger, s) catch {};
        return .{ .messages = out.items, .summary = s, .tokens_before = before, .tokens_after = estimate(out.items), .model = c.model.id };
    }

    /// The re-injection text (empty when there is nothing to add).
    pub fn reinjection(c: *const Compactor, arena: Allocator, re: Reinject) Allocator.Error![]const u8 {
        var t: std.ArrayList(u8) = .empty;
        if (re.memory) |set| for (set.files) |f| {
            if (f.paths_globs.len > 0) continue;
            try t.print(arena, "<memory path=\"{s}\" scope=\"{s}\">\n{s}\n</memory>\n\n", .{ f.path, @tagName(f.scope), std.mem.trimEnd(u8, f.text, "\n") });
        };
        if (re.plan) |p| try t.print(arena, "# Current plan\n\n{s}\n\n", .{std.mem.trimEnd(u8, p, "\n")});
        if (re.skills.len > 0) {
            try t.appendSlice(arena, "# Skills\n\n");
            for (re.skills) |s| try t.print(arena, "- {s}: {s}\n", .{ s.name, s.description });
            try t.append(arena, '\n');
        }
        if (re.todos.len > 0) {
            try t.appendSlice(arena, "# Todos\n\n");
            for (re.todos) |td| try t.print(arena, "- [{s}] {s}\n", .{ switch (td.status) {
                .pending => " ",
                .in_progress => "~",
                .completed => "x",
            }, td.text });
            try t.append(arena, '\n');
        }
        const n = @min(re.recent_files.len, c.cfg.recent_files);
        for (re.recent_files[0..n]) |f| {
            const fits = if (f.text) |x| (x.len + 3) / 4 <= c.cfg.file_token_cap else false;
            if (fits) {
                try t.print(arena, "<file path=\"{s}\">\n{s}\n</file>\n\n", .{ f.path, std.mem.trimEnd(u8, f.text.?, "\n") });
            } else try t.print(arena, "Referenced file {s}\n\n", .{f.path});
        }
        if (re.background.len > 0) {
            try t.appendSlice(arena, "# Still running\n\n");
            for (re.background) |b| try t.print(arena, "- {s}\n", .{b});
        }
        return std.mem.trimEnd(u8, t.items, "\n");
    }
};

/// Adapts a compactor to the loop's `deps.Compaction` seam. `reinject`
/// is read at each compaction, so its owner keeps it current.
pub const LoopCompaction = struct {
    compactor: *Compactor,
    reinject: Reinject = .{},

    pub fn compaction(l: *LoopCompaction) deps.Compaction {
        return .{ .ctx = l, .should_compact = should, .compact = run };
    }

    fn should(ctx: *anyopaque, est_input_tokens: u64, window: u32) bool {
        const l: *LoopCompaction = @ptrCast(@alignCast(ctx));
        return l.compactor.shouldCompact(est_input_tokens, window) != null;
    }

    fn run(ctx: *anyopaque, io: Io, arena: Allocator, base: *const request.Request, history: []const proto.Message, overflow: bool) anyerror!deps.CompactedHistory {
        const l: *LoopCompaction = @ptrCast(@alignCast(ctx));
        const r = try l.compactor.compact(io, arena, base, history, l.reinject, .{ .trigger = if (overflow) .window_overflow else .auto_threshold });
        return .{ .messages = r.messages, .tokens_before = r.tokens_before, .tokens_after = r.tokens_after, .model = r.model, .fallback = r.fallback };
    }
};

/// Anthropic server-side context editing (`context-management-2025-06-27`).
pub const ContextEditing = struct {
    clear_thinking: bool = false,
    clear_tool_uses: ?struct {
        trigger_tokens: u32 = 100_000,
        keep_tool_uses: u32 = 3,
        exclude_tools: []const []const u8 = &.{},
    } = null,

    /// The beta header value.
    pub const beta = "context-management-2025-06-27";

    /// Enables the edits on an Anthropic request (`ai.anthropic.contextEditing`):
    /// adds the beta header and the body. Off by default because it changes
    /// cache behaviour.
    pub fn apply(ce: ContextEditing, arena: Allocator, req: *request.Request) Allocator.Error!void {
        const hs = try arena.alloc(request.Header, req.extra_headers.len + 1);
        @memcpy(hs[0..req.extra_headers.len], req.extra_headers);
        hs[req.extra_headers.len] = .{ .name = "anthropic-beta", .value = beta };
        req.extra_headers = hs;
        req.extra_body_json = try ce.bodyJson(arena);
    }

    /// `{"context_management":{"edits":[...]}}`; `clear_thinking` first.
    pub fn bodyJson(ce: ContextEditing, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var s: std.json.Stringify = .{ .writer = &out.writer };
        write(ce, &s) catch return error.OutOfMemory;
        return out.written();
    }

    fn write(ce: ContextEditing, s: *std.json.Stringify) !void {
        try s.beginObject();
        try s.objectField("context_management");
        try s.beginObject();
        try s.objectField("edits");
        try s.beginArray();
        if (ce.clear_thinking) {
            try s.beginObject();
            try s.objectField("type");
            try s.write("clear_thinking_20251015");
            try s.endObject();
        }
        if (ce.clear_tool_uses) |t| {
            try s.beginObject();
            try s.objectField("type");
            try s.write("clear_tool_uses_20250919");
            try s.objectField("trigger");
            try s.beginObject();
            try s.objectField("type");
            try s.write("input_tokens");
            try s.objectField("value");
            try s.write(t.trigger_tokens);
            try s.endObject();
            try s.objectField("keep");
            try s.beginObject();
            try s.objectField("type");
            try s.write("tool_uses");
            try s.objectField("value");
            try s.write(t.keep_tool_uses);
            try s.endObject();
            if (t.exclude_tools.len > 0) {
                try s.objectField("exclude_tools");
                try s.write(t.exclude_tools);
            }
            try s.endObject();
        }
        try s.endArray();
        try s.endObject();
        try s.endObject();
    }
};

/// Merges the instruction into a trailing user message so roles alternate.
fn mergeTrailingUser(arena: Allocator, msgs: []proto.Message) Allocator.Error![]const proto.Message {
    if (msgs.len < 2 or msgs[msgs.len - 2].role != .user) return msgs;
    const prev = msgs[msgs.len - 2];
    var m = prev;
    m.content = try std.mem.concat(arena, proto.ContentBlock, &.{ prev.content, msgs[msgs.len - 1].content });
    msgs[msgs.len - 2] = m;
    return msgs[0 .. msgs.len - 1];
}

/// Fallback: clear every tool result but the last `keep`.
fn clearOld(arena: Allocator, history: []const proto.Message, keep: u32) Allocator.Error![]const proto.Message {
    var total: usize = 0;
    for (history) |m| for (m.content) |b| {
        total += @intFromBool(b == .tool_result);
    };
    var to_clear = if (total > keep) total - keep else 0;
    const out = try arena.dupe(proto.Message, history);
    const parts = try arena.alloc(proto.ResultPart, 1);
    parts[0] = .{ .text = asm_mod.cleared_text };
    for (out) |*m| {
        if (to_clear == 0) break;
        var changed = false;
        const blocks = try arena.dupe(proto.ContentBlock, m.content);
        for (blocks) |*b| if (b.* == .tool_result and to_clear > 0) {
            b.tool_result.parts = parts;
            to_clear -= 1;
            changed = true;
        };
        if (changed) m.content = blocks;
    }
    return out;
}

/// Rough token estimate of messages (4 bytes per token).
pub fn estimate(msgs: []const proto.Message) u64 {
    var bytes: u64 = 0;
    for (msgs) |m| for (m.content) |b| {
        bytes += switch (b) {
            .text => |t| t.text.len,
            .thinking => |t| t.text.len,
            .tool_use => |t| t.input_json.len + t.name.len,
            .tool_result => |t| blk: {
                var n: u64 = 0;
                for (t.parts) |p| n += if (p == .text) p.text.len else 6000;
                break :blk n;
            },
            .image, .document => 6000,
            .provider_opaque => |o| o.raw_json.len,
        };
    };
    return (bytes + 3) / 4;
}
