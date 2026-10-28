//! Code lenses against the scripted fake server (codelens.script), and
//! the run/debug mapping table.

const std = @import("std");
const zg_editor = @import("zg_editor");
const Harness = @import("../Manager_test.zig").Harness;
const CodeLensService = @import("codelens.zig");
const CommandService = @import("commands.zig");
const lens_commands = @import("lens_commands.zig");

const testing = std.testing;
const gpa = testing.allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.docs.items.len > 0 and s.sync.?.isTracked(s.docs.items[s.docs.items.len - 1])) return true;
    return false;
}

const Fx = struct {
    h: Harness,
    d: DocHandle,
    s: CodeLensService,
    cmds: CommandService,

    fn init(f: *Fx) !void {
        try f.h.init("codelens.script", &.{});
        f.d = try f.h.open("main.zig", "const a = f(1, 2);\n" ** 40);
        try f.s.init(&f.h.mgr, .{});
        f.cmds = .init(&f.h.mgr, .noop);
        for (0..2000) |_| {
            f.h.mgr.tick();
            if (running(&f.h)) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    fn deinit(f: *Fx) void {
        f.h.mgr.closeDoc(f.d);
        f.h.docs.release(f.d);
        f.h.mgr.deinit();
        f.s.deinit();
        f.cmds.deinit();
        f.h.docs.deinit();
        f.h.reg.deinit();
        gpa.free(f.h.script);
        f.h.tmp.cleanup();
        _ = f.h.rt.deinit();
    }

    fn until(f: *Fx, comptime pred: fn (*Fx) bool) !void {
        for (0..2000) |_| {
            f.h.mgr.tick();
            _ = f.s.tick();
            _ = f.cmds.tick();
            if (pred(f)) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }
};

fn arrived(f: *Fx) bool {
    return f.s.lenses(f.d).len == 4;
}

fn resolvedVisible(f: *Fx) bool {
    return f.s.lenses(f.d)[2].title != null;
}

fn ran(f: *Fx) bool {
    return !f.cmds.busy();
}

test "codelens: placeholder rows prevent layout jump; resolve visible only; run/debug mapping; unknown command goes to executeCommand" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();

    try f.s.onViewport(f.d, .{ .first = 0, .end = 10 });
    try f.until(arrived);
    var rows: std.ArrayList(u64) = .empty;
    defer rows.deinit(gpa);
    try f.s.lines(f.d, gpa, &rows);
    try testing.expectEqualSlices(u64, &.{ 0, 5, 30 }, rows.items);
    var ls = f.s.lenses(f.d);
    try testing.expectEqualStrings("Run", ls[0].title.?);
    try testing.expectEqualStrings("Debug", ls[1].title.?);
    // Placeholders until resolved; only the visible one is asked.
    try testing.expect(ls[3].title == null);

    try f.until(resolvedVisible);
    ls = f.s.lenses(f.d);
    try testing.expectEqualStrings("3 references", ls[2].title.?);
    try testing.expect(ls[3].title == null and !ls[3].resolving and ls[3].raw != null);
    // Resolving kept the rows.
    try f.s.lines(f.d, gpa, &rows);
    try testing.expectEqualSlices(u64, &.{ 0, 5, 30 }, rows.items);

    // Run and debug lenses are zigguro's; the reference lens is the
    // server's command.
    const run = try f.s.execute(f.d, ls[0].id, &f.cmds);
    try testing.expectEqual(lens_commands.Action.run_task, run.action.action);
    try testing.expect(std.mem.indexOf(u8, run.action.command_json, "\"k\"") != null);
    const dbg = try f.s.execute(f.d, ls[1].id, &f.cmds);
    try testing.expectEqual(lens_commands.Action.debug_launch, dbg.action.action);
    try testing.expectEqual(CodeLensService.Outcome.none, try f.s.execute(f.d, ls[3].id, &f.cmds));
    try testing.expectEqual(CodeLensService.Outcome.server, try f.s.execute(f.d, ls[2].id, &f.cmds));
    try f.until(ran);
}

test "codelens: run/debug mapping table" {
    try testing.expectEqual(lens_commands.Action.run_task, lens_commands.lookup(&.{}, "rust-analyzer.runSingle").?);
    try testing.expectEqual(lens_commands.Action.debug_launch, lens_commands.lookup(&.{}, "rust-analyzer.debugSingle").?);
    try testing.expectEqual(lens_commands.Action.run_task, lens_commands.lookup(&.{}, "gopls.test").?);
    try testing.expect(lens_commands.lookup(&.{}, "rust-analyzer.showReferences") == null);
    // Settings come first.
    const extra = [_]lens_commands.LensMapping{.{ .server_command = "gopls.test", .action = .debug_launch }};
    try testing.expectEqual(lens_commands.Action.debug_launch, lens_commands.lookup(&extra, "gopls.test").?);
}
