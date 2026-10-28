//! Hover, document highlight and navigation against the scripted fake
//! server (nav_hover.script), and their pure helpers.

const std = @import("std");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Harness = @import("../Manager_test.zig").Harness;
const HoverService = @import("hover.zig");
const HighlightService = @import("highlight.zig");
const NavService = @import("navigation.zig");
const Store = @import("../diagnostics/Store.zig");

const testing = std.testing;
const protocol = zg_lsp.protocol;

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.docs.items.len > 0 and s.sync.?.isTracked(s.docs.items[0])) return true;
    return false;
}

fn waitRunning(h: *Harness) !void {
    for (0..2000) |_| {
        h.mgr.tick();
        if (running(h)) return;
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

/// Ticks `svc` until `pred` holds.
fn waitTick(h: *Harness, svc: anytype, comptime pred: fn (@TypeOf(svc)) bool) !void {
    for (0..2000) |_| {
        h.mgr.tick();
        _ = svc.tick();
        if (pred(svc)) return;
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

fn hoverIdle(s: *HoverService) bool {
    return s.pending == null;
}

fn highlighted(s: *HighlightService) bool {
    return s.marks.items.len > 0;
}

fn navDone(n: *NavService) bool {
    const r = n.results() orelse return false;
    return r.complete;
}

test "hover, highlight, definition and references from the fake server" {
    var h: Harness = undefined;
    try h.init("nav_hover.script", &.{});
    defer h.deinit();
    var st = try Store.init(testing.allocator, h.rt.io, .native);
    defer st.deinit();
    const text = "const a = 1;\nconst b: u32 = a;\n";
    const d = try h.open("main.zig", text);
    defer {
        h.mgr.closeDoc(d);
        h.docs.release(d);
    }
    try waitRunning(&h);

    var hov = HoverService.init(&h.mgr, &st, .noop);
    defer hov.deinit();
    var hl = HighlightService.init(&h.mgr, .noop, .{ .delay = .fromMilliseconds(0) });
    defer hl.deinit();
    var nav: NavService = undefined;
    nav.init(&h.mgr, .noop);
    defer nav.deinit();

    // Hover: Markdown kept, the command link reduced to its text, the
    // range from the server.
    try hov.request(d, 13 + 6, null, .mouse);
    try waitTick(&h, &hov, hoverIdle);
    const r = hov.current().?;
    try testing.expectEqualStrings("```zig\nconst b: u32\n```\nSee docs and [site](https://ziglang.org).", r.markdown);
    try testing.expectEqual(@as(u64, 19), r.range.start);
    try testing.expectEqual(@as(u64, 20), r.range.end);
    // A null hover hides it.
    try hov.request(d, 0, null, .keyboard);
    try waitTick(&h, &hov, hoverIdle);
    try testing.expect(hov.current() == null);

    // Highlight: write and read occurrences of `a`.
    hl.onCursor(d, 6);
    try waitTick(&h, &hl, highlighted);
    const marks = hl.marksFor(d);
    try testing.expectEqual(@as(usize, 2), marks.len);
    try testing.expectEqual(HighlightService.Kind.write, marks[0].kind);
    try testing.expectEqual(@as(u64, 13 + 15), marks[1].range.start);
    try testing.expectEqual(HighlightService.Kind.read, marks[1].kind);

    // Definition: links, deduplicated, the asking file first.
    try testing.expectEqual(@as(u8, 1), try nav.go(.definition, d, 13 + 15, false));
    try waitTick(&h, &nav, navDone);
    const res = nav.results().?;
    try testing.expectEqual(@as(usize, 2), res.targets.len);
    try testing.expect(std.mem.endsWith(u8, res.targets[0].path.?, "main.zig"));
    try testing.expectEqual(@as(u32, 6), res.targets[0].selection.start.character);
    try testing.expect(std.mem.endsWith(u8, res.targets[1].path.?, "other.zig"));
    try testing.expectEqual(@as(u32, 3), res.targets[1].range.start.line);

    // References, sorted by position.
    _ = try nav.go(.references, d, 6, true);
    try waitTick(&h, &nav, navDone);
    const refs = nav.results().?.targets;
    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqual(@as(u32, 0), refs[0].selection.start.line);
    try testing.expectEqual(@as(u32, 1), refs[1].selection.start.line);
}

test "hover: content forms to markdown; plain text escaped" {
    const gpa = testing.allocator;
    const cases = [_]struct { protocol.Hover, []const u8 }{
        .{ .{ .contents = .{ .markup_content = .{ .kind = .PlainText, .value = "a*b_c" } } }, "a\\*b\\_c" },
        .{ .{ .contents = .{ .marked_string = .{ .marked_string_with_language = .{ .language = "zig", .value = "fn f() void\n" } } } }, "```zig\nfn f() void\n```" },
        .{ .{ .contents = .{ .marked_string_array = &.{ .{ .string = "**x**" }, .{ .marked_string_with_language = .{ .language = "c", .value = "" } }, .{ .string = "y" } } } }, "**x**\n\n---\n\ny" },
    };
    for (cases) |c| {
        const md = try HoverService.hoverToMarkdown(gpa, c[0]);
        defer gpa.free(md);
        try testing.expectEqualStrings(c[1], md);
    }
}

test "hover: links blocked except http, file and allowed commands; html sanitized; code kept" {
    const gpa = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try HoverService.sanitize(gpa, "[a](javascript:x) [b](command:editor.goToDefinition) ![img](https://x/y.png) <script>bad</script><b>ok</b><br> `<i>[c](x:y)</i>` <https://z.org> <evil:x>\n```\n<keep>[d](e:f)\n```\n", &out);
    try testing.expectEqualStrings("a [b](command:editor.goToDefinition) img bad<b>ok</b><br> `<i>[c](x:y)</i>` <https://z.org> evil:x\n```\n<keep>[d](e:f)\n```\n", out.items);
}

test "history: back and forward" {
    var hist = NavService.History.init(testing.allocator);
    defer hist.deinit();
    try testing.expect((try hist.back(.{ .path = "/a", .offset = 0 })) == null);
    try hist.push(.{ .path = "/a", .offset = 10 });
    try hist.push(.{ .path = "/b", .offset = 20 });
    // Now at /c:30.
    var l = (try hist.back(.{ .path = "/c", .offset = 30 })).?;
    try testing.expectEqualStrings("/b", l.path);
    l = (try hist.back(.{ .path = "/b", .offset = 21 })).?;
    try testing.expectEqualStrings("/a", l.path);
    try testing.expect((try hist.back(.{ .path = "/a", .offset = 10 })) == null);
    l = hist.forward().?;
    try testing.expectEqualStrings("/b", l.path);
    try testing.expectEqual(@as(u64, 21), l.offset);
    l = hist.forward().?;
    try testing.expectEqualStrings("/c", l.path);
    try testing.expect(hist.forward() == null);
    // A new jump drops the way forward.
    _ = try hist.back(.{ .path = "/c", .offset = 30 });
    try hist.push(.{ .path = "/b", .offset = 5 });
    try testing.expect(hist.forward() == null);
}
