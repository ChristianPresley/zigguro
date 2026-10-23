//! The diagram view and the mermaid fence renderer in a headless window:
//! a placeholder until the worker's layout lands, then the diagram with
//! pan and zoom; errors show the source with `line:col`; a Markdown
//! mermaid fence draws through the registered renderer and a second
//! render hits the cache; snapshots at 1× and 2×.

const std = @import("std");
const zg_gui = @import("zg_gui");
const view = @import("diagram_view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;

const src =
    \\flowchart LR
    \\  a[Start] --> b{Check} -->|ok| c([Done])
    \\  b -->|retry| a
;

const Host = struct {
    st: ?*view.DiagramViewState = null,

    pub fn build(h: *Host, ui: *zg_gui.Ui) void {
        if (h.st) |st| view.diagramView(ui, st, .{ .test_id = "diagram", .max_w = 300 });
    }
};

fn finish(t: *TestApp) void {
    t.app.joinWork();
    _ = t.app.drainMessages();
    _ = t.settle();
}

/// Glyph runs in the light theme's diagram text colour: the three node
/// labels and two edge labels of `src`.
fn labels(t: *TestApp) usize {
    return std.mem.count(u8, t.paintSnapshot(), "#1f2328ff");
}

fn hasText(t: *TestApp, s: []const u8) bool {
    return t.find(.{ .kind = "text", .name = s }) != null;
}

test "placeholder, then the diagram; pan and zoom" {
    var host: Host = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&host), .size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    const st = try view.DiagramViewState.init(gpa, io, &t.app, .{});
    defer {
        finish(t);
        host.st = null;
        st.deinit();
    }
    host.st = st;
    try st.setSource(src);
    try testing.expectEqual(.pending, st.status);
    _ = t.settle();
    finish(t);
    try testing.expectEqual(.ready, st.status);
    try testing.expectEqual(1, st.builds);
    try testing.expect(t.find(.{ .role = .img, .name = "Diagram viewport" }) != null);
    try testing.expectEqual(5, labels(t));
    // Same source again: no new job.
    try st.setSource(src);
    finish(t);
    try testing.expectEqual(1, st.builds);

    // The diagram is wider than the 300 px viewport: it pans.
    try testing.expect(st.size[0] > 300);
    const vp = try t.rectOf(.{ .role = .img, .name = "Diagram viewport" });
    try testing.expectApproxEqAbs(300, vp.w, 0.5);
    t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = vp.x + 200, .y = vp.y + 10 } } });
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = vp.x + 150, .y = vp.y + 10 } } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = vp.x + 150, .y = vp.y + 10 } } });
    _ = t.settle();
    try testing.expectApproxEqAbs(50, st.pan[0], 0.5);
    // Keys: zoom in, then reset.
    t.win.dispatch(.{ .key = .{ .key = .equal } });
    _ = t.settle();
    try testing.expectApproxEqAbs(1.25, st.zoom, 1e-4);
    try t.click(.{ .role = .button, .name = "Reset" });
    _ = t.settle();
    try testing.expectEqual(1, st.zoom);
    try testing.expectEqual(0, st.pan[0]);

    // SVG export draws the same diagram.
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try testing.expect(try st.exportSvg(&w.writer));
    try testing.expect(std.mem.indexOf(u8, w.written(), ">Start</text>") != null);
}

test "parse errors show the source and line:col" {
    var host: Host = .{};
    const t = try TestApp.init(gpa, .{ .root = .of(&host), .size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    const st = try view.DiagramViewState.init(gpa, io, &t.app, .{});
    defer {
        finish(t);
        host.st = null;
        st.deinit();
    }
    host.st = st;
    try st.setSource("flowchart TB\n  a --> b\n  c -->\n");
    finish(t);
    try testing.expectEqual(.failed, st.status);
    try testing.expect(std.mem.startsWith(u8, st.notice, "3:"));
    try testing.expect(t.find(.{ .role = .status, .name = "Diagram error" }) != null);
    try testing.expect(hasText(t, st.notice));
    try testing.expect(hasText(t, st.src));

    try st.setSource("pie title Pets\n  \"Dogs\" : 3\n");
    finish(t);
    try testing.expectEqual(.unsupported, st.status);
    try testing.expect(std.mem.indexOf(u8, st.notice, "not supported") != null);
    try testing.expect(hasText(t, st.notice));
    try testing.expect(hasText(t, st.src));
}

const MdHost = struct {
    doc: zg_gui.markdown.Doc,
    state: zg_gui.markdown.MdViewState = undefined,
    props: zg_gui.markdown.MdViewProps = .{},

    pub fn build(h: *MdHost, ui: *zg_gui.Ui) void {
        zg_gui.markdown.view(ui, &h.state, h.props);
    }
};

test "fence_renderer_registered_and_cached" {
    const md = "# Notes\n\n```mermaid\n" ++ src ++ "\n```\n\nAfter.\n";
    var h: MdHost = .{ .doc = try zg_gui.markdown.parse(gpa, md, .{}) };
    defer h.doc.deinit();
    h.state = .init(gpa, &h.doc);
    defer h.state.deinit();
    var fence: view.DiagramFence = .init(gpa, io, undefined);
    var reg: zg_gui.MarkdownBlockRenderers = .{};
    try view.registerFenceRenderer(&reg, &fence);
    h.props.block_renderers = &reg;
    const t = try TestApp.init(gpa, .{ .root = .of(&h), .size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    fence.app = &t.app;
    defer {
        finish(t);
        fence.deinit();
    }
    _ = t.settle();
    try testing.expectEqual(1, fence.misses);
    finish(t);
    try testing.expect(t.find(.{ .test_id = "md-diagram" }) != null);
    try testing.expectEqual(5, labels(t));
    try testing.expect(fence.hits >= 1);
    try testing.expectEqual(1, fence.slots.items.len);
    try testing.expectEqual(.ready, fence.slots.items[0].st.status);
    // A rebuild hits the cache; nothing is laid out again.
    const hits = fence.hits;
    t.app.notifyEntity(fence.slots.items[0].st.surface.entity);
    _ = t.settle();
    try testing.expect(fence.hits > hits);
    try testing.expectEqual(1, fence.misses);
    try testing.expectEqual(1, fence.slots.items[0].st.builds);
}

test "snapshot at 1x and 2x" {
    for ([_]f32{ 1, 2 }) |scale| {
        var host: Host = .{};
        const t = try TestApp.init(gpa, .{ .root = .of(&host), .size = .{ .w = 800, .h = 600 }, .scale = scale });
        defer t.deinit();
        const st = try view.DiagramViewState.init(gpa, io, &t.app, .{});
        defer {
            finish(t);
            host.st = null;
            st.deinit();
        }
        host.st = st;
        try st.setSource(src);
        finish(t);
        finish(t);
        try testing.expect(st.surface.jobs_done >= 1);
        const snap = t.paintSnapshot();
        try testing.expect(std.mem.indexOf(u8, snap, "image") != null);
        try testing.expectEqual(5, labels(t));
    }
}
