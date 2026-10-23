//! The provenance recorder (E09.F05.S01.T01): receives edit events from
//! the editor and agent tools, and at snapshot time turns them into each
//! file's attribution map.
//!
//! - `onEdit` (any thread, O(1)) queues the event. The worker side
//!   (`drain`, `attributionFor`, `flush`; one thread at a time, the
//!   ScmService worker) interns a record per (actor, prompt, review) and
//!   keeps each file's pending splices.
//! - `attributionFor` applies the splices to the previous snapshot's map.
//!   A line replaced by a different actor than the one that wrote it
//!   becomes `mixed`: a new record whose parent is the old one. When the
//!   result disagrees with the new blob (edits nobody reported), the file
//!   is reconciled by a line diff: changed lines go to the tool that
//!   wrote the whole file when its hash matches, else to the human if
//!   they were at the keyboard within `focus_window_ms`, else `unknown`.
//! - `flush` writes the new records (and full prompts) into the
//!   snapshot's batch. Maps persist in the change's manifest, so nothing
//!   else needs saving across restarts.
//!
//! Prompts are kept per `PromptPrivacy`: no bytes for `none` and `hash`.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const record = @import("record.zig");
const attribution = @import("attribution.zig");
const ObjectId = id_mod.ObjectId;
const Actor = record.Actor;
const ProvenanceRecord = record.ProvenanceRecord;
const ProvenanceId = record.ProvenanceId;
const AttributionMap = attribution.AttributionMap;
const Seg = attribution.Seg;
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Lines old_start_line..+old_len replaced by new_len lines. The ranges of
/// one event are in the coordinates of the text before the event and do
/// not overlap.
pub const LineRange = struct { old_start_line: u32, old_len: u32, new_len: u32 };

pub const EditEvent = struct {
    /// Workspace-relative, '/'-separated.
    path: []const u8,
    workspace: []const u8,
    /// The E05 document version the ranges apply to (editor events).
    base_version: ?u64 = null,
    ranges: []const LineRange,
    actor: Actor,
    prompt: ?[]const u8 = null,
    review: ?record.ReviewRef = null,
    at_ms: i64,
};

/// The E16 secret scanner hook for prompt excerpts.
pub const Redactor = struct {
    ctx: *anyopaque,
    redact: *const fn (ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8,
};

pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now_ms: *const fn (ctx: ?*anyopaque) i64,
};

pub const RecorderConfig = struct {
    privacy: record.PromptPrivacy = .excerpt,
    excerpt_bytes: u32 = 512,
    redact: ?Redactor = null,
    /// Unreported edits count as human when a human editor had focus this
    /// recently.
    focus_window_ms: i64 = 2000,
    /// Null: the real clock.
    clock: ?Clock = null,
    /// The human at the keyboard (zg-config user identity).
    user: Actor = .{ .kind = .human },
};

/// E05's `EditOrigin`, mirrored (zg_scm does not depend on zg_editor).
pub const EditorOrigin = union(enum) {
    user,
    undo,
    redo,
    /// An agent session (E10's numeric id).
    agent: u32,
    reload,
    lsp_edit,
    format,
};

/// E10's session registry: the agent actor of a session.
pub const SessionLookup = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, session: u32) ?Actor,
};

/// Who an editor change is attributed to; null for reloads (snapshot
/// reconciliation handles those).
pub fn adaptOrigin(origin: EditorOrigin, user: Actor, sessions: ?SessionLookup) ?Actor {
    return switch (origin) {
        .user, .undo, .redo => user,
        .agent => |s| (if (sessions) |l| l.get(l.ctx, s) else null) orelse .{ .kind = .agent, .name = "agent" },
        .lsp_edit => Actor.tool("lsp.edit"),
        .format => Actor.tool("formatter"),
        .reload => null,
    };
}

/// An editor change as an `EditEvent`, or null for reloads.
pub fn adaptEditorChange(origin: EditorOrigin, path: []const u8, workspace: []const u8, version: ?u64, ranges: []const LineRange, user: Actor, sessions: ?SessionLookup, at_ms: i64) ?EditEvent {
    const actor = adaptOrigin(origin, user, sessions) orelse return null;
    return .{ .path = path, .workspace = workspace, .base_version = version, .ranges = ranges, .actor = actor, .at_ms = at_ms };
}

/// One splice, its record resolved.
const Splice = struct {
    range: LineRange,
    prov: ProvenanceId,
};

const FileWrite = struct { actor: Actor, hash: [32]u8 };

pub const Recorder = struct {
    gpa: Allocator,
    io: Io,
    store: *store_mod.Store,
    cfg: RecorderConfig,

    // Shared with `onEdit` callers, under `mutex`.
    mutex: Io.Mutex = .init,
    queue: std.ArrayList(EditEvent) = .empty,
    /// Per workspace: the latest agent actor (owned).
    agents: std.StringHashMapUnmanaged(Actor) = .empty,
    /// Per workspace: when a human editor last had focus.
    focus: std.StringHashMapUnmanaged(i64) = .empty,
    /// Per "workspace\x00path": a whole-file write by a tool.
    writes: std.StringHashMapUnmanaged(FileWrite) = .empty,

    // Worker side.
    /// Per "workspace\x00path": splices since the last snapshot.
    pending: std.StringHashMapUnmanaged(std.ArrayList(Splice)) = .empty,
    /// Interning key → record.
    interned: std.StringHashMapUnmanaged(ProvenanceId) = .empty,
    /// Actors of known records (interned or read), by record ID.
    actors: std.AutoHashMapUnmanaged([32]u8, Actor) = .empty,
    /// Encoded records and prompt texts not yet written.
    unwritten: std.ArrayList(struct { kind: id_mod.Kind, bytes: []u8 }) = .empty,

    pub fn init(gpa: Allocator, io: Io, store: *store_mod.Store, cfg: RecorderConfig) !*Recorder {
        const r = try gpa.create(Recorder);
        r.* = .{ .gpa = gpa, .io = io, .store = store, .cfg = cfg };
        return r;
    }

    pub fn deinit(r: *Recorder) void {
        const gpa = r.gpa;
        for (r.queue.items) |*e| freeEvent(gpa, e.*);
        r.queue.deinit(gpa);
        freeActorMap(gpa, &r.agents, true);
        freeKeys(gpa, &r.focus);
        var wi = r.writes.iterator();
        while (wi.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.actor.free(gpa);
        }
        r.writes.deinit(gpa);
        var pi = r.pending.iterator();
        while (pi.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        r.pending.deinit(gpa);
        freeKeys(gpa, &r.interned);
        var ai = r.actors.valueIterator();
        while (ai.next()) |a| a.free(gpa);
        r.actors.deinit(gpa);
        for (r.unwritten.items) |u| gpa.free(u.bytes);
        r.unwritten.deinit(gpa);
        gpa.destroy(r);
    }

    fn now(r: *const Recorder) i64 {
        if (r.cfg.clock) |c| return c.now_ms(c.ctx);
        return @intCast(@divTrunc(Io.Timestamp.now(r.io, .real).nanoseconds, std.time.ns_per_ms));
    }

    /// Queues `ev` (copied). Cheap enough for document listeners on the
    /// UI thread; drops the event when out of memory.
    pub fn onEdit(r: *Recorder, ev: EditEvent) void {
        const copy = dupeEvent(r.gpa, ev) catch return;
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.queue.append(r.gpa, copy) catch return freeEvent(r.gpa, copy);
        if (ev.actor.kind == .agent) setActor(r.gpa, &r.agents, ev.workspace, ev.actor) catch {};
        if (ev.actor.kind == .human) setFocus(r, ev.workspace, ev.at_ms);
    }

    /// A tool wrote `path` whole; when the snapshot finds exactly that
    /// content, changed lines are the tool's.
    pub fn onFileWritten(r: *Recorder, path: []const u8, workspace: []const u8, actor: Actor, content_hash: [32]u8) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const key = fileKey(r.gpa, workspace, path) catch return;
        const a = actor.dupe(r.gpa) catch return r.gpa.free(key);
        const gop = r.writes.getOrPut(r.gpa, key) catch {
            a.free(r.gpa);
            return r.gpa.free(key);
        };
        if (gop.found_existing) {
            r.gpa.free(key);
            gop.value_ptr.actor.free(r.gpa);
        }
        gop.value_ptr.* = .{ .actor = a, .hash = content_hash };
    }

    /// A human editor of `workspace` has focus (E01 window focus).
    pub fn noteFocus(r: *Recorder, workspace: []const u8, at_ms: i64) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        setFocus(r, workspace, at_ms);
    }

    /// The agent editing `workspace` (for `OpMeta.actor`), copied into
    /// `arena`; null after `endTurn` or before any agent edit.
    pub fn activeAgentActor(r: *Recorder, arena: Allocator, workspace: []const u8) !?Actor {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const a = r.agents.get(workspace) orelse return null;
        return try a.dupe(arena);
    }

    /// The agent's turn in `workspace` ended.
    pub fn endTurn(r: *Recorder, workspace: []const u8) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        if (r.agents.fetchRemove(workspace)) |kv| {
            r.gpa.free(kv.key);
            kv.value.free(r.gpa);
        }
    }

    /// Worker: turns queued events into pending splices.
    pub fn drain(r: *Recorder) !void {
        var batch: std.ArrayList(EditEvent) = .empty;
        {
            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);
            batch = r.queue;
            r.queue = .empty;
        }
        defer {
            for (batch.items) |e| freeEvent(r.gpa, e);
            batch.deinit(r.gpa);
        }
        for (batch.items) |ev| {
            const prov = try r.intern(ev.actor, ev.prompt, ev.review, null, ev.at_ms);
            const key = try fileKey(r.gpa, ev.workspace, ev.path);
            const gop = r.pending.getOrPut(r.gpa, key) catch |e| {
                r.gpa.free(key);
                return e;
            };
            if (gop.found_existing) r.gpa.free(key) else gop.value_ptr.* = .empty;
            // Last range first, so earlier coordinates stay valid.
            var i = ev.ranges.len;
            while (i > 0) {
                i -= 1;
                try gop.value_ptr.append(r.gpa, .{ .range = ev.ranges[i], .prov = prov });
            }
        }
    }

    /// The record for (actor, prompt, review, parent), interned; written
    /// at the next `flush`.
    pub fn intern(r: *Recorder, actor: Actor, prompt: ?[]const u8, review: ?record.ReviewRef, parent: ?ProvenanceId, at_ms: i64) !ProvenanceId {
        const KeyT = struct { actor: Actor, prompt: ?ObjectId, review: ?record.ReviewRef, parent: ?ObjectId };
        const key = try enc.encodeAlloc(r.gpa, KeyT, .{ .actor = actor, .prompt = if (prompt) |p| record.promptHash(p) else null, .review = review, .parent = parent });
        if (r.interned.get(key)) |id| {
            r.gpa.free(key);
            return id;
        }
        errdefer r.gpa.free(key);
        var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena_state.deinit();
        const ref: ?record.PromptRef = if (prompt) |p| try r.promptRef(arena_state.allocator(), p) else null;
        const rec: ProvenanceRecord = .{ .actor = actor, .created_ms = at_ms, .prompt = ref, .review = review, .parent = parent };
        const bytes = try enc.encodeAlloc(r.gpa, ProvenanceRecord, rec);
        errdefer r.gpa.free(bytes);
        const id = id_mod.hashObject(.prov_record, bytes);
        try r.unwritten.ensureUnusedCapacity(r.gpa, 1);
        try r.interned.ensureUnusedCapacity(r.gpa, 1);
        try r.rememberActor(id, actor);
        r.unwritten.appendAssumeCapacity(.{ .kind = .prov_record, .bytes = bytes });
        r.interned.putAssumeCapacity(key, id);
        return id;
    }

    fn promptRef(r: *Recorder, arena: Allocator, p: []const u8) !record.PromptRef {
        const h = record.promptHash(p);
        return switch (r.cfg.privacy) {
            .none => .{ .privacy = .none },
            .hash => .{ .privacy = .hash, .hash = h },
            .excerpt => blk: {
                var cut: usize = @min(p.len, r.cfg.excerpt_bytes);
                while (cut > 0 and cut < p.len and (p[cut] & 0xC0) == 0x80) cut -= 1;
                const ex = if (r.cfg.redact) |red| try red.redact(red.ctx, arena, p[0..cut]) else p[0..cut];
                break :blk .{ .privacy = .excerpt, .hash = h, .excerpt = ex };
            },
            .full => blk: {
                const bytes = try r.gpa.dupe(u8, p);
                errdefer r.gpa.free(bytes);
                const id = id_mod.hashObject(.text, bytes);
                try r.unwritten.append(r.gpa, .{ .kind = .text, .bytes = bytes });
                break :blk .{ .privacy = .full, .hash = h, .text = id };
            },
        };
    }

    fn rememberActor(r: *Recorder, id: ProvenanceId, actor: Actor) !void {
        const gop = try r.actors.getOrPut(r.gpa, id.bytes);
        if (gop.found_existing) return;
        gop.value_ptr.* = actor.dupe(r.gpa) catch |e| {
            _ = r.actors.remove(id.bytes);
            return e;
        };
    }

    /// The actor of record `id` (read from the store when not seen yet).
    fn actorOf(r: *Recorder, id: ProvenanceId) !Actor {
        if (r.actors.get(id.bytes)) |a| return a;
        var arena_state: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena_state.deinit();
        const ref = try r.store.read(id);
        defer ref.release();
        if (ref.kind != .prov_record) return error.WrongKind;
        const rec = try enc.decode(ProvenanceRecord, arena_state.allocator(), try arena_state.allocator().dupe(u8, ref.bytes));
        try r.rememberActor(id, rec.actor);
        return r.actors.get(id.bytes).?;
    }

    /// Worker: the attribution of `path` at `new_blob`, given the previous
    /// snapshot's map and text (null for a file new to this change, whose
    /// lines are then all written by it). Consumes the file's pending
    /// splices and whole-file write. The result lives in `arena`.
    pub fn attributionFor(r: *Recorder, arena: Allocator, workspace: []const u8, path: []const u8, old: ?AttributionMap, old_blob: ?[]const u8, new_blob: []const u8) !AttributionMap {
        try r.drain();
        const key = try fileKey(r.gpa, workspace, path);
        defer r.gpa.free(key);
        var splices: std.ArrayList(Splice) = .empty;
        if (r.pending.fetchRemove(key)) |kv| {
            r.gpa.free(kv.key);
            splices = kv.value;
        }
        defer splices.deinit(r.gpa);
        var write: ?FileWrite = null;
        {
            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);
            if (r.writes.fetchRemove(key)) |kv| {
                r.gpa.free(kv.key);
                write = kv.value;
            }
        }
        defer if (write) |w| w.actor.free(r.gpa);

        const old_text = old_blob orelse "";
        const base_lines = attribution.lineCountOf(old_text);
        var base = if (old) |m| try attribution.Builder.initFrom(r.gpa, m) else try attribution.Builder.initInherited(r.gpa, base_lines);
        defer base.deinit();
        if (base.lineCount() != base_lines) {
            // A stale map: start over from the text.
            base.deinit();
            base = try attribution.Builder.initInherited(r.gpa, base_lines);
        }
        const base_map = try base.toMap(arena);

        var live = try attribution.Builder.initFrom(r.gpa, base_map);
        defer live.deinit();
        const applied = r.applySplices(&live, splices.items) catch |e| switch (e) {
            error.OutOfRange => false,
            else => return e,
        };
        var hash: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(new_blob, &hash, .{});
        const written = if (write) |w| std.mem.eql(u8, &w.hash, &hash) else false;
        if (applied and !written and live.lineCount() == attribution.lineCountOf(new_blob)) return live.toMap(arena);

        // Reconcile with a line diff.
        const filler: ProvenanceId = if (written)
            try r.intern(write.?.actor, null, null, null, r.now())
        else
            try r.intern(r.unreportedActor(workspace), null, null, null, r.now());
        return attribution.mapThroughDiff(r.gpa, arena, base_map, old_text, new_blob, .{ .len = 0, .prov = filler });
    }

    /// Who wrote lines nobody reported.
    fn unreportedActor(r: *Recorder, workspace: []const u8) Actor {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const at = r.focus.get(workspace) orelse return .unknown;
        return if (r.now() - at <= r.cfg.focus_window_ms) r.cfg.user else .unknown;
    }

    /// Applies `splices` (in order); false when one does not fit.
    fn applySplices(r: *Recorder, live: *attribution.Builder, splices: []const Splice) !bool {
        var scratch: std.heap.ArenaAllocator = .init(r.gpa);
        defer scratch.deinit();
        for (splices) |sp| {
            _ = scratch.reset(.retain_capacity);
            const rg = sp.range;
            const count = live.lineCount();
            if (rg.old_start_line > count or rg.old_len > count - rg.old_start_line) return false;
            const kept = @min(rg.old_len, rg.new_len);
            var segs: std.ArrayList(Seg) = .empty;
            // Lines replaced in place: mixed when another actor wrote them.
            const old_segs = try live.slice(scratch.allocator(), rg.old_start_line, kept);
            for (old_segs) |os| {
                const own = r.actors.get(sp.prov.bytes).?;
                const mixed = !os.prov.eql(attribution.inherited) and !os.prov.eql(sp.prov) and !(try r.actorOf(os.prov)).eql(own);
                if (mixed) {
                    const m = try r.intern(own, null, null, os.prov, r.now());
                    try segs.append(scratch.allocator(), .{ .len = os.len, .prov = m, .mixed = true });
                } else try segs.append(scratch.allocator(), .{ .len = os.len, .prov = sp.prov });
            }
            if (rg.new_len > kept) try segs.append(scratch.allocator(), .{ .len = rg.new_len - kept, .prov = sp.prov });
            try live.replace(rg.old_start_line, rg.old_len, segs.items);
        }
        return true;
    }

    /// Worker: writes the records and prompt texts interned since the
    /// last flush into `batch`.
    pub fn flush(r: *Recorder, batch: *store_mod.WriteBatch) !void {
        for (r.unwritten.items) |u| _ = try batch.put(u.kind, u.bytes);
        for (r.unwritten.items) |u| r.gpa.free(u.bytes);
        r.unwritten.clearRetainingCapacity();
    }

    /// Records interned but not yet flushed.
    pub fn unflushed(r: *const Recorder) usize {
        return r.unwritten.items.len;
    }
};

fn fileKey(gpa: Allocator, workspace: []const u8, path: []const u8) ![]u8 {
    return std.mem.concat(gpa, u8, &.{ workspace, "\x00", path });
}

fn dupeEvent(gpa: Allocator, ev: EditEvent) !EditEvent {
    var out = ev;
    out.path = try gpa.dupe(u8, ev.path);
    errdefer gpa.free(out.path);
    out.workspace = try gpa.dupe(u8, ev.workspace);
    errdefer gpa.free(out.workspace);
    out.ranges = try gpa.dupe(LineRange, ev.ranges);
    errdefer gpa.free(out.ranges);
    out.prompt = if (ev.prompt) |p| try gpa.dupe(u8, p) else null;
    errdefer if (out.prompt) |p| gpa.free(p);
    out.actor = try ev.actor.dupe(gpa);
    return out;
}

fn freeEvent(gpa: Allocator, ev: EditEvent) void {
    gpa.free(ev.path);
    gpa.free(ev.workspace);
    gpa.free(ev.ranges);
    if (ev.prompt) |p| gpa.free(p);
    ev.actor.free(gpa);
}

fn setActor(gpa: Allocator, map: *std.StringHashMapUnmanaged(Actor), ws: []const u8, actor: Actor) !void {
    if (map.getPtr(ws)) |a| {
        if (a.eql(actor)) return;
        const n = try actor.dupe(gpa);
        a.free(gpa);
        a.* = n;
        return;
    }
    const key = try gpa.dupe(u8, ws);
    errdefer gpa.free(key);
    const n = try actor.dupe(gpa);
    errdefer n.free(gpa);
    try map.put(gpa, key, n);
}

fn setFocus(r: *Recorder, ws: []const u8, at_ms: i64) void {
    if (r.focus.getPtr(ws)) |v| {
        v.* = @max(v.*, at_ms);
        return;
    }
    const key = r.gpa.dupe(u8, ws) catch return;
    r.focus.put(r.gpa, key, at_ms) catch r.gpa.free(key);
}

fn freeKeys(gpa: Allocator, map: anytype) void {
    var it = map.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    map.deinit(gpa);
}

fn freeActorMap(gpa: Allocator, map: *std.StringHashMapUnmanaged(Actor), owned_keys: bool) void {
    var it = map.iterator();
    while (it.next()) |e| {
        if (owned_keys) gpa.free(e.key_ptr.*);
        e.value_ptr.free(gpa);
    }
    map.deinit(gpa);
}

test {
    _ = @import("recorder_test.zig");
}
