const std = @import("std");
const zg_core = @import("zg_core");
const n_mod = @import("notification.zig");
const Router = @import("router.zig");
const map = @import("map.zig");
const run = @import("../runs/run.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const Notification = n_mod.Notification;

const Clock = struct {
    now: i64 = 1_000_000,
    fn read(ctx: ?*anyopaque) i64 {
        const c: *Clock = @ptrCast(@alignCast(ctx.?));
        return c.now;
    }
};

/// Records shows; asserts it never runs on the UI thread.
const FakeOs = struct {
    rt: *zg_core.Runtime,
    mutex: std.Io.Mutex = .init,
    shows: u32 = 0,
    replaced: u32 = 0,
    last_title: [64]u8 = undefined,
    last_len: usize = 0,
    next: u64 = 100,
    freed: bool = false,

    fn backend(f: *FakeOs) n_mod.OsBackend {
        return .{ .ctx = f, .vtable = &.{ .show = show, .close = close, .deinit = deinitFn } };
    }

    fn show(ctx: *anyopaque, n: *const Notification, replaces: ?u64) anyerror!u64 {
        const f: *FakeOs = @ptrCast(@alignCast(ctx));
        f.rt.assertNotUi();
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        f.shows += 1;
        if (replaces != null) f.replaced += 1;
        f.last_len = @min(n.title.len, f.last_title.len);
        @memcpy(f.last_title[0..f.last_len], n.title[0..f.last_len]);
        if (replaces) |r| return r;
        f.next += 1;
        return f.next;
    }

    fn title(f: *FakeOs) []const u8 {
        return f.last_title[0..f.last_len];
    }

    fn close(_: *anyopaque, _: u64) void {}

    fn deinitFn(ctx: *anyopaque) void {
        const f: *FakeOs = @ptrCast(@alignCast(ctx));
        f.freed = true;
    }
};

const Center = struct {
    mutex: std.Io.Mutex = .init,
    recorded: u32 = 0,
    toasts: u32 = 0,

    fn sink(c: *Center) n_mod.ToastSink {
        return .{ .ctx = c, .deliver = deliver };
    }

    fn deliver(ctx: *anyopaque, _: *const Notification, _: u32, show_toast: bool) void {
        const c: *Center = @ptrCast(@alignCast(ctx));
        c.mutex.lockUncancelable(io);
        defer c.mutex.unlock(io);
        c.recorded += 1;
        if (show_toast) c.toasts += 1;
    }
};

const Fx = struct {
    rt: zg_core.Runtime = undefined,
    clock: Clock = .{},
    os: FakeOs = undefined,
    center: Center = .{},
    r: *Router = undefined,

    fn init(f: *Fx, with_os: bool) !void {
        f.* = .{};
        f.rt.initTesting();
        f.rt.bindUiThread(.noop);
        f.os = .{ .rt = &f.rt };
        f.r = try Router.init(gpa, &f.rt, if (with_os) f.os.backend() else null, f.center.sink(), .{}, .{ .clock = .{ .ctx = &f.clock, .now = Clock.read } });
    }

    fn deinit(f: *Fx) void {
        f.r.deinit();
        _ = f.rt.deinit();
    }
};

test "dedupe_replaces_within_interval" {
    var f: Fx = undefined;
    try f.init(true);
    defer f.deinit();
    f.r.post(.{ .key = "run:a", .severity = .needs_input, .title = "Fix build needs input" });
    f.clock.now += 3_000;
    f.r.post(.{ .key = "run:a", .severity = .success, .title = "Done: Fix build" });
    f.r.flush();
    try testing.expectEqual(@as(u32, 2), f.os.shows);
    try testing.expectEqual(@as(u32, 1), f.os.replaced);
    try testing.expectEqualStrings("Done: Fix build", f.os.title());
    // Unfocused: OS, and recorded in the center without a toast.
    try testing.expectEqual(@as(u32, 2), f.center.recorded);
    try testing.expectEqual(@as(u32, 0), f.center.toasts);
    f.clock.now += 20_000;
    f.r.post(.{ .key = "run:a", .severity = .success, .title = "Done again" });
    f.r.flush();
    try testing.expectEqual(@as(u32, 1), f.os.replaced);
}

test "group_merges_workers" {
    var f: Fx = undefined;
    try f.init(true);
    defer f.deinit();
    var key: [16]u8 = undefined;
    for (1..41) |i| {
        f.r.post(.{
            .key = try std.fmt.bufPrint(&key, "run:{d}", .{i}),
            .group = "wf:release",
            .severity = .success,
            .title = "Done: step",
            .progress = .{ .done = @intCast(i), .total = 40 },
        });
        f.clock.now += 250; // 40 workers in 10 s
    }
    f.r.flush();
    // One notification, updated in place 39 times.
    try testing.expectEqual(@as(u32, 40), f.os.shows);
    try testing.expectEqual(@as(u32, 39), f.os.replaced);
    try testing.expectEqualStrings("40/40 done", f.os.title());
}

test "focus decides toast, os or nothing; no backend still records" {
    var f: Fx = undefined;
    try f.init(false);
    defer f.deinit();
    const vis = [_]run.RunId{.fromInt(7)};
    f.r.setFocus(.{ .window_focused = true, .visible_runs = &vis });
    f.r.post(.{ .key = "a", .run = .fromInt(7), .severity = .success, .title = "seen" });
    f.r.post(.{ .key = "b", .run = .fromInt(8), .severity = .success, .title = "toast" });
    f.r.setFocus(.{ .window_focused = false });
    // No OS backend: the notification center still gets it.
    f.r.post(.{ .key = "c", .severity = .error_, .title = "away" });
    f.r.flush();
    try testing.expectEqual(@as(u32, 2), f.center.recorded);
    try testing.expectEqual(@as(u32, 2), f.center.toasts);
    try testing.expectEqual(@as(u64, 1), f.r.stats.suppressed);
    f.r.setPolicy(.{ .dnd = true });
    f.r.post(.{ .key = "d", .severity = .error_, .title = "quiet" });
    f.r.flush();
    try testing.expectEqual(@as(u32, 2), f.center.recorded);
}

test "delivery_off_ui_thread" {
    // FakeOs.show asserts it is not on the UI thread this test bound.
    var f: Fx = undefined;
    try f.init(true);
    defer f.deinit();
    for (0..20) |i| {
        var key: [8]u8 = undefined;
        f.r.post(.{ .key = try std.fmt.bufPrint(&key, "k{d}", .{i}), .severity = .info, .title = "x" });
    }
    f.r.flush();
    try testing.expectEqual(@as(u32, 20), f.os.shows);
}

test "activation routes to callbacks" {
    var f: Fx = undefined;
    try f.init(true);
    defer f.deinit();
    const Got = struct {
        key: [32]u8 = undefined,
        len: usize = 0,
        action: [16]u8 = undefined,
        alen: usize = 0,
        fn on(ctx: *anyopaque, key: []const u8, action: []const u8, _: ?[]const u8) void {
            const g: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(g.key[0..key.len], key);
            g.len = key.len;
            @memcpy(g.action[0..action.len], action);
            g.alen = action.len;
        }
    };
    var got: Got = .{};
    try f.r.onActivated(.{ .ctx = &got, .f = Got.on });
    f.r.activation().call("run:abc", "deny", null);
    try testing.expectEqualStrings("run:abc", got.key[0..got.len]);
    try testing.expectEqualStrings("deny", got.action[0..got.alen]);
}

test "run events post through the router" {
    var f: Fx = undefined;
    try f.init(true);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const rec: run.RunRecord = .{ .id = .fromInt(5), .spec = .{ .kind = .background, .title = "Triage", .prompt = "p" }, .status = .completed, .summary = "3 labelled", .created_ms = 0 };
    const n = (try map.fromRunEvent(arena.allocator(), .{ .run = rec.id, .revision = 4, .kind = .status }, &rec)).?;
    f.r.post(n);
    f.r.flush();
    try testing.expectEqualStrings("Done: Triage", f.os.title());
}

test "registry runs notify through the router" {
    const RunRegistry = @import("../runs/registry.zig");
    const RunNotifier = @import("run_notifier.zig");
    var f: Fx = undefined;
    try f.init(true);
    defer f.deinit();
    const reg = try RunRegistry.init(gpa, io, null, .{});
    defer reg.deinit();
    const rn = try RunNotifier.init(reg, f.r);
    defer rn.deinit();
    const id = try reg.create(.{ .kind = .background, .title = "Lint", .prompt = "p" });
    for ([_]run.RunStatus{ .starting, .working }) |s| try reg.update(id, .{ .status = s });
    try reg.update(id, .{ .question = "Allow npm install?" });
    try reg.update(id, .{ .status = .needs_input });
    f.r.flush();
    try testing.expectEqualStrings("Lint needs input", f.os.title());
    try reg.update(id, .{ .status = .working });
    try reg.update(id, .{ .status = .failed });
    f.r.flush();
    try testing.expectEqualStrings("Failed: Lint", f.os.title());
    // The same key within 10 s: updated, not stacked.
    try testing.expectEqual(@as(u32, 2), f.os.shows);
    try testing.expectEqual(@as(u32, 1), f.os.replaced);
}
