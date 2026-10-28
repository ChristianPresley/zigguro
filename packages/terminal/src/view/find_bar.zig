//! The terminal's find bar (E06.F05.S03.T01): a text field searched as
//! you type, toggles for case (Aa), whole word (ab) and regex (.*), the
//! match count ("3 of 120"), previous/next buttons and a close button.
//!
//! Enter moves to the next older match, Shift+Enter to the next newer one,
//! Escape closes the bar and clears the highlights (the owner then gives
//! focus back to the terminal). The owner keeps a `FindBar` per terminal
//! and builds it above the terminal while `open`.

const std = @import("std");
const zg_gui = @import("zg_gui");
const view_mod = @import("terminal_view.zig");
const search = @import("search.zig");

const Ui = zg_gui.Ui;
const TextBuffer = zg_gui.w.text_field.TextBuffer;
const TerminalView = view_mod.TerminalView;
const KeyPress = zg_gui.input.event.KeyPress;
const ev_mod = zg_gui.input.event;
const widget = zg_gui.core.widget;
const controls = zg_gui.w.controls;

/// One terminal's find bar state.
pub const FindBar = struct {
    field: TextBuffer,
    open: bool = false,
    regex: bool = false,
    case_sensitive: bool = false,
    whole_word: bool = false,
    /// The text field's node, for focusing.
    field_node: zg_gui.core.NodeId = .none,
    /// Set when Escape or the close button closed it; the owner clears it
    /// once focus is back on the terminal.
    closed: bool = false,
    /// Focus the field once it is in the tree.
    focus_pending: bool = false,

    pub fn init(gpa: std.mem.Allocator) !FindBar {
        return .{ .field = try .init(gpa, "") };
    }

    pub fn deinit(f: *FindBar) void {
        f.field.deinit();
    }

    /// Opens the bar (with `seed`, the selected text, when given) and asks
    /// for focus on its field.
    pub fn show(f: *FindBar, seed: ?[]const u8) void {
        f.open = true;
        f.focus_pending = true;
        if (seed) |s| if (s.len > 0 and std.mem.indexOfScalar(u8, s, '\n') == null) f.field.setText(s) catch {};
    }

    /// Closes the bar and clears the view's highlights.
    pub fn close(f: *FindBar, v: *TerminalView) void {
        f.open = false;
        f.closed = true;
        v.endFind();
    }

    /// The query the bar describes.
    pub fn query(f: *FindBar) search.Query {
        return .{
            .pattern = f.field.slice(),
            .regex = f.regex,
            .case = if (f.case_sensitive) .sensitive else .smart,
            .whole_word = f.whole_word,
        };
    }

    /// Runs the search again (the text or a toggle changed).
    pub fn refresh(f: *FindBar, v: *TerminalView) void {
        v.find(f.query()) catch {};
    }

    /// Enter, Shift+Enter and Escape; true when handled.
    pub fn onKey(f: *FindBar, v: *TerminalView, k: KeyPress) bool {
        if (k.action == .release) return false;
        const m = k.mods;
        if (m.ctrl or m.alt or m.super) return false;
        switch (k.key) {
            .enter, .numpad_enter => {
                // A search not run yet (or cleared by a resize) runs first.
                if (v.search.matches.items.len == 0) f.refresh(v) else v.findStep(if (m.shift) .newer else .older);
                return true;
            },
            .escape => {
                f.close(v);
                return true;
            },
            else => return false,
        }
    }

    /// "3 of 120", "No results", or the pattern error.
    pub fn status(f: *FindBar, v: *const TerminalView, buf: []u8) []const u8 {
        const s = &v.search;
        if (s.errorText().len > 0) return s.errorText();
        if (f.field.len() == 0) return "";
        const n = s.matches.items.len;
        if (n == 0) return "No results";
        const cur = if (s.current) |c| c + 1 else 0;
        return std.fmt.bufPrint(buf, "{d} of {d}{s}", .{ cur, n, if (s.capped) "+" else "" }) catch "";
    }
};

/// Captures the bar's keys before the text field sees them.
const Keys = struct {
    pub const name = "terminal_find_keys";
    pub const Props = struct { f: *FindBar, v: *TerminalView };

    pub fn style(_: *const Props, _: *const zg_gui.theme.Theme) zg_gui.Style {
        return .{ .dir = .row, .align_items = .center, .shrink = 0 };
    }

    pub fn event(ec: *ev_mod.EventCx, props: *const Props, _: *widget.NoState, ev: *const ev_mod.InputEvent) bool {
        if (ec.phase != .capture) return false;
        const k = switch (ev.*) {
            .key => |k| k,
            else => return false,
        };
        if (!props.f.onKey(props.v, k)) return false;
        ec.respond(.{ .changed = true });
        return true;
    }

    pub fn a11y(_: *const Props, _: *widget.NoState) widget.A11y {
        return .{ .role = .group, .name = "Find in terminal" };
    }
};

/// Builds the bar for `v` (call only while `f.open`).
pub fn findBar(ui: *Ui, f: *FindBar, v: *TerminalView) void {
    const th = ui.theme();
    _ = ui.begin(Keys, .{ .f = f, .v = v });
    defer ui.end(Keys);
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_xs), .padding = .xy(6, 2), .align_items = .center, .grow = 1 } });
    defer ui.close();
    ui.open(.{ .style = .{ .w = .{ .px = 240 }, .shrink = 1 } });
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &f.field, .a11y_label = "Find", .placeholder = "Find", .invalid = v.search.errorText().len > 0 });
    f.field_node = ui.lastNode();
    ui.close();
    if (r.changed) f.refresh(v);

    const toggles = [_]struct { label: []const u8, on: *bool }{
        .{ .label = "Aa", .on = &f.case_sensitive },
        .{ .label = "ab", .on = &f.whole_word },
        .{ .label = ".*", .on = &f.regex },
    };
    for (toggles) |t| {
        if (controls.button(ui, .{ .label = t.label, .variant = if (t.on.*) .primary else .ghost }).clicked) {
            t.on.* = !t.on.*;
            f.refresh(v);
        }
    }
    var buf: [48]u8 = undefined;
    const st = f.status(v, &buf);
    ui.open(.{ .role = .status, .label = st, .style = .{ .padding = .xy(4, 0) } });
    ui.text(st, .{ .color = if (v.search.errorText().len > 0) .danger else .fg_muted, .wrap = false });
    ui.close();
    if (controls.button(ui, .{ .label = "\u{2191}", .variant = .ghost }).clicked) v.findStep(.older);
    if (controls.button(ui, .{ .label = "\u{2193}", .variant = .ghost }).clicked) v.findStep(.newer);
    if (controls.button(ui, .{ .label = "\u{00d7}", .variant = .ghost }).clicked) f.close(v);
}

const testing = std.testing;
const zg_terminal = @import("zg_terminal");
const term_widget = @import("widget.zig");

const TestPage = struct {
    f: *FindBar,
    v: *TerminalView,

    pub fn build(p: *TestPage, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        defer ui.close();
        if (p.f.open) findBar(ui, p.f, p.v);
        _ = term_widget.terminal(ui, .{ .view = p.v });
    }
};

test "find bar: typing searches, Enter steps, toggles and Escape" {
    const gpa = testing.allocator;
    var term: zg_terminal.Terminal = try .init(gpa, .{ .cols = 80, .rows = 24 });
    defer term.deinit();
    var v: TerminalView = .init(gpa, &term, .{});
    defer v.deinit();
    var f = try FindBar.init(gpa);
    defer f.deinit();
    var page: TestPage = .{ .f = &f, .v = &v };
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .root = .of(&page), .size = .{ .w = 700, .h = 300 } });
    defer t.deinit();
    v.feed("error: one\r\nfine\r\nError: two\r\nerror three\r\n");
    f.show(null);
    t.win.markAllDirty();
    _ = t.settle();
    try t.click(.{ .role = .textbox, .name = "Find" });
    t.typeText("error");
    _ = t.settle();
    // Smart case: all three, the newest current.
    try testing.expectEqual(@as(usize, 3), v.search.matches.items.len);
    try testing.expectEqual(@as(?usize, 2), v.search.current);
    try testing.expect(t.find(.{ .role = .status, .name = "3 of 3" }) != null);

    t.press(.enter, .{});
    _ = t.settle();
    try testing.expectEqual(@as(?usize, 1), v.search.current);
    t.press(.enter, .{ .shift = true });
    _ = t.settle();
    try testing.expectEqual(@as(?usize, 2), v.search.current);

    try t.click(.{ .role = .button, .name = "Aa" });
    _ = t.settle();
    try testing.expectEqual(@as(usize, 2), v.search.matches.items.len);
    try t.click(.{ .role = .button, .name = ".*" });
    try t.click(.{ .role = .textbox, .name = "Find" });
    t.typeText("(");
    _ = t.settle();
    try testing.expect(v.search.errorText().len > 0);

    t.press(.escape, .{});
    _ = t.settle();
    try testing.expect(!f.open);
    try testing.expect(f.closed);
    try testing.expect(!v.find_active);
}
