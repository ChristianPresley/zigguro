//! `ContextAssembler`: builds every provider-neutral `Request` from agent
//! state (E10.F07.S02.T01) and plugs into the loop as its
//! `ContextBuilder`.
//!
//! System prompt, stable-first: the base prompt (plus the plan-mode
//! addendum), the skills index, memory (managed, user, project, unscoped
//! rules, the rules index and the auto-memory index), the environment
//! block, then the plan. Dynamic items never touch the system prompt: they
//! are appended to the newest user message (after its tool results) as
//! `<system-reminder>` and `<context-item>` blocks, and remembered, so the
//! same message is byte-identical in every later request.
//!
//! Fitting: when the estimate exceeds the window minus the output cap, the
//! oldest tool results (all but the last `keep_tool_results`) are replaced
//! with a placeholder, again remembered; if it still does not fit,
//! `error.ContextOverflow` (the loop compacts first, F07.S03).
//!
//! Provenance: only harness and memory text reaches `system`; tool results,
//! web pages and MCP output stay in user-role messages. `provenance` in the
//! report records the origin of every system part.

const std = @import("std");
const proto = @import("zg_ai_proto");
const request = @import("../provider/request.zig");
const deps = @import("../loop/deps.zig");
const registry = @import("../models/registry.zig");
const estimate = @import("../models/estimate.zig");
const memory = @import("memory.zig");
const reminders = @import("reminders.zig");
const pins = @import("pins.zig");
const cache_plan = @import("cache_plan.zig");
const env_block = @import("env_block.zig");
const auto_memory = @import("auto_memory.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The embedded base prompt.
pub const base_prompt = @embedFile("base_prompt.md");
/// Added after the base prompt in plan mode.
pub const plan_mode_prompt = @embedFile("plan_mode.md");
/// Recorded in session metadata; bump when the base prompt changes.
pub const prompt_version = "zigguro-base-1";

/// Replaces cleared tool-result contents.
pub const cleared_text = "[cleared to save context; re-run the tool if needed]";

/// A skill as listed in the system prompt.
pub const SkillSummary = struct { name: []const u8, description: []const u8 };

/// One todo item.
pub const Todo = struct {
    text: []const u8,
    status: enum { pending, in_progress, completed } = .pending,
};

/// Permission mode (E16), as far as the prompt cares.
pub const Mode = enum { default, plan, accept_edits, bypass };

/// Where a piece of request text came from.
pub const Origin = enum { system_trusted, user, tool_untrusted };

/// Agent state the assembler reads. Slices are borrowed and must stay
/// valid while the agent runs; update fields between turns.
pub const State = struct {
    env: env_block.Env,
    memory: ?*const memory.MemorySet = null,
    /// Auto-memory index text (`AutoMemory.loadIndex`), when enabled.
    auto_memory_index: ?[]const u8 = null,
    plan: ?[]const u8 = null,
    todos: []const Todo = &.{},
    skills: []const SkillSummary = &.{},
    mode: Mode = .default,
};

pub const Options = struct {
    /// `ai.cache.longTtl`: one-hour TTL for the breakpoints.
    long_ttl: bool = false,
    /// Tool results never cleared when fitting.
    keep_tool_results: u32 = 3,
    base_prompt: []const u8 = base_prompt,
    /// Subagents: no skills index, auto memory or plan.
    minimal: bool = false,
    /// Token budget for resolving pins and mentions.
    attach_budget: u32 = 20_000,
};

/// One line of `/context`.
pub const Section = struct { name: []const u8, tokens: u64 };

/// What the last build produced.
pub const Report = struct {
    sections: []const Section = &.{},
    total_tokens: u64 = 0,
    window: u32 = 0,
    /// Tool results cleared so far.
    cleared: u32 = 0,
    provenance: []const Origin = &.{},
};

pub const ContextAssembler = struct {
    gpa: Allocator,
    state: State,
    opts: Options,
    queue: *reminders.ReminderQueue,
    resolver: ?pins.ContextResolver = null,
    estimator: ?*estimate.TokenEstimator = null,
    pinned: pins.PinSet,
    /// Owns injected blocks, mentions and cleared-result bookkeeping.
    persist: std.heap.ArenaAllocator,
    /// Extra blocks appended to transcript message `index`.
    injected: std.AutoHashMapUnmanaged(u32, []const proto.ContentBlock) = .empty,
    /// Cleared tool results: `index << 16 | block`.
    cleared: std.AutoHashMapUnmanaged(u64, void) = .empty,
    mentions: std.ArrayList(proto.ContextRef) = .empty,
    /// Token estimates by content hash.
    token_cache: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    last_todos: u64 = 0,
    last_mode: Mode = .default,
    report_arena: std.heap.ArenaAllocator,
    report: Report = .{},

    pub fn init(gpa: Allocator, queue: *reminders.ReminderQueue, state: State, opts: Options) ContextAssembler {
        return .{ .gpa = gpa, .state = state, .opts = opts, .queue = queue, .pinned = .init(gpa), .persist = .init(gpa), .report_arena = .init(gpa), .last_mode = state.mode, .last_todos = todosHash(state.todos) };
    }

    pub fn deinit(a: *ContextAssembler) void {
        a.injected.deinit(a.gpa);
        a.cleared.deinit(a.gpa);
        a.token_cache.deinit(a.gpa);
        a.pinned.deinit();
        a.persist.deinit();
        a.report_arena.deinit();
    }

    /// The loop seam.
    pub fn builder(a: *ContextAssembler) deps.ContextBuilder {
        return .{ .ctx = a, .build = buildThunk };
    }

    fn buildThunk(ctx: *anyopaque, io: Io, arena: Allocator, view: *const deps.ContextView) anyerror!request.Request {
        const a: *ContextAssembler = @ptrCast(@alignCast(ctx));
        return a.build(io, arena, view);
    }

    pub fn pin(a: *ContextAssembler, ref: proto.ContextRef) Allocator.Error!void {
        try a.pinned.add(ref);
    }

    pub fn unpin(a: *ContextAssembler, ref: proto.ContextRef) bool {
        return a.pinned.remove(ref);
    }

    /// Attaches `refs` to the next request's newest user message, once.
    pub fn mention(a: *ContextAssembler, refs: []const proto.ContextRef) Allocator.Error!void {
        for (refs) |r| try a.mentions.append(a.persist.allocator(), try pins.cloneRef(a.persist.allocator(), r));
    }

    /// Forgets per-message state after the transcript head moved (compaction
    /// or rewind): injections and cleared results for indices at or after
    /// `from` are dropped.
    pub fn forgetFrom(a: *ContextAssembler, from: u32) void {
        var it = a.injected.iterator();
        var drop: std.ArrayList(u32) = .empty;
        defer drop.deinit(a.gpa);
        while (it.next()) |e| if (e.key_ptr.* >= from) drop.append(a.gpa, e.key_ptr.*) catch {};
        for (drop.items) |k| _ = a.injected.remove(k);
        var cit = a.cleared.iterator();
        var cdrop: std.ArrayList(u64) = .empty;
        defer cdrop.deinit(a.gpa);
        while (cit.next()) |e| if (e.key_ptr.* >> 16 >= from) cdrop.append(a.gpa, e.key_ptr.*) catch {};
        for (cdrop.items) |k| _ = a.cleared.remove(k);
    }

    /// Loads memory that applies after the agent touched `path` and queues
    /// newly loaded files as reminders.
    pub fn fileTouched(a: *ContextAssembler, io: Io, loader: *memory.MemoryLoader, path: []const u8) !void {
        const added = try loader.onFileTouched(io, path);
        for (added) |f| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(a.gpa);
            try buf.print(a.gpa, "Instructions from {s} now apply:\n\n{s}", .{ f.path, f.text });
            a.queue.push(.rule_loaded, buf.items);
        }
    }

    /// Builds the next request.
    pub fn build(a: *ContextAssembler, io: Io, arena: Allocator, view: *const deps.ContextView) !request.Request {
        const model = view.model;
        var sections: std.ArrayList(Section) = .empty;
        const ra = blk: {
            _ = a.report_arena.reset(.retain_capacity);
            break :blk a.report_arena.allocator();
        };

        // Tools.
        var decl_list: std.ArrayList(request.ToolDecl) = .empty;
        var tool_tokens: u64 = 0;
        for (view.tools) |*t| {
            const d = request.declFor(t, model.provider) orelse continue;
            try decl_list.append(arena, d);
            tool_tokens += a.tokens(model, t.name) + a.tokens(model, t.description) + a.tokens(model, d.raw_json orelse t.input_schema_json);
        }
        const decls = decl_list.items;
        // The breakpoint goes on the last function tool (native ones are sent verbatim).
        if (cache_plan.worth(tool_tokens, model.cache_min_tokens)) {
            var k = decls.len;
            while (k > 0) : (k -= 1) if (decls[k - 1].kind == .function) {
                decls[k - 1].cache_break = true;
                break;
            };
        }
        try sections.append(ra, .{ .name = "tools", .tokens = tool_tokens });

        // System prompt.
        var sys: std.ArrayList(request.SystemPart) = .empty;
        var prov: std.ArrayList(Origin) = .empty;
        var base = a.opts.base_prompt;
        if (a.state.mode == .plan) base = try std.mem.concat(arena, u8, &.{ base, "\n", plan_mode_prompt });
        try sys.append(arena, .{ .text = base });
        if (view.system_append) |s| try sys.append(arena, .{ .text = s });
        if (!a.opts.minimal and a.state.skills.len > 0) {
            var t: std.ArrayList(u8) = .empty;
            try t.appendSlice(arena, "# Skills\n\nRead a skill's SKILL.md before using it.\n");
            for (a.state.skills) |s| try t.print(arena, "- {s}: {s}\n", .{ s.name, s.description });
            try sys.append(arena, .{ .text = t.items });
        }
        var sys_tokens: u64 = 0;
        for (sys.items) |p| sys_tokens += a.tokens(model, p.text);
        try sections.append(ra, .{ .name = "system", .tokens = sys_tokens });
        const memory_start = sys.items.len;
        if (a.state.memory) |set| {
            for (set.files) |f| {
                if (f.paths_globs.len > 0) continue; // scoped rules arrive as reminders
                const text = try std.fmt.allocPrint(arena, "<memory path=\"{s}\" scope=\"{s}\">\n{s}\n</memory>", .{ f.path, @tagName(f.scope), std.mem.trimEnd(u8, f.text, "\n") });
                try sys.append(arena, .{ .text = text });
                try sections.append(ra, .{ .name = try ra.dupe(u8, f.path), .tokens = a.tokens(model, text) });
            }
            if (set.rules_index.len > 0) {
                var t: std.ArrayList(u8) = .empty;
                try t.appendSlice(arena, "# Rules available on request\n\nRead one with read_file when its description fits the task.\n");
                for (set.rules_index) |r| try t.print(arena, "- {s}: {s}\n", .{ r.path, r.description });
                try sys.append(arena, .{ .text = t.items });
                try sections.append(ra, .{ .name = "rules index", .tokens = a.tokens(model, t.items) });
            }
        }
        if (!a.opts.minimal) if (a.state.auto_memory_index) |ix| {
            const text = try std.fmt.allocPrint(arena, "{s}\n## MEMORY.md\n\n{s}", .{ auto_memory.prompt, ix });
            try sys.append(arena, .{ .text = text });
            try sections.append(ra, .{ .name = "auto memory", .tokens = a.tokens(model, text) });
        };
        for (sys.items[memory_start..]) |p| sys_tokens += a.tokens(model, p.text);
        // Breakpoint 2: end of the memory section (or of the base prompt).
        if (cache_plan.worth(tool_tokens + sys_tokens, model.cache_min_tokens)) sys.items[sys.items.len - 1].cache_break = true;
        const env = try env_block.render(arena, a.state.env);
        try sys.append(arena, .{ .text = env });
        sys_tokens += a.tokens(model, env);
        if (!a.opts.minimal) if (a.state.plan) |p| {
            const text = try std.fmt.allocPrint(arena, "# Current plan\n\n{s}", .{p});
            try sys.append(arena, .{ .text = text, .stable = false });
            sys_tokens += a.tokens(model, text);
            try sections.append(ra, .{ .name = "plan", .tokens = a.tokens(model, text) });
        };
        for (sys.items) |_| try prov.append(ra, .system_trusted);

        // Dynamic additions to the newest user message.
        const msgs = view.transcript;
        if (msgs.len > 0 and msgs[msgs.len - 1].role == .user) try a.attach(io, arena, view.head + @as(u32, @intCast(msgs.len - 1)));

        // Messages with injections and cleared results applied.
        const out = try arena.alloc(proto.Message, msgs.len);
        for (msgs, out, 0..) |m, *o, i| o.* = try a.sent(arena, view.head + @as(u32, @intCast(i)), m);

        var msg_tokens = try arena.alloc(u64, out.len);
        var hist: u64 = 0;
        for (out, 0..) |m, i| {
            msg_tokens[i] = a.messageTokens(model, m);
            hist += msg_tokens[i];
        }
        try sections.append(ra, .{ .name = "messages", .tokens = hist });

        // Window fitting: clear the oldest tool results.
        const limit: u64 = if (model.context_window > view.max_output_tokens) model.context_window - view.max_output_tokens else 0;
        var total = tool_tokens + sys_tokens + hist;
        if (total > limit) {
            const results = try a.toolResultPositions(arena, out);
            const clearable = if (results.len > a.opts.keep_tool_results) results.len - a.opts.keep_tool_results else 0;
            for (results[0..clearable]) |pos| {
                if (total <= limit) break;
                const k = (@as(u64, view.head + pos.msg) << 16) | pos.block;
                if (a.cleared.contains(k)) continue;
                try a.cleared.put(a.gpa, k, {});
                const before = msg_tokens[pos.msg];
                out[pos.msg] = try a.sent(arena, view.head + pos.msg, msgs[pos.msg]);
                msg_tokens[pos.msg] = a.messageTokens(model, out[pos.msg]);
                total = total - before + msg_tokens[pos.msg];
            }
            if (total > limit) return error.ContextOverflow;
        }

        // Breakpoints 3 and 4.
        const prefix = try arena.alloc(u64, out.len);
        var acc = tool_tokens + sys_tokens;
        var summary: ?u32 = null;
        for (out, 0..) |m, i| {
            acc += msg_tokens[i];
            prefix[i] = acc;
            if (m.meta.synthetic and m.role == .user and m.content.len > 0 and m.content[0] == .text and std.mem.startsWith(u8, m.content[0].text.text, compaction_marker)) summary = @intCast(i);
        }
        const breaks = try cache_plan.messageBreaks(arena, prefix, model.cache_min_tokens, summary);

        a.report = .{ .sections = sections.items, .total_tokens = total, .window = model.context_window, .cleared = @intCast(a.cleared.count()), .provenance = prov.items };
        return .{
            .model = model.id,
            .system = sys.items,
            .messages = out,
            .tools = decls,
            .max_output_tokens = view.max_output_tokens,
            .thinking = view.profile.thinking,
            .effort = view.profile.effort,
            .temperature = view.profile.temperature,
            .cache = .{ .ttl = if (a.opts.long_ttl) .h1 else .m5, .message_breaks = breaks },
        };
    }

    /// Resolves mentions and pins and drains reminders into blocks that
    /// are remembered for transcript message `index`.
    fn attach(a: *ContextAssembler, io: Io, arena: Allocator, index: u32) !void {
        const pa = a.persist.allocator();
        var blocks: std.ArrayList(proto.ContentBlock) = .empty;

        if (a.resolver) |r| {
            if (a.mentions.items.len > 0) {
                const items = try r.resolve(r.ctx, io, arena, a.mentions.items, a.opts.attach_budget);
                for (items) |it| try blocks.append(pa, .{ .text = .{ .text = try pins.renderItem(pa, it) } });
                a.mentions.clearRetainingCapacity();
            }
            if (a.pinned.items.items.len > 0) {
                const refs = try arena.alloc(proto.ContextRef, a.pinned.items.items.len);
                for (a.pinned.items.items, refs) |p, *x| x.* = p.ref;
                const items = try r.resolve(r.ctx, io, arena, refs, a.opts.attach_budget);
                for (a.pinned.items.items, items) |*p, it| {
                    if (p.attached) |h| {
                        if (h == it.version_hash) continue;
                        var lb: [512]u8 = undefined;
                        const msg = try std.fmt.allocPrint(arena, "{s} changed since it was attached; the fresh excerpt follows.", .{pins.refLabel(&lb, it.ref)});
                        try blocks.append(pa, .{ .text = .{ .text = try reminders.wrap(pa, msg) } });
                    }
                    try blocks.append(pa, .{ .text = .{ .text = try pins.renderItem(pa, it) } });
                    p.attached = it.version_hash;
                }
            }
        }

        const th = todosHash(a.state.todos);
        if (th != a.last_todos) {
            a.last_todos = th;
            var t: std.ArrayList(u8) = .empty;
            try t.appendSlice(arena, "The todo list changed:\n");
            for (a.state.todos) |td| try t.print(arena, "- [{s}] {s}\n", .{ switch (td.status) {
                .pending => " ",
                .in_progress => "~",
                .completed => "x",
            }, td.text });
            a.queue.push(.todo, t.items);
        }
        if (a.state.mode != a.last_mode) {
            a.last_mode = a.state.mode;
            const t = try std.fmt.allocPrint(arena, "The permission mode is now {s}.", .{@tagName(a.state.mode)});
            a.queue.push(.mode, t);
        }
        for (try a.queue.drain(pa)) |t| try blocks.append(pa, .{ .text = .{ .text = t } });

        if (blocks.items.len == 0) return;
        const prev = a.injected.get(index) orelse &.{};
        const all = try std.mem.concat(pa, proto.ContentBlock, &.{ prev, blocks.items });
        try a.injected.put(a.gpa, index, all);
    }

    /// Message `index` as sent: injected blocks appended, cleared results replaced.
    fn sent(a: *ContextAssembler, arena: Allocator, index: u32, m: proto.Message) Allocator.Error!proto.Message {
        const extra = a.injected.get(index) orelse &.{};
        var any_cleared = false;
        for (m.content, 0..) |b, bi| if (b == .tool_result and a.cleared.contains((@as(u64, index) << 16) | bi)) {
            any_cleared = true;
        };
        if (extra.len == 0 and !any_cleared) return m;
        const blocks = try std.mem.concat(arena, proto.ContentBlock, &.{ m.content, extra });
        if (any_cleared) for (blocks[0..m.content.len], 0..) |*b, bi| if (b.* == .tool_result and a.cleared.contains((@as(u64, index) << 16) | bi)) {
            b.tool_result.parts = &cleared_parts;
        };
        var c = m;
        c.content = blocks;
        return c;
    }

    const Pos = struct { msg: u32, block: u16 };

    fn toolResultPositions(_: *ContextAssembler, arena: Allocator, msgs: []const proto.Message) Allocator.Error![]const Pos {
        var out: std.ArrayList(Pos) = .empty;
        for (msgs, 0..) |m, i| for (m.content, 0..) |b, bi| if (b == .tool_result) try out.append(arena, .{ .msg = @intCast(i), .block = @intCast(bi) });
        return out.items;
    }

    fn tokens(a: *ContextAssembler, model: *const registry.ModelInfo, text: []const u8) u64 {
        if (text.len == 0) return 0;
        const h = std.hash.XxHash3.hash(text.len, text);
        if (a.token_cache.get(h)) |t| return t;
        const t: u32 = if (a.estimator) |e| e.estimate(model.family, text) else @intCast(@min((text.len + 3) / 4, std.math.maxInt(u32)));
        a.token_cache.put(a.gpa, h, t) catch {};
        return t;
    }

    fn messageTokens(a: *ContextAssembler, model: *const registry.ModelInfo, m: proto.Message) u64 {
        var n: u64 = 4;
        for (m.content) |b| n += switch (b) {
            .text => |t| a.tokens(model, t.text),
            .thinking => |t| a.tokens(model, t.text),
            .tool_use => |t| a.tokens(model, t.input_json) + 8,
            .tool_result => |t| blk: {
                var x: u64 = 8;
                for (t.parts) |p| x += switch (p) {
                    .text => |s| a.tokens(model, s),
                    else => 1500,
                };
                break :blk x;
            },
            .image, .document => 1500,
            .provider_opaque => |o| a.tokens(model, o.raw_json),
        };
        return n;
    }
};

/// The first text of the synthetic message that starts a compacted history.
pub const compaction_marker = "[Conversation compacted. Summary follows.]";

const cleared_parts = [_]proto.ResultPart{.{ .text = cleared_text }};

fn todosHash(todos: []const Todo) u64 {
    var h: std.hash.XxHash3 = .init(0);
    for (todos) |t| {
        h.update(t.text);
        h.update(&[1]u8{@intFromEnum(t.status)});
    }
    return if (todos.len == 0) 0 else h.final();
}
