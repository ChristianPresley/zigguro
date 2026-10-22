//! TrigramIndex tests.

const std = @import("std");
const Io = std.Io;
const index = @import("index.zig");
const TrigramIndex = index.TrigramIndex;
const query = @import("query.zig");
const FileId = @import("../../ids.zig").FileId;

const gpa = std.testing.allocator;
const io = std.testing.io;

fn fid(i: u32) FileId {
    return .{ .index = i, .gen = 1 };
}

/// Candidate file ids of a literal, sorted by index.
fn find(ix: *TrigramIndex, lit: []const u8, ci: bool) !?[]u32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const r = try ix.reader();
    defer r.release();
    const c = try r.execute(try query.planLiteral(arena.allocator(), lit, ci), gpa);
    defer c.deinit(gpa);
    if (c == .all) return null;
    var out: std.ArrayList(u32) = .empty;
    for (c.docs) |d| if (r.docToFile(d)) |f| try out.append(gpa, f.index);
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    return try out.toOwnedSlice(gpa);
}

fn expectFind(ix: *TrigramIndex, lit: []const u8, want: []const u32) !void {
    const got = (try find(ix, lit, false)) orelse return error.TestExpectedCandidates;
    defer gpa.free(got);
    try std.testing.expectEqualSlices(u32, want, got);
}

test "trigram: builder + reader roundtrip (1k docs)" {
    const ix = try TrigramIndex.open(gpa, io, null, .{});
    defer ix.deinit();
    var buf: [128]u8 = undefined;
    for (0..1000) |i| {
        const text = try std.fmt.bufPrint(&buf, "fn handler_{d}() {{ return token{d}; }}", .{ i, i % 10 });
        try ix.add(i, fid(@intCast(i)), text);
        if (i % 300 == 299) try ix.flush();
    }
    try ix.flush();
    try std.testing.expectEqual(@as(usize, 4), ix.segmentCount());
    try expectFind(ix, "handler_123(", &.{123});
    // Postings are case-folded, and candidates are a superset: without
    // positions, "handler_999(" also has every trigram of "handler_99(".
    try expectFind(ix, "HANDLER_99(", &.{ 99, 999 });
    try std.testing.expect((try find(ix, "token", false)) == null); // in every doc: scan instead
}

test "trigram: tombstone hides changed doc; re-added doc found in new segment" {
    const ix = try TrigramIndex.open(gpa, io, null, .{});
    defer ix.deinit();
    for (0..10) |i| try ix.add(i, fid(@intCast(i)), if (i == 3) "alpha beta" else "gamma delta");
    try ix.flush();
    try expectFind(ix, "alpha", &.{3});
    // File 3 changes: its old doc is tombstoned, the new one is pending.
    try ix.add(3, fid(3), "epsilon zeta");
    try expectFind(ix, "alpha", &.{});
    try expectFind(ix, "epsilon", &.{}); // not committed yet
    try ix.flush();
    try expectFind(ix, "epsilon", &.{3});
    ix.remove(3);
    try expectFind(ix, "epsilon", &.{});
    // A doc changed twice before a flush keeps only its last version.
    try ix.add(4, fid(4), "first version");
    try ix.add(4, fid(4), "second version");
    try ix.flush();
    try expectFind(ix, "first", &.{});
    try expectFind(ix, "second", &.{4});
}

test "trigram: merge preserves postings and drops tombstones" {
    const ix = try TrigramIndex.open(gpa, io, null, .{ .merge_factor = 4 });
    defer ix.deinit();
    var buf: [64]u8 = undefined;
    for (0..40) |i| {
        try ix.add(i, fid(@intCast(i)), try std.fmt.bufPrint(&buf, "doc{d:0>3} common{d}", .{ i, i % 2 }));
        if (i % 10 == 9) try ix.flush();
    }
    for (0..10) |i| ix.remove(i * 4);
    const r0 = try ix.reader();
    defer r0.release(); // an old reader stays valid across the merge
    try ix.merge(true);
    try std.testing.expectEqual(@as(usize, 1), ix.segmentCount());
    const r = try ix.reader();
    defer r.release();
    try std.testing.expectEqual(@as(u32, 30), r.docCount());
    try expectFind(ix, "doc005", &.{5});
    try expectFind(ix, "doc004", &.{});
    try std.testing.expectEqual(@as(u32, 40), r0.docCount());
    // The policy path: with merge_factor segments, commit merges them.
    for (40..44) |i| {
        try ix.add(i, fid(@intCast(i)), "tail");
        try ix.flush();
    }
    try std.testing.expectEqual(@as(usize, 5), ix.segmentCount());
    try ix.merge(false);
    try std.testing.expectEqual(@as(usize, 2), ix.segmentCount());
    try expectFind(ix, "doc039", &.{39});
}

test "trigram: persistence and corrupted segment detected via checksum" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    {
        const ix = try TrigramIndex.open(gpa, io, tmp.dir, .{});
        defer ix.deinit();
        try ix.add(1, fid(1), "persistent words");
        try ix.add(2, fid(2), "other words");
        try ix.flush();
        ix.remove(2);
        try ix.save();
    }
    {
        const ix = try TrigramIndex.open(gpa, io, tmp.dir, .{});
        defer ix.deinit();
        try std.testing.expect(!ix.rebuilt);
        // Files are bound to this session's ids at warm start.
        try std.testing.expect(ix.bind(1, fid(10)));
        try std.testing.expect(!ix.bind(2, fid(11))); // tombstoned
        try expectFind(ix, "persistent", &.{10});
        try expectFind(ix, "other", &.{});
    }
    {
        // Flip a byte in the segment.
        const bytes = try tmp.dir.readFileAlloc(io, "seg-0.zgt", gpa, .unlimited);
        defer gpa.free(bytes);
        bytes[30] ^= 0xFF;
        try tmp.dir.writeFile(io, .{ .sub_path = "seg-0.zgt", .data = bytes });
        const ix = try TrigramIndex.open(gpa, io, tmp.dir, .{});
        defer ix.deinit();
        try std.testing.expect(ix.rebuilt);
        try std.testing.expectEqual(@as(usize, 0), ix.segmentCount());
        try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "seg-0.zgt", .{}));
    }
}

test "trigram: no false negatives (literal property test)" {
    const ix = try TrigramIndex.open(gpa, io, null, .{});
    defer ix.deinit();
    var prng: std.Random.DefaultPrng = .init(0x7219);
    const r = prng.random();
    const alphabet = "abcAB_ \xc3\xa9";
    var docs: [200][64]u8 = undefined;
    for (&docs, 0..) |*d, i| {
        for (d) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        try ix.add(i, fid(@intCast(i)), d);
        if (i % 50 == 49) try ix.flush();
    }
    for (0..10_000) |_| {
        // A substring of a random doc (so matches exist), sometimes mutated.
        const d = &docs[r.uintLessThan(usize, docs.len)];
        const len = 1 + r.uintLessThan(usize, 8);
        const at = r.uintLessThan(usize, d.len - len);
        var lit: [8]u8 = undefined;
        @memcpy(lit[0..len], d[at..][0..len]);
        if (r.boolean()) lit[r.uintLessThan(usize, len)] = alphabet[r.uintLessThan(usize, alphabet.len)];
        const ci = r.boolean();
        const cands = (try find(ix, lit[0..len], ci)) orelse continue;
        defer gpa.free(cands);
        for (docs, 0..) |doc, i| {
            const hit = if (ci) std.ascii.indexOfIgnoreCase(&doc, lit[0..len]) != null else std.mem.indexOf(u8, &doc, lit[0..len]) != null;
            if (hit and std.mem.indexOfScalar(u32, cands, @intCast(i)) == null) {
                std.debug.print("false negative: doc {d} lit '{s}' ci={}\n", .{ i, lit[0..len], ci });
                return error.TestUnexpectedResult;
            }
        }
    }
}
