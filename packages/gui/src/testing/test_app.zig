//! `TestApp`: drives a window headlessly for tests and agents. It uses
//! `MonoText` (deterministic metrics) and a recording canvas, so layout
//! and paint snapshots are identical on every OS.

const std = @import("std");
const zg_platform = @import("zg_platform");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const widget = @import("../core/widget.zig");
const view_mod = @import("../core/view.zig");
const app_mod = @import("../core/app.zig");
const window_mod = @import("../core/window.zig");
const canvas = @import("../paint/canvas.zig");
const text = @import("../paint/text.zig");
const event = @import("../input/event.zig");

const NodeId = ids.NodeId;
const Rect = geom.Rect;
const Window = window_mod.Window;

/// Selects nodes; every set field must match.
pub const Query = struct {
    role: ?widget.Role = null,
    /// Accessible name, exact match.
    name: ?[]const u8 = null,
    /// `BoxDesc.test_id`.
    test_id: ?[]const u8 = null,
    /// Widget kind name ("button", "text", ...).
    kind: ?[]const u8 = null,
    /// Accessible name, substring match.
    name_contains: ?[]const u8 = null,
    /// Only below this node.
    within: ?NodeId = null,
};

/// A headless app with one window.
pub const TestApp = struct {
    gpa: std.mem.Allocator,
    app: app_mod.App,
    win: *Window,
    mono: text.MonoText = .{},
    rec: canvas.Recorder,

    /// Options for `init`.
    pub const Options = struct {
        size: geom.Size = .{ .w = 800, .h = 600 },
        scale: f32 = 1,
        root: ?view_mod.AnyView = null,
    };

    /// A test app showing `opts.root`.
    pub fn init(gpa: std.mem.Allocator, opts: Options) !*TestApp {
        const t = try gpa.create(TestApp);
        errdefer gpa.destroy(t);
        t.* = .{ .gpa = gpa, .app = app_mod.App.init(gpa), .win = undefined, .rec = .init(gpa) };
        errdefer t.app.deinit();
        t.win = try t.app.openWindow(.{ .size = opts.size, .scale = opts.scale, .root = opts.root, .text = t.mono.system(), .canvas = t.rec.canvas() });
        return t;
    }

    /// Frees everything.
    pub fn deinit(t: *TestApp) void {
        t.app.deinit();
        t.rec.deinit();
        t.gpa.destroy(t);
    }

    /// Runs one frame.
    pub fn frame(t: *TestApp) window_mod.FrameStats {
        return t.win.frame();
    }

    /// Runs frames until one is idle (at most 8), running posted calls
    /// first; returns how many did work.
    pub fn settle(t: *TestApp) u32 {
        var n: u32 = 0;
        while (n < 8) : (n += 1) {
            _ = t.app.drainMessages();
            if (t.win.frame().idle) break;
        }
        return n;
    }

    fn matches(t: *TestApp, n: NodeId, q: Query) bool {
        const s = &t.win.store;
        const vt = widget.vtable(s.hot.items(.kind)[n.index]);
        if (q.kind) |k| if (!std.mem.eql(u8, k, vt.name)) return false;
        if (q.test_id) |tid| if (s.coldOf(n).test_id != std.hash.Wyhash.hash(0, tid)) return false;
        if (q.role != null or q.name != null or q.name_contains != null) {
            const info = t.a11yOf(n) orelse return false;
            if (q.role) |r| if (info.role != r) return false;
            if (q.name) |nm| if (!std.mem.eql(u8, nm, info.name)) return false;
            if (q.name_contains) |nm| if (std.mem.indexOf(u8, info.name, nm) == null) return false;
        }
        return true;
    }

    /// What node `n` exposes to assistive technology, if anything.
    pub fn a11yOf(t: *TestApp, n: NodeId) ?widget.A11y {
        const s = &t.win.store;
        const vt = widget.vtable(s.hot.items(.kind)[n.index]);
        const f = vt.a11y orelse return null;
        const props = s.props(n) orelse return null;
        const st: *anyopaque = s.hot.items(.state)[n.index] orelse @ptrCast(&dummy);
        return f(props, st);
    }

    /// The widget kind name of `n`.
    pub fn kindOf(t: *TestApp, n: NodeId) []const u8 {
        return widget.vtable(t.win.store.hot.items(.kind)[n.index]).name;
    }

    var dummy: u8 = 0;

    /// The first node in tree order matching `q`.
    pub fn find(t: *TestApp, q: Query) ?NodeId {
        return t.findNth(q, 0);
    }

    /// The `nth` (from 0) node in tree order matching `q`.
    pub fn findNth(t: *TestApp, q: Query, nth: usize) ?NodeId {
        var left = nth;
        return t.findFrom(q.within orelse t.win.root, q, &left);
    }

    fn findFrom(t: *TestApp, n: NodeId, q: Query, left: *usize) ?NodeId {
        if (t.win.store.flags(n).hidden) return null;
        if (t.matches(n, q)) {
            if (left.* == 0) return n;
            left.* -= 1;
        }
        var it = t.win.store.children(n);
        while (it.next()) |c| {
            if (t.findFrom(c, q, left)) |r| return r;
        }
        return null;
    }

    /// How many visible nodes match `q`.
    pub fn count(t: *TestApp, q: Query) usize {
        return t.countFrom(q.within orelse t.win.root, q);
    }

    fn countFrom(t: *TestApp, n: NodeId, q: Query) usize {
        if (t.win.store.flags(n).hidden) return 0;
        var c: usize = if (t.matches(n, q)) 1 else 0;
        var it = t.win.store.children(n);
        while (it.next()) |k| c += t.countFrom(k, q);
        return c;
    }

    /// The absolute rectangle of the node matching `q`.
    pub fn rectOf(t: *TestApp, q: Query) !Rect {
        const n = t.find(q) orelse return error.NotFound;
        return t.win.store.absRect(n);
    }

    fn center(r: Rect) geom.Vec2 {
        return .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
    }

    /// Double-clicks the centre of the node matching `q` and settles.
    pub fn doubleClick(t: *TestApp, q: Query) !void {
        const p = center(try t.rectOf(q));
        t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        t.win.dispatch(.{ .pointer_down = .{ .pos = p } });
        t.win.dispatch(.{ .pointer_up = .{ .pos = p } });
        t.win.dispatch(.{ .pointer_down = .{ .pos = p, .clicks = 2 } });
        t.win.dispatch(.{ .pointer_up = .{ .pos = p, .clicks = 2 } });
        _ = t.settle();
    }

    /// Scrolls by `dx`, `dy` pixels over the node matching `q`.
    pub fn scroll(t: *TestApp, q: Query, dx: f32, dy: f32) !void {
        const p = center(try t.rectOf(q));
        t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        t.win.dispatch(.{ .scroll = .{ .pos = p, .dx = dx, .dy = dy, .precise = true } });
        _ = t.settle();
    }

    /// Presses the node matching `q`, moves to `to` in four steps (frames
    /// in between) and releases there.
    pub fn drag(t: *TestApp, q: Query, to: geom.Vec2) !void {
        const p = center(try t.rectOf(q));
        t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        t.win.dispatch(.{ .pointer_down = .{ .pos = p } });
        var i: f32 = 1;
        while (i <= 4) : (i += 1) {
            t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = p.x + (to.x - p.x) * i / 4, .y = p.y + (to.y - p.y) * i / 4 } } });
            _ = t.settle();
        }
        t.win.dispatch(.{ .pointer_up = .{ .pos = to } });
        _ = t.settle();
    }

    /// Advances the app clock by `ms`, runs due timers and settles.
    pub fn advance(t: *TestApp, ms: u64) void {
        t.app.now_ms += ms;
        t.win.tick(t.app.now_ms);
        _ = t.settle();
    }

    /// Moves the pointer to `p` and settles.
    pub fn moveTo(t: *TestApp, p: geom.Vec2) void {
        t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        _ = t.settle();
    }

    /// Right-clicks the centre of the node matching `q` and settles.
    pub fn rightClick(t: *TestApp, q: Query) !void {
        const p = center(try t.rectOf(q));
        t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        t.win.dispatch(.{ .pointer_down = .{ .pos = p, .button = .right } });
        t.win.dispatch(.{ .pointer_up = .{ .pos = p, .button = .right } });
        _ = t.settle();
    }

    /// Moves the pointer over the node matching `q`.
    pub fn hover(t: *TestApp, q: Query) !void {
        const p = center(try t.rectOf(q));
        t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        _ = t.settle();
    }

    /// Clicks the centre of the node matching `q` and settles.
    pub fn click(t: *TestApp, q: Query) !void {
        const p = center(try t.rectOf(q));
        t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
        t.win.dispatch(.{ .pointer_down = .{ .pos = p } });
        t.win.dispatch(.{ .pointer_up = .{ .pos = p } });
        _ = t.settle();
    }

    /// Presses and releases `key` and settles.
    pub fn press(t: *TestApp, key: zg_platform.keys.Key, mods: zg_platform.keys.Mods) void {
        t.win.dispatch(.{ .key = .{ .key = key, .mods = mods } });
        t.win.dispatch(.{ .key = .{ .key = key, .mods = mods, .action = .release } });
        _ = t.settle();
    }

    /// Types `s` into the focused node and settles.
    pub fn typeText(t: *TestApp, s: []const u8) void {
        t.win.dispatch(.{ .text = s });
        _ = t.settle();
    }

    /// Sends an IME composition (`s` with target clause
    /// `[begin, end)`; empty ends it) to the focused node and settles.
    pub fn imeCompose(t: *TestApp, s: []const u8, begin: i32, end: i32) void {
        t.win.dispatch(.{ .ime_preedit = .{ .text = s, .cursor_begin = begin, .cursor_end = end } });
        _ = t.settle();
    }

    /// Sends an IME delete-surrounding request to the focused node and
    /// settles.
    pub fn imeDeleteSurrounding(t: *TestApp, before: u32, after: u32) void {
        t.win.dispatch(.{ .ime_delete_surrounding = .{ .before = before, .after = after } });
        _ = t.settle();
    }

    /// The tree as indented lines `kind "name" x,y wxh` (visible nodes).
    pub fn layoutSnapshot(t: *TestApp, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try t.snap(gpa, &out, t.win.root, 0);
        return out.toOwnedSlice(gpa);
    }

    fn snap(t: *TestApp, gpa: std.mem.Allocator, out: *std.ArrayList(u8), n: NodeId, depth: usize) !void {
        const s = &t.win.store;
        if (s.flags(n).hidden) return;
        const vt = widget.vtable(s.hot.items(.kind)[n.index]);
        try out.appendNTimes(gpa, ' ', depth * 2);
        try out.appendSlice(gpa, vt.name);
        if (vt.a11y) |f| if (s.props(n)) |props| {
            const st: *anyopaque = s.hot.items(.state)[n.index] orelse @ptrCast(&dummy);
            const info = f(props, st);
            if (info.name.len > 0) try out.print(gpa, " \"{s}\"", .{info.name});
            if (info.checked) |c| try out.print(gpa, " checked={}", .{c});
        };
        try out.print(gpa, " {f}\n", .{canvas.fmtRect(s.absRect(n))});
        var it = s.children(n);
        while (it.next()) |c| try t.snap(gpa, out, c, depth + 1);
    }

    /// The accessibility tree as indented lines `role "name" states`
    /// (nodes with a role; others are skipped and their children lifted).
    pub fn semanticsSnapshot(t: *TestApp, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try t.sem(gpa, &out, t.win.root, 0);
        return out.toOwnedSlice(gpa);
    }

    fn sem(t: *TestApp, gpa: std.mem.Allocator, out: *std.ArrayList(u8), n: NodeId, depth: usize) !void {
        const s = &t.win.store;
        if (s.flags(n).hidden) return;
        var d = depth;
        if (t.a11yOf(n)) |info| if (info.role != .none) {
            try out.appendNTimes(gpa, ' ', depth * 2);
            try out.print(gpa, "{t}", .{info.role});
            if (info.name.len > 0) try out.print(gpa, " \"{s}\"", .{info.name});
            if (info.text.len > 0) try out.print(gpa, " text=\"{s}\"", .{info.text});
            if (info.checked) |c| try out.print(gpa, " checked={}", .{c});
            if (info.value) |v| try out.print(gpa, " value={d:.2}", .{v});
            if (info.expanded) |e| try out.print(gpa, " expanded={}", .{e});
            if (info.selected) |e| if (e) try out.appendSlice(gpa, " selected");
            if (info.level > 0) try out.print(gpa, " level={d}", .{info.level});
            if (info.disabled) try out.appendSlice(gpa, " disabled");
            if (t.win.focus == n) try out.appendSlice(gpa, " focused");
            try out.append(gpa, '\n');
            d += 1;
        };
        var it = s.children(n);
        while (it.next()) |c| try t.sem(gpa, out, c, d);
    }

    /// The recorded text of the last presented frame.
    pub fn paintSnapshot(t: *TestApp) []const u8 {
        return t.rec.text();
    }
};

test {
    std.testing.refAllDecls(@This());
}
