//! Attribution through rewrites and merges (E09.F05.S01.T02): every new
//! commit made by rebase, squash, split, absorb, conflict resolution or
//! describe gets a provenance manifest derived from its inputs.
//!
//! A manifest covers only the lines a change introduced (blame semantics).
//! For each file, a result line takes its attribution from:
//! 1. the new parent's file, when the line diff aligns it there: the line
//!    is inherited, not introduced here;
//! 2. else a source (the rewritten commit, or each squashed one) where
//!    the diff aligns it, preferring a source that attributes it;
//! 3. else a source line with the same text that the diff deleted (a
//!    moved block keeps its provenance);
//! 4. else the filler: the rewriting actor's record, or inherited for
//!    rewrites that do not change content on their own (rebase, describe).
//!
//! Results depend only on the inputs (the filler record's time is the new
//! commit's committer time), so rebasing the same stack twice gives the
//! same manifests and commit IDs.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const store_mod = @import("../store/store.zig");
const chunker = @import("../store/chunker.zig");
const op_mod = @import("../oplog/operation.zig");
const materialize = @import("../merge/materialize.zig");
const record = @import("record.zig");
const attribution = @import("attribution.zig");
const manifest_mod = @import("manifest.zig");
const ObjectId = id_mod.ObjectId;
const Change = object.Change;
const Tree = object.Tree;
const Actor = record.Actor;
const ProvenanceId = record.ProvenanceId;
const AttributionMap = attribution.AttributionMap;
const Allocator = std.mem.Allocator;

pub const mapThroughDiff = attribution.mapThroughDiff;

pub const RewriteKind = enum {
    rebase,
    describe,
    squash,
    split,
    absorb,
    resolve,
    edit,

    /// Whether the rewrite itself writes content (else unexplained lines
    /// stay inherited).
    pub fn writesContent(k: RewriteKind) bool {
        return switch (k) {
            .rebase, .describe => false,
            else => true,
        };
    }
};

pub const RemapContext = struct {
    gpa: Allocator,
    store: *store_mod.Store,
    /// Where new records and manifests go.
    batch: *store_mod.WriteBatch,
};

/// A version of the file and its attribution (null: all inherited).
pub const SideText = struct {
    text: []const u8,
    map: ?AttributionMap = null,
};

/// Writes `r` into the batch.
pub fn writeRecord(ctx: *RemapContext, r: record.ProvenanceRecord) !ProvenanceId {
    const bytes = try enc.encodeAlloc(ctx.gpa, record.ProvenanceRecord, r);
    defer ctx.gpa.free(bytes);
    return ctx.batch.put(.prov_record, bytes);
}

/// The attribution of `result` given the parent's text (`parent`, whose
/// lines are inherited), the sources it was made from, and `filler` for
/// lines none of them explains. The map lives in `arena`.
pub fn attributionForMerge(gpa: Allocator, arena: Allocator, parent: ?[]const u8, sides: []const SideText, result: []const u8, filler: ProvenanceId) !AttributionMap {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const s = scratch_state.allocator();
    const out_lines = try materialize.splitLines(s, result);
    const n = out_lines.len;
    // Per result line: whether it is settled, and its segment.
    const settled = try s.alloc(bool, n);
    @memset(settled, false);
    const segs = try s.alloc(attribution.Seg, n);
    for (segs) |*g| g.* = .{ .len = 1, .prov = filler };

    if (parent) |p| {
        const pl = try materialize.splitLines(s, p);
        for (try aligned(s, pl, out_lines), 0..) |al, i| if (al != null) {
            segs[i] = .{ .len = 1, .prov = attribution.inherited };
            settled[i] = true;
        };
    }
    // Aligned source lines; a source that attributes the line wins over
    // one that inherits it.
    const weak = try s.alloc(bool, n);
    @memset(weak, false);
    const side_lines = try s.alloc([]const []const u8, sides.len);
    const side_align = try s.alloc([]const ?usize, sides.len);
    for (sides, side_lines, side_align) |side, *sl, *sa| {
        sl.* = try materialize.splitLines(s, side.text);
        if (side.map) |m| if (m.lineCount() != sl.len) return error.MapMismatch;
        sa.* = try aligned(s, sl.*, out_lines);
        for (sa.*, 0..) |al, i| {
            if (settled[i] and !weak[i]) continue;
            const j = al orelse continue;
            const run = lineRun(side.map, j);
            if (run.prov.eql(attribution.inherited)) {
                if (!settled[i]) {
                    segs[i] = .{ .len = 1, .prov = attribution.inherited };
                    settled[i] = true;
                    weak[i] = true;
                }
                continue;
            }
            segs[i] = .{ .len = 1, .prov = run.prov, .mixed = run.mixed };
            settled[i] = true;
            weak[i] = false;
        }
    }
    // Moved lines: an unsettled line equal to a source line the diff did
    // not align (blank and very short lines are too common to count).
    for (sides, side_lines, side_align) |side, sl, sa| {
        if (side.map == null) continue;
        var used = try s.alloc(bool, sl.len);
        @memset(used, false);
        for (sa) |al| if (al) |j| {
            used[j] = true;
        };
        var by_text: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
        for (sl, 0..) |line, j| {
            if (used[j] or std.mem.trim(u8, line, " \t\r\n").len < 3) continue;
            const gop = try by_text.getOrPut(s, line);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(s, j);
        }
        for (out_lines, 0..) |line, i| {
            if (settled[i]) continue;
            const list = by_text.getPtr(line) orelse continue;
            if (list.items.len == 0) continue;
            const j = list.orderedRemove(0);
            const run = lineRun(side.map, j);
            segs[i] = .{ .len = 1, .prov = run.prov, .mixed = run.mixed };
            settled[i] = true;
        }
    }
    var b: attribution.Builder = .init(gpa);
    defer b.deinit();
    for (segs) |g| try b.push(g);
    return b.toMap(arena);
}

fn lineRun(m: ?AttributionMap, line: usize) attribution.Run {
    const map = m orelse return .{ .start_line = @intCast(line), .len = 1, .prov = attribution.inherited };
    return map.at(@intCast(line)).?;
}

/// For each line of `b`, the line of `a` the diff keeps it as, if any.
fn aligned(s: Allocator, a: []const []const u8, b: []const []const u8) ![]const ?usize {
    const out = try s.alloc(?usize, b.len);
    @memset(out, null);
    var bi: usize = 0;
    for (try materialize.diffLines(s, a, b)) |op| switch (op.kind) {
        .equal => {
            out[bi] = op.index;
            bi += 1;
        },
        .insert => bi += 1,
        .delete => {},
    };
    return out;
}

/// A file's text and blob ID; null when absent, not a regular file or
/// binary.
pub const FileText = struct { blob: ObjectId, text: []const u8 };

pub fn readFile(s: *store_mod.Store, arena: Allocator, tree: ?ObjectId, path: []const u8) !?FileText {
    var cur = tree orelse return null;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |name| {
        const t = try op_mod.read(Tree, s, arena, cur);
        const e = t.find(name) orelse return null;
        if (parts.peek() == null) {
            if (e.kind != .file and e.kind != .executable) return null;
            var buf: [16 << 10]u8 = undefined;
            var br = try chunker.blobReader(s, e.id, &buf);
            defer br.deinit();
            const bytes = try br.interface.readAlloc(arena, @intCast(br.size));
            if (std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8 << 10)], 0) != null) return null;
            return .{ .blob = e.id, .text = bytes };
        }
        if (e.kind != .tree) return null;
        cur = e.id;
    }
    return null;
}

fn treeOf(c: Change) ?ObjectId {
    return if (c.tree_terms.len == 1) c.tree_terms[0] else null;
}

/// Paths of regular files that differ between two trees, into `out`.
fn changedPaths(s: *store_mod.Store, arena: Allocator, prefix: []const u8, a_id: ?ObjectId, b_id: ?ObjectId, out: *std.StringArrayHashMapUnmanaged(void)) !void {
    if (a_id != null and b_id != null and a_id.?.eql(b_id.?)) return;
    const empty: Tree = .{ .entries = &.{} };
    const a = if (a_id) |x| try op_mod.read(Tree, s, arena, x) else empty;
    const b = if (b_id) |x| try op_mod.read(Tree, s, arena, x) else empty;
    for (b.entries) |e| {
        const old = a.find(e.name);
        if (old != null and old.?.kind == e.kind and old.?.id.eql(e.id)) continue;
        const path = if (prefix.len == 0) e.name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, e.name });
        if (e.kind == .tree) {
            try changedPaths(s, arena, path, if (old != null and old.?.kind == .tree) old.?.id else null, e.id, out);
        } else if (e.kind == .file or e.kind == .executable) try out.put(arena, path, {});
    }
}

/// The manifest of `new` made from `sources` (the commits it rewrites or
/// combines); `filler` attributes lines none of them explains (null:
/// inherited, and only files the sources attribute are considered).
/// Null when no line is attributed.
pub fn remapFrom(ctx: *RemapContext, arena: Allocator, sources: []const Change, new: Change, filler: ?ProvenanceId) !?ObjectId {
    const s = ctx.store;
    const new_tree = treeOf(new) orelse return null;
    const parent_tree: ?ObjectId = if (new.parents.len > 0) blk: {
        const p = try op_mod.read(Change, s, arena, new.parents[0]);
        break :blk treeOf(p);
    } else null;

    const manifests = try arena.alloc(?manifest_mod.ProvenanceManifest, sources.len);
    var paths: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (sources, manifests) |src, *m| {
        m.* = if (src.provenance) |id| try manifest_mod.read(s, arena, id) else null;
        if (m.*) |mm| for (mm.files) |f| try paths.put(arena, f.path, {});
    }
    if (filler != null) try changedPaths(s, arena, "", parent_tree, new_tree, &paths);

    var files: std.ArrayList(manifest_mod.FileAttribution) = .empty;
    const sides = try arena.alloc(SideText, sources.len);
    for (paths.keys()) |path| {
        const result = (try readFile(s, arena, new_tree, path)) orelse continue;
        var any = false;
        for (sources, manifests, sides) |src, m, *side| {
            const ft = try readFile(s, arena, treeOf(src), path);
            side.* = .{ .text = if (ft) |x| x.text else "" };
            const fa = if (m) |mm| mm.find(path) else null;
            if (fa != null and ft != null and fa.?.blob.eql(ft.?.blob)) {
                side.map = try fa.?.map(arena);
                any = true;
            }
        }
        if (!any and filler == null) continue;
        const parent = try readFile(s, arena, parent_tree, path);
        const map = try attributionForMerge(ctx.gpa, arena, if (parent) |x| x.text else null, sides, result.text, filler orelse attribution.inherited);
        if (map.allInherited()) continue;
        try files.append(arena, try manifest_mod.encodeFile(arena, path, result.blob, map));
    }
    if (files.items.len == 0) return null;
    manifest_mod.sortFiles(files.items);
    return try manifest_mod.write(ctx.batch, ctx.gpa, .{ .files = files.items });
}

/// Sets `new.provenance` for `new`, a rewrite of `old` by `actor`.
pub fn remapForRewrite(ctx: *RemapContext, arena: Allocator, old: Change, new: *Change, kind: RewriteKind, actor: Actor) !void {
    const filler: ?ProvenanceId = if (kind.writesContent())
        try writeRecord(ctx, .{ .actor = actor, .created_ms = new.committer.time_ms })
    else
        null;
    if (filler == null and old.provenance == null) {
        new.provenance = null;
        return;
    }
    new.provenance = try remapFrom(ctx, arena, &.{old}, new.*, filler);
}

test {
    _ = @import("remap_test.zig");
}
