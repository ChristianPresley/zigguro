//! Scheduler tests over real temp trees.

const std = @import("std");
const Io = std.Io;
const scheduler = @import("scheduler.zig");
const Scheduler = scheduler.Scheduler;
const plugin_mod = @import("plugin.zig");
const IndexPlugin = plugin_mod.IndexPlugin;
const FileRef = plugin_mod.FileRef;
const PluginOutput = plugin_mod.PluginOutput;
const ContentClass = @import("content_class.zig").ContentClass;
const Cache = @import("cache.zig").Cache;
const PathStore = @import("../paths/path_store.zig").PathStore;
const IgnoreStack = @import("../ignore/ignore_stack.zig").IgnoreStack;
const Scanner = @import("../scan/scanner.zig").Scanner;
const RootId = @import("../ids.zig").RootId;
const FileId = @import("../ids.zig").FileId;

const gpa = std.testing.allocator;
const io = std.testing.io;

/// Records the files it indexes, in order.
const Recorder = struct {
    name: []const u8 = "rec",
    version: u32 = 1,
    lock: Io.Mutex = .init,
    seen: std.ArrayList([]u8) = .empty,
    classes: std.ArrayList(ContentClass) = .empty,
    removed: u32 = 0,
    commits: u32 = 0,
    /// Pause the scheduler from inside the first `index` call.
    pause_on_first: ?*Scheduler = null,

    fn deinit(r: *Recorder) void {
        for (r.seen.items) |p| gpa.free(p);
        r.seen.deinit(gpa);
        r.classes.deinit(gpa);
    }

    fn plugin(r: *Recorder) IndexPlugin {
        return .{ .name = r.name, .version = r.version, .ctx = r, .wants = wants, .index = index, .remove = remove, .commit = commit };
    }

    fn wants(_: *anyopaque, _: *const FileRef, _: ContentClass) bool {
        return true;
    }

    fn index(ctx: *anyopaque, f: *const FileRef, _: []const u8, class: ContentClass, _: *PluginOutput) anyerror!void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.lock.lockUncancelable(io);
        defer r.lock.unlock(io);
        try r.seen.append(gpa, try gpa.dupe(u8, f.rel));
        try r.classes.append(gpa, class);
        if (r.pause_on_first) |s| if (r.seen.items.len == 1) s.pause();
    }

    fn remove(ctx: *anyopaque, _: *const FileRef) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.removed += 1;
    }

    fn commit(ctx: *anyopaque) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.commits += 1;
    }

    fn count(r: *Recorder) usize {
        r.lock.lockUncancelable(io);
        defer r.lock.unlock(io);
        return r.seen.items.len;
    }
};

const Fixture = struct {
    tmp: std.testing.TmpDir,
    abs: []u8,
    ps: *PathStore,
    ign: *IgnoreStack,
    root: RootId,

    fn init(files: []const [2][]const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        for (files) |f| {
            if (std.fs.path.dirname(f[0])) |d| try tmp.dir.createDirPath(io, d);
            try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
        }
        const z = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(z);
        var f: Fixture = .{ .tmp = tmp, .abs = try gpa.dupe(u8, z), .ps = undefined, .ign = undefined, .root = undefined };
        try f.rescan();
        return f;
    }

    /// A fresh PathStore filled by the scanner.
    fn rescan(f: *Fixture) !void {
        f.ps = try PathStore.init(gpa, io);
        f.ign = try IgnoreStack.init(gpa, io, 0);
        f.root = try f.ign.addRoot();
        try f.ps.addRoot(f.root, false);
        const job = try Scanner.start(gpa, io, .{ .paths = f.ps, .ignore = f.ign, .root = f.root, .abs_path = f.abs }, "", .{});
        job.deinit();
    }

    fn dropStore(f: *Fixture) void {
        f.ps.deinit();
        f.ign.deinit();
    }

    fn deinit(f: *Fixture) void {
        f.dropStore();
        gpa.free(f.abs);
        f.tmp.cleanup();
    }

    fn id(f: *Fixture, rel: []const u8) FileId {
        const s = f.ps.snapshot();
        defer s.release();
        return s.lookup(f.root, rel).?;
    }

    fn sched(f: *Fixture, cache: ?*Cache, workers: u8) !*Scheduler {
        const s = try Scheduler.init(gpa, io, f.ps, cache, .{ .max_workers = workers });
        try s.addRoot(f.root, f.abs);
        return s;
    }
};

test "scheduler: priority order open > visible > recent > background" {
    var f = try Fixture.init(&.{ .{ "bg.txt", "b" }, .{ "recent.txt", "r" }, .{ "vis.txt", "v" }, .{ "open.txt", "o" } });
    defer f.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    const s = try f.sched(null, 1);
    defer s.deinit();
    try s.register(rec.plugin());
    s.start(true);
    try s.enqueue(f.id("bg.txt"), .background);
    try s.enqueue(f.id("recent.txt"), .recent);
    try s.enqueue(f.id("vis.txt"), .visible);
    try s.enqueue(f.id("open.txt"), .open);
    s.@"resume"();
    s.waitIdle();
    try std.testing.expectEqual(@as(usize, 4), rec.seen.items.len);
    const want = [_][]const u8{ "open.txt", "vis.txt", "recent.txt", "bg.txt" };
    for (want, rec.seen.items) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expect(rec.commits >= 1);
}

test "scheduler: boost moves queued file" {
    var f = try Fixture.init(&.{ .{ "a", "a" }, .{ "b", "b" }, .{ "c", "c" } });
    defer f.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    const s = try f.sched(null, 1);
    defer s.deinit();
    try s.register(rec.plugin());
    s.start(true);
    for ([_][]const u8{ "a", "b", "c" }) |n| try s.enqueue(f.id(n), .background);
    try s.boost(&.{f.id("c")}, .visible);
    try s.enqueue(f.id("a"), .background); // already queued: no duplicate
    try std.testing.expectEqual(@as(u64, 3), s.stats().queued);
    s.@"resume"();
    s.waitIdle();
    try std.testing.expectEqual(@as(usize, 3), rec.seen.items.len);
    try std.testing.expectEqualStrings("c", rec.seen.items[0]);
    try std.testing.expectEqualStrings("a", rec.seen.items[1]);
    try std.testing.expectEqualStrings("b", rec.seen.items[2]);
}

test "scheduler: pause takes effect within one file" {
    var files: [20][2][]const u8 = undefined;
    var names: [20][8]u8 = undefined;
    for (&files, 0..) |*e, i| e.* = .{ try std.fmt.bufPrint(&names[i], "f{d}", .{i}), "x" };
    var f = try Fixture.init(&files);
    defer f.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    const s = try f.sched(null, 1);
    defer s.deinit();
    rec.pause_on_first = s;
    try s.register(rec.plugin());
    s.start(true);
    const snap = f.ps.snapshot();
    try s.enqueueAll(snap);
    snap.release();
    s.@"resume"();
    // Let the worker run into the pause.
    var waited: u32 = 0;
    while (rec.count() == 0 and waited < 2000) : (waited += 1) try io.sleep(.fromMilliseconds(1), .awake);
    try io.sleep(.fromMilliseconds(20), .awake);
    try std.testing.expectEqual(@as(usize, 1), rec.count());
    try std.testing.expectEqual(@as(u64, 19), s.stats().queued);
    s.@"resume"();
    s.waitIdle();
    try std.testing.expectEqual(@as(usize, 20), rec.count());
}

test "cache: warm start re-indexes only changed files" {
    var f = try Fixture.init(&.{ .{ "a.txt", "alpha" }, .{ "b.txt", "beta" }, .{ "sub/c.txt", "gamma" }, .{ "bin.dat", "\x00\x01" } });
    defer f.deinit();
    var cache: Cache = .init(gpa, io);
    defer cache.deinit();
    {
        var rec: Recorder = .{};
        defer rec.deinit();
        const s = try f.sched(&cache, 2);
        defer s.deinit();
        try s.register(rec.plugin());
        s.start(false);
        const snap = f.ps.snapshot();
        try s.enqueueAll(snap);
        snap.release();
        s.waitIdle();
        try std.testing.expectEqual(@as(usize, 4), rec.count());
        for (rec.seen.items, rec.classes.items) |p, c| if (std.mem.eql(u8, p, "bin.dat")) try std.testing.expectEqual(ContentClass.binary, c);
    }
    var tmp_state = std.testing.tmpDir(.{});
    defer tmp_state.cleanup();
    try cache.save(tmp_state.dir);

    // "Restart": a new store, a loaded cache, one file changed.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "beta, changed" });
    f.dropStore();
    try f.rescan();
    var warm: Cache = .init(gpa, io);
    defer warm.deinit();
    try warm.load(tmp_state.dir);
    try std.testing.expectEqual(@as(usize, 4), warm.count());
    var rec: Recorder = .{};
    defer rec.deinit();
    const s = try f.sched(&warm, 2);
    defer s.deinit();
    try s.register(rec.plugin());
    s.start(false);
    const snap = f.ps.snapshot();
    try s.enqueueAll(snap);
    snap.release();
    s.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), rec.count());
    try std.testing.expectEqualStrings("b.txt", rec.seen.items[0]);
    try std.testing.expectEqual(@as(u64, 3), s.stats().cached);
}

test "scheduler: plugin version bump invalidates only that plugin" {
    var f = try Fixture.init(&.{ .{ "a.txt", "alpha" }, .{ "b.txt", "beta" } });
    defer f.deinit();
    var cache: Cache = .init(gpa, io);
    defer cache.deinit();
    {
        var p1: Recorder = .{ .name = "one" };
        defer p1.deinit();
        var p2: Recorder = .{ .name = "two" };
        defer p2.deinit();
        const s = try f.sched(&cache, 1);
        defer s.deinit();
        try s.register(p1.plugin());
        try s.register(p2.plugin());
        s.start(false);
        const snap = f.ps.snapshot();
        try s.enqueueAll(snap);
        snap.release();
        s.waitIdle();
        try std.testing.expectEqual(@as(usize, 2), p1.count());
        try std.testing.expectEqual(@as(usize, 2), p2.count());
    }
    var p1: Recorder = .{ .name = "one" };
    defer p1.deinit();
    var p2: Recorder = .{ .name = "two", .version = 2 };
    defer p2.deinit();
    const s = try f.sched(&cache, 1);
    defer s.deinit();
    try s.register(p1.plugin());
    try s.register(p2.plugin());
    s.start(false);
    const snap = f.ps.snapshot();
    try s.enqueueAll(snap);
    snap.release();
    s.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), p1.count());
    try std.testing.expectEqual(@as(usize, 2), p2.count());
}

test "scheduler: removed file reaches plugins; vanished file is skipped" {
    var f = try Fixture.init(&.{ .{ "keep.txt", "k" }, .{ "gone.txt", "g" }, .{ "race.txt", "r" } });
    defer f.deinit();
    var rec: Recorder = .{};
    defer rec.deinit();
    const s = try f.sched(null, 1);
    defer s.deinit();
    try s.register(rec.plugin());
    s.start(false);
    const snap = f.ps.snapshot();
    try s.enqueueAll(snap);
    snap.release();
    s.waitIdle();
    try std.testing.expectEqual(@as(usize, 3), rec.count());
    s.forget(f.id("gone.txt"));
    try std.testing.expectEqual(@as(u32, 1), rec.removed);
    // Deleted on disk but still in the store: the job quietly does nothing.
    try f.tmp.dir.deleteFile(io, "race.txt");
    try s.enqueue(f.id("race.txt"), .open);
    s.waitIdle();
    try std.testing.expectEqual(@as(usize, 3), rec.count());
}
