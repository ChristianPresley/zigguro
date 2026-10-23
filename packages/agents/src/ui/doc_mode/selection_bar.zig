//! Document mode's selection bar (E13.F04.S01.T02): a few shortcut
//! buttons ("Suggest edits", "Shorten", ...) and an "Ask…" field that
//! appear 300 ms after the person stops selecting, or at once on Ctrl+K.
//! Picking one hands the expanded prompt, scoped to the selection, to the
//! agent pane.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const TextBuffer = zg_gui.w.text_field.TextBuffer;
const sections = zg_agents.docs.sections;
const shortcuts = zg_agents.docs.shortcuts;

/// How long a selection must stay still before the bar shows.
pub const debounce_ms: i64 = 300;
/// How many default shortcuts get a button (the rest are commands).
pub const buttons = 4;

/// What the person picked.
pub const Pick = union(enum) {
    shortcut: *const shortcuts.Shortcut,
    ask: []const u8,
};

pub const SelectionBar = struct {
    selection: ?sections.Range = null,
    dragging: bool = false,
    changed_at: i64 = 0,
    visible: bool = false,
    /// Opened by keyboard: shows even without a selection.
    forced: bool = false,
    ask: TextBuffer,

    pub fn init(gpa: Allocator) !SelectionBar {
        return .{ .ask = try TextBuffer.init(gpa, "") };
    }

    pub fn deinit(b: *SelectionBar) void {
        b.ask.deinit();
    }

    /// The editor's selection changed (`dragging`: the mouse is still down).
    pub fn onSelection(b: *SelectionBar, range: ?sections.Range, dragging: bool, now_ms: i64) void {
        const same = if (b.selection) |s| (if (range) |r| s.start == r.start and s.end == r.end else false) else range == null;
        if (!same) {
            b.selection = range;
            b.changed_at = now_ms;
            b.visible = false;
            b.forced = false;
        }
        // The debounce runs from when the mouse is let go.
        if (b.dragging and !dragging) b.changed_at = now_ms;
        b.dragging = dragging;
        if (dragging) b.visible = false;
    }

    /// Shows the bar once the selection has been still for long enough.
    /// Returns whether visibility changed.
    pub fn tick(b: *SelectionBar, now_ms: i64) bool {
        const was = b.visible;
        const has = if (b.selection) |s| s.end > s.start else false;
        b.visible = b.forced or (has and !b.dragging and now_ms - b.changed_at >= debounce_ms);
        return was != b.visible;
    }

    /// Ctrl+K: shows the bar now.
    pub fn openFromKeyboard(b: *SelectionBar) void {
        b.forced = true;
        b.visible = true;
    }

    pub fn dismiss(b: *SelectionBar) void {
        b.visible = false;
        b.forced = false;
        b.ask.setText("") catch {};
    }

    /// The bar's buttons; what the person picked this frame, if anything.
    pub fn build(b: *SelectionBar, ui: *Ui) ?Pick {
        if (!b.visible) return null;
        const has = if (b.selection) |s| s.end > s.start else false;
        ui.open(.{ .role = .toolbar, .label = "Ask about the selection", .test_id = "doc-selection-bar", .style = .{
            .dir = .row,
            .gap = 4,
            .align_items = .center,
            .padding = .xy(6, 4),
            .bg = .{ .token = .bg_elevated },
        } });
        defer ui.close();
        var pick: ?Pick = null;
        var shown: usize = 0;
        for (&shortcuts.default_shortcuts) |*s| {
            if (shown == buttons) break;
            if (s.needs_selection and !has) continue;
            shown += 1;
            if (controls.button(ui, .{ .label = s.label, .variant = .ghost }).clicked) pick = .{ .shortcut = s };
        }
        ui.open(.{ .style = .{ .grow = 1 } });
        const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &b.ask, .a11y_label = "Ask", .placeholder = "Ask…" });
        ui.close();
        if (r.submitted) {
            const t = std.mem.trim(u8, b.ask.slice(), " \t");
            if (t.len > 0) pick = .{ .ask = t };
        }
        return pick;
    }
};
