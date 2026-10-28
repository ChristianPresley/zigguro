//! The debug hover (E07.F07.S01.T04): while the program is paused, the
//! pointer resting on an expression in an editor evaluates it and a
//! popover shows the value, opening into its children (a `VarTree` in
//! hover mode over the result's model node).
//!
//! - **Extent.** The identifier under the pointer, extended left through
//!   member access (`a.b`, `a->b`) and indexing (`a[0]`); a one-line
//!   selection the pointer is in is taken as it is. Calls are never
//!   part of it: evaluating one could change the program.
//! - **Context.** `hover`, which falls back to `watch` (never `repl`,
//!   unless `debug.hoverEvaluateWithRepl`; zg_dap's `Evaluator`).
//! - **Priority.** It takes the pointer before the language hover
//!   (`EditorView.priority_hook`) while the session is paused and the
//!   pointer is on an expression; the language hover gives way.
//! - An error shows nothing. The popover goes when the program runs,
//!   the session ends, on Escape or another key, and a moment after the
//!   pointer leaves (not while it is over the popover).
//!
//! UI thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_dap = @import("zg_dap");
const zg_editor = @import("zg_editor");
const var_tree = @import("var_tree.zig");

const Allocator = std.mem.Allocator;
const Window = zg_gui.Window;
const Rect = zg_gui.core.Rect;
const OverlayId = zg_gui.w.overlay.OverlayId;
const Inspector = zg_dap.inspect.Inspector;
const Evaluator = zg_dap.inspect.Evaluator;
const Document = zg_editor.model.document.Document;
const VarTree = var_tree.VarTree;

/// How long the pointer rests before the expression is evaluated.
pub const delay_ms = 300;
/// How long the popover stays after the pointer leaves.
pub const grace_ms = 300;
/// The popover's size.
pub const width: f32 = 380;
pub const max_rows = 12;

pub const Range = struct { start: u64, end: u64 };

/// The expression around byte `at` of `text`: `[start, end)`, or null
/// when `at` is not on an identifier.
pub fn expressionIn(text: []const u8, at: usize) ?[2]usize {
    if (at >= text.len or !isIdent(text[at])) return null;
    var a = at;
    while (a > 0 and isIdent(text[a - 1])) a -= 1;
    var b = at;
    while (b < text.len and isIdent(text[b])) b += 1;
    if (std.ascii.isDigit(text[a])) return null;
    // Left through `.x`, `->x` and `[...]`.
    while (a > 0) {
        var p = a;
        if (text[p - 1] == '.') {
            p -= 1;
        } else if (p >= 2 and text[p - 1] == '>' and text[p - 2] == '-') {
            p -= 2;
        } else break;
        // What the member is of: a name or an index.
        a = before(text, p) orelse break;
    }
    return .{ a, b };
}

/// The start of the name (and its indexes) that ends at `end`.
fn before(text: []const u8, end: usize) ?usize {
    var p = end;
    while (p > 0 and text[p - 1] == ']') {
        var depth: usize = 0;
        var q = p;
        while (q > 0) {
            q -= 1;
            switch (text[q]) {
                ']' => depth += 1,
                '[' => {
                    depth -= 1;
                    if (depth == 0) break;
                },
                '(', ')', '\n' => return null,
                else => {},
            }
        } else return null;
        if (depth != 0) return null;
        p = q;
    }
    var a = p;
    while (a > 0 and isIdent(text[a - 1])) a -= 1;
    if (a == p or std.ascii.isDigit(text[a])) return null;
    return a;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// The expression at `offset` of `doc` (a window of its text around it).
pub fn expressionAt(doc: *const Document, offset: u64) ?Range {
    const len = doc.len();
    var buf: [512]u8 = undefined;
    const lo = offset -| 384;
    const hi = @min(len, offset + 128);
    var n: usize = 0;
    var it = doc.tree.slice(.{ .start = lo, .end = hi });
    while (it.next()) |c| {
        @memcpy(buf[n..][0..c.len], c);
        n += c.len;
    }
    const r = expressionIn(buf[0..n], @intCast(offset - lo)) orelse return null;
    return .{ .start = lo + r[0], .end = lo + r[1] };
}

/// The session the hover asks (the debug service's active one, paused).
pub const Target = struct {
    insp: *Inspector,
    /// The session's id (the hover goes with it).
    id: u32,
};

pub const DebugHover = struct {
    gpa: Allocator,
    win: ?*Window = null,
    tree: VarTree = undefined,
    timer: Window.TimerId = .none,
    /// Where the pointer rests: evaluated at `due_ms`.
    rest: ?Spot = null,
    /// The spot asked about (answers for another are dropped).
    asked: ?Spot = null,
    token: u64 = 0,
    /// What is shown.
    shown: ?Spot = null,
    value: []u8 = &.{},
    type: ?[]u8 = null,
    hide_due_ms: ?u64 = null,
    overlay: OverlayId = .none,
    /// The popover takes focus (opened from the keyboard).
    focus: bool = false,
    /// Where the timer finds the paused session (set by the owner).
    target_of: ?*const fn (h: *DebugHover) ?Target = null,
    /// The popover's view (its own type: a view's `deinit` runs when its
    /// node goes).
    pop: Pop = .{},

    const Pop = struct {
        pub fn build(p: *Pop, ui: *zg_gui.Ui) void {
            const h: *DebugHover = @alignCast(@fieldParentPtr("pop", p));
            h.buildPopover(ui);
        }
    };

    /// An expression in an editor.
    pub const Spot = struct {
        /// The editor (identity only).
        view: *const anyopaque,
        range: Range,
        expr: []u8,
        /// Where it is in the window.
        anchor: Rect,
        session: u32 = 0,
        /// The stop it was evaluated at.
        gen: u64 = 0,
        due_ms: u64 = 0,

        fn same(s: Spot, view: *const anyopaque, r: Range) bool {
            return s.view == view and s.range.start == r.start and s.range.end == r.end;
        }
    };

    /// `h` must not move afterwards.
    pub fn init(h: *DebugHover, gpa: Allocator, hooks: var_tree.Hooks) !void {
        h.* = .{ .gpa = gpa };
        try h.tree.init(gpa, .hover, hooks);
    }

    pub fn deinit(h: *DebugHover) void {
        h.hide();
        h.cancelTimer();
        h.tree.deinit();
        h.freeShown();
        if (h.rest) |s| h.gpa.free(s.expr);
        if (h.asked) |s| h.gpa.free(s.expr);
    }

    fn freeShown(h: *DebugHover) void {
        if (h.shown) |s| h.gpa.free(s.expr);
        h.shown = null;
        h.gpa.free(h.value);
        h.value = &.{};
        if (h.type) |t| h.gpa.free(t);
        h.type = null;
        h.tree.hover_root = null;
    }

    pub fn isOpen(h: *const DebugHover) bool {
        const w = h.win orelse return false;
        return h.overlay != .none and w.isOverlayOpen(h.overlay);
    }

    /// Whether the hover holds the pointer (resting, asking or shown).
    pub fn busy(h: *const DebugHover) bool {
        return h.rest != null or h.asked != null or h.isOpen();
    }

    /// The pointer rests on `range` of `view` (`expr` its text, `anchor`
    /// its place in the window) at `now_ms`: evaluated after the delay,
    /// unless it is what is shown or asked already.
    pub fn restOn(h: *DebugHover, view: *const anyopaque, range: Range, expr: []const u8, anchor: Rect, now_ms: u64) void {
        h.hide_due_ms = null;
        if (h.shown) |s| if (s.same(view, range) and h.isOpen()) return;
        if (h.asked) |s| if (s.same(view, range)) return;
        if (h.rest) |s| if (s.same(view, range)) return;
        h.hide();
        h.dropAsked();
        h.dropRest();
        const copy = h.gpa.dupe(u8, expr) catch return;
        h.rest = .{ .view = view, .range = range, .expr = copy, .anchor = anchor, .due_ms = now_ms + delay_ms };
        h.arm(now_ms);
    }

    /// The pointer is off any expression (or left the editor): what is
    /// shown goes after the grace.
    pub fn away(h: *DebugHover, now_ms: u64) void {
        h.dropRest();
        h.dropAsked();
        if (h.isOpen() and h.hide_due_ms == null) {
            h.hide_due_ms = now_ms + grace_ms;
            h.arm(now_ms);
        }
    }

    /// Evaluates `range` of `view` now (the keyboard: the popover takes
    /// focus).
    pub fn showNow(h: *DebugHover, t: Target, view: *const anyopaque, range: Range, expr: []const u8, anchor: Rect) void {
        h.hide();
        h.dropAsked();
        h.dropRest();
        const copy = h.gpa.dupe(u8, expr) catch return;
        h.focus = true;
        h.ask(t, .{ .view = view, .range = range, .expr = copy, .anchor = anchor });
    }

    fn dropRest(h: *DebugHover) void {
        if (h.rest) |s| h.gpa.free(s.expr);
        h.rest = null;
    }

    fn dropAsked(h: *DebugHover) void {
        if (h.asked) |s| h.gpa.free(s.expr);
        h.asked = null;
        h.token += 1;
    }

    fn arm(h: *DebugHover, now_ms: u64) void {
        h.cancelTimer();
        const w = h.win orelse return;
        var due: ?u64 = null;
        if (h.rest) |s| due = s.due_ms;
        if (h.hide_due_ms) |d| due = if (due) |x| @min(x, d) else d;
        const at = due orelse return;
        h.timer = w.setTimer(@max(at, now_ms + 1), .{ .ctx = h, .f = onTimer }) catch .none;
    }

    fn cancelTimer(h: *DebugHover) void {
        if (h.timer == .none) return;
        if (h.win) |w| w.cancelTimer(h.timer);
        h.timer = .none;
    }

    fn onTimer(ctx: *anyopaque, w: *Window) void {
        const h: *DebugHover = @ptrCast(@alignCast(ctx));
        h.timer = .none;
        h.tick(w.app.now_ms, if (h.target_of) |f| f(h) else null);
    }

    /// Due work at `now_ms`: the rest's evaluation (with `t`), the
    /// grace's end.
    pub fn tick(h: *DebugHover, now_ms: u64, t: ?Target) void {
        if (h.rest) |s| if (now_ms >= s.due_ms) {
            h.rest = null;
            if (t) |x| {
                h.focus = false;
                h.ask(x, s);
            } else h.gpa.free(s.expr);
        };
        if (h.hide_due_ms) |d| if (now_ms >= d) {
            h.hide_due_ms = null;
            const over = if (h.win) |w| h.contains(w.hot) else false;
            if (over) h.hide_due_ms = now_ms + grace_ms else h.hide();
        };
        h.arm(now_ms);
    }

    fn ask(h: *DebugHover, t: Target, spot: Spot) void {
        var s = spot;
        s.session = t.id;
        s.gen = t.insp.liveGen() orelse {
            h.gpa.free(s.expr);
            return;
        };
        h.asked = s;
        h.token += 1;
        const frame = t.insp.vars.frame_id;
        t.insp.eval.evaluate(s.expr, .hover, frame, .{ .ctx = h, .user = h.token, .func = onResult });
    }

    fn onResult(ctx: ?*anyopaque, token: u64, r: *const Evaluator.EvalResult) void {
        const h: *DebugHover = @ptrCast(@alignCast(ctx.?));
        if (token != h.token) return;
        const s = h.asked orelse return;
        h.asked = null;
        if (r.err) return h.gpa.free(s.expr);
        h.show(s, r) catch {
            h.freeShown();
            h.hide();
        };
    }

    fn show(h: *DebugHover, s: Spot, r: *const Evaluator.EvalResult) !void {
        h.hide();
        h.freeShown();
        h.shown = s;
        h.value = try h.gpa.dupe(u8, r.value);
        if (r.type) |t| if (t.len > 0) {
            h.type = try h.gpa.dupe(u8, t);
        };
        h.tree.hover_root = .{ .expr = s.expr, .value = h.value, .type = h.type, .node = r.node };
        // `update` follows from the owner (`refresh`), with the models.
        const w = h.win orelse return;
        h.overlay = try w.openOverlay(.of(&h.pop), .{
            .layer = .popover,
            .anchor = .{ .rect = s.anchor },
            .placement = .{ .side = .above, .alignment = .start, .gap = 2 },
            .light_dismiss = true,
            .consume_outside_click = false,
            .take_focus = h.focus,
            .restore_focus = h.focus,
            .role = .tooltip,
            .label = "Debug Hover",
            .test_id = "debug-hover",
            .on_close = .{ .ctx = h, .f = onClose },
        });
        w.markAllDirty();
    }

    /// Re-reads the models after they changed; hides when the session
    /// `t` (the active, paused one) is not the one shown or ran since.
    pub fn refresh(h: *DebugHover, t: ?Target) void {
        const s = h.shown orelse return;
        const x = t orelse return h.close();
        if (x.id != s.session or x.insp.liveGen() != s.gen) return h.close();
        h.tree.update(x.insp) catch {};
    }

    /// Hides it and forgets what was asked (the session ended or ran).
    pub fn close(h: *DebugHover) void {
        h.dropRest();
        h.dropAsked();
        h.hide();
        h.freeShown();
        h.tree.update(null) catch {};
    }

    /// Closes the popover (what was shown stays until replaced).
    pub fn hide(h: *DebugHover) void {
        h.hide_due_ms = null;
        const w = h.win orelse return;
        if (h.overlay == .none) return;
        const id = h.overlay;
        h.overlay = .none;
        w.closeOverlay(id);
    }

    /// Whether `n` is inside the popover.
    pub fn contains(h: *const DebugHover, n: zg_gui.core.NodeId) bool {
        const w = h.win orelse return false;
        if (n.isNone() or h.overlay == .none) return false;
        const i = w.overlays.indexOf(h.overlay) orelse return false;
        const panel = w.overlays.items.items[i].panel;
        return !panel.isNone() and w.store.valid(panel) and w.store.valid(n) and (panel.eql(n) or w.store.isAncestor(panel, n));
    }

    fn onClose(ctx: *anyopaque, id: OverlayId) void {
        const h: *DebugHover = @ptrCast(@alignCast(ctx));
        if (h.overlay == id) h.overlay = .none;
    }

    fn buildPopover(h: *DebugHover, ui: *zg_gui.Ui) void {
        const rows: f32 = @floatFromInt(@min(@max(h.tree.tv.flat.len(), 1), max_rows));
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .px = width }, .h = .{ .px = rows * h.tree.tv.props.row_h + 4 } } });
        defer ui.close();
        h.tree.build(ui);
        if (h.focus) {
            h.focus = false;
            ui.window().afterNextFrame(.{ .ctx = h, .f = focusTree });
        }
    }

    fn focusTree(ctx: *anyopaque, w: *Window) void {
        const h: *DebugHover = @ptrCast(@alignCast(ctx));
        h.tree.focus(w);
    }
};

test "hover: expression extent through member access and index" {
    const testing = std.testing;
    const Case = struct { text: []const u8, at: usize, want: ?[]const u8 };
    const cases = [_]Case{
        .{ .text = "x = foo + 1", .at = 5, .want = "foo" },
        .{ .text = "a.b.c = 1", .at = 4, .want = "a.b.c" },
        .{ .text = "a.b.c = 1", .at = 2, .want = "a.b" },
        .{ .text = "a.b.c = 1", .at = 0, .want = "a" },
        .{ .text = "p->next->val", .at = 10, .want = "p->next->val" },
        .{ .text = "xs[i + 1].len", .at = 11, .want = "xs[i + 1].len" },
        .{ .text = "m[0][1].v", .at = 8, .want = "m[0][1].v" },
        .{ .text = "xs[idx]", .at = 4, .want = "idx" },
        // Calls are left out.
        .{ .text = "f(x).y", .at = 5, .want = "y" },
        .{ .text = "n = 42", .at = 4, .want = null },
        .{ .text = "a + b", .at = 2, .want = null },
        .{ .text = "  ", .at = 5, .want = null },
    };
    for (cases) |c| {
        const r = expressionIn(c.text, c.at);
        if (c.want) |w| {
            try testing.expect(r != null);
            try testing.expectEqualStrings(w, c.text[r.?[0]..r.?[1]]);
        } else try testing.expect(r == null);
    }
}
