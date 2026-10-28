//! Formatting, the save pipeline and file-operation hooks against the
//! scripted fake server (format.script).

const std = @import("std");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Harness = @import("../Manager_test.zig").Harness;
const Manager = @import("../Manager.zig");
const FormatService = @import("format.zig");
const SaveActions = @import("save_actions.zig");
const FileOpHooks = @import("file_ops.zig");
const CommandService = @import("commands.zig");
const Engine = @import("../edits/Engine.zig");
const MemFs = @import("../edits/wsedit_test.zig").MemFs;

const testing = std.testing;
const gpa = testing.allocator;
const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.docs.items.len > 0 and s.sync.?.isTracked(s.docs.items[s.docs.items.len - 1])) return true;
    return false;
}

const Fx = struct {
    h: Harness,
    d: DocHandle,
    fs: MemFs,
    engine: Engine,
    commands: CommandService,
    format: FormatService,
    save: SaveActions,
    hooks: FileOpHooks,

    fn init(f: *Fx) !void {
        try f.h.init("format.script", &.{});
        f.d = try f.h.open("main.zig", "const a=1;\nconst b=2;\nconst c=3;\n");
        f.fs = .{ .gpa = gpa };
        f.engine = .init(gpa, &f.h.docs, f.fs.ops(), .{});
        f.commands = .init(&f.h.mgr, .noop);
        f.format = .init(&f.h.mgr, &f.engine, .noop);
        f.format.options = .{ .ctx = f, .f = options };
        f.save = .init(&f.h.mgr, &f.engine, &f.commands);
        f.save.options = f.format.options;
        f.hooks = .init(&f.h.mgr, &f.engine);
        for (0..2000) |_| {
            f.h.mgr.tick();
            if (running(&f.h)) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    fn options(_: *anyopaque, _: DocHandle) protocol.FormattingOptions {
        return .{ .tabSize = 2, .insertSpaces = true };
    }

    fn deinit(f: *Fx) void {
        f.h.mgr.closeDoc(f.d);
        f.h.docs.release(f.d);
        f.h.mgr.deinit();
        f.format.deinit();
        f.save.deinit();
        f.hooks.deinit();
        f.commands.deinit();
        f.engine.deinit();
        f.fs.deinit();
        f.h.docs.deinit();
        f.h.reg.deinit();
        gpa.free(f.h.script);
        f.h.tmp.cleanup();
        _ = f.h.rt.deinit();
    }

    fn untilIdle(f: *Fx) !void {
        for (0..2000) |_| {
            f.h.mgr.tick();
            _ = f.format.tick();
            if (!f.format.busy()) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    fn expectText(f: *Fx, want: []const u8) !void {
        const doc = f.h.docs.get(f.d).?;
        const t = try doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
        defer gpa.free(t);
        try testing.expectEqualStrings(want, t);
    }
};

test "format: document, ranges fallback last first, on type; save pipeline order and deadline; willRename before didRename" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();

    try f.format.document(f.d, .user);
    try f.untilIdle();
    try testing.expectEqualStrings("", f.format.failure.items);
    try f.expectText("const a = 1;\nconst b=2;\nconst c=3;\n");

    // No rangesSupport: one rangeFormatting per range, the last first.
    try f.format.ranges(f.d, &.{ .{ .start = 13, .end = 23 }, .{ .start = 24, .end = 34 } }, .user);
    try f.untilIdle();
    try testing.expectEqualStrings("", f.format.failure.items);
    try f.expectText("const a = 1;\nconst b = 2;\nconst c = 3;\n");
    try testing.expectEqual(@as(u32, 3), f.format.applied);

    // On type: only the trigger character asks.
    try testing.expect(!f.format.triggers(f.d, '}'));
    try f.format.onType(f.d, '}', 12);
    try testing.expect(!f.format.busy());
    try f.format.onType(f.d, ';', 12);
    try f.untilIdle();
    try f.expectText("const a = 1; // one\nconst b = 2;\nconst c = 3;\n");

    // Save: willSaveWaitUntil, then the code action (resolved), then
    // format, each seeing the text the last left.
    const r = f.save.beforeSave(f.d, .{ .code_actions = &.{"source.organizeImports"}, .format = true }, f.save.clock());
    try testing.expectEqualSlices(SaveActions.Step, &.{ .will_save, .code_action, .format }, f.save.trace.items);
    try testing.expectEqual(@as(u8, 2), r.edited);
    try testing.expect(!r.timed_out);
    try f.expectText("const a = 1; // one\nconst b = 2;\nconst c = 3;\n");

    // Out of time (the server sleeps): saved as is, warned once.
    const slow: SaveActions.Plan = .{ .format = true, .budget_ms = 30 };
    const t1 = f.save.beforeSave(f.d, slow, f.save.clock());
    try testing.expect(t1.timed_out and t1.warn);
    try testing.expectEqualSlices(SaveActions.Step, &.{.will_save}, f.save.trace.items);
    const t2 = f.save.beforeSave(f.d, slow, f.save.clock());
    try testing.expect(t2.timed_out and !t2.warn);

    // Rename hooks: the server's edit applies before the rename.
    const old = f.h.docs.name(f.d).?;
    const new = try std.fs.path.join(gpa, &.{ f.h.ws, "lib.zig" });
    defer gpa.free(new);
    const pairs = [_]FileOpHooks.Pair{.{ .old = old, .new = new }};
    f.hooks.willRename(&pairs, f.save.clock());
    try testing.expectEqual(@as(u32, 1), f.hooks.applied);
    try f.expectText("const a = 1; // one\nconst b = 2;\n// renamed\nconst c = 3;\n");
    f.hooks.didRename(&pairs);
    // The script checks the rest (a mismatch ends the server).
    for (0..40) |_| {
        f.h.mgr.tick();
        try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expect(f.h.mgr.serverList()[0].status == .running);
}

test "file_ops: filters by scheme, glob, file or folder, and case" {
    const F = protocol.FileOperationFilter;
    const zig_files = [_]F{.{ .pattern = .{ .glob = "**/*.zig", .matches = .file } }};
    try testing.expect(FileOpHooks.matches(gpa, &zig_files, "/w/src/a.zig", false));
    try testing.expect(!FileOpHooks.matches(gpa, &zig_files, "/w/src/a.zig", true));
    try testing.expect(!FileOpHooks.matches(gpa, &zig_files, "/w/src/A.ZIG", false));
    const any_case = [_]F{.{ .pattern = .{ .glob = "**/*.zig", .options = .{ .ignoreCase = true } } }};
    try testing.expect(FileOpHooks.matches(gpa, &any_case, "/w/src/A.ZIG", false));
    try testing.expect(FileOpHooks.matches(gpa, &any_case, "C:\\w\\a.zig", false));
    const folders = [_]F{.{ .scheme = "file", .pattern = .{ .glob = "**/src", .matches = .folder } }};
    try testing.expect(FileOpHooks.matches(gpa, &folders, "/w/src", true));
    try testing.expect(!FileOpHooks.matches(gpa, &folders, "/w/src", false));
    const untitled = [_]F{.{ .scheme = "untitled", .pattern = .{ .glob = "**" } }};
    try testing.expect(!FileOpHooks.matches(gpa, &untitled, "/w/a.zig", false));
}
