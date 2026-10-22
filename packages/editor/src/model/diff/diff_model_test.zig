//! DiffModel: incremental updates stay exact, hunk ChangeSets, background
//! full diffs and listener events.

const std = @import("std");
const zg_core = @import("zg_core");
const dm = @import("diff_model.zig");
const Document = @import("../document.zig").Document;
const ChangeSet = @import("../edit/change_set.zig").ChangeSet;
const LineSource = @import("line_ids.zig").LineSource;

const gpa = std.testing.allocator;

const Fixture = struct {
    rt: zg_core.Runtime,
    threaded: bool,
    doc: *Document,
    m: *dm.DiffModel,

    fn init(f: *Fixture, base: []const u8, current: []const u8) !void {
        return f.initWith(base, current, true);
    }

    fn initWith(f: *Fixture, base: []const u8, current: []const u8, threaded: bool) !void {
        f.threaded = threaded;
        if (threaded) f.rt.initTesting();
        f.doc = try Document.initBytes(gpa, @enumFromInt(1), base);
        const snap = f.doc.snapshot();
        try f.replaceAll(current);
        f.m = try dm.DiffModel.init(gpa, if (threaded) &f.rt else null, snap, f.doc, .{});
        try f.m.completeFull();
    }

    fn deinit(f: *Fixture) void {
        f.m.deinit();
        f.doc.deinit();
        if (f.threaded) _ = f.rt.deinit();
    }

    fn edit(f: *Fixture, start: u64, end: u64, text: []const u8) !void {
        var cs = try ChangeSet.fromEdits(gpa, f.doc.len(), &.{.{ .range = .{ .start = start, .end = end }, .text = text }});
        defer cs.deinit();
        try f.doc.applyChangeSet(&cs, .{ .user = 0 });
    }

    fn replaceAll(f: *Fixture, text: []const u8) !void {
        try f.edit(0, f.doc.len(), text);
    }

    fn content(f: *Fixture) ![]u8 {
        return f.doc.tree.copyRange(gpa, .{ .start = 0, .end = f.doc.len() });
    }

    /// The hunks must be sorted, disjoint, aligned on equal runs, and
    /// rebuild the current lines from the base (lines compare without
    /// terminators, as the line diff does).
    fn check(f: *Fixture) !void {
        const base = &f.m.base;
        const cur = try f.content();
        defer gpa.free(cur);
        var cs = try LineSource.fromBytes(gpa, cur);
        defer cs.deinit(gpa);
        var b: usize = 0;
        var c: usize = 0;
        for (f.m.hunks()) |h| {
            if (h.old.start < b or h.new.start < c) return error.TestUnexpectedResult;
            if (h.old.start - b != h.new.start - c) return error.TestUnexpectedResult;
            if (h.old.count == 0 and h.new.count == 0) return error.TestUnexpectedResult;
            while (b < h.old.start) : ({
                b += 1;
                c += 1;
            }) try expectSameLine(base, b, &cs, c);
            b += @intCast(h.old.count);
            c += @intCast(h.new.count);
        }
        if (base.count() - b != cs.count() - c) return error.TestUnexpectedResult;
        while (b < base.count()) : ({
            b += 1;
            c += 1;
        }) try expectSameLine(base, b, &cs, c);
    }
};

fn expectSameLine(a: *const LineSource, i: usize, b: *const LineSource, j: usize) !void {
    try std.testing.expectEqualStrings(a.line(i), b.line(j));
    try std.testing.expectEqual(a.missingEol(i), b.missingEol(j));
}

fn genLines(r: std.Random, buf: *std.ArrayList(u8), n: usize) !void {
    for (0..n) |_| {
        try buf.appendSlice(gpa, ([_][]const u8{ "alpha", "beta", "gamma", "delta", "  }", "x = 1;", "" })[r.uintLessThan(usize, 7)]);
        try buf.append(gpa, '\n');
    }
}

/// One random edit: line insert/delete or a few bytes anywhere.
fn randomEdit(f: *Fixture, r: std.Random) !void {
    const len = f.doc.len();
    const at = r.uintAtMost(u64, len);
    switch (r.uintLessThan(u8, 5)) {
        0 => try f.edit(at, at, "new line\n"),
        1 => try f.edit(at, @min(len, at + r.uintLessThan(u64, 40)), ""),
        2 => try f.edit(at, at, "z"),
        3 => try f.edit(at, @min(len, at + 3), "\r\nq\n"),
        else => {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(gpa);
            try genLines(r, &buf, r.uintLessThan(usize, 6));
            try f.edit(at, @min(len, at + r.uintLessThan(u64, 60)), buf.items);
        },
    }
}

test "diff_model: incremental equals full after random edits" {
    for (0..40) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const r = prng.random();
        var base: std.ArrayList(u8) = .empty;
        defer base.deinit(gpa);
        try genLines(r, &base, 30 + r.uintLessThan(usize, 200));
        var f: Fixture = undefined;
        try f.init(base.items, base.items);
        defer f.deinit();
        try std.testing.expectEqual(@as(usize, 0), f.m.hunks().len);
        for (0..60) |_| {
            try randomEdit(&f, r);
            if (f.m.fullPending()) try f.m.completeFull();
            try f.check();
            try std.testing.expectEqual(f.doc.version, f.m.version());
        }
        // A full diff of the final texts describes them too, and the
        // incremental hunks change no more lines than twice its count.
        var inc: u64 = 0;
        for (f.m.hunks()) |h| inc += h.old.count + h.new.count;
        try f.m.setBase(f.m.base_snap.retain());
        try f.m.completeFull();
        try f.check();
        var full: u64 = 0;
        for (f.m.hunks()) |h| full += h.old.count + h.new.count;
        try std.testing.expect(inc <= 2 * full + 2);
    }
}

test "diff_model: revert hunk restores base text for that region" {
    var f: Fixture = undefined;
    try f.init("a\nb\nc\nd\ne\nf\ng\nh\n", "a\nB\nc\nd\ne\nf\nG\nh\nextra\n");
    defer f.deinit();
    const hs = f.m.hunks();
    try std.testing.expectEqual(@as(usize, 3), hs.len);
    try std.testing.expectEqual(@as(u64, 1), hs[0].new.start);
    // Accepting hunk 1 onto the base applies only that change.
    var acc = try f.m.hunkChangeSet(1, .base_to_current);
    defer acc.deinit();
    const staged = try acc.applyToSlice(gpa, f.m.base.text);
    defer gpa.free(staged);
    try std.testing.expectEqualStrings("a\nb\nc\nd\ne\nf\nG\nh\n", staged);
    var cs = try f.m.hunkChangeSet(0, .current_to_base);
    defer cs.deinit();
    try f.doc.applyChangeSet(&cs, .{ .user = 1 });
    const t = try f.content();
    defer gpa.free(t);
    try std.testing.expectEqualStrings("a\nb\nc\nd\ne\nf\nG\nh\nextra\n", t);
    try std.testing.expectEqual(@as(usize, 2), f.m.hunks().len);
    try f.check();
}

test "diff_model: large paste triggers background full diff" {
    var f: Fixture = undefined;
    try f.init("one\ntwo\n", "one\ntwo\n");
    defer f.deinit();
    const paste = try gpa.alloc(u8, 12_000 * 4);
    defer gpa.free(paste);
    for (0..12_000) |k| @memcpy(paste[k * 4 ..][0..4], "ln.\n");
    try f.edit(4, 4, paste);
    try std.testing.expect(f.m.fullPending());
    // Edits made while it runs are mapped onto its result.
    try f.edit(0, 0, "zero\n");
    // Edits next to a hunk this large rediff in full again.
    while (f.m.fullPending()) try f.m.completeFull();
    try std.testing.expect(!f.m.fullPending());
    try f.check();
    try std.testing.expectEqual(@as(usize, 2), f.m.hunks().len);
}

test "diff_model: base change recomputes" {
    var f: Fixture = undefined;
    try f.init("a\nb\n", "a\nb\nc\n");
    defer f.deinit();
    try std.testing.expectEqual(@as(usize, 1), f.m.hunks().len);
    try f.m.setBase(f.doc.snapshot());
    try f.m.completeFull();
    try std.testing.expectEqual(@as(usize, 0), f.m.hunks().len);
    try f.edit(0, 0, "x");
    try std.testing.expectEqual(@as(usize, 1), f.m.hunks().len);
    try f.check();
}

test "diff_model: listener events contiguous" {
    const Mirror = struct {
        len: usize,
        ok: bool = true,
        last_version: u64 = 0,

        fn on(ctx: *anyopaque, ev: dm.HunksChanged) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (ev.first + ev.removed > s.len or ev.version < s.last_version) s.ok = false;
            s.len = s.len - ev.removed + ev.inserted;
            s.last_version = ev.version;
        }
    };
    var f: Fixture = undefined;
    try f.init("a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n", "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl\n");
    defer f.deinit();
    var mirror: Mirror = .{ .len = f.m.hunks().len };
    try f.m.subscribe(.{ .ctx = &mirror, .onHunks = Mirror.on });
    var prng: std.Random.DefaultPrng = .init(1191);
    for (0..200) |_| {
        try randomEdit(&f, prng.random());
        if (f.m.fullPending()) try f.m.completeFull();
        try std.testing.expect(mirror.ok);
        try std.testing.expectEqual(f.m.hunks().len, mirror.len);
    }
}

test "diff_model: intraline highlights" {
    var f: Fixture = undefined;
    try f.init("keep\nconst x = 1;\nkeep\n", "keep\nconst y = 1;\nkeep\n");
    defer f.deinit();
    const r = try f.m.intraline(0, .word, gpa);
    defer gpa.free(r);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    for (r) |x| try std.testing.expectEqual(@as(u64, 1), x.range.len());
    try std.testing.expectEqual(@as(u64, 11), r[1].range.start);
}

test "fuzz: diff_model incremental" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var f: Fixture = undefined;
            try f.initWith("a\nb\nc\nd\ne\nf\ng\n", "a\nb\nX\nd\ne\nf\ng\n", false);
            defer f.deinit();
            for (0..1 + s.index(16)) |_| {
                const len = f.doc.len();
                const at = s.index(@intCast(len + 1));
                const end = @min(len, at + s.index(8));
                var buf: [8]u8 = undefined;
                const n = s.slice(&buf);
                for (buf[0..n]) |*c| c.* = "ab\n\r x"[c.* % 6];
                try f.edit(at, end, buf[0..n]);
                if (f.m.fullPending()) try f.m.completeFull();
                try f.check();
            }
        }
    }.one, .{});
}
