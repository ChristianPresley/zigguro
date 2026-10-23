//! The automation tools against a temporary workspace and a fake E12.

const std = @import("std");
const zone = @import("zone.zig");
const history = @import("history.zig");
const tools = @import("tools.zig");
const Scheduler = @import("scheduler.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const FakeChanges = struct {
    next: u64 = 100,
    path: [128]u8 = undefined,
    path_len: usize = 0,
    base_null: bool = false,
    new: std.ArrayList(u8) = .empty,
    label: [64]u8 = undefined,
    label_len: usize = 0,

    fn port(f: *FakeChanges) tools.ChangePort {
        return .{ .ctx = f, .propose = propose };
    }

    fn propose(ctx: *anyopaque, label: []const u8, _: []const u8, changes: []const tools.FileChange) anyerror!u64 {
        const f: *FakeChanges = @ptrCast(@alignCast(ctx));
        const c = changes[0];
        @memcpy(f.path[0..c.path.len], c.path);
        f.path_len = c.path.len;
        @memcpy(f.label[0..label.len], label);
        f.label_len = label.len;
        f.base_null = c.base == null;
        f.new.clearRetainingCapacity();
        try f.new.appendSlice(gpa, c.new);
        f.next += 1;
        return f.next;
    }
};

const Clock = struct {
    ms: i64 = 1_792_742_400_000, // 2026-10-23 08:00 UTC, a Friday
    fn clock(c: *Clock) Scheduler.Clock {
        return .{ .ctx = c, .nowRealMs = now };
    }
    fn now(ctx: ?*anyopaque) i64 {
        const c: *Clock = @ptrCast(@alignCast(ctx.?));
        return c.ms;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    dir: std.Io.Dir,
    hist: std.Io.Dir,
    changes: FakeChanges = .{},
    clock: Clock = .{},
    src: tools.Source,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fx) !void {
        f.* = .{ .tmp = testing.tmpDir(.{}), .dir = undefined, .hist = undefined, .src = undefined, .arena = .init(gpa) };
        f.dir = try f.tmp.dir.createDirPathOpen(io, "automations", .{ .open_options = .{ .iterate = true } });
        f.hist = try f.tmp.dir.createDirPathOpen(io, "hist", .{});
        f.src = .{ .gpa = gpa, .io = io, .dir = f.dir, .history_dir = f.hist, .changes = f.changes.port(), .zone = zone.utcZone(), .clock = f.clock.clock() };
    }

    fn deinit(f: *Fx) void {
        f.changes.new.deinit(gpa);
        f.arena.deinit();
        f.dir.close(io);
        f.hist.close(io);
        f.tmp.cleanup();
    }

    fn call(f: *Fx, tool: []const u8, input: []const u8) !tools.Output {
        return tools.run(&f.src, f.arena.allocator(), tool, input);
    }

    /// The text block of a result.
    fn text(f: *Fx, out: tools.Output) ![]const u8 {
        const R = struct { content: []const struct { text: []const u8 } };
        const r = try std.json.parseFromSliceLeaky(R, f.arena.allocator(), out.json, .{ .ignore_unknown_fields = true });
        return r.content[0].text;
    }
};

test "tools_create_produces_changeset" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const out = try f.call("automation_create",
        \\{"name":"standup","description":"Morning summary","cron":"0 9 * * 1-5","prompt":"Summarize open PRs","profile":"unattended-readonly"}
    );
    try testing.expect(!out.is_error);
    try testing.expectEqual(@as(?u64, 101), out.changeset);
    try testing.expectEqualStrings(".zigguro/automations/standup.zon", f.changes.path[0..f.changes.path_len]);
    try testing.expect(f.changes.base_null);
    try testing.expectEqualStrings("Create automation standup", f.changes.label[0..f.changes.label_len]);
    // Nothing written: the change waits for review.
    try testing.expectError(error.FileNotFound, f.dir.access(io, "standup.zon", .{}));
    const t = try f.text(out);
    try testing.expect(std.mem.indexOf(u8, t, "\"status\":\"pending review\"") != null);
    try testing.expect(std.mem.indexOf(u8, t, "at 09:00 on weekdays") != null);
    // Jitter for a daily job is at most five minutes: the first fire is
    // today between 09:00 and 09:05.
    try testing.expect(std.mem.indexOf(u8, t, "\"next_fires\":[\"2026-10-23 09:0") != null);
    // The proposed file parses, with the default cost cap.
    try testing.expect(std.mem.indexOf(u8, f.changes.new.items, ".max_cost_micro_usd = 500000") != null);
    try f.dir.writeFile(io, .{ .sub_path = "standup.zon", .data = f.changes.new.items });
    // Creating it again is refused.
    const again = try f.call("automation_create", "{\"name\":\"standup\",\"cron\":\"@daily\",\"prompt\":\"x\"}");
    try testing.expect(again.is_error);
    try testing.expect(std.mem.indexOf(u8, try f.text(again), "already exists") != null);
    // Bad input is an error result, not a failure.
    const bad = try f.call("automation_create", "{\"name\":\"x\",\"cron\":\"0 0 L * *\",\"prompt\":\"x\"}");
    try testing.expect(bad.is_error);
    try testing.expect(std.mem.indexOf(u8, try f.text(bad), "invalid cron") != null);
    const no_action = try f.call("automation_create", "{\"name\":\"y\",\"cron\":\"@daily\"}");
    try testing.expect(no_action.is_error);
}

test "tools_update_list_history" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const created = try f.call("automation_create", "{\"name\":\"tidy\",\"cron\":\"*/5 * * * *\",\"prompt\":\"Tidy\"}");
    try testing.expect(!created.is_error);
    try f.dir.writeFile(io, .{ .sub_path = "tidy.zon", .data = f.changes.new.items });
    const original = try f.arena.allocator().dupe(u8, f.changes.new.items);
    const upd = try f.call("automation_update", "{\"name\":\"tidy\",\"cron\":\"0 * * * *\",\"enabled\":false}");
    try testing.expect(!upd.is_error);
    try testing.expect(!f.changes.base_null);
    try testing.expect(std.mem.indexOf(u8, f.changes.new.items, "0 * * * *") != null);
    try testing.expect(std.mem.indexOf(u8, f.changes.new.items, ".enabled = false") != null);
    try testing.expect(std.mem.indexOf(u8, f.changes.new.items, "*/5") == null);
    _ = original;
    const missing = try f.call("automation_update", "{\"name\":\"nope\",\"cron\":\"@daily\"}");
    try testing.expect(missing.is_error);
    // List: one valid (every 5 minutes, no jitter), one broken file.
    try f.dir.writeFile(io, .{ .sub_path = "broken.zon", .data = ".{ .name = 1 }" });
    try history.append(io, f.hist, "tidy", .{ .t = 1, .due = 1, .reason = .scheduled, .skip = .overlap });
    const l = try f.text(try f.call("automation_list", "{}"));
    try testing.expect(std.mem.indexOf(u8, l, "\"name\":\"broken\"") != null);
    try testing.expect(std.mem.indexOf(u8, l, "\"problem\":\"broken.zon:1:") != null);
    try testing.expect(std.mem.indexOf(u8, l, "\"triggers\":\"every 5 minutes\"") != null);
    try testing.expect(std.mem.indexOf(u8, l, "\"next_fires\":[\"2026-10-23 08:05\",\"2026-10-23 08:10\",\"2026-10-23 08:15\"]") != null);
    try testing.expect(std.mem.indexOf(u8, l, "\"last_status\":\"overlap\"") != null);
    const h = try f.text(try f.call("automation_history", "{\"name\":\"tidy\"}"));
    try testing.expect(std.mem.indexOf(u8, h, "\"skip\":\"overlap\"") != null);
    // Running needs a scheduler.
    const r = try f.call("automation_run", "{\"name\":\"tidy\"}");
    try testing.expect(r.is_error);
    try testing.expectError(error.UnknownTool, f.call("automation_delete", "{}"));
}

test "exporter lists the tools" {
    var x: tools.ToolExporter = .{ .src = undefined };
    const e = x.exporter();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const list = try e.list(e.ctx, arena.allocator());
    try testing.expectEqual(@as(usize, 5), list.len);
    for (list) |t| {
        // Each schema is valid JSON.
        _ = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), t.input_schema_json, .{});
        try testing.expect(!(t.mutates and t.read_only));
    }
}
