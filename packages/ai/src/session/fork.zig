//! Forks (E10.F08.S02.T01): a new session that shares a prefix of another.
//! The child file holds only a header with `parent{session, seq}` and a
//! `title` record; records with `seq <= parent.seq` are read from the
//! parent, which is opened read-only (no lock conflict with its writer).
//! Chains are walked up to `max_chain_depth`; a fork deeper than that
//! copies its parent's prefix into its own file (`parent.materialized`).

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const loader = @import("loader.zig");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const SessionStore = store_mod.SessionStore;

/// Longest chain of parents read when loading.
pub const max_chain_depth = 32;
/// Title of a fork without a name.
pub const default_title = "Branch";

/// Creates a session that continues `src` after its record `at_seq`.
/// Returns the new session's id.
pub fn fork(s: *SessionStore, io: Io, src: proto.SessionId, at_seq: u64, name: ?[]const u8) !proto.SessionId {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const src_header = try readHeader(a, io, try s.pathFor(a, src));
    const depth = try chainDepth(s, io, src);
    const materialize = depth + 1 > max_chain_depth;
    const w = try s.create(io, .{
        .parent = .{ .session = src, .seq = at_seq, .materialized = materialize },
        .cwd = src_header.cwd,
        .prompt_version = src_header.prompt_version,
        .app_version = src_header.app_version,
        .origin = src_header.origin,
        .model = src_header.model,
    });
    defer w.close();
    if (materialize) {
        const l = try openChain(s, io, src, .{ .mode = .full, .repair = false });
        defer l.deinit();
        for (l.tail) |line| if (line.seq <= at_seq) try w.append(line.seq, line.record);
    }
    try w.append(at_seq + 1, .{ .title = name orelse default_title });
    try w.sync();
    return w.id;
}

/// Parents read when loading `id` (0 for a session without a parent or
/// with a materialized one).
pub fn chainDepth(s: *SessionStore, io: Io, id: proto.SessionId) !u32 {
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var depth: u32 = 0;
    var cur = id;
    while (true) {
        const h = try readHeader(a, io, try s.pathFor(a, cur));
        const p = h.parent orelse return depth;
        if (p.materialized) return depth;
        depth += 1;
        if (depth > max_chain_depth) return error.ChainTooDeep;
        cur = p.session;
    }
}

/// Loads `id` like `SessionStore.open`, with the records it shares with
/// its parents placed before its own. In tail-first mode the parents are
/// not read when the child's tail already reaches a compaction.
pub fn openChain(s: *SessionStore, io: Io, id: proto.SessionId, opts: loader.Options) !*loader.LoadedSession {
    const l = try s.open(io, id, opts);
    errdefer l.deinit();
    const p = l.header.parent orelse return l;
    if (p.materialized) return l;
    if (opts.mode == .tail_first) {
        for (l.tail) |line| if (line.record == .compaction) return l;
        // Only part of the child was read: the parents are not adjacent.
        if (l.tail_start > l.body_start) return l;
    }
    const a = l.arena.allocator();
    var prefix: std.ArrayList(records.Line) = .empty;
    try appendAncestor(s, io, a, p, &prefix, 1);
    try prefix.appendSlice(a, l.tail);
    l.tail = prefix.items;
    l.interrupted = try loader.interruptedResults(a, l.tail);
    return l;
}

/// Appends the records of `p.session` with `seq <= p.seq`, after those of
/// its own parents.
fn appendAncestor(s: *SessionStore, io: Io, a: Allocator, p: records.Parent, out: *std.ArrayList(records.Line), depth: u32) !void {
    if (depth > max_chain_depth) return error.ChainTooDeep;
    const path = try s.pathFor(a, p.session);
    const f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var it: loader.Forward = .{ .file = f, .pos = 0, .end = try f.length(io), .gpa = s.gpa };
    defer it.deinit();
    const first = (try it.next(io)) orelse return error.InvalidSession;
    const hline = records.decode(a, first) catch return error.InvalidSession;
    if (hline.record != .header) return error.InvalidSession;
    if (hline.record.header.parent) |gp| if (!gp.materialized) {
        try appendAncestor(s, io, a, .{ .session = gp.session, .seq = @min(gp.seq, p.seq) }, out, depth + 1);
    };
    while (try it.next(io)) |text| {
        const line = records.decode(a, text) catch continue;
        if (line.seq > p.seq) continue;
        try out.append(a, line);
    }
}

/// The header of the session file at `path`.
pub fn readHeader(a: Allocator, io: Io, path: []const u8) !records.Header {
    const f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var it: loader.Forward = .{ .file = f, .pos = 0, .end = try f.length(io), .gpa = a };
    const first = (try it.next(io)) orelse return error.InvalidSession;
    const line = records.decode(a, first) catch return error.InvalidSession;
    if (line.record != .header) return error.InvalidSession;
    return line.record.header;
}
