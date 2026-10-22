//! Flexbox, stack and absolute layout cases (E04.F02.S01.T01). Each case
//! builds a container and checks children rects relative to it; expected
//! values follow the normative text of CSS Flexbox §9.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const geom = @import("../core/geom.zig");
const style_mod = @import("style.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Style = style_mod.Style;
const Rect = geom.Rect;

const Node = struct {
    id: []const u8 = "",
    style: Style = .{},
    text: ?[]const u8 = null,
    kids: []const Node = &.{},
};

const TreeView = struct {
    root: Node,

    fn emit(ui: *ui_mod.Ui, n: Node) void {
        if (n.text) |s| {
            ui.with(.{ .grow = n.style.grow, .align_self = n.style.align_self });
            ui.text(s, .{});
            return;
        }
        ui.open(.{ .style = n.style, .test_id = n.id });
        for (n.kids) |k| emit(ui, k);
        ui.close();
    }

    pub fn build(self: *TreeView, ui: *ui_mod.Ui) void {
        emit(ui, self.root);
    }
};

const Expect = struct { id: []const u8, r: Rect };

fn check(root: Node, expect: []const Expect) !void {
    var v: TreeView = .{ .root = root };
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.settle();
    const base = try t.rectOf(.{ .test_id = root.id });
    for (expect) |e| {
        const r = t.rectOf(.{ .test_id = e.id }) catch |err| {
            std.debug.print("missing node {s}\n", .{e.id});
            return err;
        };
        const rel = r.translate(.{ .x = -base.x, .y = -base.y });
        if (@abs(rel.x - e.r.x) > 0.01 or @abs(rel.y - e.r.y) > 0.01 or @abs(rel.w - e.r.w) > 0.01 or @abs(rel.h - e.r.h) > 0.01) {
            std.debug.print("node {s}: expected {any}, got {any}\n", .{ e.id, e.r, rel });
            return error.LayoutMismatch;
        }
    }
}

fn box(id: []const u8, st: Style) Node {
    return .{ .id = id, .style = st };
}

fn px(v: f32) style_mod.Dim {
    return .{ .px = v };
}

fn R(x: f32, y: f32, w: f32, h: f32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

const row300: Style = .{ .w = .{ .px = 300 }, .h = .{ .px = 100 } };

fn with(base: Style, comptime f: anytype) Style {
    var s = base;
    f(&s);
    return s;
}

test "flex: equal grow fills and stretches" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .grow = 1 }), box("b", .{ .grow = 1 }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 150, 100) },
        .{ .id = "b", .r = R(150, 0, 150, 100) },
    });
}

test "flex: grow ratio with zero basis" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .grow = 1, .basis = px(0) }), box("b", .{ .grow = 2, .basis = px(0) }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 100, 100) },
        .{ .id = "b", .r = R(100, 0, 200, 100) },
    });
}

test "flex: fixed plus grow" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .w = px(100) }), box("b", .{ .grow = 1 }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 100, 100) },
        .{ .id = "b", .r = R(100, 0, 200, 100) },
    });
}

test "flex: equal shrink" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .w = px(200) }), box("b", .{ .w = px(200) }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 150, 100) },
        .{ .id = "b", .r = R(150, 0, 150, 100) },
    });
}

test "flex: shrink scaled by base size" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .w = px(100) }), box("b", .{ .w = px(300) }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 75, 100) },
        .{ .id = "b", .r = R(75, 0, 225, 100) },
    });
}

test "flex: min violation freezes and redistributes" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .w = px(200), .min_w = 180 }), box("b", .{ .w = px(200) }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 180, 100) },
        .{ .id = "b", .r = R(180, 0, 120, 100) },
    });
}

test "flex: max violation freezes and redistributes" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .grow = 1, .max_w = 50 }), box("b", .{ .grow = 1 }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 50, 100) },
        .{ .id = "b", .r = R(50, 0, 250, 100) },
    });
}

test "flex: no shrink overflows" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .w = px(200), .shrink = 0 }), box("b", .{ .w = px(200), .shrink = 0 }) } }, &.{
        .{ .id = "b", .r = R(200, 0, 200, 100) },
    });
}

test "flex: justify start/center/end" {
    inline for (.{ .{ style_mod.Justify.start, 0 }, .{ style_mod.Justify.center, 125 }, .{ style_mod.Justify.end, 250 } }) |c| {
        var st = row300;
        st.justify = c[0];
        try check(.{ .id = "c", .style = st, .kids = &.{box("a", .{ .w = px(50) })} }, &.{.{ .id = "a", .r = R(c[1], 0, 50, 100) }});
    }
}

test "flex: justify space_between" {
    var st = row300;
    st.justify = .space_between;
    try check(.{ .id = "c", .style = st, .kids = &.{ box("a", .{ .w = px(50) }), box("b", .{ .w = px(50) }), box("d", .{ .w = px(50) }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 50, 100) },
        .{ .id = "b", .r = R(125, 0, 50, 100) },
        .{ .id = "d", .r = R(250, 0, 50, 100) },
    });
}

test "flex: justify space_around and space_evenly" {
    var st = row300;
    st.justify = .space_around;
    try check(.{ .id = "c", .style = st, .kids = &.{ box("a", .{ .w = px(50) }), box("b", .{ .w = px(50) }) } }, &.{
        .{ .id = "a", .r = R(50, 0, 50, 100) },
        .{ .id = "b", .r = R(200, 0, 50, 100) },
    });
    st.justify = .space_evenly;
    try check(.{ .id = "c", .style = st, .kids = &.{ box("a", .{ .w = px(50) }), box("b", .{ .w = px(50) }) } }, &.{
        .{ .id = "a", .r = R(200.0 / 3.0, 0, 50, 100) },
        .{ .id = "b", .r = R(400.0 / 3.0 + 50, 0, 50, 100) },
    });
}

test "flex: justify with free space negative starts at 0" {
    var st = row300;
    st.justify = .center;
    try check(.{ .id = "c", .style = st, .kids = &.{box("a", .{ .w = px(400), .shrink = 0 })} }, &.{.{ .id = "a", .r = R(0, 0, 400, 100) }});
}

test "flex: align items start/center/end/stretch" {
    inline for (.{ .{ style_mod.Align.start, 0, 20 }, .{ style_mod.Align.center, 40, 20 }, .{ style_mod.Align.end, 80, 20 } }) |c| {
        var st = row300;
        st.align_items = c[0];
        try check(.{ .id = "c", .style = st, .kids = &.{box("a", .{ .w = px(50), .h = px(20) })} }, &.{.{ .id = "a", .r = R(0, c[1], 50, c[2]) }});
    }
    try check(.{ .id = "c", .style = row300, .kids = &.{box("a", .{ .w = px(50) })} }, &.{.{ .id = "a", .r = R(0, 0, 50, 100) }});
}

test "flex: align self overrides align items" {
    var st = row300;
    st.align_items = .start;
    try check(.{ .id = "c", .style = st, .kids = &.{ box("a", .{ .w = px(50), .h = px(20) }), box("b", .{ .w = px(50), .h = px(20), .align_self = .end }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 50, 20) },
        .{ .id = "b", .r = R(50, 80, 50, 20) },
    });
}

test "flex: stretched item respects max cross size" {
    try check(.{ .id = "c", .style = row300, .kids = &.{box("a", .{ .w = px(50), .max_h = 30 })} }, &.{.{ .id = "a", .r = R(0, 0, 50, 30) }});
}

test "flex: gap, padding, border and margin" {
    var st = row300;
    st.gap = 10;
    st.padding = .all(10);
    st.border_w = 2;
    try check(.{ .id = "c", .style = st, .kids = &.{ box("a", .{ .w = px(50), .margin = .{ .l = 5, .r = 5 } }), box("b", .{ .w = px(50) }) } }, &.{
        .{ .id = "a", .r = R(17, 12, 50, 76) },
        .{ .id = "b", .r = R(82, 12, 50, 76) },
    });
}

test "flex: column direction" {
    try check(.{ .id = "c", .style = .{ .dir = .column, .w = px(300), .h = px(100) }, .kids = &.{ box("a", .{ .h = px(20) }), box("b", .{ .h = px(20) }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 300, 20) },
        .{ .id = "b", .r = R(0, 20, 300, 20) },
    });
}

test "flex: column grow" {
    try check(.{ .id = "c", .style = .{ .dir = .column, .w = px(300), .h = px(100) }, .kids = &.{ box("a", .{ .h = px(20) }), box("b", .{ .grow = 1 }) } }, &.{
        .{ .id = "b", .r = R(0, 20, 300, 80) },
    });
}

test "flex: row reverse" {
    var st = row300;
    st.dir = .row_reverse;
    try check(.{ .id = "c", .style = st, .kids = &.{ box("a", .{ .w = px(50) }), box("b", .{ .w = px(50) }) } }, &.{
        .{ .id = "a", .r = R(250, 0, 50, 100) },
        .{ .id = "b", .r = R(200, 0, 50, 100) },
    });
}

test "flex: column reverse" {
    try check(.{ .id = "c", .style = .{ .dir = .column_reverse, .w = px(300), .h = px(100) }, .kids = &.{ box("a", .{ .h = px(20) }), box("b", .{ .h = px(20) }) } }, &.{
        .{ .id = "a", .r = R(0, 80, 300, 20) },
        .{ .id = "b", .r = R(0, 60, 300, 20) },
    });
}

test "flex: wrap into lines" {
    try check(.{ .id = "c", .style = .{ .w = px(100), .h = px(100), .wrap = true }, .kids = &.{ box("a", .{ .w = px(60), .h = px(20) }), box("b", .{ .w = px(60), .h = px(20) }), box("d", .{ .w = px(30), .h = px(20) }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 60, 20) },
        .{ .id = "b", .r = R(0, 20, 60, 20) },
        .{ .id = "d", .r = R(60, 20, 30, 20) },
    });
}

test "flex: wrap with align content center and end" {
    try check(.{ .id = "c", .style = .{ .w = px(100), .h = px(100), .wrap = true, .align_content = .center }, .kids = &.{ box("a", .{ .w = px(60), .h = px(20) }), box("b", .{ .w = px(60), .h = px(20) }) } }, &.{
        .{ .id = "a", .r = R(0, 30, 60, 20) },
        .{ .id = "b", .r = R(0, 50, 60, 20) },
    });
    try check(.{ .id = "c", .style = .{ .w = px(100), .h = px(100), .wrap = true, .align_content = .end }, .kids = &.{ box("a", .{ .w = px(60), .h = px(20) }), box("b", .{ .w = px(60), .h = px(20) }) } }, &.{
        .{ .id = "a", .r = R(0, 60, 60, 20) },
        .{ .id = "b", .r = R(0, 80, 60, 20) },
    });
}

test "flex: wrap with gap" {
    try check(.{ .id = "c", .style = .{ .w = px(100), .h = px(100), .wrap = true, .gap = 10 }, .kids = &.{ box("a", .{ .w = px(50), .h = px(20) }), box("b", .{ .w = px(50), .h = px(20) }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 50, 20) },
        .{ .id = "b", .r = R(0, 30, 50, 20) },
    });
}

test "flex: aspect ratio derives height" {
    var st = row300;
    st.align_items = .start;
    try check(.{ .id = "c", .style = st, .kids = &.{box("a", .{ .w = px(40), .aspect = 2 })} }, &.{.{ .id = "a", .r = R(0, 0, 40, 20) }});
}

test "flex: percentage widths" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .w = .{ .pct = 50 } }), box("b", .{ .w = .{ .pct = 25 } }) } }, &.{
        .{ .id = "a", .r = R(0, 0, 150, 100) },
        .{ .id = "b", .r = R(150, 0, 75, 100) },
    });
}

test "flex: auto-sized container hugs content" {
    try check(.{ .id = "outer", .style = .{ .dir = .column, .align_items = .start, .w = px(500), .h = px(500) }, .kids = &.{
        .{ .id = "c", .style = .{ .gap = 10 }, .kids = &.{ box("a", .{ .w = px(50), .h = px(20) }), box("b", .{ .w = px(50), .h = px(30) }) } },
    } }, &.{
        .{ .id = "c", .r = R(0, 0, 110, 30) },
        .{ .id = "a", .r = R(0, 0, 50, 20) },
        .{ .id = "b", .r = R(60, 0, 50, 30) },
    });
}

test "flex: min width on auto container" {
    try check(.{ .id = "outer", .style = .{ .dir = .column, .align_items = .start, .w = px(500), .h = px(500) }, .kids = &.{
        .{ .id = "c", .style = .{ .min_w = 200, .justify = .end }, .kids = &.{box("a", .{ .w = px(50), .h = px(20) })} },
    } }, &.{
        .{ .id = "c", .r = R(0, 0, 200, 20) },
        .{ .id = "a", .r = R(150, 0, 50, 20) },
    });
}

test "flex: display none takes no space" {
    try check(.{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .w = px(50), .display = .none }), box("b", .{ .w = px(50) }) } }, &.{
        .{ .id = "b", .r = R(0, 0, 50, 100) },
    });
}

test "flex: text wraps at the column width" {
    try check(.{ .id = "c", .style = .{ .dir = .column, .w = px(60), .h = px(200), .align_items = .start }, .kids = &.{
        .{ .id = "t", .style = .{}, .kids = &.{.{ .text = "hello world" }} },
    } }, &.{
        // 13 px font: 7.8 px per char, so "hello world" (85.8) does not fit;
        // the box is fit-content (60) and the text wraps to two 17 px lines.
        .{ .id = "t", .r = R(0, 0, 60, 34) },
    });
}

test "stack: alignment on both axes" {
    try check(.{ .id = "c", .style = .{ .display = .stack, .w = px(300), .h = px(100), .align_items = .center }, .kids = &.{ box("a", .{ .w = px(50), .h = px(20) }), box("b", .{ .w = px(10), .h = px(10), .align_self = .end }) } }, &.{
        .{ .id = "a", .r = R(125, 40, 50, 20) },
        .{ .id = "b", .r = R(290, 90, 10, 10) },
    });
}

test "stack: stretch fills" {
    try check(.{ .id = "c", .style = .{ .display = .stack, .w = px(300), .h = px(100), .padding = .all(5) }, .kids = &.{box("a", .{})} }, &.{
        .{ .id = "a", .r = R(5, 5, 290, 90) },
    });
}

test "absolute: insets from each edge" {
    try check(.{ .id = "c", .style = row300, .kids = &.{
        box("a", .{ .position = .absolute, .inset = .{ .l = 10, .t = 5 }, .w = px(50), .h = px(20) }),
        box("b", .{ .position = .absolute, .inset = .{ .r = 10, .b = 10 }, .w = px(50), .h = px(20) }),
        box("d", .{ .w = px(30) }),
    } }, &.{
        .{ .id = "a", .r = R(10, 5, 50, 20) },
        .{ .id = "b", .r = R(240, 70, 50, 20) },
        .{ .id = "d", .r = R(0, 0, 30, 100) },
    });
}

test "absolute: left and right stretch" {
    try check(.{ .id = "c", .style = row300, .kids = &.{box("a", .{ .position = .absolute, .inset = .{ .l = 10, .r = 10, .t = 0, .b = 0 } })} }, &.{
        .{ .id = "a", .r = R(10, 0, 280, 100) },
    });
}

test "layout cache: unchanged rebuild relayouts nothing" {
    var v: TreeView = .{ .root = .{ .id = "c", .style = row300, .kids = &.{ box("a", .{ .grow = 1 }), box("b", .{ .grow = 1 }) } } };
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.settle();
    t.win.markAllDirty();
    const st = t.frame();
    try std.testing.expectEqual(@as(u32, 0), st.layout.visited);
}

test "layout cache: a leaf change relayouts only its ancestors" {
    const V = struct {
        label: []const u8 = "a",
        pub fn build(self: *@This(), ui: *ui_mod.Ui) void {
            ui.open(.{ .style = .{ .dir = .column } });
            for (0..20) |i| {
                ui.id(i);
                ui.open(.{ .style = .{ .h = .{ .px = 20 } } });
                ui.text(if (i == 7) self.label else "x", .{});
                ui.close();
            }
            ui.close();
        }
    };
    var v: V = .{};
    const t = try TestApp.init(std.testing.allocator, .{ .root = view_mod.AnyView.of(&v) });
    defer t.deinit();
    _ = t.settle();
    v.label = "a much longer label";
    t.win.markAllDirty();
    const st = t.frame();
    try std.testing.expect(st.layout.visited > 0);
    try std.testing.expect(st.layout.cache_hits >= 19);
    // Max-content for the flex basis, then the definite width.
    try std.testing.expect(st.layout.measured <= 2);
}
