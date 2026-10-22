//! Layout persistence (E04.F07.S03.T01): random layouts survive a save
//! and a load unchanged, a failed write keeps the old file, version 0
//! files migrate, a corrupt file is set aside, unknown panel kinds come
//! back as they were, saves are debounced, and restoring a 40-tab layout
//! is fast.

const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const persist = @import("persist.zig");
const model_test = @import("model_test.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const DockModel = model.DockModel;
const PanelRef = model.PanelRef;
const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

fn kindName(_: ?*anyopaque, k: model.PanelKindId) ?[]const u8 {
    return switch (k) {
        1 => "editor",
        2 => "terminal",
        else => null,
    };
}

fn kindId(_: ?*anyopaque, name: []const u8) ?model.PanelKindId {
    if (std.mem.eql(u8, name, "editor")) return 1;
    if (std.mem.eql(u8, name, "terminal")) return 2;
    return null;
}

const kinds: persist.Kinds = .{ .name = kindName, .id = kindId };

/// `m` as saved text.
fn textOf(m: *const DockModel) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const f = try persist.fromModel(arena.allocator(), m, kinds, &.{}, &.{});
    return persist.serialize(gpa, &f);
}

/// Saves `m` to `dir`, loads it back and checks it is the same layout.
fn roundTrip(dir: std.Io.Dir, m: *const DockModel) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const f = try persist.fromModel(arena.allocator(), m, kinds, &.{}, &.{});
    try persist.save(gpa, io, dir, &f);
    var r = persist.load(gpa, io, dir);
    defer r.deinit();
    try testing.expect(r == .ok);
    var back = try persist.toModel(gpa, &r.ok.file, kinds);
    defer back.deinit();
    try back.validate();
    const want = try textOf(m);
    defer gpa.free(want);
    const got = try textOf(&back);
    defer gpa.free(got);
    try expectSameText(want, got);
}

/// Equal line by line, numbers with a decimal point within 1e-5 (split
/// ratios are renormalized on load).
fn expectSameText(want: []const u8, got: []const u8) !void {
    var a = std.mem.splitScalar(u8, want, '\n');
    var b = std.mem.splitScalar(u8, got, '\n');
    while (true) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return;
        const lx = std.mem.trim(u8, x orelse return error.Shorter, " ,");
        const ly = std.mem.trim(u8, y orelse return error.Longer, " ,");
        if (std.mem.eql(u8, lx, ly)) continue;
        if (std.mem.indexOfScalar(u8, lx, '.') != null) {
            const fx = std.fmt.parseFloat(f64, lx) catch return testing.expectEqualStrings(lx, ly);
            const fy = std.fmt.parseFloat(f64, ly) catch return testing.expectEqualStrings(lx, ly);
            if (@abs(fx - fy) < 1e-5) continue;
        }
        return testing.expectEqualStrings(lx, ly);
    }
}

test "roundtrip equals model" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var m = try DockModel.init(gpa);
    defer m.deinit();
    var live: std.ArrayList(PanelRef) = .empty;
    defer live.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x1a70_0de5);
    const n: usize = if (builtin.mode == .Debug) 1500 else 6000;
    for (0..n) |i| {
        try model_test.randomOp(&m, &live, prng.random());
        if (i % 25 == 0) {
            // Sizes, visibility and a floating window's monitor too.
            m.setAreaSizeLive(.left, 100 + @as(f32, @floatFromInt(i % 300)));
            if (m.floating.items.len > 0) m.floating.items[0].monitor.set("HDMI-1");
            try roundTrip(tmp.dir, &m);
        }
    }
}

test "atomic write leaves old file on simulated failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try persist.saveText(io, tmp.dir, ".{ .version = 1 }\n", .{});
    try testing.expectError(error.Injected, persist.saveText(io, tmp.dir, ".{ .version = 1, .next_id = 99 }\n", .{ .fail_after = 10 }));
    var buf: [64]u8 = undefined;
    const got = try tmp.dir.readFile(io, persist.file_name, &buf);
    try testing.expectEqualStrings(".{ .version = 1 }\n", got);
    // No temporary file is left behind.
    var d = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    var files: usize = 0;
    while (try it.next(io)) |_| files += 1;
    try testing.expectEqual(@as(usize, 1), files);
}

test "migration chain v0→v1" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const v0 = try std.Io.Dir.cwd().readFileAlloc(io, @import("zg_options").package_root ++ "/testdata/layout/v0.zon", gpa, .limited(1 << 16));
    defer gpa.free(v0);
    try testing.expectEqual(@as(u32, 0), persist.scanVersion(v0));
    try persist.saveText(io, tmp.dir, v0, .{});
    var r = persist.load(gpa, io, tmp.dir);
    defer r.deinit();
    try testing.expect(r == .migrated);
    const f = &r.migrated.file;
    try testing.expectEqual(@as(u32, 1), f.version);
    try testing.expectEqual(@as(u32, 6), f.next_id);
    try testing.expectEqualStrings("main", f.windows[0].id);
    try testing.expectEqualStrings("docs", f.ui_state[0].value);
    var m = try persist.toModel(gpa, f, kinds);
    defer m.deinit();
    const center = m.areas[@intFromEnum(model.Area.center)].root.?.group;
    try testing.expectEqual(@as(usize, 2), m.group(center).?.tabs.items.len);
    try testing.expectEqual(@as(u32, 1), m.group(center).?.active);
    try testing.expectEqualStrings("build.zig", m.panels.get(@enumFromInt(3)).?.state.?);
    try testing.expectEqual(@as(f32, 300), m.areas[@intFromEnum(model.Area.bottom)].size);
    try testing.expect(!m.areas[@intFromEnum(model.Area.agent)].visible);
    // New ids do not collide.
    try testing.expectEqual(@as(u32, 6), @intFromEnum(try m.addPanel(1, null)));
}

test "corrupt renamed and defaults used" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try persist.saveText(io, tmp.dir, ".{ .version = 1, .panels = .{ .{ .ref = ", .{});
    var r = persist.load(gpa, io, tmp.dir);
    defer r.deinit();
    try testing.expect(r == .corrupt);
    const name = r.renamedTo();
    try testing.expect(std.mem.startsWith(u8, name, "layout.zon.bad-"));
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, persist.file_name, .{}));
    try tmp.dir.access(io, name, .{});
    // Parses but breaks the model: a group referenced twice.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const bad: persist.LayoutFile = .{
        .groups = &.{.{ .id = 1 }},
        .areas = .{ .{ .root = .{ .group = 1 } }, .{}, .{}, .{ .root = .{ .group = 1 } }, .{} },
    };
    try testing.expectError(error.Invalid, persist.toModel(gpa, &bad, kinds));
    // A newer version is left alone.
    try persist.saveText(io, tmp.dir, ".{ .version = 7 }\n", .{});
    var newer = persist.load(gpa, io, tmp.dir);
    defer newer.deinit();
    try testing.expectEqual(@as(u32, 7), newer.too_new);
    try tmp.dir.access(io, persist.file_name, .{});
    // No file at all.
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    try testing.expect(persist.load(gpa, io, tmp2.dir) == .missing);
}

test "unknown kind placeholder roundtrip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f: persist.LayoutFile = .{
        .panels = &.{ .{ .ref = 2, .kind = "editor", .state = "a.zig" }, .{ .ref = 3, .kind = "notebook", .state = "{\"cell\":4}" } },
        .groups = &.{.{ .id = 1, .tabs = &.{ 2, 3 } }},
        .areas = .{ .{}, .{}, .{}, .{ .root = .{ .group = 1 } }, .{} },
        .next_id = 4,
    };
    var m = try persist.toModel(gpa, &f, kinds);
    defer m.deinit();
    try testing.expectEqual(persist.placeholder_kind, m.panels.get(@enumFromInt(3)).?.kind);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const again = try persist.fromModel(arena.allocator(), &m, kinds, &.{}, &.{});
    try testing.expectEqualStrings("notebook", again.panels[1].kind);
    try testing.expectEqualStrings("{\"cell\":4}", again.panels[1].state);
    try roundTrip(tmp.dir, &m);
}

const Counter = struct {
    m: *DockModel,
    snaps: u32 = 0,

    fn snapshot(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!persist.LayoutFile {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        c.snaps += 1;
        return persist.fromModel(arena, c.m, kinds, &.{}, &.{.{ .key = "k", .value = "v" }});
    }
};

const Blank = struct {
    pub fn build(_: *Blank, ui: *@import("../core/ui.zig").Ui) void {
        ui.open(.{});
        ui.close();
    }
};

test "debounce 1s coalesces" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var m = try DockModel.init(gpa);
    defer m.deinit();
    var blank: Blank = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&blank) });
    defer t.deinit();
    var c: Counter = .{ .m = &m };
    var p: persist.Persister = .{ .gpa = gpa, .io = io, .app = &t.app, .dir = tmp.dir, .source = .{ .ctx = &c, .snapshot = Counter.snapshot }, .win = t.win };
    defer p.deinit();
    for (0..5) |_| {
        _ = try m.addPanel(1, "x.zig");
        p.markDirty();
        t.advance(150);
    }
    try testing.expectEqual(@as(u32, 0), p.saves.load(.acquire));
    t.advance(300);
    try testing.expectEqual(@as(u32, 1), c.snaps);
    try testing.expectEqual(@as(u32, 1), p.saves.load(.acquire));
    t.advance(2000);
    try testing.expectEqual(@as(u32, 1), p.saves.load(.acquire));
    var r = persist.load(gpa, io, tmp.dir);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 5), r.ok.file.panels.len);
    // saveNow writes at once and cancels a pending save.
    p.markDirty();
    try p.saveNow();
    try testing.expectEqual(@as(u32, 2), p.saves.load(.acquire));
    t.advance(2000);
    try testing.expectEqual(@as(u32, 2), p.saves.load(.acquire));
}

test "restore under 3ms for 40 tabs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var m = try DockModel.init(gpa);
    defer m.deinit();
    const center = m.firstGroup(m.areas[@intFromEnum(model.Area.center)].root).?;
    var names: [40][16]u8 = undefined;
    for (0..40) |i| {
        const p = try m.addPanel(1, try std.fmt.bufPrint(&names[i], "src/f{d}.zig", .{i}));
        try m.openIn(p, center, null, .{});
        if (i % 10 == 9) _ = try m.split(m.groupOf(p).?, .right, p);
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try persist.save(gpa, io, tmp.dir, &(try persist.fromModel(arena.allocator(), &m, kinds, &.{}, &.{})));
    const start = std.Io.Timestamp.now(io, .awake);
    var r = persist.load(gpa, io, tmp.dir);
    defer r.deinit();
    var back = try persist.toModel(gpa, &r.ok.file, kinds);
    defer back.deinit();
    const ms = @as(f64, @floatFromInt(start.untilNow(io, .awake).nanoseconds)) / std.time.ns_per_ms;
    try testing.expectEqual(@as(usize, 40), back.panels.count());
    // The budget is for optimized builds; Debug gets ten times as long.
    const budget: f64 = if (builtin.mode == .Debug) 30 else 3;
    if (ms > budget) {
        std.debug.print("restore took {d:.2} ms\n", .{ms});
        return error.TooSlow;
    }
}
