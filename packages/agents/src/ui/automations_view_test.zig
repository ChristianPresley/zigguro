//! The Automations manager in a headless window over a real service in a
//! temporary workspace.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const view_mod = @import("automations_view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const runs = zg_agents.runs;
const sched = zg_agents.sched;

const Starter = struct {
    fn start(ctx: *anyopaque, spec: runs.RunSpec) anyerror!runs.RunId {
        const r: *runs.RunRegistry = @ptrCast(@alignCast(ctx));
        return r.create(spec);
    }
    fn stop(_: *anyopaque, _: runs.RunId) void {}
};

/// Writes saves straight into the workspace (what an auto-applied
/// changeset does).
const Saver = struct {
    dir: std.Io.Dir,
    saves: u32 = 0,

    fn save(ctx: *anyopaque, path: []const u8, _: ?[]const u8, text: []const u8) anyerror!void {
        const s: *Saver = @ptrCast(@alignCast(ctx));
        try s.dir.writeFile(io, .{ .sub_path = path, .data = text });
        s.saves += 1;
    }
};

const Trust = struct {
    approved: ?sched.loader.Hash = null,
    fn isApproved(ctx: *anyopaque, _: []const u8, hash: sched.loader.Hash) bool {
        const t: *Trust = @ptrCast(@alignCast(ctx));
        return if (t.approved) |h| std.mem.eql(u8, &h, &hash) else false;
    }
    fn approve(ctx: *anyopaque, _: []const u8, hash: sched.loader.Hash) anyerror!void {
        const t: *Trust = @ptrCast(@alignCast(ctx));
        t.approved = hash;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    reg: *runs.RunRegistry,
    svc: *sched.Service,
    saver: Saver,
    trust: Trust = .{},
    v: *view_mod.AutomationsView,
    t: *TestApp,

    fn init(f: *Fx, with_trust: bool) !void {
        f.* = .{ .tmp = testing.tmpDir(.{}), .reg = undefined, .svc = undefined, .saver = undefined, .v = undefined, .t = undefined };
        f.saver = .{ .dir = f.tmp.dir };
        try f.tmp.dir.createDirPath(io, ".zigguro/automations");
        try f.tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/automations/digest.zon", .data = ".{ .name = \"digest\", .description = \"Daily digest\", .triggers = .{.{ .schedule = .{ .cron = \"0 9 * * 1-5\", .jitter_s = 0 } }}, .action = .{ .agent = .{ .prompt = \"Summarize\" } }, .profile = \"unattended-notes-write\", .budgets = .{ .max_cost_micro_usd = 100000 } }" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/automations/broken.zon", .data = ".{ .name = \"broken\" }" });
        f.reg = try runs.RunRegistry.init(gpa, io, null, .{});
        f.svc = try sched.Service.init(gpa, io, f.tmp.dir, f.reg, .{ .ctx = f.reg, .start = Starter.start, .stop = Starter.stop }, sched.utcZone(), .{
            .trust = if (with_trust) .{ .ctx = &f.trust, .isApproved = Trust.isApproved } else null,
        });
        f.v = try view_mod.AutomationsView.init(gpa, .{
            .service = f.svc,
            .save = .{ .ctx = &f.saver, .f = Saver.save },
            .approve = .{ .ctx = &f.trust, .f = Trust.approve },
        });
        f.t = try TestApp.init(gpa, .{ .root = .of(f.v), .size = .{ .w = 900, .h = 1200 } });
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.t.deinit();
        f.v.deinit();
        f.svc.deinit();
        f.reg.deinit();
        f.tmp.cleanup();
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn sem(f: *Fx) ![]u8 {
        return f.t.semanticsSnapshot(gpa);
    }
};

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing {s} in\n{s}\n", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

test "automations_view: list, editor with live schedule, save, toggle and run" {
    var f: Fx = undefined;
    try f.init(false);
    defer f.deinit();
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "list \"Automations\"");
        try expectHas(s, "listitem \"broken, invalid, next -\"");
        try expectHas(s, "listitem \"digest, enabled, next ");
    }
    // Select: the editor shows the schedule in words.
    try f.t.click(.{ .role = .listitem, .name_contains = "digest" });
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "automation-editor" }) != null);
    try testing.expect(f.t.find(.{ .role = .status, .name = "at 09:00 on weekdays" }) != null);
    // Edit the schedule: the description follows; save writes the file.
    f.v.cron_text.setText("*/30 * * * *") catch {};
    f.settle();
    try testing.expect(f.t.find(.{ .role = .status, .name = "every 30 minutes" }) != null);
    try f.t.click(.{ .role = .button, .name = "Save" });
    f.settle();
    try testing.expectEqual(@as(u32, 1), f.saver.saves);
    const text = try f.tmp.dir.readFileAlloc(io, ".zigguro/automations/digest.zon", gpa, .limited(1 << 16));
    defer gpa.free(text);
    try expectHas(text, "*/30 * * * *");
    try expectHas(text, "unattended-notes-write");
    // Disable and enable.
    try f.t.click(.{ .role = .button, .name = "Disable" });
    f.settle();
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "listitem \"digest, disabled, next -\"");
    }
    try f.t.click(.{ .role = .button, .name = "Enable" });
    f.settle();
    // Run now starts a run.
    try f.t.click(.{ .role = .button, .name = "Run now" });
    f.settle();
    {
        const v = f.reg.snapshot();
        defer f.reg.release(v);
        try testing.expectEqual(@as(usize, 1), v.runs.len);
    }
    try testing.expect(f.t.find(.{ .name_contains = "Started digest" }) != null);
    // A new automation from the editor.
    try f.t.click(.{ .role = .button, .name = "New automation" });
    f.settle();
    f.v.new_name.setText("weekly") catch {};
    f.v.cron_text.setText("@weekly") catch {};
    f.v.prompt.setText("Plan the week") catch {};
    try f.t.click(.{ .role = .button, .name = "Save" });
    f.settle();
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "listitem \"weekly, enabled, next ");
    }
    // An invalid one is refused with a reason.
    try f.t.click(.{ .role = .button, .name = "New automation" });
    f.settle();
    f.v.new_name.setText("Bad Name") catch {};
    f.v.prompt.setText("x") catch {};
    try f.t.click(.{ .role = .button, .name = "Save" });
    f.settle();
    try testing.expect(f.t.find(.{ .name_contains = "Cannot save: name must match" }) != null);
}

test "automations_view: repository automations need approval" {
    var f: Fx = undefined;
    try f.init(true);
    defer f.deinit();
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "listitem \"digest, needs approval, next -\"");
    }
    try f.t.click(.{ .role = .button, .name = "Review & enable" });
    f.settle();
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "listitem \"digest, enabled, next ");
    }
    // Disabling it is the user's own edit: it stays approved.
    try f.t.click(.{ .role = .button, .name = "Disable" });
    f.settle();
    const s = try f.sem();
    defer gpa.free(s);
    try expectHas(s, "listitem \"digest, disabled, next -\"");
}
