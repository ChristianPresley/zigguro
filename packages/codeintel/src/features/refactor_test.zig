//! Rename, code actions and commands against the scripted fake server
//! (refactor.script).

const std = @import("std");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Harness = @import("../Manager_test.zig").Harness;
const Manager = @import("../Manager.zig");
const RenameService = @import("rename.zig");
const CodeActionService = @import("code_action.zig");
const CommandService = @import("commands.zig");
const Engine = @import("../edits/Engine.zig");
const plan_mod = @import("../edits/plan.zig");
const Store = @import("../diagnostics/Store.zig");
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
    diags: Store,
    commands: CommandService,
    rename: RenameService,
    actions: CodeActionService,
    review: Review = .{},
    /// workspace/applyEdit answers.
    replies: std.ArrayList(Engine.ApplyEditResult) = .empty,

    const Review = struct {
        n: u32 = 0,
        origin: ?Engine.Origin = null,
        fn submit(ctx: *anyopaque, _: *const plan_mod.EditPlan, origin: Engine.Origin) anyerror!u64 {
            const r: *Review = @ptrCast(@alignCast(ctx));
            r.n += 1;
            r.origin = origin;
            return 9;
        }
    };

    fn init(f: *Fx) !void {
        try f.h.init("refactor.script", &.{});
        f.d = try f.h.open("main.zig", "const foo = 1;\n_ = foo;\nvar unused = 2;\n");
        f.fs = .{ .gpa = gpa };
        f.review = .{};
        f.replies = .empty;
        f.engine = .init(gpa, &f.h.docs, f.fs.ops(), .{});
        f.engine.review = .{ .ctx = &f.review, .submit = Review.submit };
        f.diags = try .init(gpa, f.h.rt.io, .native);
        f.commands = .init(&f.h.mgr, .noop);
        f.rename = .init(&f.h.mgr, &f.engine, .noop);
        f.actions = .init(&f.h.mgr, &f.engine, &f.commands, &f.diags, .noop);
        f.h.mgr.apply_edit_hook = .{ .ctx = f, .f = onApplyEdit };
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
        f.rename.deinit();
        f.actions.deinit();
        f.commands.deinit();
        f.engine.deinit();
        f.diags.deinit();
        f.fs.deinit();
        f.replies.deinit(gpa);
        // The harness's own deinit, minus the manager.
        f.h.docs.deinit();
        f.h.reg.deinit();
        gpa.free(f.h.script);
        f.h.tmp.cleanup();
        _ = f.h.rt.deinit();
    }

    fn onApplyEdit(ctx: *anyopaque, s: *Manager.Server, params: *const protocol.ApplyWorkspaceEditParams, reply: Manager.ApplyEditCb) void {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        const r = f.engine.serverEdit(s, params, s.agent_command);
        f.replies.append(gpa, r) catch {};
        reply.call(r);
    }

    fn tick(f: *Fx) void {
        f.h.mgr.tick();
        _ = f.rename.tick();
        _ = f.actions.tick();
        _ = f.commands.tick();
    }

    fn until(f: *Fx, comptime pred: fn (*Fx) bool) !void {
        for (0..2000) |_| {
            f.tick();
            if (pred(f)) return;
            try f.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    fn text(f: *Fx) ![]u8 {
        const doc = f.h.docs.get(f.d).?;
        return doc.tree.copyRange(gpa, .{ .start = 0, .end = doc.len() });
    }

    fn expectText(f: *Fx, want: []const u8) !void {
        const t = try f.text();
        defer gpa.free(t);
        try testing.expectEqualStrings(want, t);
    }
};

fn notPreparing(f: *Fx) bool {
    return f.rename.state != .preparing;
}

fn renamed(f: *Fx) bool {
    return f.rename.state != .renaming;
}

fn actionsIn(f: *Fx) bool {
    return f.actions.complete() and f.actions.items().len > 0;
}

fn editedTwice(f: *Fx) bool {
    return f.h.docs.get(f.d).?.version >= 2 and !f.commands.busy();
}

fn replied(f: *Fx) bool {
    return f.replies.items.len > 0 and !f.commands.busy();
}

test "rename and code actions: prepare forms, errors, resolve then edit then command, agent commands to review" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();

    // Prepare with a placeholder, then the rename, in one undo step.
    try f.rename.begin(f.d, 7);
    try f.until(notPreparing);
    try testing.expectEqualStrings("foo", f.rename.state.ready.placeholder);
    try testing.expectEqual(@as(u64, 6), f.rename.state.ready.range.start);
    try f.rename.commit("bar", .auto, .user);
    try f.until(renamed);
    try testing.expect(f.rename.state.done == .applied);
    try f.expectText("const bar = 1;\n_ = bar;\nvar unused = 2;\n");
    try testing.expectEqualStrings("Rename", f.engine.lastUndo().?.label);

    // An error shows its message and opens no input.
    try f.rename.begin(f.d, 15);
    try f.until(notPreparing);
    try testing.expectEqualStrings("You cannot rename this element.", f.rename.state.failed);
    // Default behavior: the word at the caret.
    try f.rename.begin(f.d, 0);
    try f.until(notPreparing);
    try testing.expectEqualStrings("const", f.rename.state.ready.placeholder);
    f.rename.cancel();

    // Code actions with the overlapping diagnostic (its data sent back).
    const doc = f.h.docs.get(f.d).?;
    const set = try Store.Set.create(gpa, .{ .server = 0 });
    const sa = set.allocator();
    const ds = try sa.alloc(Store.Diagnostic, 1);
    ds[0] = .{ .start = .{ .line = 2, .character = 4 }, .end = .{ .line = 2, .character = 10 }, .bytes = .{ .start = 28, .end = 34 }, .message = "unused", .code = "9", .data = "{\"fix\":7,\"s\":\"x\"}" };
    set.diags = ds;
    set.version = doc.version;
    set.finish();
    const key = try f.diags.keyOf(gpa, f.h.docs.uri(f.d).?);
    defer gpa.free(key);
    try f.diags.replace(key, .{ .server = 0 }, set);
    f.diags.commit();
    try f.actions.request(f.d, .{ .start = 28, .end = 34 }, .invoked, null);
    try f.until(actionsIn);
    const items = f.actions.items();
    try testing.expectEqual(@as(usize, 4), items.len);
    // Preferred first, then by group, disabled last.
    try testing.expectEqualStrings("Remove it", items[0].title);
    try testing.expectEqualStrings("Extract", items[1].title);
    try testing.expectEqualStrings("Run fix", items[2].title);
    try testing.expectEqualStrings("Can't", items[3].title);
    try testing.expect(f.actions.bulb().preferred);
    // A disabled action says why.
    try f.actions.run(3, .user);
    try testing.expectEqualStrings("Nope", f.actions.failure.items);
    // Resolve, then the edit, then the command (the script checks the order).
    try f.actions.run(0, .user);
    try f.until(editedTwice);
    try f.expectText("const bar = 1;\n_ = bar;\n");

    // An agent's command: the edit it causes goes to review, not the buffer.
    const s = f.h.mgr.serverList()[0];
    try f.commands.execute(s, .{ .title = "agent", .command = "fake.agentEdit" }, 5);
    try testing.expectEqual(@as(?u32, 5), s.agent_command);
    try f.until(replied);
    try testing.expect(!f.replies.items[0].applied);
    try testing.expectEqual(@as(u32, 1), f.review.n);
    try testing.expectEqual(Engine.Origin{ .server = 5 }, f.review.origin.?);
    try testing.expect(s.agent_command == null);
    try f.expectText("const bar = 1;\n_ = bar;\n");
}

test "code actions: groups by kind prefix" {
    try testing.expectEqual(CodeActionService.Group.quickfix, CodeActionService.Group.of("quickfix"));
    try testing.expectEqual(CodeActionService.Group.extract, CodeActionService.Group.of("refactor.extract.function"));
    try testing.expectEqual(CodeActionService.Group.refactor, CodeActionService.Group.of("refactor"));
    try testing.expectEqual(CodeActionService.Group.refactor, CodeActionService.Group.of("refactor.other"));
    try testing.expectEqual(CodeActionService.Group.source, CodeActionService.Group.of("source.organizeImports"));
    try testing.expectEqual(CodeActionService.Group.other, CodeActionService.Group.of("quickfixer"));
    try testing.expectEqualStrings("editor.triggerSuggest", CommandService.clientCommand("editor.action.triggerSuggest").?);
}
