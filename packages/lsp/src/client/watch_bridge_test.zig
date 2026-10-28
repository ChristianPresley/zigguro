const std = @import("std");
const protocol = @import("../gen/protocol.zig");
const wb = @import("watch_bridge.zig");
const WatchBridge = wb.WatchBridge;
const testing = std.testing;

const ms = std.time.ns_per_ms;

/// Records each batch as `server:type uri` lines.
const Recorder = struct {
    out: std.ArrayList(u8) = .empty,
    dirty: []const []const u8 = &.{},

    fn sender(r: *Recorder) wb.Sender {
        return .{ .ctx = r, .send = send };
    }

    fn check(r: *Recorder) wb.DirtyCheck {
        return .{ .ctx = r, .isDirty = isDirty };
    }

    fn send(ctx: ?*anyopaque, server: u32, params: protocol.DidChangeWatchedFilesParams) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        for (params.changes) |c| r.out.print(testing.allocator, "{d}:{d} {s}\n", .{ server, @intFromEnum(c.type), c.uri }) catch {};
    }

    fn isDirty(ctx: ?*anyopaque, path: []const u8) bool {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        for (r.dirty) |d| if (std.mem.eql(u8, d, path)) return true;
        return false;
    }

    fn take(r: *Recorder) []u8 {
        return r.out.toOwnedSlice(testing.allocator) catch unreachable;
    }

    fn deinit(r: *Recorder) void {
        r.out.deinit(testing.allocator);
    }
};

fn bridge(rec: *Recorder) !WatchBridge {
    return WatchBridge.init(testing.allocator, testing.io, &.{"/w"}, .{ .sender = rec.sender(), .dirty = rec.check(), .windows = false });
}

fn watcher(pattern: []const u8, kind: ?u32) protocol.FileSystemWatcher {
    return .{ .globPattern = .{ .pattern = pattern }, .kind = if (kind) |k| @enumFromInt(k) else null };
}

fn expectSent(rec: *Recorder, want: []const u8) !void {
    const got = rec.take();
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "watch_bridge: glob and kind filtering" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var b = try bridge(&rec);
    defer b.deinit();
    // Server 0 wants every change to Zig files; server 1 only deletions
    // of build files.
    try b.setWatchers(0, "a", &.{watcher("**/*.zig", null)});
    try b.setWatchers(1, "b", &.{watcher("**/build.zig.zon", 4)});
    b.onFsEventsAt(&.{
        .{ .path = "/w/src/a.zig", .kind = .created },
        .{ .path = "/w/README.md", .kind = .changed },
        .{ .path = "/w/build.zig.zon", .kind = .changed },
        .{ .path = "/w/sub/build.zig.zon", .kind = .deleted },
        .{ .path = "/elsewhere/x.zig", .kind = .created },
        .{ .path = "/w/.zig-cache/o/x.zig", .kind = .created },
        .{ .path = "/w/zig-out/bin/y.zig", .kind = .changed },
    }, 0);
    b.flushAt(10 * ms);
    try expectSent(&rec, "");
    try testing.expectEqual(@as(?i96, 50 * ms), b.nextDue());
    b.flushAt(50 * ms);
    try expectSent(&rec,
        \\0:1 file:///w/src/a.zig
        \\1:3 file:///w/sub/build.zig.zon
        \\
    );
    try testing.expect(b.nextDue() == null);

    // A pattern that names an ignored directory sees inside it.
    try b.setWatchers(0, "c", &.{watcher("**/zig-out/**", null)});
    b.onFsEventsAt(&.{.{ .path = "/w/zig-out/bin/y.zig", .kind = .changed }}, 100 * ms);
    b.flushAt(150 * ms);
    try expectSent(&rec, "0:2 file:///w/zig-out/bin/y.zig\n");
}

test "watch_bridge: RelativePattern base" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var b = try bridge(&rec);
    defer b.deinit();
    try b.setWatchers(0, "r", &.{
        .{ .globPattern = .{ .relative_pattern = .{ .baseUri = .{ .uri = "file:///w/pkg" }, .pattern = "*.json" } } },
        .{ .globPattern = .{ .relative_pattern = .{ .baseUri = .{ .workspace_folder = .{ .uri = "file:///other", .name = "o" } }, .pattern = "**/*.txt" } } },
        watcher("/abs/**/*.c", null),
    });
    b.onFsEventsAt(&.{
        .{ .path = "/w/pkg/a.json", .kind = .created },
        .{ .path = "/w/pkg/deep/b.json", .kind = .created },
        .{ .path = "/w/c.json", .kind = .created },
        .{ .path = "/other/x/y.txt", .kind = .changed },
        .{ .path = "/abs/q/r.c", .kind = .deleted },
    }, 0);
    b.flushAt(50 * ms);
    try expectSent(&rec,
        \\0:1 file:///w/pkg/a.json
        \\0:2 file:///other/x/y.txt
        \\0:3 file:///abs/q/r.c
        \\
    );
}

test "watch_bridge: coalescing table" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var b = try bridge(&rec);
    defer b.deinit();
    try b.setWatchers(0, "a", &.{watcher("**/*", null)});
    // Two registrations of one server send a change once.
    try b.setWatchers(0, "b", &.{watcher("**/*.zig", null)});
    b.onFsEventsAt(&.{
        .{ .path = "/w/gone.zig", .kind = .created },
        .{ .path = "/w/gone.zig", .kind = .deleted },
        .{ .path = "/w/new.zig", .kind = .created },
        .{ .path = "/w/new.zig", .kind = .changed },
        .{ .path = "/w/old.zig", .kind = .changed },
        .{ .path = "/w/old.zig", .kind = .deleted },
        .{ .path = "/w/swap.zig", .kind = .deleted },
        .{ .path = "/w/swap.zig", .kind = .created },
        .{ .path = "/w/edit.zig", .kind = .changed },
        .{ .path = "/w/edit.zig", .kind = .changed },
    }, 0);
    b.flushAt(50 * ms);
    try expectSent(&rec,
        \\0:1 file:///w/new.zig
        \\0:3 file:///w/old.zig
        \\0:2 file:///w/swap.zig
        \\0:2 file:///w/edit.zig
        \\
    );
}

test "watch_bridge: dirty open documents suppressed" {
    var rec: Recorder = .{ .dirty = &.{"/w/open.zig"} };
    defer rec.deinit();
    var b = try bridge(&rec);
    defer b.deinit();
    try b.setWatchers(0, "a", &.{watcher("**/*.zig", null)});
    b.onFsEventsAt(&.{.{ .path = "/w/open.zig", .kind = .changed }}, 0);
    b.flushAt(50 * ms);
    try expectSent(&rec, "");
    // Creation and deletion still go out.
    b.onFsEventsAt(&.{.{ .path = "/w/open.zig", .kind = .deleted }}, 60 * ms);
    b.flushAt(110 * ms);
    try expectSent(&rec, "0:3 file:///w/open.zig\n");
}

test "watch_bridge: rescan_required sends root change" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var b = try bridge(&rec);
    defer b.deinit();
    try b.setWatchers(0, "a", &.{watcher("**/*.zig", null)});
    try b.setWatchers(2, "a", &.{watcher("**/*.md", null)});
    b.onFsEventsAt(&.{.{ .path = "/w/src", .kind = .rescan_required }}, 0);
    b.flushAt(50 * ms);
    try expectSent(&rec,
        \\0:2 file:///w
        \\2:2 file:///w
        \\
    );
}

test "watch_bridge: unregister stops delivery" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var b = try bridge(&rec);
    defer b.deinit();
    try b.setWatchers(0, "a", &.{watcher("**/*.zig", null)});
    try b.setWatchers(1, "a", &.{watcher("**/*.zig", null)});
    b.onFsEventsAt(&.{.{ .path = "/w/a.zig", .kind = .created }}, 0);
    // Pending changes go with the registration.
    b.removeWatchers(0, "a");
    b.removeServer(1);
    try testing.expect(!b.active());
    b.onFsEventsAt(&.{.{ .path = "/w/b.zig", .kind = .created }}, 10 * ms);
    b.flushAt(100 * ms);
    try expectSent(&rec, "");
    // A bad glob is skipped, the rest of the registration stays.
    try b.setWatchers(0, "x", &.{ watcher("[", null), watcher("*.zig", null) });
    b.onFsEventsAt(&.{.{ .path = "/w/c.zig", .kind = .created }}, 200 * ms);
    b.flushAt(250 * ms);
    try expectSent(&rec, "0:1 file:///w/c.zig\n");
}

test "watch_bridge: windows paths" {
    var rec: Recorder = .{};
    defer rec.deinit();
    var b = try WatchBridge.init(testing.allocator, testing.io, &.{"C:\\Repo\\"}, .{ .sender = rec.sender(), .windows = true });
    defer b.deinit();
    try b.setWatchers(0, "a", &.{watcher("**/*.ZIG", null)});
    b.onFsEventsAt(&.{
        .{ .path = "c:\\repo\\src\\A.zig", .kind = .created },
        .{ .path = "C:\\Repo\\.GIT\\x.zig", .kind = .created },
    }, 0);
    b.flushAt(50 * ms);
    try expectSent(&rec, "0:1 file:///c%3A/repo/src/A.zig\n");
}
