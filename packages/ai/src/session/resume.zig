//! Resume (E10.F08.S02.T01): rebuilds an agent from its session file.
//!
//! 1. Load the chain tail-first, up to the latest compaction.
//! 2. Rebuild the state: the active history (after the latest compaction,
//!    without rewound messages), the model (header, then the latest
//!    `model_change` event, unless overridden), the agent definition
//!    (re-resolved, with a warning when it is gone) and the permission
//!    mode (the latest `mode` event under the E16 restore policy: bypass
//!    is never restored, plan is restored unless forking).
//! 3. Memory is reloaded by the new context assembler (F07.S01.T02).
//! 4. Publish `status=idle`.
//!
//! Tool calls cut off by a crash get "interrupted" results, written to the
//! session so the history stays valid. Background tasks that died with the
//! old process become notes.

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const loader = @import("loader.zig");
const store_mod = @import("store.zig");
const writer_mod = @import("writer.zig");
const fork_mod = @import("fork.zig");
const Agent = @import("../loop/Agent.zig");
const AgentManager = @import("../loop/Manager.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = proto.json;

/// E16 permission modes, as recorded in `mode` events.
pub const PermissionMode = enum { default, accept_edits, plan, bypass_permissions, dont_ask };

pub const ResumeOptions = struct {
    mode_override: ?PermissionMode = null,
    model_override: ?[]const u8 = null,
    /// Continue in a new session forked at the end of this one.
    fork: bool = false,
    /// An in-process `/branch` (session-scoped grants carry over); a
    /// cross-process fork starts without them.
    in_process: bool = false,
};

/// Re-resolves an agent definition by name (F09.S01).
pub const AgentResolver = struct {
    ctx: *anyopaque,
    exists: *const fn (ctx: *anyopaque, name: []const u8) bool,
};

/// The state rebuilt from a session. Slices live in the caller's arena.
pub const Restored = struct {
    /// The active history, plus interrupted results when calls were cut off.
    messages: []const proto.Message,
    seqs: []const u64,
    /// The highest sequence number in the session.
    last_seq: u64,
    model: []const u8,
    mode: PermissionMode,
    /// The agent definition in use, when it still exists.
    agent: ?[]const u8 = null,
    title: ?[]const u8 = null,
    /// The last `todo_changed` record's data (restore with
    /// `TodoStore.restore`).
    todos_json: ?[]const u8 = null,
    checkpoints: []const Agent.CheckpointMark,
    warnings: []const []const u8,
    /// Background tasks that died with the previous process.
    notes: []const []const u8,
    /// The last message is synthesized interrupted results.
    interrupted: bool = false,
};

/// Rebuilds the state from loaded lines (file order). `complete` is false
/// when the lines start after the beginning of the session (tail-first);
/// `error.NeedsFullLoad` then means a rewind reaches before them.
pub fn restore(a: Allocator, l: *const loader.LoadedSession, complete: bool, o: ResumeOptions, resolver: ?AgentResolver) !Restored {
    const Item = struct { seq: u64, line: *const records.Line };
    var items: std.ArrayList(Item) = .empty;
    var warnings: std.ArrayList([]const u8) = .empty;
    var tasks: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var model: []const u8 = l.header.model;
    var mode: PermissionMode = .default;
    var agent: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var todos_json: ?[]const u8 = null;
    var last_seq: u64 = 0;
    var first_seq: u64 = std.math.maxInt(u64);

    for (l.tail) |*line| {
        last_seq = @max(last_seq, line.seq);
        switch (line.record) {
            .user, .assistant, .tool_results, .compaction, .checkpoint => {
                first_seq = @min(first_seq, line.seq);
                try items.append(a, .{ .seq = line.seq, .line = line });
            },
            .rewind => |r| {
                if (!complete and r.to_seq < first_seq) return error.NeedsFullLoad;
                var keep: usize = 0;
                for (items.items) |it| if (it.seq <= r.to_seq) {
                    items.items[keep] = it;
                    keep += 1;
                };
                items.items.len = keep;
            },
            .title => |t| title = t,
            .event => |e| {
                const data = if (e.data_json.len > 0) json.parseValue(a, e.data_json) catch null else null;
                const obj = if (data) |d| json.asObject(d) else null;
                if (std.mem.eql(u8, e.kind, "model_change")) {
                    if (obj) |ob| if (json.str(ob, "model")) |m| {
                        model = m;
                    };
                } else if (std.mem.eql(u8, e.kind, "mode")) {
                    if (obj) |ob| if (json.str(ob, "mode")) |m| {
                        mode = std.meta.stringToEnum(PermissionMode, m) orelse mode;
                    };
                } else if (std.mem.eql(u8, e.kind, "agent")) {
                    if (obj) |ob| agent = json.str(ob, "name");
                } else if (std.mem.eql(u8, e.kind, "todo_changed")) {
                    todos_json = e.data_json;
                } else if (std.mem.eql(u8, e.kind, "task_started")) {
                    if (obj) |ob| if (json.str(ob, "id")) |id| try tasks.put(a, id, json.str(ob, "command") orelse id);
                } else if (std.mem.eql(u8, e.kind, "task_finished")) {
                    if (obj) |ob| if (json.str(ob, "id")) |id| {
                        _ = tasks.orderedRemove(id);
                    };
                }
            },
            .usage => |u| if (u.model.len > 0 and model.len == 0) {
                model = u.model;
            },
            else => {},
        }
    }

    // The active history starts at the latest surviving compaction.
    var head: u64 = 0;
    var compacted = false;
    for (items.items) |it| if (it.line.record == .compaction) {
        head = it.line.record.compaction.head_seq;
        compacted = true;
    };
    if (!complete and !compacted and l.tail_start > l.body_start) return error.NeedsFullLoad;

    var msgs: std.ArrayList(proto.Message) = .empty;
    var seqs: std.ArrayList(u64) = .empty;
    var marks: std.ArrayList(Agent.CheckpointMark) = .empty;
    for (items.items) |it| switch (it.line.record) {
        .checkpoint => |c| try marks.append(a, .{ .seq = it.seq, .id = c.id }),
        .compaction => {},
        else => if (it.seq >= head) {
            try msgs.append(a, it.line.record.message().?);
            try seqs.append(a, it.seq);
        },
    };
    // Calls cut off by a crash (the loader's view, or recomputed after rewinds).
    const lines = try a.alloc(records.Line, msgs.items.len);
    for (lines, msgs.items, seqs.items) |*x, m, s| x.* = .{ .seq = s, .t = 0, .record = records.Record.fromMessage(m) };
    const interrupted = try loader.interruptedResults(a, lines);
    if (interrupted) |m| {
        last_seq += 1;
        try msgs.append(a, m);
        try seqs.append(a, last_seq);
    }

    if (o.model_override) |m| model = m;
    // E16 restore policy.
    if (mode == .bypass_permissions) {
        mode = .default;
        try warnings.append(a, "Bypass permissions mode is not restored; the session resumes in default mode.");
    }
    if (mode == .plan and o.fork) mode = .default;
    if (o.mode_override) |m| mode = m;
    if (agent) |name| if (resolver) |r| if (!r.exists(r.ctx, name)) {
        try warnings.append(a, try std.fmt.allocPrint(a, "The agent definition \"{s}\" no longer exists; continuing with the default agent.", .{name}));
        agent = null;
    };

    var notes: std.ArrayList([]const u8) = .empty;
    for (tasks.values()) |cmd| try notes.append(a, try std.fmt.allocPrint(a, "Background task `{s}` stopped when the previous session ended.", .{cmd}));

    return .{
        .messages = msgs.items,
        .seqs = seqs.items,
        .last_seq = last_seq,
        .model = model,
        .mode = mode,
        .agent = agent,
        .title = title,
        .todos_json = todos_json,
        .checkpoints = marks.items,
        .warnings = warnings.items,
        .notes = notes.items,
        .interrupted = interrupted != null,
    };
}

/// What `resumeAgent` needs besides the manager.
pub const ResumeDeps = struct {
    store: *store_mod.SessionStore,
    /// Settings of the new agent (`model` and `session` are replaced).
    config: Agent.Config,
    resolver: ?AgentResolver = null,
};

/// A resumed agent and its session.
pub const Resumed = struct {
    arena: std.heap.ArenaAllocator,
    agent: *Agent,
    writer: *writer_mod.SessionWriter,
    /// The session written to (a new one when forking).
    session: proto.SessionId,
    state: Restored,
    /// Session-scoped permission grants carry over (in-process branch).
    carry_session_grants: bool,

    /// Closes the session writer and frees the state (the agent stays
    /// with its manager). Dispose of the agent first.
    pub fn deinit(r: *Resumed) void {
        r.writer.close();
        r.arena.deinit();
    }
};

/// Rebuilds the agent of session `id` in `m`.
pub fn resumeAgent(m: *AgentManager, io: Io, id: proto.SessionId, o: ResumeOptions, d: ResumeDeps) !Resumed {
    var r: Resumed = .{ .arena = .init(m.gpa), .agent = undefined, .writer = undefined, .session = id, .state = undefined, .carry_session_grants = o.fork and o.in_process };
    errdefer r.arena.deinit();
    const a = r.arena.allocator();

    // Read up to the latest compaction (the active history), or everything.
    var l = try fork_mod.openChain(d.store, io, id, .{ .tail_messages = std.math.maxInt(u32), .repair = !o.fork });
    defer l.deinit();
    r.state = restore(a, l, l.tail_start == l.body_start, o, d.resolver) catch |e| switch (e) {
        error.NeedsFullLoad => blk: {
            l.deinit();
            l = try fork_mod.openChain(d.store, io, id, .{ .mode = .full, .repair = !o.fork });
            break :blk try restore(a, l, true, o, d.resolver);
        },
        else => return e,
    };
    var last = r.state.last_seq;
    if (r.state.interrupted) last -= 1;

    if (o.fork) {
        r.session = try fork_mod.fork(d.store, io, id, last, null);
        last += 1;
        r.writer = try d.store.reopen(io, r.session, last);
    } else {
        r.writer = try d.store.reopen(io, id, last);
    }
    errdefer r.writer.close();
    if (r.state.interrupted) {
        last += 1;
        const msgs = @constCast(r.state.seqs);
        msgs[msgs.len - 1] = last;
        try r.writer.append(last, .{ .tool_results = r.state.messages[r.state.messages.len - 1] });
        try r.writer.sync();
    }

    var cfg = d.config;
    cfg.model = r.state.model;
    cfg.session = r.session;
    cfg.parent = null;
    var deps = m.deps;
    deps.session = r.writer.sessionLog();
    r.agent = try m.createWith(cfg, deps);
    errdefer m.dispose(r.agent);
    _ = try r.agent.subscribe(r.writer.subscriber());
    try r.agent.setTranscript(r.state.messages, r.state.seqs, last);
    try r.agent.setCheckpoints(r.state.checkpoints);
    r.agent.publish(.{ .status = .idle });
    return r;
}
