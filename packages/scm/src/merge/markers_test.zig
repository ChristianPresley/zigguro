//! Conflict marker tests: byte-identity with git's diff3/zdiff3 output on
//! the checked-in fixtures, round trips through `parseMarkers`, partial
//! resolution and marker-length selection.

const std = @import("std");
const options = @import("zg_options");
const merge_mod = @import("merge.zig");
const mat = @import("materialize.zig");
const pm = @import("parse_markers.zig");
const Merge = merge_mod.Merge;
const MergeHunk = mat.MergeHunk;
const Allocator = std.mem.Allocator;
const t = std.testing;

const labels = [_][]const u8{ "ours", "base", "theirs" };
const two_sided_file: Merge(?[]const u8) = .{ .values = &[_]?[]const u8{ "", "", "" } };

/// Splits git's diff3 output into hunks (test-only; the real hunks come
/// from the content merge).
fn hunksFromDiff3(arena: Allocator, text: []const u8) ![]MergeHunk {
    var hunks: std.ArrayList(MergeHunk) = .empty;
    var it = mat.LineIter{ .text = text };
    var start: usize = 0;
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "<<<<<<< ")) continue;
        const region_start = it.pos - line.len;
        if (region_start > start) try hunks.append(arena, .{ .resolved = text[start..region_start] });
        var bounds: [3][2]usize = undefined;
        var sec: usize = 0;
        bounds[0][0] = it.pos;
        while (it.next()) |l| {
            const ls = it.pos - l.len;
            if (std.mem.startsWith(u8, l, "||||||| ") or std.mem.eql(u8, l, "=======\n")) {
                bounds[sec][1] = ls;
                sec += 1;
                bounds[sec][0] = it.pos;
            } else if (std.mem.startsWith(u8, l, ">>>>>>> ")) {
                bounds[sec][1] = ls;
                break;
            }
        }
        const vals = try arena.alloc([]const u8, 3);
        for (vals, bounds) |*v, b| v.* = text[b[0]..b[1]];
        try hunks.append(arena, .{ .conflict = .{ .values = vals } });
        start = it.pos;
    }
    if (start < text.len) try hunks.append(arena, .{ .resolved = text[start..] });
    return hunks.items;
}

fn render(gpa: Allocator, hunks: []const MergeHunk, o: mat.MaterializeOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const vals = [_]?[]const u8{ "", "", "" };
    try mat.materialize(gpa, .{ .values = &vals }, hunks, o, &aw.writer);
    return aw.toOwnedSlice();
}

test "markers: materialize golden (git diff3 and zdiff3 fixtures)" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = try std.Io.Dir.openDirAbsolute(t.io, options.package_root, .{});
    defer root.close(t.io);
    var dir = try root.openDir(t.io, "testdata/merge", .{});
    defer dir.close(t.io);
    var cases: usize = 0;
    for (1..100) |n| {
        var name: [8]u8 = undefined;
        const d = std.fmt.bufPrint(&name, "{d:0>2}", .{n}) catch unreachable;
        var case_dir = dir.openDir(t.io, d, .{}) catch break;
        defer case_dir.close(t.io);
        cases += 1;
        const diff3 = try case_dir.readFileAlloc(t.io, "diff3", arena, .limited(1 << 20));
        const zdiff3 = try case_dir.readFileAlloc(t.io, "zdiff3", arena, .limited(1 << 20));
        const merge_style = try case_dir.readFileAlloc(t.io, "merge", arena, .limited(1 << 20));
        const hunks = try hunksFromDiff3(arena, diff3);
        try t.expectEqualStrings(diff3, try render(arena, hunks, .{ .style = .diff3, .labels = &labels }));
        try t.expectEqualStrings(zdiff3, try render(arena, hunks, .{ .style = .zdiff3, .labels = &labels }));
        // git's default style may also split regions zealously; compare
        // only where it kept diff3's regions.
        const ours_merge = try render(arena, hunks, .{ .style = .merge, .labels = &labels });
        if (std.mem.count(u8, merge_style, "<<<<<<<") == std.mem.count(u8, diff3, "<<<<<<<")) {
            try t.expectEqualStrings(merge_style, ours_merge);
        }

        // Parsing git's diff3 file gives each term in full: the merged
        // text outside the regions plus that term's region text.
        var want: [3]std.ArrayList(u8) = .{ .empty, .empty, .empty };
        for (hunks) |h| switch (h) {
            .resolved => |text| for (&want) |*w| try w.appendSlice(arena, text),
            .conflict => |m| for (&want, m.values) |*w, v| try w.appendSlice(arena, v),
        };
        const r = try pm.parseMarkers(t.allocator, diff3, two_sided_file, .{ .style = .diff3 });
        defer r.deinit(t.allocator);
        for (want, r.conflict.values) |w, got| try t.expectEqualStrings(w.items, got);
        // zdiff3 moved shared lines out, so only the sides are the same.
        const rz = try pm.parseMarkers(t.allocator, zdiff3, two_sided_file, .{ .style = .zdiff3 });
        defer rz.deinit(t.allocator);
        try t.expectEqualStrings(want[0].items, rz.conflict.values[0]);
        try t.expectEqualStrings(want[2].items, rz.conflict.values[2]);
    }
    try t.expectEqual(@as(usize, 20), cases);
}

test "markers: zg style golden, 2 and 3 sides" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const three = [_][]const u8{ "a\nB\nc\n", "a\nb\nc\n", "a\nb\nC\n", "a\nb\nc\n", "A\nb\nc\n" };
    const hunks = [_]MergeHunk{ .{ .resolved = "top\n" }, .{ .conflict = .{ .values = &three } } };
    var aw: std.Io.Writer.Allocating = .init(arena);
    const vals = [_]?[]const u8{ "", "", "", "", "" };
    try mat.materialize(arena, .{ .values = &vals }, &hunks, .{ .style = .diff3 }, &aw.writer);
    try t.expectEqualStrings(
        \\top
        \\<<<<<<< conflict 1 of 1
        \\%%%%%%% diff from base #1 to side #1
        \\ a
        \\-b
        \\+B
        \\ c
        \\%%%%%%% diff from base #2 to side #2
        \\ a
        \\ b
        \\-c
        \\+C
        \\+++++++ side #3
        \\A
        \\b
        \\c
        \\>>>>>>> conflict 1 of 1 ends
        \\
    , aw.written());
    const r = try pm.parseMarkers(t.allocator, aw.written(), .{ .values = &vals }, .{ .style = .zg });
    defer r.deinit(t.allocator);
    for (three, r.conflict.values) |want, got| {
        const full = try std.mem.concat(arena, u8, &.{ "top\n", want });
        try t.expectEqualStrings(full, got);
    }
}

test "markers: parse roundtrip (random conflicts)" {
    var prng: std.Random.DefaultPrng = .init(4);
    const rng = prng.random();
    const pool = [_][]const u8{ "a\n", "b\n", "c\n", "=======\n", "<<<<<<< x\n", "+++\n", " \n", "\n", "%%\n" };
    for (0..10_000) |iter| {
        var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const nterms: usize = if (iter % 4 == 0) 5 else 3;
        var hunks: std.ArrayList(MergeHunk) = .empty;
        const want = try arena.alloc(std.ArrayList(u8), nterms);
        for (want) |*w| w.* = .empty;
        for (0..1 + rng.uintLessThan(usize, 4)) |_| {
            if (rng.boolean()) {
                const text = try randomText(arena, rng, &pool, 3);
                if (text.len == 0) continue;
                if (hunks.items.len > 0 and hunks.items[hunks.items.len - 1] == .resolved) continue;
                try hunks.append(arena, .{ .resolved = text });
                for (want) |*w| try w.appendSlice(arena, text);
            } else {
                const vals = try arena.alloc([]const u8, nterms);
                for (vals, want) |*v, *w| {
                    v.* = try randomText(arena, rng, &pool, 4);
                    try w.appendSlice(arena, v.*);
                }
                try hunks.append(arena, .{ .conflict = .{ .values = vals } });
            }
        }
        const fvals = try arena.alloc(?[]const u8, nterms);
        @memset(fvals, "");
        const file: Merge(?[]const u8) = .{ .values = fvals };
        const styles: []const mat.ConflictStyle = if (nterms == 3) &.{ .zg, .diff3 } else &.{.zg};
        for (styles) |style| {
            var aw: std.Io.Writer.Allocating = .init(arena);
            try mat.materialize(arena, file, hunks.items, .{ .style = style }, &aw.writer);
            const len = mat.markerLen(hunks.items, 7);
            const r = try pm.parseMarkers(arena, aw.written(), file, .{ .style = style, .marker_len = len });
            switch (r) {
                .resolved => |text| {
                    for (hunks.items) |h| try t.expect(h == .resolved);
                    try t.expectEqualStrings(want[0].items, text);
                },
                .conflict => |m| for (want, m.values) |w, got| try t.expectEqualStrings(w.items, got),
                .unparseable => return error.TestUnexpectedResult,
            }
        }
    }
}

fn randomText(arena: Allocator, rng: std.Random, pool: []const []const u8, max: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..rng.uintLessThan(usize, max + 1)) |_| try out.appendSlice(arena, pool[rng.uintLessThan(usize, pool.len)]);
    return out.items;
}

test "markers: partial resolution" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r1 = [_][]const u8{ "X\n", "b\n", "Y\n" };
    const r2 = [_][]const u8{ "P\n", "q\n", "R\n" };
    const hunks = [_]MergeHunk{ .{ .resolved = "a\n" }, .{ .conflict = .{ .values = &r1 } }, .{ .resolved = "c\n" }, .{ .conflict = .{ .values = &r2 } } };
    const text = try render(arena, &hunks, .{ .style = .diff3 });
    // Resolve the first region by hand, keep the second.
    const end_first = std.mem.indexOf(u8, text, ">>>>>>> side #2\n").? + ">>>>>>> side #2\n".len;
    const edited = try std.mem.concat(arena, u8, &.{ "a\nXY\n", text[end_first..] });
    const r = try pm.parseMarkers(t.allocator, edited, two_sided_file, .{ .style = .diff3 });
    defer r.deinit(t.allocator);
    try t.expectEqualStrings("a\nXY\nc\nP\n", r.conflict.values[0]);
    try t.expectEqualStrings("a\nXY\nc\nq\n", r.conflict.values[1]);
    try t.expectEqualStrings("a\nXY\nc\nR\n", r.conflict.values[2]);
    // Everything resolved.
    const done = try pm.parseMarkers(t.allocator, "all\nfine\n", two_sided_file, .{});
    defer done.deinit(t.allocator);
    try t.expectEqualStrings("all\nfine\n", done.resolved);
    // Broken markers are reported, never guessed at.
    for ([_][]const u8{
        "a\n<<<<<<< x\nb\n=======\nc\n",
        "<<<<<<< x\nb\n<<<<<<< y\n>>>>>>> z\n",
        "<<<<<<< x\nb\n=======\nc\n>>>>>>> y\n",
        "<<<<<<< conflict 1 of 1\n%%%%%%% d\n?bad\n+++++++ s\nx\n>>>>>>> e\n",
    }) |bad| {
        const b = try pm.parseMarkers(t.allocator, bad, two_sided_file, .{});
        try t.expectEqual(pm.ParseResult.unparseable, b);
    }
}

test "markers: long-marker selection when file contains =======" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const region = [_][]const u8{ "=======\nX\n", "b\n", "Y\n" };
    const hunks = [_]MergeHunk{ .{ .resolved = "<<<<<<<<\n" }, .{ .conflict = .{ .values = &region } } };
    const len = mat.markerLen(&hunks, 7);
    try t.expectEqual(@as(u8, 9), len);
    const text = try render(arena, &hunks, .{ .style = .diff3 });
    try t.expect(std.mem.indexOf(u8, text, "\n<<<<<<<<< side #1\n") != null);
    const r = try pm.parseMarkers(t.allocator, text, two_sided_file, .{ .style = .diff3, .marker_len = len });
    defer r.deinit(t.allocator);
    try t.expectEqualStrings("<<<<<<<<\n=======\nX\n", r.conflict.values[0]);
    try t.expectEqualStrings("<<<<<<<<\nY\n", r.conflict.values[2]);
}

test "fuzz: scm-markers" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [2048]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            if (input.len == 0) return;
            const nterms: usize = if (input[0] & 1 == 0) 3 else 5;
            const fvals = [_]?[]const u8{ "", "", "", "", "" };
            const file: Merge(?[]const u8) = .{ .values = fvals[0..nterms] };
            const style: mat.ConflictStyle = if (input[0] & 2 == 0) .zg else .diff3;
            const r = try pm.parseMarkers(t.allocator, input[1..], file, .{ .style = style, .marker_len = 7 });
            defer r.deinit(t.allocator);
            // Whatever parses as a conflict re-materializes and parses to
            // the same texts.
            if (r != .conflict) return;
            const v = r.conflict.values;
            var hunks = [_]MergeHunk{.{ .conflict = r.conflict }};
            // Only newline-terminated texts survive the round trip.
            for (v) |x| if (x.len > 0 and x[x.len - 1] != '\n') return;
            var aw: std.Io.Writer.Allocating = .init(t.allocator);
            defer aw.deinit();
            try mat.materialize(t.allocator, file, &hunks, .{ .style = style }, &aw.writer);
            const again = try pm.parseMarkers(t.allocator, aw.written(), file, .{ .style = style, .marker_len = mat.markerLen(&hunks, 7) });
            defer again.deinit(t.allocator);
            for (v, again.conflict.values) |a, b| try t.expectEqualStrings(a, b);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "scm-markers") });
}
