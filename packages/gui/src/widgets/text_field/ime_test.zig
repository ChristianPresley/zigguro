//! TextField IME tests (E04.F05.S02.T02): what the field reports to the
//! window's IME state, and composition events through a headless window.

const std = @import("std");
const model = @import("model.zig");
const view = @import("view.zig");
const ime = @import("ime.zig");
const ui_mod = @import("../../core/ui.zig");
const view_mod = @import("../../core/view.zig");
const TestApp = @import("../../testing/test_app.zig").TestApp;

const testing = std.testing;
const gpa = testing.allocator;
const TextBuffer = model.TextBuffer;
const Ui = ui_mod.Ui;

const Form = struct {
    name: *TextBuffer,
    secret: *TextBuffer,

    pub fn build(self: *Form, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 8, .padding = .all(8) } });
        defer ui.close();
        ui.with(.{ .w = .{ .px = 200 } });
        _ = view.textField(ui, .{ .buffer = self.name, .placeholder = "Name" });
        ui.with(.{ .w = .{ .px = 200 } });
        _ = view.textField(ui, .{ .buffer = self.secret, .placeholder = "Secret", .password = true });
    }
};

const Harness = struct {
    name: TextBuffer,
    secret: TextBuffer,
    form: Form = undefined,
    t: *TestApp = undefined,

    fn init(h: *Harness, name: []const u8) !void {
        h.name = try .init(gpa, name);
        h.secret = try .init(gpa, "hunter2");
        h.form = .{ .name = &h.name, .secret = &h.secret };
        h.t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&h.form) });
        _ = h.t.settle();
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.name.deinit();
        h.secret.deinit();
    }

    fn state(h: *Harness, name: []const u8) *view.TextField.State {
        const n = h.t.find(.{ .name = name }).?;
        return @ptrCast(@alignCast(h.t.win.store.hot.items(.state)[n.index].?));
    }
};

test "ime enable on focus with purpose; disable on blur" {
    var h: Harness = .{ .name = undefined, .secret = undefined };
    try h.init("abc");
    defer h.deinit();
    const t = h.t;
    const im = &t.win.ime;
    try testing.expect(!im.enabled);

    try t.click(.{ .name = "Name" });
    try testing.expect(im.enabled);
    try testing.expect(im.owner.eql(t.find(.{ .name = "Name" }).?));
    try testing.expectEqual(.normal, im.purpose);
    const sr = im.surrounding().?;
    try testing.expectEqualStrings("abc", sr.text);
    // The caret sits inside the field.
    const field = try t.rectOf(.{ .name = "Name" });
    try testing.expect(im.caret.x >= field.x and im.caret.right() <= field.right());
    try testing.expect(im.caret.y >= field.y and im.caret.bottom() <= field.bottom());
    try testing.expect(im.caret.h > 0);

    // A password field: its purpose, and never its text.
    try t.click(.{ .name = "Secret" });
    try testing.expect(im.enabled);
    try testing.expect(im.owner.eql(t.find(.{ .name = "Secret" }).?));
    try testing.expectEqual(.password, im.purpose);
    try testing.expect(im.surrounding() == null);

    // Focus leaving every field turns the IME off.
    t.win.setFocus(.none, false);
    _ = t.settle();
    try testing.expect(!im.enabled);
}

test "caret rect resent only when it moves" {
    var h: Harness = .{ .name = undefined, .secret = undefined };
    try h.init("");
    defer h.deinit();
    const t = h.t;
    const im = &t.win.ime;
    try t.click(.{ .name = "Name" });
    t.typeText("ab");
    const s1 = im.serial;
    const x1 = im.caret.x;
    try testing.expectEqual(@as(u32, 2), im.surrounding().?.cursor_byte);

    // At the end already: nothing moved, nothing to send.
    t.press(.arrow_right, .{});
    t.press(.end, .{});
    try testing.expectEqual(s1, im.serial);

    t.press(.arrow_left, .{});
    try testing.expect(im.serial != s1);
    try testing.expect(im.caret.x < x1);
    try testing.expectEqual(@as(u32, 1), im.surrounding().?.cursor_byte);
}

test "preedit inline, keys consumed, commit is one undo step" {
    var h: Harness = .{ .name = undefined, .secret = undefined };
    try h.init("");
    defer h.deinit();
    const t = h.t;
    try t.click(.{ .name = "Name" });
    t.typeText("ab");
    const st = h.state("Name");

    t.imeCompose("ni hao", 3, 6);
    const pe = st.preedit.?;
    try testing.expectEqualStrings("ni hao", pe.text);
    try testing.expectEqual([2]i32{ 3, 6 }, pe.cursor);
    try testing.expectEqual([2]u32{ 2, 2 }, pe.range_in_buffer);
    // The buffer holds only committed text.
    try testing.expectEqualStrings("ab", h.name.slice());

    // The IME owns the keys while composing.
    t.press(.backspace, .{});
    t.press(.arrow_left, .{});
    try testing.expectEqualStrings("ab", h.name.slice());
    try testing.expectEqual(@as(u32, 2), st.sel.head);

    t.typeText("你好");
    try testing.expect(st.preedit == null);
    try testing.expectEqualStrings("ab你好", h.name.slice());
    t.press(.key_z, .{ .ctrl = true });
    try testing.expectEqualStrings("ab", h.name.slice());

    // An empty preedit ends a composition without committing.
    t.imeCompose("x", 0, 0);
    try testing.expect(st.preedit != null);
    t.imeCompose("", 0, 0);
    try testing.expect(st.preedit == null);
    try testing.expectEqualStrings("ab", h.name.slice());
    // Blur drops an open composition.
    t.imeCompose("y", -1, -1);
    try testing.expectEqual(@as(i32, -1), st.preedit.?.cursor[0]);
    try t.click(.{ .name = "Secret" });
    try testing.expect(st.preedit == null);
}

test "delete surrounding clamps to graphemes" {
    var h: Harness = .{ .name = undefined, .secret = undefined };
    try h.init("");
    defer h.deinit();
    const t = h.t;
    try t.click(.{ .name = "Name" });
    t.typeText("hello");
    t.imeDeleteSurrounding(2, 0);
    try testing.expectEqualStrings("hel", h.name.slice());
    try testing.expectEqual(@as(u32, 3), h.state("Name").sel.head);

    // "xe" + combining acute: deleting one byte before the caret takes the
    // whole "é"; bytes past the end are clamped.
    t.press(.key_a, .{ .ctrl = true });
    t.typeText("xe\u{301}y");
    t.press(.arrow_left, .{});
    t.imeDeleteSurrounding(1, 9);
    try testing.expectEqualStrings("x", h.name.slice());
    try testing.expectEqual(@as(u32, 1), h.state("Name").sel.head);
}

test "surrounding text window 4000 bytes at utf8 boundaries" {
    // 2500 two-byte characters: 5000 bytes.
    const t = "é" ** 2500;
    for ([_]u32{ 0, 2, 2500, 4998, 5000 }) |head| {
        const w = ime.window(t, head);
        try testing.expect(w[1] - w[0] <= ime.max_surrounding);
        try testing.expect(w[1] - w[0] >= ime.max_surrounding - 1);
        try testing.expect(w[0] <= head and head <= w[1]);
        // Both ends on character starts (even offsets here).
        try testing.expectEqual(@as(u32, 0), w[0] % 2);
        try testing.expectEqual(@as(u32, 0), w[1] % 2);
    }
    // Short text goes whole, less characters cut off at either end.
    try testing.expectEqual([2]u32{ 0, 3 }, ime.window("abc", 1));
    const cut = "é" ++ "ab" ++ "é";
    // Bytes 1..5 start after a lead byte and end on one: "ab" is left.
    try testing.expectEqual([2]u32{ 1, 3 }, ime.window(cut[1..5], 2));
}
