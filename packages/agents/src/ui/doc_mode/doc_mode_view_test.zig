//! Document mode in a headless window: the layout it enters and leaves,
//! the outline, streaming tracked changes, the review keys and the
//! selection bar.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const view = @import("doc_mode_view.zig");
const layout = @import("layout.zig");

const testing = std.testing;
const gpa = testing.allocator;
const TestApp = zg_gui.testing.TestApp;
const DockModel = zg_gui.dock.DockModel;
const sections = zg_agents.docs.sections;
const DocMode = view.DocMode;

const doc =
    \\# Guide
    \\
    \\An opening paragraph with some words.
    \\
    \\## Install
    \\
    \\The cat sat on the mat.
    \\
    \\## Use
    \\
    \\Run it and see.
    \\
;

const Host = struct {
    nav: ?u32 = null,
    moves: u32 = 0,
    last_move: ?sections.Move = null,
    prompt: std.ArrayList(u8) = .empty,
    scope: ?sections.Range = null,
    decisions: std.ArrayList(u8) = .empty,

    fn navigate(ctx: *anyopaque, off: u32) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.nav = off;
    }
    fn edit(ctx: *anyopaque, m: sections.Move) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.moves += 1;
        h.last_move = m;
    }
    fn request(ctx: *anyopaque, p: []const u8, scope: sections.Range) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.prompt.clearRetainingCapacity();
        h.prompt.appendSlice(gpa, p) catch {};
        h.scope = scope;
    }
    fn decide(ctx: *anyopaque, cs: u64, hunk: u32, d: zg_agents.docs.tracked.Decision) anyerror!void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        try h.decisions.print(gpa, "{d}.{d}:{t} ", .{ cs, hunk, d });
    }
};

const Fx = struct {
    host: Host = .{},
    m: *DocMode,
    t: *TestApp,

    fn init(f: *Fx) !void {
        f.host = .{};
        f.m = try DocMode.init(gpa, .{
            .navigate = .{ .ctx = &f.host, .f = Host.navigate },
            .edit = .{ .ctx = &f.host, .f = Host.edit },
            .request = .{ .ctx = &f.host, .f = Host.request },
            .decide = .{ .ctx = &f.host, .decide = Host.decide },
        }, null);
        try f.m.update(doc, 1, 0);
        f.t = try TestApp.init(gpa, .{ .root = .of(f.m), .size = .{ .w = 1200, .h = 800 } });
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.t.deinit();
        f.m.deinit();
        f.host.prompt.deinit(gpa);
        f.host.decisions.deinit(gpa);
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn focus(f: *Fx) !void {
        const n = f.t.find(.{ .role = .tree }) orelse return error.NotFound;
        f.t.win.setFocus(n, true);
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

test "enter and exit restore the layout" {
    var d = try DockModel.init(gpa);
    defer d.deinit();
    const before = d.areas;
    const panels = d.panels.count();
    var dm: layout.DocumentMode = .init(gpa, &d, .{ .editor = 1, .outline = 2, .agent = 3 }, .{});
    defer dm.deinit();
    try dm.enter("notes/guide.md");
    try testing.expect(dm.active());
    try testing.expectEqual(panels + 3, d.panels.count());
    const A = zg_gui.dock.model.Area;
    try testing.expectEqual(@as(f32, 240), d.areas[@intFromEnum(A.left)].size);
    try testing.expectEqual(@as(f32, 420), d.areas[@intFromEnum(A.agent)].size);
    try testing.expect(!d.areas[@intFromEnum(A.bottom)].visible);
    const editor = d.panels.get(dm.panels[0].?).?;
    try expectHas(editor.state.?, "\"mode\":\"document\"");
    try expectHas(editor.state.?, "\"measure\":72");
    // Switching documents keeps the saved layout.
    try dm.enter("notes/other.md");
    try testing.expectEqual(panels + 3, d.panels.count());
    try expectHas(d.panels.get(dm.panels[0].?).?.state.?, "other.md");
    try dm.exit();
    try testing.expect(!dm.active());
    try testing.expectEqual(panels, d.panels.count());
    for (before, d.areas) |b, a| {
        try testing.expectEqual(b.visible, a.visible);
        try testing.expectEqual(b.size, a.size);
    }
}

test "outline click navigates and counts" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const s = try f.sem();
    defer gpa.free(s);
    try expectHas(s, "tree \"Outline\"");
    try expectHas(s, "Install, 8 words");
    try expectHas(s, "status \"22 words · 1 min read · section 22\"");
    try f.t.click(.{ .role = .treeitem, .name_contains = "Use," });
    try testing.expectEqual(@as(?u32, @intCast(std.mem.indexOf(u8, doc, "## Use").?)), f.host.nav);
    // The keyboard too; Alt+Up moves the section as one edit.
    try f.focus();
    f.t.press(.home, .{});
    f.t.press(.arrow_down, .{});
    f.t.press(.enter, .{});
    try testing.expectEqual(@as(?u32, @intCast(std.mem.indexOf(u8, doc, "## Install").?)), f.host.nav);
    f.t.press(.arrow_down, .{});
    f.t.press(.arrow_up, .{ .alt = true });
    try testing.expectEqual(@as(u32, 1), f.host.moves);
    const mv = f.host.last_move.?;
    try testing.expect(std.mem.startsWith(u8, mv.new_text, "## Use"));
    // The status line counts words and reading time.
    const st = try f.m.status(gpa);
    defer gpa.free(st);
    try testing.expectEqualStrings("22 words · 1 min read · section 22", st);
}

test "streaming partial JSON renders incrementally and accept/reject by keyboard" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const at: u32 = @intCast(std.mem.indexOf(u8, doc, "The cat").?);
    try f.m.onToolProgress(9, "doc_propose_edit", "{\"old_text\":\"The cat\",\"new_text\":\"A");
    try testing.expectEqual(@as(usize, 1), f.m.tracked.items.items.len);
    try f.m.onToolProgress(9, "doc_propose_edit", "{\"old_text\":\"The cat\",\"new_text\":\"A dog\"}");
    try testing.expectEqualStrings("A dog", f.m.tracked.items.items[0].new);
    try f.m.onToolDone(9, 77, &.{.{ .start = at, .end = at + 7, .new = "A dog" }});
    f.settle();
    {
        const s = try f.sem();
        defer gpa.free(s);
        try expectHas(s, "Install, 8 words, changes pending");
    }
    try f.focus();
    // F8 goes to it and says what it is.
    f.t.press(.f8, .{});
    try testing.expectEqual(@as(?u32, at), f.host.nav);
    try testing.expectEqualStrings("replacement pending, 2 words", f.m.said.items);
    // Ctrl+Enter accepts it.
    f.t.press(.enter, .{ .ctrl = true });
    try testing.expectEqualStrings("77.0:accept ", f.host.decisions.items);
    try testing.expectEqual(@as(usize, 0), f.m.tracked.items.items.len);
    // Esc rejects; Ctrl+Shift+Enter takes the whole section.
    try f.m.onToolDone(10, 78, &.{ .{ .start = at, .end = at + 3, .new = "A" }, .{ .start = at + 8, .end = at + 11, .new = "lay" } });
    f.m.cursor = at;
    f.t.press(.escape, .{});
    try testing.expectEqualStrings("77.0:accept 78.0:reject ", f.host.decisions.items);
    f.t.press(.enter, .{ .ctrl = true, .shift = true });
    try testing.expectEqualStrings("77.0:accept 78.0:reject 78.1:accept ", f.host.decisions.items);
    try testing.expectEqualStrings("1 change accepted in Install", f.m.said.items);
}

test "user edit inside hunk drops it" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const at: u32 = @intCast(std.mem.indexOf(u8, doc, "The cat").?);
    try f.m.onToolDone(1, 5, &.{.{ .start = at, .end = at + 7, .new = "A dog" }});
    const edited = try std.mem.concat(gpa, u8, &.{ doc[0 .. at + 2], "!", doc[at + 2 ..] });
    defer gpa.free(edited);
    try f.m.onUserEdit(at + 2, 0, "!", edited, 2);
    try testing.expectEqual(@as(usize, 0), f.m.tracked.items.items.len);
    try testing.expectEqualStrings("5.0:stale ", f.host.decisions.items);
    try testing.expectEqualStrings("1 pending change dropped by your edit", f.m.said.items);
}

test "selection bar debounce and shortcuts" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const at: u32 = @intCast(std.mem.indexOf(u8, doc, "The cat").?);
    const sel: sections.Range = .{ .start = at, .end = at + 23 };
    f.m.onSelection(sel, true, 1000);
    try testing.expect(!f.m.tick(2000));
    f.m.onSelection(sel, false, 2000);
    try testing.expect(!f.m.tick(2200));
    try testing.expect(f.m.tick(2300));
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "doc-selection-bar" }) != null);
    try f.t.click(.{ .role = .button, .name = "Shorten" });
    f.settle();
    try expectHas(f.host.prompt.items, "from \"Install\" about half as long");
    try expectHas(f.host.prompt.items, "The cat sat on the mat.");
    try testing.expectEqual(sel.start, f.host.scope.?.start);
    try testing.expect(f.t.find(.{ .test_id = "doc-selection-bar" }) == null);
    // A new selection hides it again until it settles; Ctrl+K forces it.
    f.m.onSelection(.{ .start = 0, .end = 0 }, false, 3000);
    try testing.expect(!f.m.bar.visible);
    try f.focus();
    f.t.press(.key_k, .{ .ctrl = true });
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "doc-selection-bar" }) != null);
    // Without a selection, only shortcuts that work on the section show.
    try testing.expect(f.t.find(.{ .role = .button, .name = "Shorten" }) == null);
    try f.t.click(.{ .role = .button, .name = "Summarize above" });
    try expectHas(f.host.prompt.items, "Write a short summary of everything above");
    f.t.press(.escape, .{});
}
