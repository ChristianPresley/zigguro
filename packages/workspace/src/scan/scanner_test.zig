//! Scanner tests: real temp directories, scanned into a fresh PathStore.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const scanner = @import("scanner.zig");
const Scanner = scanner.Scanner;
const ScanJob = scanner.ScanJob;
const ScanOptions = scanner.ScanOptions;
const PathStore = @import("../paths/path_store.zig").PathStore;
const IgnoreStack = @import("../ignore/ignore_stack.zig").IgnoreStack;
const events = @import("events.zig");
const RootId = @import("../ids.zig").RootId;
const FileId = @import("../ids.zig").FileId;

const gpa = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    abs: [:0]u8,
    ps: *PathStore,
    ign: *IgnoreStack,
    root: RootId,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const abs = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        const ps = try PathStore.init(gpa, io);
        const ign = try IgnoreStack.init(gpa, io, 0);
        const root = try ign.addRoot();
        try ps.addRoot(root, false);
        return .{ .tmp = tmp, .abs = abs, .ps = ps, .ign = ign, .root = root };
    }

    fn deinit(f: *Fixture) void {
        f.ps.deinit();
        f.ign.deinit();
        gpa.free(f.abs);
        f.tmp.cleanup();
    }

    fn file(f: *Fixture, rel: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.createDirPath(io, d);
        try f.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = bytes });
    }

    fn dir(f: *Fixture, rel: []const u8) !void {
        try f.tmp.dir.createDirPath(io, rel);
    }

    fn target(f: *Fixture, bus: ?*events.Bus) scanner.Target {
        return .{ .paths = f.ps, .ignore = f.ign, .bus = bus, .root = f.root, .abs_path = f.abs };
    }

    fn scan(f: *Fixture, opts: ScanOptions) !*ScanJob {
        const job = try Scanner.start(gpa, io, f.target(null), "", opts);
        job.wait();
        return job;
    }

    /// Sorted "path kind" lines of everything in the store.
    fn dump(f: *Fixture) ![]u8 {
        const snap = f.ps.snapshot();
        defer snap.release();
        var lines: std.ArrayList([]u8) = .empty;
        defer {
            for (lines.items) |l| gpa.free(l);
            lines.deinit(gpa);
        }
        var stack: std.ArrayList(FileId) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, snap.rootDir(f.root).?);
        var buf: [1024]u8 = undefined;
        while (stack.pop()) |d| for (snap.children(d)) |c| {
            const info = snap.info(c);
            try lines.append(gpa, try std.fmt.allocPrint(gpa, "{s} {t}{s}{s}{s}", .{
                snap.pathOf(c, &buf),
                info.kind,
                if (info.flags.ignored) " ignored" else "",
                if (info.flags.unreadable) " unreadable" else "",
                if (info.flags.cycle) " cycle" else "",
            }));
            if (info.isDir()) try stack.append(gpa, c);
        };
        std.mem.sort([]u8, lines.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        var out: std.Io.Writer.Allocating = .init(gpa);
        for (lines.items) |l| {
            try out.writer.writeAll(l);
            try out.writer.writeByte('\n');
        }
        return out.toOwnedSlice();
    }
};

test "scanner: small tree exact contents" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("a.txt", "a");
    try f.file("src/main.zig", "x");
    try f.file("src/lib/util.zig", "x");
    try f.file(".hidden", "x");
    try f.dir("empty");
    try f.file(".git/HEAD", "ref");
    const job = try f.scan(.{ .max_workers = 4 });
    defer job.deinit();
    try std.testing.expect(job.isDone());
    const got = try f.dump();
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        \\.hidden file
        \\a.txt file
        \\empty dir
        \\src dir
        \\src/lib dir
        \\src/lib/util.zig file
        \\src/main.zig file
        \\
    , got);
    const snap = f.ps.snapshot();
    defer snap.release();
    const lib = snap.lookup(f.root, "src/lib").?;
    try std.testing.expect(!snap.info(lib).flags.loading);
    try std.testing.expect(snap.info(snap.lookup(f.root, "a.txt").?).flags.stat_pending);
    try std.testing.expect(snap.info(snap.lookup(f.root, ".hidden").?).flags.hidden);
}

test "scanner: ignored dirs not descended (counts readdir calls via test hook)" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file(".gitignore", "node_modules/\n*.log\n");
    try f.file("app.js", "x");
    try f.file("debug.log", "x");
    for (0..20) |i| {
        var buf: [64]u8 = undefined;
        try f.file(try std.fmt.bufPrint(&buf, "node_modules/p{d}/index.js", .{i}), "x");
    }
    const job = try f.scan(.{});
    defer job.deinit();
    // Only the root was read.
    try std.testing.expectEqual(@as(u32, 1), job.readdir_calls.load(.monotonic));
    const got = try f.dump();
    defer gpa.free(got);
    try std.testing.expectEqualStrings(".gitignore file\napp.js file\n", got);

    // With "show ignored", ignored entries are kept but still not descended.
    const ps2 = try PathStore.init(gpa, io);
    defer ps2.deinit();
    try ps2.addRoot(f.root, false);
    var t = f.target(null);
    t.paths = ps2;
    const job2 = try Scanner.start(gpa, io, t, "", .{ .include_ignored = true });
    defer job2.deinit();
    job2.wait();
    try std.testing.expectEqual(@as(u32, 1), job2.readdir_calls.load(.monotonic));
    const snap = ps2.snapshot();
    defer snap.release();
    try std.testing.expect(snap.info(snap.lookup(f.root, "node_modules").?).flags.ignored);
    try std.testing.expect(snap.info(snap.lookup(f.root, "debug.log").?).flags.ignored);
}

test "scanner: nested .gitignore loaded before children" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("pkg/.gitignore", "gen/\nsecret.txt\n!keep.txt\n");
    try f.file("pkg/gen/out.c", "x");
    try f.file("pkg/secret.txt", "x");
    try f.file("pkg/keep.txt", "x");
    try f.file("pkg/deep/secret.txt", "x");
    try f.file("other/secret.txt", "x");
    const job = try f.scan(.{ .max_workers = 3 });
    defer job.deinit();
    const got = try f.dump();
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        \\other dir
        \\other/secret.txt file
        \\pkg dir
        \\pkg/.gitignore file
        \\pkg/deep dir
        \\pkg/keep.txt file
        \\
    , got);
}

test "scanner: symlink loop terminates" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // needs junction privileges
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("a/b/file.txt", "x");
    try f.tmp.dir.symLink(io, "..", "a/b/up", .{ .is_directory = true });
    try f.tmp.dir.symLink(io, "../a", "a/self", .{ .is_directory = true });
    try f.dir("ext/inner");
    try f.tmp.dir.symLink(io, "ext", "link_to_ext", .{ .is_directory = true });
    const job = try f.scan(.{ .max_workers = 2 });
    defer job.deinit();
    try std.testing.expect(job.isDone());
    const got = try f.dump();
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        \\a dir
        \\a/b dir
        \\a/b/file.txt file
        \\a/b/up symlink_dir cycle
        \\a/self symlink_dir cycle
        \\ext dir
        \\ext/inner dir
        \\link_to_ext symlink_dir
        \\link_to_ext/inner dir
        \\
    , got);
}

test "scanner: unreadable dir flagged" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("locked/x.txt", "x");
    try f.file("open.txt", "x");
    try f.tmp.dir.setFilePermissions(io, "locked", .fromMode(0o000), .{});
    defer f.tmp.dir.setFilePermissions(io, "locked", .fromMode(0o755), .{}) catch {};
    // Root can read anything; the flag cannot be observed then.
    if (f.tmp.dir.openDir(io, "locked", .{ .iterate = true })) |d| {
        var dd = d;
        dd.close(io);
        return error.SkipZigTest;
    } else |_| {}
    const job = try f.scan(.{});
    defer job.deinit();
    const got = try f.dump();
    defer gpa.free(got);
    try std.testing.expectEqualStrings("locked dir unreadable\nopen.txt file\n", got);
}

test "scanner: cancel mid-scan leaves consistent PathStore" {
    var f = try Fixture.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..40) |i| for (0..10) |j| {
        try f.file(try std.fmt.bufPrint(&buf, "d{d}/s{d}/f.txt", .{ i, j }), "x");
    };
    const job = try Scanner.start(gpa, io, f.target(null), "", .{ .max_workers = 2, .batch_ops = 8 });
    job.cancel();
    job.deinit();
    // Every node present is reachable and named, and no parent is missing.
    const snap = f.ps.snapshot();
    defer snap.release();
    var it = snap.iterFiles(f.root);
    var n: usize = 0;
    var pbuf: [1024]u8 = undefined;
    while (it.next()) |id| : (n += 1) {
        const p = snap.pathOf(id, &pbuf);
        try std.testing.expectEqual(id, snap.lookup(f.root, p).?);
    }
    try std.testing.expect(n <= 400);
    // A fresh full scan afterwards completes the tree.
    const job2 = try f.scan(.{});
    defer job2.deinit();
    const snap2 = f.ps.snapshot();
    defer snap2.release();
    try std.testing.expectEqual(@as(u32, 400), snap2.fileCount());
}

test "scanner: rescan keeps FileIds of unchanged nodes" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file("keep/a.txt", "a");
    try f.file("keep/b.txt", "b");
    try f.file("gone/c.txt", "c");
    try f.file("top.txt", "t");
    const job = try f.scan(.{});
    job.deinit();
    const s1 = f.ps.snapshot();
    const a1 = s1.lookup(f.root, "keep/a.txt").?;
    const k1 = s1.lookup(f.root, "keep").?;
    s1.release();

    try f.tmp.dir.deleteTree(io, "gone");
    try f.file("keep/new.txt", "n");
    var bus: events.Bus = .init(gpa, io);
    defer bus.deinit();
    const Counter = struct {
        removed: u32 = 0,
        added: u32 = 0,
        modified: u32 = 0,
        done: bool = false,
        fn on(ctx: *anyopaque, ev: *const events.WorkspaceEvent, _: []const @import("../paths/path_store.zig").Change) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            switch (ev.*) {
                .paths_changed => |p| {
                    c.removed += p.removed;
                    c.added += p.added;
                    c.modified += p.modified;
                },
                .scan_progress => |p| c.done = c.done or p.done,
                else => {},
            }
        }
    };
    var counter: Counter = .{};
    _ = try bus.subscribe(.{ .ctx = &counter, .onEvent = Counter.on });
    const job2 = try Scanner.start(gpa, io, f.target(&bus), "", .{});
    job2.wait();
    job2.deinit();
    const s2 = f.ps.snapshot();
    defer s2.release();
    try std.testing.expectEqual(a1, s2.lookup(f.root, "keep/a.txt").?);
    try std.testing.expectEqual(k1, s2.lookup(f.root, "keep").?);
    try std.testing.expect(s2.lookup(f.root, "gone") == null);
    try std.testing.expect(s2.lookup(f.root, "keep/new.txt") != null);
    try std.testing.expectEqual(@as(u32, 1), counter.added);
    try std.testing.expectEqual(@as(u32, 2), counter.removed); // gone and gone/c.txt
    try std.testing.expectEqual(@as(u32, 0), counter.modified);
    try std.testing.expect(counter.done);
}

test "scanner: priority dirs are scanned once and first" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.file(".gitignore", "*.tmp\n");
    try f.file("a/deep/x.tmp", "x");
    try f.file("a/deep/y.zig", "x");
    try f.file("b/z.zig", "x");
    const job = try f.scan(.{ .priority_dirs = &.{"a/deep"}, .max_workers = 1 });
    defer job.deinit();
    try std.testing.expectEqual(@as(u32, 4), job.readdir_calls.load(.monotonic)); // root, a, a/deep, b
    const got = try f.dump();
    defer gpa.free(got);
    try std.testing.expectEqualStrings(
        \\.gitignore file
        \\a dir
        \\a/deep dir
        \\a/deep/y.zig file
        \\b dir
        \\b/z.zig file
        \\
    , got);
}
