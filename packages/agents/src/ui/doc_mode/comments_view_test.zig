//! The comments pane and the version timeline in a headless window.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const comments_view = @import("comments_view.zig");
const versions_view = @import("versions_view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const docs = zg_agents.docs;
const Range = docs.sections.Range;
const Version = docs.versions.Version;

const doc = "# Plan\n\nThe launch happens in spring.\n\nHiring may slip.\n";

const Host = struct {
    nav: ?u32 = null,
    sel: ?Range = null,
    compared: ?struct { from: ?[]const u8, to: []const u8 } = null,
    restored: ?[]const u8 = null,
    marks: u32 = 0,

    fn navigate(ctx: *anyopaque, off: u32) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.nav = off;
    }
    fn text(_: *anyopaque) []const u8 {
        return doc;
    }
    fn selection(ctx: *anyopaque) ?Range {
        const h: *Host = @ptrCast(@alignCast(ctx));
        return h.sel;
    }
    fn compare(ctx: *anyopaque, from: ?Version, to: Version) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.compared = .{ .from = if (from) |f| f.id else null, .to = to.id };
    }
    fn restore(ctx: *anyopaque, v: Version) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.restored = v.id;
    }
    fn mark(ctx: *anyopaque) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.marks += 1;
    }
};

const Panes = struct {
    c: comments_view.CommentsView,
    v: versions_view.VersionsView,

    pub fn build(p: *Panes, ui: *zg_gui.Ui) void {
        ui.open(.{ .style = .{ .dir = .row, .grow = 1 } });
        p.c.build(ui);
        p.v.build(ui);
        ui.close();
    }
};

fn rangeOf(needle: []const u8) Range {
    const at: u32 = @intCast(std.mem.indexOf(u8, doc, needle).?);
    return .{ .start = at, .end = at + @as(u32, @intCast(needle.len)) };
}

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing {s} in\n{s}\n", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

test "comments pane and version timeline" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var host: Host = .{};
    const store = try docs.CommentStore.open(gpa, io, "notes/plan.md", tmp.dir, .{});
    defer store.close();
    _ = try store.add(doc, rangeOf("in spring"), "Which month?", .{ .user = "ann" });
    const gone = try store.add(doc, rangeOf("Hiring may slip."), "Too gloomy", .{ .user = "bo" });
    _ = try store.reanchor("# Plan\n\nThe launch happens in spring.\n");
    const vs = [_]Version{
        .{ .id = "cp2", .source = .checkpoint, .at_ms = 1_792_756_800_000, .label = "Shorten intro", .author = .{ .agent = .zero }, .words = 9 },
        .{ .id = "s1", .source = .scm_snapshot, .at_ms = 1_792_750_000_000, .label = "Snapshot", .author = .{ .user = "ann" }, .words = 8 },
    };
    var panes: Panes = .{
        .c = try .init(gpa, store, .{
            .navigate = .{ .ctx = &host, .f = Host.navigate },
            .doc = .{ .ctx = &host, .f = Host.text },
            .selection = .{ .ctx = &host, .f = Host.selection },
            .user = "ann",
        }),
        .v = .init(.{ .compare = .{ .ctx = &host, .f = Host.compare }, .restore = .{ .ctx = &host, .f = Host.restore }, .mark = .{ .ctx = &host, .f = Host.mark } }),
    };
    defer panes.c.deinit();
    panes.v.setVersions(&vs);
    const t = try TestApp.init(gpa, .{ .root = .of(&panes), .size = .{ .w = 1400, .h = 900 } });
    defer t.deinit();
    t.win.markAllDirty();
    _ = t.settle();
    {
        const s = try t.semanticsSnapshot(gpa);
        defer gpa.free(s);
        try expectHas(s, "2 open");
        try expectHas(s, "listitem \"Comment on \"in spring\", 1 comment\"");
        try expectHas(s, "Detached (their text is gone)");
        try expectHas(s, "Comment on \"Hiring may slip.\", 1 comment, detached");
        try expectHas(s, "Shorten intro, agent change, 2026-10-23 12:00, agent, 9 words");
    }
    // Clicking a thread goes to its text; replying adds to it.
    try t.click(.{ .role = .listitem, .name_contains = "in spring" });
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqual(@as(?u32, rangeOf("in spring").start), host.nav);
    try t.click(.{ .role = .textbox, .name = "Reply" });
    t.typeText("April.");
    try t.click(.{ .role = .button, .name = "Reply" });
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqualStrings("April.", store.threads()[0].comments.items[1].text);
    try testing.expectEqualStrings("ann", store.threads()[0].comments.items[1].author.user);
    try t.click(.{ .role = .button, .name = "Resolve" });
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(store.threads()[0].resolved);
    // A detached thread attaches to the selection.
    host.sel = rangeOf("The launch");
    try t.click(.{ .role = .listitem, .name_contains = "detached" });
    t.win.markAllDirty();
    _ = t.settle();
    try t.click(.{ .role = .button, .name = "Attach to selection" });
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqual(@as(?Range, rangeOf("The launch")), store.get(gone).?.anchor);
    // A new comment needs a selection.
    host.sel = null;
    try t.click(.{ .role = .button, .name = "Comment" });
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqualStrings("Select the text to comment on first", panes.c.notice.?);

    // Versions: compare with current, then two, then restore.
    try t.click(.{ .role = .listitem, .name_contains = "Shorten intro" });
    t.win.markAllDirty();
    _ = t.settle();
    try t.click(.{ .role = .button, .name = "Compare with current" });
    try testing.expectEqualStrings("cp2", host.compared.?.to);
    try testing.expect(host.compared.?.from == null);
    try t.click(.{ .role = .button, .name = "Compare with…" });
    t.win.markAllDirty();
    _ = t.settle();
    try t.click(.{ .role = .listitem, .name_contains = "Snapshot" });
    t.win.markAllDirty();
    _ = t.settle();
    try t.click(.{ .role = .button, .name = "Compare these two" });
    try testing.expectEqualStrings("s1", host.compared.?.from.?);
    try t.click(.{ .role = .button, .name = "Restore" });
    try testing.expectEqualStrings("cp2", host.restored.?);
    try t.click(.{ .role = .button, .name = "Mark version" });
    try testing.expectEqual(@as(u32, 1), host.marks);
}
