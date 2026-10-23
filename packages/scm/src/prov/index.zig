//! The provenance index (E09.F05): for each commit, the agents (name and
//! model) and sessions behind the lines it wrote, so the `agent()`,
//! `human()` and `session()` revsets answer from memory instead of
//! reading manifests and records per commit. Built from changes'
//! provenance manifests; records shared between commits are read once.
//! In memory only: callers build it for the commits they query.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const store_mod = @import("../store/store.zig");
const op_mod = @import("../oplog/operation.zig");
const index_mod = @import("../graph/index.zig");
const functions = @import("../graph/revset/functions.zig");
const record = @import("record.zig");
const manifest = @import("manifest.zig");
const ObjectId = id_mod.ObjectId;
const Pattern = functions.Pattern;
const Allocator = std.mem.Allocator;

pub const ProvenanceIndex = struct {
    gpa: Allocator,
    /// Agent names, model IDs and session IDs, interned.
    strings: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Commits with at least one agent record; others are human.
    commits: std.AutoHashMapUnmanaged([32]u8, Entry) = .empty,
    /// Per commit: agent string IDs, then session string IDs.
    tags: std.ArrayList(u32) = .empty,
    /// Records already read: their agent strings, or none.
    records: std.AutoHashMapUnmanaged([32]u8, RecordTags) = .empty,
    // The last `agent()` pattern and the strings it matches.
    cache_pattern: ?Pattern = null,
    cache_text: std.ArrayList(u8) = .empty,
    cache_hits: std.DynamicBitSetUnmanaged = .{},

    const Entry = struct { start: u32, agents: u16, sessions: u16 };
    const no_string: u32 = std.math.maxInt(u32);
    /// An agent record's name, model and session (`no_string` when the
    /// record is not an agent's).
    const RecordTags = struct { name: u32 = no_string, model: u32 = no_string, session: u32 = no_string };

    pub fn init(gpa: Allocator) ProvenanceIndex {
        return .{ .gpa = gpa };
    }

    pub fn deinit(ix: *ProvenanceIndex) void {
        const gpa = ix.gpa;
        for (ix.strings.keys()) |k| gpa.free(k);
        ix.strings.deinit(gpa);
        ix.commits.deinit(gpa);
        ix.tags.deinit(gpa);
        ix.records.deinit(gpa);
        ix.cache_text.deinit(gpa);
        ix.cache_hits.deinit(gpa);
        ix.* = undefined;
    }

    /// Indexes every commit of `view`.
    pub fn addAll(ix: *ProvenanceIndex, store: *store_mod.Store, view: *const index_mod.View) !void {
        var p: u32 = 0;
        while (p < view.count) : (p += 1) try ix.addCommit(store, view.id(index_mod.Pos.of(p)));
    }

    /// Indexes `commit` from its change's manifest (none: human).
    pub fn addCommit(ix: *ProvenanceIndex, store: *store_mod.Store, commit: ObjectId) !void {
        var arena_state: std.heap.ArenaAllocator = .init(ix.gpa);
        defer arena_state.deinit();
        const change = try op_mod.read(object.Change, store, arena_state.allocator(), commit);
        if (change.provenance) |m| try ix.addManifest(store, commit, m);
    }

    /// Indexes `commit` as attributed by manifest `id`.
    pub fn addManifest(ix: *ProvenanceIndex, store: *store_mod.Store, commit: ObjectId, id: ObjectId) !void {
        const gpa = ix.gpa;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const m = try manifest.read(store, arena, id);
        var agents: std.ArrayList(u32) = .empty;
        var sessions: std.ArrayList(u32) = .empty;
        for (try m.records(arena)) |r| {
            const t = try ix.recordTags(store, arena, r);
            for ([_]u32{ t.name, t.model }) |s| {
                if (s != no_string and std.mem.indexOfScalar(u32, agents.items, s) == null) try agents.append(arena, s);
            }
            if (t.session != no_string and std.mem.indexOfScalar(u32, sessions.items, t.session) == null) try sessions.append(arena, t.session);
        }
        if (agents.items.len == 0 and sessions.items.len == 0) {
            _ = ix.commits.remove(commit.bytes);
            return;
        }
        const start: u32 = @intCast(ix.tags.items.len);
        try ix.tags.appendSlice(gpa, agents.items);
        try ix.tags.appendSlice(gpa, sessions.items);
        try ix.commits.put(gpa, commit.bytes, .{ .start = start, .agents = @intCast(agents.items.len), .sessions = @intCast(sessions.items.len) });
    }

    fn recordTags(ix: *ProvenanceIndex, store: *store_mod.Store, arena: Allocator, id: ObjectId) !RecordTags {
        if (ix.records.get(id.bytes)) |t| return t;
        const r = try op_mod.read(record.ProvenanceRecord, store, arena, id);
        var t: RecordTags = .{};
        if (r.actor.kind == .agent) {
            t.name = try ix.intern(r.actor.name);
            if (r.actor.model_id.len > 0) t.model = try ix.intern(r.actor.model_id);
            if (r.actor.session_id.len > 0) t.session = try ix.intern(r.actor.session_id);
        }
        try ix.records.put(ix.gpa, id.bytes, t);
        return t;
    }

    fn intern(ix: *ProvenanceIndex, s: []const u8) !u32 {
        if (ix.strings.getIndex(s)) |i| return @intCast(i);
        const owned = try ix.gpa.dupe(u8, s);
        errdefer ix.gpa.free(owned);
        try ix.strings.put(ix.gpa, owned, {});
        return @intCast(ix.strings.count() - 1);
    }

    fn agentsOf(ix: *const ProvenanceIndex, e: Entry) []const u32 {
        return ix.tags.items[e.start..][0..e.agents];
    }

    fn sessionsOf(ix: *const ProvenanceIndex, e: Entry) []const u32 {
        return ix.tags.items[e.start + e.agents ..][0..e.sessions];
    }

    /// Whether `commit` has lines by an agent whose name or model matches
    /// `p` (any agent when null).
    pub fn hasAgentLines(ix: *ProvenanceIndex, commit: ObjectId, p: ?Pattern) !bool {
        const e = ix.commits.get(commit.bytes) orelse return false;
        const pat = p orelse return e.agents > 0;
        const hits = try ix.matching(pat);
        for (ix.agentsOf(e)) |s| if (hits.isSet(s)) return true;
        return false;
    }

    /// Whether `commit` has lines written in agent session `session`.
    pub fn inSession(ix: *const ProvenanceIndex, commit: ObjectId, session: []const u8) bool {
        const e = ix.commits.get(commit.bytes) orelse return false;
        const s = ix.strings.getIndex(session) orelse return false;
        return std.mem.indexOfScalar(u32, ix.sessionsOf(e), @intCast(s)) != null;
    }

    /// The strings `p` matches, cached for the last pattern.
    fn matching(ix: *ProvenanceIndex, p: Pattern) !*const std.DynamicBitSetUnmanaged {
        const n = ix.strings.count();
        if (ix.cache_pattern) |c| {
            if (c.kind == p.kind and c.case_insensitive == p.case_insensitive and c.path_prefix == p.path_prefix and
                std.mem.eql(u8, ix.cache_text.items, p.text) and ix.cache_hits.bit_length == n) return &ix.cache_hits;
        }
        ix.cache_pattern = null;
        try ix.cache_hits.resize(ix.gpa, n, false);
        ix.cache_hits.unsetAll();
        for (ix.strings.keys(), 0..) |s, i| if (p.matches(s)) ix.cache_hits.set(i);
        ix.cache_text.clearRetainingCapacity();
        try ix.cache_text.appendSlice(ix.gpa, p.text);
        ix.cache_pattern = p;
        return &ix.cache_hits;
    }

    /// The index as the revset evaluator's provider. Not thread-safe: one
    /// evaluation at a time.
    pub fn query(ix: *ProvenanceIndex) functions.ProvenanceQuery {
        return .{ .ctx = ix, .hasAgentLines = hasAgentLinesFn, .inSession = inSessionFn };
    }

    fn hasAgentLinesFn(ctx: *anyopaque, commit: ObjectId, p: ?Pattern) anyerror!bool {
        const ix: *ProvenanceIndex = @ptrCast(@alignCast(ctx));
        return ix.hasAgentLines(commit, p);
    }

    fn inSessionFn(ctx: *anyopaque, commit: ObjectId, session: []const u8) anyerror!bool {
        const ix: *ProvenanceIndex = @ptrCast(@alignCast(ctx));
        return ix.inSession(commit, session);
    }
};

test {
    _ = @import("index_test.zig");
}
