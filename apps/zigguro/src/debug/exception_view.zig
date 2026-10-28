//! The exception widget (E07.F07.S01.T04): when the program stopped on
//! an exception, rows under the line its thread stopped at say what it
//! was (zg_dap's `Inspector.exception`): the type or id in the error
//! colour, the description and message, inner exceptions and the stack
//! trace, with a close box. It is a block decoration (owner
//! `dap.exception`) painted here; it goes when the program runs, and
//! Close hides it until the next stop.
//!
//! UI thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_dap = @import("zg_dap");
const zg_editor = @import("zg_editor");

const Allocator = std.mem.Allocator;
const EditorView = zg_editor.view.EditorView;
const BlockInfo = zg_editor.view.editor_view.BlockInfo;
const store = zg_editor.model.decorations.store;
const DecorationStore = store.DecorationStore;
const Exception = zg_dap.inspect.exception.Exception;

/// Most rows the widget takes.
pub const max_rows = 12;
/// The close box's width, at the first row's right end.
const close_w: f32 = 24;

pub const Tone = enum { title, text, muted };
pub const Line = struct { text: []const u8, tone: Tone };

/// The widget's rows for `e` (in `a`).
pub fn linesOf(a: Allocator, e: *const Exception) Allocator.Error![]Line {
    var out: std.ArrayList(Line) = .empty;
    const head = if (!e.signal)
        try std.fmt.allocPrint(a, "Exception has occurred: {s}", .{e.title()})
    else if (std.mem.eql(u8, e.id, "signal"))
        "The program received a signal"
    else
        try std.fmt.allocPrint(a, "Signal received: {s}", .{e.title()});
    try out.append(a, .{ .text = head, .tone = .title });
    const add = struct {
        fn f(al: Allocator, list: *std.ArrayList(Line), text: []const u8, tone: Tone) Allocator.Error!void {
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |l| {
                if (list.items.len >= max_rows) return;
                const t = std.mem.trimEnd(u8, l, "\r");
                if (t.len == 0) continue;
                try list.append(al, .{ .text = t, .tone = tone });
            }
        }
    }.f;
    if (e.description) |d| if (!std.mem.eql(u8, d, e.title())) try add(a, &out, d, .text);
    if (e.message) |m| if (e.description == null or !std.mem.eql(u8, m, e.description.?)) try add(a, &out, m, .text);
    for (e.inner) |x| try add(a, &out, try std.fmt.allocPrint(a, "Inner: {s}", .{x}), .text);
    if (e.stack_trace) |s| try add(a, &out, s, .muted);
    return out.items;
}

pub const ExceptionView = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    lines: []Line = &.{},
    /// Where it shows: the editor, its decorations and the 0-based line.
    at: ?At = null,
    /// The stop it shows (session id and generation); a closed one stays
    /// closed.
    stop: ?Stop = null,
    closed: ?Stop = null,
    /// The close box, in the block's coordinates (from the last paint).
    close_x: f32 = 0,

    pub const Stop = struct { session: u32, gen: u64 };
    const At = struct { view: *EditorView, deco: *DecorationStore, owner: store.OwnerId, line: u64 };

    pub fn init(gpa: Allocator) ExceptionView {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(ev: *ExceptionView) void {
        ev.detach();
        ev.arena.deinit();
    }

    /// Whether it shows.
    pub fn shown(ev: *const ExceptionView) bool {
        return ev.at != null;
    }

    /// Shows `e` (of stop `stop`) under 0-based `line` of `view`, whose
    /// decorations are `deco`; null hides it.
    pub fn apply(ev: *ExceptionView, e: ?*const Exception, stop: Stop, view: ?*EditorView, deco: ?*DecorationStore, line: u64) void {
        const x = e orelse return ev.hide();
        const v = view orelse return ev.hide();
        const d = deco orelse return ev.hide();
        if (ev.closed) |c| if (std.meta.eql(c, stop)) return ev.hide();
        if (ev.at) |at| if (at.view == v and at.deco == d and at.line == line) if (ev.stop) |s| if (std.meta.eql(s, stop)) return;
        ev.detach();
        _ = ev.arena.reset(.retain_capacity);
        ev.lines = linesOf(ev.arena.allocator(), x) catch return;
        ev.stop = stop;
        const owner = d.ownerByName("dap.exception") orelse d.registerOwner("dap.exception", 6) catch return;
        if (!v.setOwnerPainter(owner, .{ .ctx = ev, .paint = paint })) return;
        const doc = v.doc;
        const l = @min(line, doc.tree.lineCount() -| 1);
        const start = doc.tree.lineStart(l);
        const one: [1]store.Decoration = .{.{
            .range = .{ .start = start, .end = start },
            .owner = owner,
            .stick = .point_left,
            .kind = .{ .block_below = .{ .rows = @intCast(ev.lines.len), .payload = 0 } },
        }};
        d.setOwnerDecorations(owner, doc.version, &one) catch {
            _ = v.setOwnerPainter(owner, null);
            return;
        };
        ev.at = .{ .view = v, .deco = d, .owner = owner, .line = l };
    }

    /// Hides it (the program runs, or nothing to show).
    pub fn hide(ev: *ExceptionView) void {
        ev.detach();
        ev.stop = null;
    }

    fn detach(ev: *ExceptionView) void {
        const at = ev.at orelse return;
        ev.at = null;
        at.deco.clearOwner(at.owner);
        _ = at.view.setOwnerPainter(at.owner, null);
    }

    /// `view` closes.
    pub fn forget(ev: *ExceptionView, view: *EditorView) void {
        if (ev.at) |at| if (at.view == view) ev.detach();
    }

    /// Close: hidden until the next stop.
    pub fn close(ev: *ExceptionView) void {
        ev.closed = ev.stop;
        ev.hide();
    }

    /// A click on a block row of `view` at `x` from its left: true when
    /// it was on the widget (the close box closes it).
    pub fn click(ev: *ExceptionView, view: *EditorView, b: BlockInfo, x: f32) bool {
        const at = ev.at orelse return false;
        if (at.view != view or b.owner != at.owner) return false;
        if (x >= ev.close_x) ev.close();
        return true;
    }

    fn paint(ctx: ?*anyopaque, pc: *zg_gui.paint.PaintCx, rect: zg_gui.core.Rect, b: BlockInfo) void {
        const ev: *ExceptionView = @ptrCast(@alignCast(ctx.?));
        _ = b;
        const at = ev.at orelse return;
        const v = at.view;
        const st = v.textStyle();
        const m = pc.text_sys.metrics(st);
        const lh = v.lineHeight();
        const base = (lh - (m.ascent + m.descent)) / 2 + m.ascent;
        const box: zg_gui.core.Rect = .{ .x = rect.x + 2, .y = rect.y, .w = @max(0, rect.w - 4), .h = rect.h };
        pc.fill(box, .bg_elevated, 2);
        const danger = pc.color(.danger);
        pc.rect(.{ .x = box.x, .y = box.y, .w = 3, .h = box.h }, danger, .{});
        for (ev.lines, 0..) |l, i| {
            const y = rect.y + @as(f32, @floatFromInt(i)) * lh + base;
            const color = switch (l.tone) {
                .title => danger,
                .text => pc.color(.fg),
                .muted => pc.color(.fg_muted),
            };
            pc.textLine(l.text, st, color, .{ .x = box.x + 10, .y = y });
        }
        // Close, at the first row's right end.
        ev.close_x = box.x + box.w - close_w - rect.x;
        pc.textLine("\u{00D7}", st, pc.color(.fg_muted), .{ .x = box.x + box.w - close_w + 6, .y = rect.y + base });
    }
};

test "exception view: rows from the exception" {
    const testing = std.testing;
    var e = try zg_dap.inspect.exception.parse(testing.allocator, 1,
        \\{"exceptionId":"SIGSEGV","description":"Segmentation fault","details":{"message":"address 0x0","stackTrace":"f\nmain\n"}}
    );
    defer e.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const ls = try linesOf(arena.allocator(), &e);
    try testing.expectEqual(@as(usize, 5), ls.len);
    try testing.expectEqualStrings("Exception has occurred: SIGSEGV", ls[0].text);
    try testing.expectEqual(Tone.title, ls[0].tone);
    try testing.expectEqualStrings("Segmentation fault", ls[1].text);
    try testing.expectEqualStrings("address 0x0", ls[2].text);
    try testing.expectEqualStrings("f", ls[3].text);
    try testing.expectEqual(Tone.muted, ls[4].tone);
}
