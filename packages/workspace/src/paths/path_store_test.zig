//! PathStore tests.

const std = @import("std");
const ps_mod = @import("path_store.zig");
const PathStore = ps_mod.PathStore;
const Delta = ps_mod.Delta;
const Change = ps_mod.Change;
const NodeInfo = ps_mod.NodeInfo;
const RootId = @import("../ids.zig").RootId;
const FileId = @import("../ids.zig").FileId;

const r0: RootId = .of(0);
const file: NodeInfo = .{ .kind = .file, .size = 1 };

fn upsert(ps: *PathStore, ch: *std.ArrayList(Change), rel: []const u8, info: NodeInfo) !void {
    try ps.apply(&.{ .ops = &.{.{ .upsert = .{ .root = r0, .rel = rel, .info = info } }} }, ch);
}

fn randomPath(r: std.Random, buf: []u8) []const u8 {
    const segs = [_][]const u8{ "src", "lib", "a", "b", "index.ts", "mod.rs", "x", "test", "deep", "util.zig" };
    var n: usize = 0;
    const depth = 1 + r.uintLessThan(usize, 5);
    for (0..depth) |d| {
        if (d > 0) {
            buf[n] = '/';
            n += 1;
        }
        const s = segs[r.uintLessThan(usize, segs.len)];
        @memcpy(buf[n..][0..s.len], s);
        n += s.len;
        // Make names distinct enough.
        n += (std.fmt.bufPrint(buf[n..], "{d}", .{r.uintLessThan(u8, 20)}) catch unreachable).len;
    }
    return buf[0..n];
}

test "path_store: insert/lookup/pathOf roundtrip for 10k random paths" {
    const gpa = std.testing.allocator;
    const ps = try PathStore.init(gpa, std.testing.io);
    defer ps.deinit();
    try ps.addRoot(r0, false);
    var ch: std.ArrayList(Change) = .empty;
    defer ch.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(42);
    var paths: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = paths.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        paths.deinit(gpa);
    }
    var ops: std.ArrayList(Delta.Op) = .empty;
    defer ops.deinit(gpa);
    var buf: [256]u8 = undefined;
    // Leaves only: a path is never a prefix directory of another leaf.
    while (paths.count() < 10_000) {
        const p = randomPath(prng.random(), &buf);
        const own = try std.fmt.allocPrint(gpa, "{s}.f", .{p});
        if (paths.contains(own)) {
            gpa.free(own);
            continue;
        }
        try paths.put(gpa, own, {});
        try ops.append(gpa, .{ .upsert = .{ .root = r0, .rel = own, .info = file } });
    }
    try ps.apply(&.{ .ops = ops.items }, &ch);
    const s = ps.snapshot();
    defer s.release();
    try std.testing.expectEqual(@as(u32, 10_000), s.fileCount());
    var it = paths.keyIterator();
    var pbuf: [512]u8 = undefined;
    while (it.next()) |k| {
        const id = s.lookup(r0, k.*) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(k.*, s.pathOf(id, &pbuf));
    }
    try std.testing.expect(s.lookup(r0, "nope/x") == null);
    // iterFiles visits every file once; siblings come in name order.
    var n: usize = 0;
    var prev: ?FileId = null;
    var fi = s.iterFiles(r0);
    while (fi.next()) |id| {
        try std.testing.expect(paths.contains(s.pathOf(id, &pbuf)));
        if (prev) |q| if (s.parentOf(q).?.eql(s.parentOf(id).?)) {
            try std.testing.expect(std.mem.lessThan(u8, s.basename(q), s.basename(id)));
        };
        prev = id;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 10_000), n);
}

test "path_store: rename dir keeps subtree FileIds" {
    const gpa = std.testing.allocator;
    const ps = try PathStore.init(gpa, std.testing.io);
    defer ps.deinit();
    try ps.addRoot(r0, false);
    var ch: std.ArrayList(Change) = .empty;
    defer ch.deinit(gpa);
    try upsert(ps, &ch, "a/b/c.txt", file);
    try upsert(ps, &ch, "a/b/d.txt", file);
    const s1 = ps.snapshot();
    defer s1.release();
    const dir = s1.lookup(r0, "a/b").?;
    const c = s1.lookup(r0, "a/b/c.txt").?;
    ch.clearRetainingCapacity();
    try ps.apply(&.{ .ops = &.{.{ .rename = .{ .root = r0, .from = "a/b", .to = "z/y" } }} }, &ch);
    const s2 = ps.snapshot();
    defer s2.release();
    try std.testing.expect(s2.lookup(r0, "z/y").?.eql(dir));
    try std.testing.expect(s2.lookup(r0, "z/y/c.txt").?.eql(c));
    try std.testing.expect(s2.lookup(r0, "a/b") == null);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("z/y/c.txt", s2.pathOf(c, &buf));
    // The old snapshot still sees the old layout.
    try std.testing.expectEqualStrings("a/b/c.txt", s1.pathOf(c, &buf));
    var renamed = false;
    for (ch.items) |x| if (x.what == .renamed and x.id.eql(dir)) {
        renamed = true;
        try std.testing.expect(x.old_parent.?.eql(s1.lookup(r0, "a").?));
    };
    try std.testing.expect(renamed);
    try std.testing.expectError(error.RenameIntoSelf, ps.apply(&.{ .ops = &.{.{ .rename = .{ .root = r0, .from = "z", .to = "z/y/q" } }} }, &ch));
}

test "path_store: remove recursive frees slots and bumps generation (stale id -> null)" {
    const gpa = std.testing.allocator;
    const ps = try PathStore.init(gpa, std.testing.io);
    defer ps.deinit();
    try ps.addRoot(r0, false);
    var ch: std.ArrayList(Change) = .empty;
    defer ch.deinit(gpa);
    try upsert(ps, &ch, "d/e/f.txt", file);
    try upsert(ps, &ch, "d/g.txt", file);
    const s1 = ps.snapshot();
    const f = s1.lookup(r0, "d/e/f.txt").?;
    s1.release();
    ch.clearRetainingCapacity();
    try ps.apply(&.{ .ops = &.{.{ .remove = .{ .root = r0, .rel = "d" } }} }, &ch);
    try std.testing.expectEqual(@as(usize, 4), ch.items.len);
    for (ch.items) |x| try std.testing.expectEqual(.removed, x.what);
    try std.testing.expectEqual(@as(u32, 0), ps.nodeCount());
    // Reuse the slots: the stale id must not resolve to the new node.
    try upsert(ps, &ch, "n1/n2/n3/n4", file);
    const s2 = ps.snapshot();
    defer s2.release();
    try std.testing.expect(!s2.contains(f));
    try std.testing.expectEqualStrings("", s2.basename(f));
    try std.testing.expectEqual(@as(u32, 1), s2.fileCount());
}

test "path_store: upsert modifies, creates loading parents and changes kind" {
    const gpa = std.testing.allocator;
    const ps = try PathStore.init(gpa, std.testing.io);
    defer ps.deinit();
    try ps.addRoot(r0, false);
    var ch: std.ArrayList(Change) = .empty;
    defer ch.deinit(gpa);
    try upsert(ps, &ch, "p/q.txt", file);
    try std.testing.expectEqual(@as(usize, 2), ch.items.len);
    ch.clearRetainingCapacity();
    try upsert(ps, &ch, "p/q.txt", file);
    try std.testing.expectEqual(@as(usize, 0), ch.items.len);
    try upsert(ps, &ch, "p/q.txt", .{ .kind = .file, .size = 9 });
    try std.testing.expectEqual(.modified, ch.items[0].what);
    const s = ps.snapshot();
    try std.testing.expect(s.info(s.lookup(r0, "p").?).flags.loading);
    try std.testing.expectEqual(@as(u48, 9), s.info(s.lookup(r0, "p/q.txt").?).size);
    s.release();
    try ps.apply(&.{ .ops = &.{.{ .set_children_complete = .{ .root = r0, .rel_dir = "p" } }} }, &ch);
    // A directory replaced by a file drops its subtree.
    try upsert(ps, &ch, "p", file);
    const s2 = ps.snapshot();
    defer s2.release();
    try std.testing.expect(!s2.info(s2.lookup(r0, "p").?).isDir());
    try std.testing.expect(s2.lookup(r0, "p/q.txt") == null);
    try std.testing.expectEqual(@as(u32, 1), s2.fileCount());
    try std.testing.expectError(error.NotADirectory, upsert(ps, &ch, "p/x", file));
    // mtime packing keeps 64 ns precision.
    const inf: NodeInfo = .init(.file, 1 << 50, 1_700_000_000_123_456_789);
    try std.testing.expectEqual(@as(u48, std.math.maxInt(u48)), inf.size);
    try std.testing.expect(@abs(inf.mtimeNs() - 1_700_000_000_123_456_789) < 64);
}

test "path_store: snapshot isolation" {
    const gpa = std.testing.allocator;
    const ps = try PathStore.init(gpa, std.testing.io);
    defer ps.deinit();
    try ps.addRoot(r0, false);
    var ch: std.ArrayList(Change) = .empty;
    defer ch.deinit(gpa);
    try upsert(ps, &ch, "keep/a.txt", file);
    const a = ps.snapshot();
    defer a.release();
    var buf: [64]u8 = undefined;
    for (0..1000) |i| {
        const p = try std.fmt.bufPrint(&buf, "gen/{d}/f{d}.txt", .{ i % 37, i });
        try upsert(ps, &ch, p, file);
        if (i % 3 == 0) try ps.apply(&.{ .ops = &.{.{ .remove = .{ .root = r0, .rel = "keep" } }} }, &ch);
        if (i % 3 == 1) try upsert(ps, &ch, "keep/a.txt", .{ .kind = .file, .size = @intCast(i) });
    }
    try std.testing.expectEqual(@as(u32, 1), a.fileCount());
    const id = a.lookup(r0, "keep/a.txt").?;
    try std.testing.expectEqual(@as(u48, 1), a.info(id).size);
    try std.testing.expect(a.lookup(r0, "gen") == null);
    try std.testing.expectEqual(@as(usize, 1), a.children(a.rootDir(r0).?).len);
}

test "path_store: case-insensitive root lookup" {
    const gpa = std.testing.allocator;
    const ps = try PathStore.init(gpa, std.testing.io);
    defer ps.deinit();
    try ps.addRoot(r0, true);
    try ps.addRoot(.of(1), false);
    var ch: std.ArrayList(Change) = .empty;
    defer ch.deinit(gpa);
    try upsert(ps, &ch, "Src/Main.zig", file);
    // Same name in another case updates the same node.
    try upsert(ps, &ch, "src/MAIN.zig", .{ .kind = .file, .size = 5 });
    try ps.apply(&.{ .ops = &.{.{ .upsert = .{ .root = .of(1), .rel = "Src/Main.zig", .info = file } }} }, &ch);
    const s = ps.snapshot();
    defer s.release();
    try std.testing.expectEqual(@as(u32, 2), s.fileCount());
    const id = s.lookup(r0, "SRC/main.ZIG").?;
    try std.testing.expectEqual(@as(u48, 5), s.info(id).size);
    try std.testing.expect(s.lookup(.of(1), "src/main.zig") == null);
    try std.testing.expect(s.lookup(.of(1), "Src/Main.zig") != null);
    // Case-only rename keeps the id.
    try ps.apply(&.{ .ops = &.{.{ .rename = .{ .root = r0, .from = "src/main.zig", .to = "src/main.ZIG" } }} }, &ch);
    const s2 = ps.snapshot();
    defer s2.release();
    try std.testing.expectEqualStrings("main.ZIG", s2.basename(id));
}

test "path_store: flatNames consistent with iterFiles after random op sequence" {
    const gpa = std.testing.allocator;
    const ps = try PathStore.init(gpa, std.testing.io);
    defer ps.deinit();
    try ps.addRoot(r0, false);
    var ch: std.ArrayList(Change) = .empty;
    defer ch.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    var buf: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    for (0..2000) |_| {
        const p = randomPath(r, &buf);
        switch (r.uintLessThan(u8, 10)) {
            0...5 => upsert(ps, &ch, p, file) catch |e| if (e != error.NotADirectory) return e,
            6, 7 => try ps.apply(&.{ .ops = &.{.{ .remove = .{ .root = r0, .rel = p } }} }, &ch),
            else => {
                const q = randomPath(r, &buf2);
                ps.apply(&.{ .ops = &.{.{ .rename = .{ .root = r0, .from = p, .to = q } }} }, &ch) catch |e| switch (e) {
                    error.NotADirectory, error.RenameIntoSelf => {},
                    else => return e,
                };
            },
        }
        ch.clearRetainingCapacity();
    }
    const s = ps.snapshot();
    defer s.release();
    const f = s.flatNames();
    var it = s.iterFiles(null);
    var i: usize = 0;
    var pbuf: [512]u8 = undefined;
    while (it.next()) |id| : (i += 1) {
        try std.testing.expect(f.ids[i].eql(id));
        const p = s.pathOf(id, &pbuf);
        try std.testing.expectEqualStrings(p, f.path(i));
        try std.testing.expectEqualStrings(s.basename(id), p[f.basename_start[i]..]);
        for (p) |c| try std.testing.expect(f.char_mask[i] & ps_mod.FlatNames.maskOf(c) == ps_mod.FlatNames.maskOf(c));
    }
    try std.testing.expectEqual(f.ids.len, i);
    try std.testing.expectEqual(@as(usize, s.fileCount()), i);
}

test "path_store: concurrent readers see consistent snapshots" {
    const gpa = std.testing.allocator;
    const ps = try PathStore.init(gpa, std.testing.io);
    defer ps.deinit();
    try ps.addRoot(r0, false);
    var stop: std.atomic.Value(bool) = .init(false);
    var bad: std.atomic.Value(u32) = .init(0);
    const Reader = struct {
        fn run(store: *PathStore, stop_flag: *std.atomic.Value(bool), bad_count: *std.atomic.Value(u32)) void {
            var buf: [128]u8 = undefined;
            while (!stop_flag.load(.acquire)) {
                const s = store.snapshot();
                defer s.release();
                // Writer invariant: files come in pairs x/N/a and x/N/b.
                var n: u32 = 0;
                var it = s.iterFiles(r0);
                while (it.next()) |id| {
                    const p = s.pathOf(id, &buf);
                    if (s.lookup(r0, p) == null) _ = bad_count.fetchAdd(1, .monotonic);
                    n += 1;
                }
                if (n % 2 != 0 or n != s.fileCount()) _ = bad_count.fetchAdd(1, .monotonic);
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Reader.run, .{ ps, &stop, &bad });
    var ch: std.ArrayList(Change) = .empty;
    defer ch.deinit(gpa);
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    for (0..400) |i| {
        const a = try std.fmt.bufPrint(&b1, "x/{d}/a", .{i % 50});
        const b = try std.fmt.bufPrint(&b2, "x/{d}/b", .{i % 50});
        if (i % 4 == 3) {
            const d = try std.fmt.bufPrint(&b1, "x/{d}", .{(i / 4) % 50});
            try ps.apply(&.{ .ops = &.{.{ .remove = .{ .root = r0, .rel = d } }} }, &ch);
        } else {
            try ps.apply(&.{ .ops = &.{ .{ .upsert = .{ .root = r0, .rel = a, .info = file } }, .{ .upsert = .{ .root = r0, .rel = b, .info = file } } } }, &ch);
        }
        ch.clearRetainingCapacity();
    }
    stop.store(true, .release);
    for (threads) |t| t.join();
    ps.collect();
    try std.testing.expectEqual(@as(u32, 0), bad.load(.acquire));
}
