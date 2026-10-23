//! Standalone HTML export: ten documents against goldens, hostile input,
//! images embedded or linked, diagrams through the port, and balanced
//! tags.

const std = @import("std");
const builtin = @import("builtin");
const zg_agents = @import("zg_agents");
const ex = @import("export_html.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const Writer = std.Io.Writer;
const sanitize = zg_agents.docs.html_sanitize;

const names = [_][]const u8{ "01_headings", "02_lists", "03_tables", "04_code", "05_quotes", "06_links", "07_images", "08_mermaid", "09_xss", "10_math" };

const sources = blk: {
    var out: [names.len][]const u8 = undefined;
    for (names, 0..) |n, i| out[i] = @embedFile("testdata/export/" ++ n ++ ".md");
    break :blk out;
};

const goldens = blk: {
    var out: [names.len][]const u8 = undefined;
    for (names, 0..) |n, i| out[i] = @embedFile("testdata/export/" ++ n ++ ".html");
    break :blk out;
};

/// The smallest thing `sniff` takes for a PNG.
const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR";

const Ports = struct {
    diagrams: u32 = 0,

    /// Wraps `const`, `var` and `fn` in keyword spans.
    fn highlight(_: *anyopaque, lang: []const u8, code: []const u8, w: *Writer) anyerror!bool {
        if (!std.mem.eql(u8, lang, "zig")) return false;
        var it = std.mem.tokenizeScalar(u8, code, ' ');
        var first = true;
        while (it.next()) |word| {
            if (!first) try w.writeByte(' ');
            first = false;
            if (std.mem.eql(u8, word, "const") or std.mem.eql(u8, word, "var") or std.mem.eql(u8, word, "fn")) {
                try w.print("<span class=\"hl-keyword\">{s}</span>", .{word});
            } else try ex.escapeTo(w, word);
        }
        return true;
    }

    /// "Renders" sources starting with `graph`, with hostile bits the
    /// exporter must strip.
    fn diagram(ctx: *anyopaque, src: []const u8, w: *Writer) anyerror!bool {
        const p: *Ports = @ptrCast(@alignCast(ctx));
        p.diagrams += 1;
        if (!std.mem.startsWith(u8, src, "graph")) return false;
        try w.writeAll("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><script>bad()</script><g onclick=\"bad()\"><text x=\"1\" y=\"5\">A</text></g></svg>");
        return true;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    doc_dir: std.Io.Dir,
    ports: Ports = .{},

    fn init(f: *Fx) !void {
        f.* = .{ .tmp = testing.tmpDir(.{}), .doc_dir = undefined };
        try f.tmp.dir.createDirPath(io, "doc/img");
        try f.tmp.dir.writeFile(io, .{ .sub_path = "doc/img/dot.png", .data = png });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "doc/img/big.png", .data = png ++ ("x" ** 300) });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "doc/img/pic.svg", .data = "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"bad()\"><script>bad()</script><a href=\"javascript:bad()\"><rect width=\"4\" height=\"4\"/></a></svg>" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "secret.png", .data = png });
        f.doc_dir = try f.tmp.dir.openDir(io, "doc", .{});
    }

    fn deinit(f: *Fx) void {
        f.doc_dir.close(io);
        f.tmp.cleanup();
    }

    fn opts(f: *Fx) ex.ExportOpts {
        return .{
            .embed_images_max_bytes = 256,
            .theme = .auto,
            .highlight = .{ .ctx = &f.ports, .f = Ports.highlight },
            .diagram_svg = .{ .ctx = &f.ports, .f = Ports.diagram },
            .base_dir = f.doc_dir,
        };
    }

    fn run(f: *Fx, a: std.mem.Allocator, src: []const u8, o: ex.ExportOpts) ![]const u8 {
        _ = f;
        var w: Writer.Allocating = .init(a);
        try ex.exportMarkdown(io, a, src, &w.writer, o);
        return w.written();
    }
};

fn expectNone(hay: []const u8, needles: []const []const u8) !void {
    for (needles) |n| if (std.ascii.indexOfIgnoreCase(hay, n)) |at| {
        std.debug.print("found {s} at {d}:\n{s}\n", .{ n, at, hay[at -| 80..@min(hay.len, at + 80)] });
        return error.TestUnexpectedResult;
    };
}

fn expectHas(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("missing {s} in\n{s}\n", .{ needle, hay });
        return error.TestUnexpectedResult;
    }
}

/// The page's body (the stylesheet is the same everywhere).
fn body(html: []const u8) []const u8 {
    const s = std.mem.indexOf(u8, html, "<main>") orelse return html;
    return html[s..];
}

test "export html goldens" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var failed = false;
    for (names, sources, goldens) |n, src, golden| {
        const got = try f.run(arena.allocator(), src, f.opts());
        if (!std.mem.eql(u8, body(got), golden)) {
            std.debug.print("=====BEGIN {s}=====\n{s}=====END=====\n", .{ n, body(got) });
            failed = true;
        }
    }
    if (failed) return error.TestUnexpectedResult;
}

test "escaping and xss fixtures neutralized" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const hostile = [_][]const u8{ "<script", "onclick", "onerror", "onload", "javascript:", "data:text" };
    for ([_]bool{ false, true }) |raw| {
        var o = f.opts();
        o.allow_raw_html = raw;
        for (sources) |src| try expectNone(try f.run(arena.allocator(), src, o), &hostile);
        const xss = try f.run(arena.allocator(), sources[8], o);
        if (raw) try expectHas(xss, "<div>raw div</div>") else try expectNone(xss, &.{"raw div"});
    }
    // The sanitizer on its own.
    const a = arena.allocator();
    try testing.expectEqualStrings("<b>x</b>", try sanitize.sanitize(a, "<b onmouseover='x()'>x</b><!-- c --><script>y()</script>"));
    try testing.expectEqualStrings("<a>t</a>", try sanitize.sanitize(a, "<a href=\"&#106;avascript:x\">t</a>"));
    try testing.expectEqualStrings("<a href=\"https://e.org/?a=1\">t</a>", try sanitize.sanitize(a, "<a href=https://e.org/?a=1>t</a>"));
    try testing.expectEqualStrings("<svg><use href=\"#s\" /><use /></svg>", try sanitize.sanitize(a, "<svg><use href=\"#s\"/><use href=\"http://e.org/x.svg#s\"/></svg>"));
    try testing.expectEqualStrings("1 &lt; 2", try sanitize.sanitize(a, "1 < 2"));
    try testing.expectError(error.Malformed, sanitize.sanitize(a, "<a href=\"x>"));
    try testing.expect(!sanitize.safeLink(" java\tscript:x"));
    try testing.expect(!sanitize.safeLink("VBScript:x"));
    try testing.expect(sanitize.safeLink("dir/a:b.md"));
    try testing.expect(sanitize.safeLink("page.md#top"));
}

test "images embedded or linked by size" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const html = try f.run(arena.allocator(), sources[6], f.opts());
    try expectHas(html, "<img src=\"data:image/png;base64,iVBORw0KGgo");
    try expectHas(html, "alt=\"small png\" title=\"Dot\">");
    try expectHas(html, "<a class=\"image-link\" href=\"img/big.png\">big</a>");
    try expectHas(html, "<a class=\"image-link\" href=\"https://example.com/x.png\">remote</a>");
    try expectHas(html, "<img src=\"data:image/svg+xml;base64,");
    try expectHas(html, "<a class=\"image-link\" href=\"../secret.png\">escape</a>");
    try expectHas(html, "<a class=\"image-link\" href=\"img/none.png\">missing</a>");
    // Only data: images; nothing else loads.
    try expectNone(html, &.{ "<img src=\"img", "<img src=\"http" });
    // The SVG lost its script.
    const at = std.mem.indexOf(u8, html, "data:image/svg+xml;base64,").? + 26;
    const end = std.mem.indexOfScalarPos(u8, html, at, '"').?;
    const dec = std.base64.standard.Decoder;
    const svg = try arena.allocator().alloc(u8, try dec.calcSizeForSlice(html[at..end]));
    try dec.decode(svg, html[at..end]);
    try expectNone(svg, &.{ "script", "onload", "javascript" });
    try expectHas(svg, "<rect width=\"4\" height=\"4\" />");
    // Without a base directory, local images are links.
    var o = f.opts();
    o.base_dir = null;
    try expectHas(try f.run(arena.allocator(), sources[6], o), "<a class=\"image-link\" href=\"img/dot.png\">small png</a>");

    try testing.expectEqualStrings("a b/c.png", ex.localPath(arena.allocator(), "a%20b/c.png?x#y").?);
    try testing.expect(ex.localPath(arena.allocator(), "/etc/passwd") == null);
    try testing.expect(ex.localPath(arena.allocator(), "a/../../b.png") == null);
    try testing.expect(ex.localPath(arena.allocator(), "C:/x.png") == null);
    try testing.expect(ex.localPath(arena.allocator(), "file:///x.png") == null);
}

test "mermaid fence uses diagram callback" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const html = try f.run(arena.allocator(), sources[7], f.opts());
    try testing.expectEqual(@as(u32, 2), f.ports.diagrams);
    try expectHas(html, "<figure class=\"diagram\">\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><g><text x=\"1\" y=\"5\">A</text></g></svg>\n</figure>");
    try expectHas(html, "<!-- diagram could not be rendered -->\n<pre><code class=\"language-mermaid\">not a diagram");
    var o = f.opts();
    o.diagram_svg = null;
    const plain = try f.run(arena.allocator(), sources[7], o);
    try expectNone(plain, &.{ "<svg", "<figure" });
    try expectHas(plain, "<pre><code class=\"language-mermaid\">graph TD; A--&gt;B");
}

/// Every element closes in order (void elements and `/>` excepted).
fn checkBalanced(html: []const u8) !void {
    const void_tags = [_][]const u8{ "meta", "br", "hr", "img", "input", "link", "!doctype" };
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(gpa);
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        if (std.mem.startsWith(u8, html[lt..], "<!--")) {
            i = (std.mem.indexOfPos(u8, html, lt, "-->") orelse return error.Unclosed) + 3;
            continue;
        }
        const gt = std.mem.indexOfScalarPos(u8, html, lt, '>') orelse return error.Unclosed;
        const tag = html[lt + 1 .. gt];
        i = gt + 1;
        const closing = tag.len > 0 and tag[0] == '/';
        const name_s = if (closing) tag[1..] else tag;
        const name = name_s[0 .. std.mem.indexOfAny(u8, name_s, " \t\n/") orelse name_s.len];
        if (closing) {
            const top = stack.pop() orelse return error.Unbalanced;
            if (!std.ascii.eqlIgnoreCase(top, name)) return error.Unbalanced;
            continue;
        }
        if (std.mem.endsWith(u8, tag, "/")) continue;
        var is_void = false;
        for (void_tags) |v| is_void = is_void or std.ascii.eqlIgnoreCase(v, name);
        if (!is_void) try stack.append(gpa, name);
    }
    if (stack.items.len != 0) return error.Unbalanced;
}

test "well formed structure" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (sources) |src| for ([_]ex.Theme{ .auto, .light, .dark }) |th| {
        var o = f.opts();
        o.theme = th;
        const html = try f.run(arena.allocator(), src, o);
        try checkBalanced(html);
        try testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>\n"));
    };
    try testing.expectError(error.Unbalanced, checkBalanced("<p><em></p></em>"));
    // The title is the first heading's text.
    try expectHas(try f.run(arena.allocator(), sources[0], f.opts()), "<title>Writing Guide</title>");
    try expectHas(try f.run(arena.allocator(), sources[8], f.opts()), "<title>XSS alert(1)</title>");
}

test "export of a 50k-word document" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    var words: usize = 0;
    var sec: usize = 0;
    while (words < 50_000) : (sec += 1) {
        try src.print(a, "## Section {d}\n\n", .{sec});
        for (0..5) |_| {
            try src.appendSlice(a, "The quick *brown* fox jumps over the **lazy** dog, see [the docs](https://example.com/a) and `code` here; again and again until done.\n\n");
            words += 22;
        }
        try src.appendSlice(a, "- item one\n- item two\n\n```zig\nconst x = 1;\n```\n\n");
    }
    const t0 = std.Io.Timestamp.now(io, .awake);
    var w: Writer.Allocating = .init(a);
    try ex.exportMarkdown(io, a, src.items, &w.writer, .{});
    const ms = t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expect(w.written().len > src.items.len);
    // The budget holds for optimized builds; Debug is several times slower.
    if (builtin.mode != .Debug) try testing.expect(ms < 100);
}
