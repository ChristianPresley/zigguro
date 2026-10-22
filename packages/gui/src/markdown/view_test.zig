//! MarkdownView behaviour (E04.F06.S01.T02): streaming relayout, code
//! blocks, highlighting, tables, tasks, selection and copy, links,
//! images, callouts, virtualization.

const std = @import("std");
const ast = @import("ast.zig");
const doc_mod = @import("doc.zig");
const stream = @import("stream.zig");
const md = @import("view.zig");
const ui_mod = @import("../core/ui.zig");
const view_mod = @import("../core/view.zig");
const geom = @import("../core/geom.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const testing = std.testing;
const gpa = testing.allocator;
const Ui = ui_mod.Ui;

/// Monospace test metrics: 13 px text advances 7.8 px per character.
const adv: f32 = 13 * 0.6;

const Harness = struct {
    doc: doc_mod.Doc,
    state: md.MdViewState = undefined,
    props: md.MdViewProps = .{},

    fn create(src: []const u8, streaming: bool) !*Harness {
        const h = try gpa.create(Harness);
        errdefer gpa.destroy(h);
        h.* = .{ .doc = if (streaming) stream.init(gpa, .{}) else try stream.parse(gpa, src, .{}) };
        h.state = .init(gpa, &h.doc);
        if (streaming) _ = try h.state.append(src);
        return h;
    }

    fn destroy(h: *Harness) void {
        h.state.deinit();
        h.doc.deinit();
        gpa.destroy(h);
    }

    pub fn build(h: *Harness, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .padding = .all(10) } });
        defer ui.close();
        md.view(ui, &h.state, h.props);
    }

    fn app(h: *Harness) !*TestApp {
        return h.appSized(.{ .w = 600, .h = 800 });
    }

    fn appSized(h: *Harness, size: geom.Size) !*TestApp {
        const t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(h), .size = size });
        _ = t.settle();
        return t;
    }
};

fn press(t: *TestApp, p: geom.Vec2, clicks: u8) void {
    t.win.dispatch(.{ .pointer_move = .{ .pos = p } });
    t.win.dispatch(.{ .pointer_down = .{ .pos = p, .clicks = clicks } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = p, .clicks = clicks } });
    _ = t.settle();
}

test "blocks render as text leaves, lists, quotes and callouts" {
    const h = try Harness.create(
        \\# Title
        \\
        \\Some *styled* text.
        \\
        \\- one
        \\- two
        \\
        \\> quoted
        \\
        \\> [!WARNING] Careful
        \\> body
        \\
        \\---
        \\
    , false);
    defer h.destroy();
    const t = try h.app();
    defer t.deinit();
    try testing.expect(t.find(.{ .kind = "md_text", .name = "Title" }) != null);
    try testing.expect(t.find(.{ .kind = "md_text", .name = "Some styled text." }) != null);
    try testing.expectEqual(@as(usize, 1), t.count(.{ .role = .list }));
    try testing.expectEqual(@as(usize, 2), t.count(.{ .role = .listitem }));
    try testing.expect(t.find(.{ .role = .group, .name = "Warning" }) != null);
    try testing.expect(t.find(.{ .kind = "text", .name = "Careful" }) != null);
    try testing.expect(t.find(.{ .kind = "separator" }) != null);
    // The heading is larger than the paragraph.
    const title = try t.rectOf(.{ .kind = "md_text", .name = "Title" });
    const para = try t.rectOf(.{ .kind = "md_text", .name = "Some styled text." });
    try testing.expect(title.h > para.h);
}

test "stream append relayouts only tail" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..30) |i| try src.print(gpa, "Paragraph number {d} with some words.\n\n", .{i});
    const h = try Harness.create(src.items, true);
    defer h.destroy();
    const t = try h.app();
    defer t.deinit();
    const flat0 = h.state.stats.flattened;
    const laid0 = h.state.stats.laid_out;
    _ = try h.state.append("A new paragraph streams ");
    t.win.markAllDirty();
    _ = t.settle();
    _ = try h.state.append("in.\n\n");
    t.win.markAllDirty();
    _ = t.settle();
    // Only the last paragraph (and the one that was still open) changed.
    try testing.expect(h.state.stats.flattened - flat0 <= 4);
    try testing.expect(h.state.stats.laid_out - laid0 <= 6);
    try testing.expect(t.find(.{ .kind = "md_text", .name = "A new paragraph streams in." }) != null);
}

test "code block copy puts the raw code on the clipboard" {
    const h = try Harness.create("```zig\nconst a = 1;\n    indented();\n```\n", false);
    defer h.destroy();
    const t = try h.app();
    defer t.deinit();
    try testing.expect(t.find(.{ .kind = "text", .name = "zig" }) != null);
    try t.click(.{ .role = .button, .name = "Copy" });
    try testing.expectEqualStrings("const a = 1;\n    indented();", t.app.clipboard.get());
}

const CountingHighlighter = struct {
    calls: u32 = 0,
    fn hl(ptr: *anyopaque, a: std.mem.Allocator, _: []const u8, code: []const u8, out: *std.ArrayList(md.Span)) std.mem.Allocator.Error!void {
        const self: *CountingHighlighter = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        if (std.mem.indexOf(u8, code, "const")) |k| try out.append(a, .{ .start = @intCast(k), .end = @intCast(k + 5), .class = .keyword });
    }
    fn highlighter(self: *CountingHighlighter) md.Highlighter {
        return .{ .ptr = self, .highlight = hl };
    }
};

test "highlighter cache by hash" {
    const h = try Harness.create("```zig\nconst a = 1;\n```\n\ntext\n\n```zig\nconst a = 1;\n```\n", false);
    defer h.destroy();
    var hl: CountingHighlighter = .{};
    h.props.highlighter = hl.highlighter();
    const t = try h.app();
    defer t.deinit();
    try testing.expectEqual(@as(u32, 1), hl.calls);
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqual(@as(u32, 1), hl.calls);
}

test "table column sizing and hscroll" {
    const h = try Harness.create(
        \\| a | longer header |
        \\|:-:|--:|
        \\| 1 | 2 |
        \\
    , false);
    defer h.destroy();
    const t = try h.app();
    defer t.deinit();
    try testing.expect(t.find(.{ .role = .group, .name = "Table" }) != null);
    const a = try t.rectOf(.{ .kind = "md_text", .name = "a" });
    const long = try t.rectOf(.{ .kind = "md_text", .name = "longer header" });
    // Column 2 is as wide as its header plus padding; column 1 is narrow.
    try testing.expect(long.w >= 13 * adv - 0.5);
    try testing.expect(a.w < long.w);
    // A table wider than the view scrolls instead of squeezing.
    var wide: std.ArrayList(u8) = .empty;
    defer wide.deinit(gpa);
    try wide.appendSlice(gpa, "| x | y | z |\n|---|---|---|\n|");
    for (0..3) |_| {
        try wide.appendNTimes(gpa, 'w', 60);
        try wide.appendSlice(gpa, " |");
    }
    try wide.append(gpa, '\n');
    const h2 = try Harness.create(wide.items, false);
    defer h2.destroy();
    const t2 = try h2.app();
    defer t2.deinit();
    const tbl = try t2.rectOf(.{ .role = .group, .name = "Table" });
    try testing.expect(tbl.w > 600);
}

const TaskSink = struct {
    offset: u32 = 0,
    checked: ?bool = null,
    fn f(ctx: *anyopaque, off: u32, checked: bool) void {
        const s: *TaskSink = @ptrCast(@alignCast(ctx));
        s.offset = off;
        s.checked = checked;
    }
};

test "task toggle callback offset" {
    const src = "Intro\n\n- [ ] first\n- [x] second\n";
    const h = try Harness.create(src, false);
    defer h.destroy();
    var sink: TaskSink = .{};
    h.props.on_task_toggle = .{ .ctx = &sink, .f = TaskSink.f };
    const t = try h.app();
    defer t.deinit();
    try testing.expectEqual(@as(usize, 2), t.count(.{ .role = .checkbox }));
    try t.click(.{ .role = .checkbox, .name = "Task" });
    try testing.expectEqual(std.mem.indexOf(u8, src, "[ ]").?, sink.offset);
    try testing.expectEqual(@as(?bool, true), sink.checked);
    // Read-only without a callback.
    h.props.on_task_toggle = null;
    sink = .{};
    t.win.markAllDirty();
    _ = t.settle();
    try t.click(.{ .role = .checkbox, .name = "Task" });
    try testing.expectEqual(@as(?bool, null), sink.checked);
}

test "cross-block selection copy text" {
    const h = try Harness.create("Alpha beta gamma\n\nDelta epsilon\n\n- item one\n- item two\n", false);
    defer h.destroy();
    const t = try h.app();
    defer t.deinit();
    const r1 = try t.rectOf(.{ .kind = "md_text", .name = "Alpha beta gamma" });
    const r3 = try t.rectOf(.{ .kind = "md_text", .name = "item one" });
    const from: geom.Vec2 = .{ .x = r1.x + 8 * adv + 1, .y = r1.y + r1.h / 2 };
    const to: geom.Vec2 = .{ .x = r3.x + 4 * adv + 1, .y = r3.y + r3.h / 2 };
    t.win.dispatch(.{ .pointer_move = .{ .pos = from } });
    t.win.dispatch(.{ .pointer_down = .{ .pos = from } });
    var k: f32 = 1;
    while (k <= 4) : (k += 1) {
        t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = from.x + (to.x - from.x) * k / 4, .y = from.y + (to.y - from.y) * k / 4 } } });
        _ = t.settle();
    }
    t.win.dispatch(.{ .pointer_up = .{ .pos = to } });
    _ = t.settle();
    t.press(.key_c, .{ .ctrl = true });
    try testing.expectEqualStrings("ta gamma\n\nDelta epsilon\n\n- item", t.app.clipboard.get());

    // Double-click selects a word, triple-click the block.
    press(t, .{ .x = r1.x + 7 * adv, .y = r1.y + 2 }, 1);
    t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = r1.x + 7 * adv, .y = r1.y + 2 }, .clicks = 2 } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = r1.x + 7 * adv, .y = r1.y + 2 }, .clicks = 2 } });
    _ = t.settle();
    t.press(.key_c, .{ .ctrl = true });
    try testing.expectEqualStrings("beta", t.app.clipboard.get());
    t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = r1.x + 2, .y = r1.y + 2 }, .clicks = 3 } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = r1.x + 2, .y = r1.y + 2 }, .clicks = 3 } });
    _ = t.settle();
    t.press(.key_c, .{ .ctrl = true });
    try testing.expectEqualStrings("Alpha beta gamma", t.app.clipboard.get());
    // Select All, Escape.
    t.press(.key_a, .{ .ctrl = true });
    t.press(.key_c, .{ .ctrl = true });
    try testing.expectEqualStrings("Alpha beta gamma\n\nDelta epsilon\n\n- item one\n- item two", t.app.clipboard.get());
    t.press(.escape, .{});
    try testing.expect(h.state.selection == null);
}

const LinkSink = struct {
    url: [64]u8 = undefined,
    len: usize = 0,
    calls: u32 = 0,
    fn f(ctx: *anyopaque, target: md.LinkTarget, _: bool) void {
        const s: *LinkSink = @ptrCast(@alignCast(ctx));
        s.calls += 1;
        const v = switch (target) {
            inline else => |x| x,
        };
        @memcpy(s.url[0..v.len], v);
        s.len = v.len;
    }
};

test "links open through the callback; unsafe links never do" {
    const h = try Harness.create("[docs](https://example.com/a) [bad](javascript:alert(1))\n", false);
    defer h.destroy();
    var sink: LinkSink = .{};
    h.props.on_link = .{ .ctx = &sink, .f = LinkSink.f };
    const t = try h.app();
    defer t.deinit();
    const r = try t.rectOf(.{ .kind = "md_text", .name = "docs bad" });
    press(t, .{ .x = r.x + 1.5 * adv, .y = r.y + r.h / 2 }, 1);
    try testing.expectEqual(@as(u32, 1), sink.calls);
    try testing.expectEqualStrings("https://example.com/a", sink.url[0..sink.len]);
    press(t, .{ .x = r.x + 6 * adv, .y = r.y + r.h / 2 }, 1);
    try testing.expectEqual(@as(u32, 1), sink.calls);
    // Text past the line end is not a link.
    press(t, .{ .x = r.x + 30 * adv, .y = r.y + r.h / 2 }, 1);
    try testing.expectEqual(@as(u32, 1), sink.calls);
}

const Loader = struct {
    ready: bool = false,
    asked: u32 = 0,
    fn load(ptr: *anyopaque, src: []const u8) ?md.ImageHandle {
        const l: *Loader = @ptrCast(@alignCast(ptr));
        l.asked += 1;
        if (!l.ready or !std.mem.eql(u8, src, "cat.png")) return null;
        return .{ .tex = @enumFromInt(7), .w = 200, .h = 100 };
    }
    const vt: md.ImageLoader.VTable = .{ .load = load };
};

test "image placeholder then loaded" {
    const h = try Harness.create("![a cat](cat.png)\n\n![x](javascript:1)\n", false);
    defer h.destroy();
    var loader: Loader = .{};
    h.props.image_loader = .{ .ptr = &loader, .vtable = &Loader.vt };
    const t = try h.app();
    defer t.deinit();
    const before = try t.rectOf(.{ .role = .img, .name = "a cat" });
    try testing.expectEqual(@as(f32, 72), before.h);
    try testing.expect(loader.asked > 0);
    loader.ready = true;
    h.state.imagesChanged();
    t.win.markAllDirty();
    _ = t.settle();
    const after = try t.rectOf(.{ .role = .img, .name = "a cat" });
    try testing.expectEqual(@as(f32, 200), after.w);
    try testing.expectEqual(@as(f32, 100), after.h);
    try testing.expect(t.find(.{ .role = .img, .name = "x" }) != null);
}

test "streaming caret follows the last block" {
    const h = try Harness.create("text\n\n---\n", true);
    defer h.destroy();
    h.props.streaming = true;
    const t = try h.app();
    defer t.deinit();
    try testing.expectEqual(@as(usize, 1), t.count(.{ .kind = "md_caret" }));
    _ = try h.state.append("\nmore");
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqual(@as(usize, 0), t.count(.{ .kind = "md_caret" }));
    h.props.streaming = false;
    t.win.markAllDirty();
    _ = t.settle();
}

test "large documents build only the blocks in view" {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..1000) |i| try src.print(gpa, "Block {d}\n\n", .{i});
    const h = try Harness.create(src.items, false);
    defer h.destroy();
    const t = try h.app();
    defer t.deinit();
    const n = t.count(.{ .kind = "md_text" });
    try testing.expect(n > 10 and n < 120);
    try testing.expect(t.find(.{ .kind = "md_text", .name = "Block 0" }) != null);
    try t.scroll(.{ .test_id = "markdown-rows" }, 0, 5000);
    try testing.expect(t.find(.{ .kind = "md_text", .name = "Block 0" }) == null);
    // Small documents (chat bubbles) can opt out.
    h.props.virtualize = false;
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqual(@as(usize, 1000), t.count(.{ .kind = "md_text" }));
}

test "showcase snapshots in the four themes" {
    const theme_mod = @import("../theme/theme.zig");
    const golden = @import("zg_core").testkit.golden;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/testdata/markdown/showcase.md", .{@import("zg_options").package_root});
    const src = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
    defer gpa.free(src);
    const h = try Harness.create(src, false);
    defer h.destroy();
    var hl: CountingHighlighter = .{};
    h.props.highlighter = hl.highlighter();
    const t = try h.appSized(.{ .w = 600, .h = 1300 });
    defer t.deinit();
    const layout = try t.layoutSnapshot(gpa);
    defer gpa.free(layout);
    try golden.expectGoldenOpts(testing.io, @src(), "showcase.layout", layout, .{ .root = @import("zg_options").package_root, .dir = "testdata/golden/markdown" });
    for (theme_mod.builtins) |th| {
        t.app.setTheme(th);
        _ = t.settle();
        var name: [64]u8 = undefined;
        const n = try std.fmt.bufPrint(&name, "showcase.{s}", .{th.name});
        try golden.expectGoldenOpts(testing.io, @src(), n, t.paintSnapshot(), .{ .root = @import("zg_options").package_root, .dir = "testdata/golden/markdown" });
    }
}
