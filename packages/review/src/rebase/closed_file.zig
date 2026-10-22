//! Rebase of one pending file change onto new content (E12.F02.S02.T01,
//! closed-file part): a three-way merge from the change's recorded base,
//! with the new content as one side and the proposed text as the other.
//!
//! - Clean: the edits become the line diff from the new content to the
//!   merged text, the base becomes the new content, and hunks are derived
//!   again (unchanged hunks keep their decision).
//! - Conflicted: each conflict region takes the proposed text (accepting
//!   the hunk means "take the change", rejecting it "keep what is there")
//!   and the hunks it covers get a `ConflictInfo`, undecided. The file
//!   stays open, so both answers go through the Applier. A conflicted
//!   hunk that a later rebase leaves unchanged keeps its `ConflictInfo`.
//! - Nothing left (the new content already holds the change): the file is
//!   `applied` with no edits.
//! - Base gone, binary or larger than 64 MiB: the file is `stale`.
//!
//! A text create whose path now exists is merged from an empty base and
//! becomes a modify. Binary files, renames without text and mode changes
//! are left alone. Always merges from the recorded base blob, never from
//! an earlier merge result. Pure: no queue, no I/O beyond `blobs`.

const std = @import("std");
const zg_core = @import("zg_core");
const model = @import("../model/root.zig");

const Allocator = std.mem.Allocator;
const FileChange = model.FileChange;
const ChangeSet = model.changeset.ChangeSet;
const merge3 = model.merge3;

pub const max_text_bytes: usize = 64 << 20;

pub const StaleReason = enum { base_missing, became_binary, too_large, base_changed };

pub const RebaseOutcome = union(enum) {
    unchanged,
    clean: struct { hunks: u32 },
    conflicted: struct { hunks: u32 },
    stale: StaleReason,
    /// The new content already has the change; the file is `applied`.
    dropped_empty,
};

pub const Options = struct {
    hunk_options: model.HunkOptions = .{},
    conflict_kind: model.ConflictKind = .external_change,
    /// The changeset whose write moved the base (`sibling_changeset`).
    other: ?model.ChangesetId = null,
};

/// Rebases `fc` onto `new_base` (null: the file is gone). Hunks and
/// conflict texts are allocated in `cs_arena` (the changeset's arena);
/// the new base goes to `blobs`.
pub fn rebaseFile(gpa: Allocator, blobs: model.Blobs, cs_arena: Allocator, fc: *FileChange, new_base: ?[]const u8, o: Options) !RebaseOutcome {
    switch (fc.content) {
        .text => return rebaseText(gpa, blobs, cs_arena, fc, new_base, o),
        .none => if (fc.op == .delete) {
            const want = (fc.base orelse return .unchanged).hash;
            const now = new_base orelse {
                try model.fileTransition(fc, .applied);
                return .dropped_empty;
            };
            if (std.mem.eql(u8, &model.blobHash(now), &want)) return .unchanged;
            return markStale(fc, .base_changed);
        },
        .binary => {},
    }
    return .unchanged;
}

fn rebaseText(gpa: Allocator, blobs: model.Blobs, cs_arena: Allocator, fc: *FileChange, new_base: ?[]const u8, o: Options) !RebaseOutcome {
    const t = &fc.content.text;
    const ours = new_base orelse {
        if (t.base == null) return .unchanged;
        return markStale(fc, .base_missing);
    };
    if (t.base) |b| if (std.mem.eql(u8, &model.blobHash(ours), &b.hash)) return .unchanged;
    if (ours.len > max_text_bytes) return markStale(fc, .too_large);
    if (std.mem.indexOfScalar(u8, ours[0..@min(ours.len, 8192)], 0) != null) return markStale(fc, .became_binary);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base: []const u8 = if (t.base) |b| try blobs.get(arena, b.hash) orelse return error.MissingBlob else "";
    const theirs = try t.edits.applyToSlice(arena, base);
    var m = try merge3.merge(gpa, base, ours, theirs, .{ .prefer = .theirs });
    defer m.deinit(gpa);

    const ref: model.BaseRef = .{ .hash = try blobs.put(ours), .size = ours.len, .eol = .detect(ours) };
    if (std.mem.eql(u8, m.text, ours)) {
        t.edits.deinit();
        t.edits = .identity(gpa, ours.len);
        t.base = ref;
        fc.hunks = &.{};
        if (fc.op == .create) fc.op = .modify;
        if (fc.state != .applied) try model.fileTransition(fc, .applied);
        return .dropped_empty;
    }

    var edits = try merge3.lineChangeSet(gpa, ours, m.text);
    errdefer edits.deinit();
    var lines: zg_core.LineIndex = try .build(gpa, ours);
    defer lines.deinit(gpa);
    var ho = o.hunk_options;
    ho.previous = fc.hunks;
    const derived = try model.deriveHunks(gpa, ours, &lines, &edits, ho);
    defer gpa.free(derived);
    const hunks = try cs_arena.dupe(model.Hunk, derived);

    var conflicted: u32 = 0;
    if (m.conflicts.len > 0) {
        const ol = try merge3.splitLines(arena, ours);
        for (hunks) |*h| {
            for (m.conflicts) |c| {
                if (!meets(h.base_lines, c.ours)) continue;
                var text: std.ArrayList(u8) = .empty;
                for (ol[c.ours[0]..c.ours[1]]) |l| try text.appendSlice(arena, l);
                h.conflict = .{
                    .kind = o.conflict_kind,
                    .other = o.other,
                    .ours_lines = .{ .start = c.ours[0], .count = c.ours[1] - c.ours[0] },
                    .theirs_text = try cs_arena.dupe(u8, text.items),
                };
                h.decision = .undecided;
                conflicted += 1;
                break;
            }
        }
    }

    // A hunk that conflicted before and is unchanged still does: the
    // merge from the new base no longer sees the other side.
    for (hunks) |*h| {
        if (h.conflict != null) continue;
        for (fc.hunks) |old| if (old.key == h.key and old.conflict != null) {
            h.conflict = old.conflict;
            h.conflict.?.ours_lines = h.base_lines;
            h.decision = .undecided;
            conflicted += 1;
            break;
        };
    }

    t.edits.deinit();
    t.edits = edits;
    t.base = ref;
    fc.hunks = hunks;
    if (fc.op == .create) fc.op = .modify;
    if (fc.state == .stale or fc.state == .conflicted) try model.fileTransition(fc, .pending);
    if (conflicted > 0) return .{ .conflicted = .{ .hunks = conflicted } };
    return .{ .clean = .{ .hunks = @intCast(hunks.len) } };
}

fn markStale(fc: *FileChange, why: StaleReason) !RebaseOutcome {
    if (fc.state != .stale) try model.fileTransition(fc, .stale);
    return .{ .stale = why };
}

/// Whether hunk lines `h` and conflict lines `[c0, c1)` overlap; an empty
/// range meets a range it touches.
fn meets(h: model.LineRange, c: [2]u32) bool {
    if (h.start < c[1] and c[0] < h.end()) return true;
    if (h.count == 0) return c[0] <= h.start and h.start <= c[1];
    if (c[0] == c[1]) return h.start <= c[0] and c[0] <= h.end();
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const Fixture = struct {
    blobs: model.MemBlobs,
    arena: std.heap.ArenaAllocator,
    fc: FileChange,

    fn init(f: *Fixture, base: []const u8, new: []const u8) !void {
        f.blobs = .init(testing.allocator);
        f.arena = .init(testing.allocator);
        const b = f.blobs.blobs();
        const ref: model.BaseRef = .{ .hash = try b.put(base), .size = base.len };
        const edits = try merge3.lineChangeSet(testing.allocator, base, new);
        var lines: zg_core.LineIndex = try .build(testing.allocator, base);
        defer lines.deinit(testing.allocator);
        const hs = try model.deriveHunks(testing.allocator, base, &lines, &edits, .{});
        defer testing.allocator.free(hs);
        f.fc = .{ .path = "a.txt", .op = .modify, .content = .{ .text = .{ .base = ref, .edits = edits } }, .hunks = try f.arena.allocator().dupe(model.Hunk, hs) };
    }

    fn deinit(f: *Fixture) void {
        f.fc.deinitContent();
        f.arena.deinit();
        f.blobs.deinit();
    }

    fn rebase(f: *Fixture, new: ?[]const u8) !RebaseOutcome {
        return rebaseFile(testing.allocator, f.blobs.blobs(), f.arena.allocator(), &f.fc, new, .{ .conflict_kind = .sibling_changeset, .other = @enumFromInt(9) });
    }

    fn proposed(f: *Fixture) ![]u8 {
        const b = (try f.blobs.blobs().get(f.arena.allocator(), f.fc.content.text.base.?.hash)).?;
        return f.fc.content.text.edits.applyToSlice(f.arena.allocator(), b);
    }
};

test "rebase: disjoint change merges clean onto the new base" {
    var f: Fixture = undefined;
    try f.init("a\nb\nc\nd\ne\n", "a\nB\nc\nd\ne\n");
    defer f.deinit();
    const r = try f.rebase("a\nb\nc\nd\nE\n");
    try testing.expectEqual(@as(u32, 1), r.clean.hunks);
    try testing.expectEqualStrings("a\nB\nc\nd\nE\n", try f.proposed());
    try testing.expectEqual(@as(u32, 1), f.fc.hunks[0].base_lines.start);
    try testing.expectEqual(@as(?model.ConflictInfo, null), f.fc.hunks[0].conflict);
    try testing.expectEqual(.unchanged, try f.rebase("a\nb\nc\nd\nE\n"));
}

test "rebase: overlapping change keeps the proposal and marks the hunk" {
    var f: Fixture = undefined;
    try f.init("a\nb\nc\n", "a\nmine\nc\n");
    defer f.deinit();
    f.fc.hunks[0].decision = .accepted;
    const r = try f.rebase("a\ntheirs\nc\nz\n");
    try testing.expectEqual(@as(u32, 1), r.conflicted.hunks);
    try testing.expectEqualStrings("a\nmine\nc\nz\n", try f.proposed());
    const h = f.fc.hunks[0];
    try testing.expectEqual(model.Decision.undecided, h.decision);
    try testing.expectEqual(model.ConflictKind.sibling_changeset, h.conflict.?.kind);
    try testing.expectEqual(@as(?model.ChangesetId, @enumFromInt(9)), h.conflict.?.other);
    try testing.expectEqualStrings("theirs\n", h.conflict.?.theirs_text);
    try testing.expectEqual(model.FileState.pending, f.fc.state);
}

test "rebase: same change drops to applied; deleted base is stale" {
    var f: Fixture = undefined;
    try f.init("a\nb\n", "a\nB\n");
    defer f.deinit();
    try testing.expectEqual(.dropped_empty, try f.rebase("a\nB\n"));
    try testing.expectEqual(model.FileState.applied, f.fc.state);
    try testing.expectEqual(@as(usize, 0), f.fc.hunks.len);

    var g: Fixture = undefined;
    try g.init("a\nb\nc\n", "A\nb\nc\n");
    defer g.deinit();
    try testing.expectEqual(RebaseOutcome{ .stale = .base_missing }, try g.rebase(null));
    try testing.expectEqual(model.FileState.stale, g.fc.state);
    try testing.expectEqual(RebaseOutcome{ .stale = .became_binary }, try g.rebase("\x00\x01"));
    // Content that merges again brings it back.
    _ = try g.rebase("a\nb\nC\n");
    try testing.expectEqual(model.FileState.pending, g.fc.state);
    try testing.expectEqualStrings("A\nb\nC\n", try g.proposed());
}
