//! Smart typing: per-language golden scenarios
//! (`testdata/golden/smart_edit/<lang>/cases.txt`) and unit tests for
//! pairs, comments and indentation guessing.
//!
//! A golden file holds scenarios:
//!
//!     === name
//!     --- before
//!     text with ¦ carets and «ranges»
//!     --- keys
//!     typed text, with <enter> <bs> <lc> (line comment) <bc> (block
//!     comment) <lt> (a literal '<') <tab>
//!     --- after
//!     the expected text and selections
//!
//! `-Dupdate-golden` rewrites the `after` sections.

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const options = @import("zg_options");
const smart = @import("smart_edit.zig");
const indent = @import("indent.zig");
const pairs = @import("pairs.zig");
const sel_mod = @import("selection.zig");
const document = @import("../document.zig");
const syntax_mod = @import("../syntax.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const Document = document.Document;
const langs = zg_syntax.langs;

const caret = "¦";
const open_mark = "«";
const close_mark = "»";

/// A document with live syntax, auto pairs and selections.
const Harness = struct {
    doc: *Document,
    reg: zg_syntax.Registry,
    ds: syntax_mod.DocumentSyntax,
    tokens: syntax_mod.SyntaxTokens = undefined,
    ap: pairs.AutoPairs,
    sels: SelectionSet,
    lang: *const zg_syntax.Language,

    fn init(h: *Harness, lang: *const zg_syntax.Language, marked: []const u8) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        var sels: std.ArrayList(Selection) = .empty;
        defer sels.deinit(gpa);
        try parseMarked(marked, &text, &sels);
        h.lang = lang;
        h.doc = try Document.initBytes(gpa, @enumFromInt(1), text.items);
        errdefer h.doc.deinit();
        h.reg = try zg_syntax.defaultRegistry(gpa);
        errdefer h.reg.deinit(gpa);
        h.ds = try .init(gpa, lang, &h.reg, &h.doc.tree, h.doc.version);
        _ = try h.ds.idle(&h.doc.tree, null);
        _ = try h.doc.subscribe(.{ .ctx = h, .onChange = onChange });
        h.tokens = .{ .ds = &h.ds, .tree = &h.doc.tree };
        h.ap = .{ .gpa = gpa };
        h.sels = try .init(gpa, .caret(0));
        if (sels.items.len > 0) try h.sels.set(sels.items, sels.items.len - 1);
    }

    fn deinit(h: *Harness) void {
        h.sels.deinit();
        h.ap.deinit();
        h.ds.deinit();
        h.doc.deinit();
        h.reg.deinit(gpa);
    }

    fn onChange(p: *anyopaque, ev: *const document.ChangeEvent) void {
        const h: *Harness = @ptrCast(@alignCast(p));
        h.ds.onChange(ev, &h.doc.tree, null) catch {};
    }

    fn ctx(h: *Harness) smart.EditCtx {
        return .{ .lang = h.lang, .tokens = h.tokens.query(), .auto_pairs = &h.ap };
    }

    fn run(h: *Harness, keys: []const u8) !void {
        var i: usize = 0;
        while (i < keys.len) {
            if (keys[i] == '<') {
                const e = std.mem.indexOfScalarPos(u8, keys, i, '>').?;
                const k = keys[i + 1 .. e];
                i = e + 1;
                if (std.mem.eql(u8, k, "enter")) {
                    _ = try smart.newline(h.doc, &h.sels, h.ctx());
                } else if (std.mem.eql(u8, k, "bs")) {
                    _ = try smart.deleteLeft(h.doc, &h.sels, h.ctx(), true);
                } else if (std.mem.eql(u8, k, "lc")) {
                    _ = try smart.toggleLineComment(h.doc, &h.sels, h.ctx());
                } else if (std.mem.eql(u8, k, "bc")) {
                    _ = try smart.toggleBlockComment(h.doc, &h.sels, h.ctx());
                } else if (std.mem.eql(u8, k, "lt")) {
                    _ = try smart.typeChar(h.doc, &h.sels, '<', h.ctx());
                } else if (std.mem.eql(u8, k, "tab")) {
                    _ = try smart.typeChar(h.doc, &h.sels, '\t', h.ctx());
                } else return error.UnknownKey;
                continue;
            }
            const n = try std.unicode.utf8ByteSequenceLength(keys[i]);
            const cp = try std.unicode.utf8Decode(keys[i..][0..n]);
            i += n;
            _ = try smart.typeChar(h.doc, &h.sels, cp, h.ctx());
        }
    }

    /// The text with the selections marked.
    fn render(h: *Harness, out: *std.ArrayList(u8)) !void {
        const text = try h.doc.tree.copyRange(gpa, .{ .start = 0, .end = h.doc.len() });
        defer gpa.free(text);
        var marks: std.ArrayList(struct { at: u64, s: []const u8 }) = .empty;
        defer marks.deinit(gpa);
        for (h.sels.slice()) |s| {
            if (s.isCaret()) {
                try marks.append(gpa, .{ .at = s.head, .s = caret });
            } else {
                try marks.append(gpa, .{ .at = s.start(), .s = open_mark });
                try marks.append(gpa, .{ .at = s.end(), .s = close_mark });
            }
        }
        var prev: usize = 0;
        for (marks.items) |m| {
            try out.appendSlice(gpa, text[prev..@intCast(m.at)]);
            try out.appendSlice(gpa, m.s);
            prev = @intCast(m.at);
        }
        try out.appendSlice(gpa, text[prev..]);
    }
};

fn parseMarked(marked: []const u8, text: *std.ArrayList(u8), sels: *std.ArrayList(Selection)) !void {
    var i: usize = 0;
    var anchor: ?u64 = null;
    while (i < marked.len) {
        if (std.mem.startsWith(u8, marked[i..], caret)) {
            try sels.append(gpa, .caret(text.items.len));
            i += caret.len;
        } else if (std.mem.startsWith(u8, marked[i..], open_mark)) {
            anchor = text.items.len;
            i += open_mark.len;
        } else if (std.mem.startsWith(u8, marked[i..], close_mark)) {
            try sels.append(gpa, .{ .anchor = anchor.?, .head = text.items.len });
            i += close_mark.len;
        } else {
            try text.append(gpa, marked[i]);
            i += 1;
        }
    }
}

const Scenario = struct { name: []const u8, before: []const u8, keys: []const u8, after: []const u8 };

/// Sections of a golden file. Section bodies end before the next "---"
/// or "===" line; the final newline of each body is dropped.
fn parseScenarios(text: []const u8, out: *std.ArrayList(Scenario)) !void {
    var it = std.mem.splitSequence(u8, text, "\n=== ");
    var first = true;
    while (it.next()) |chunk_in| {
        var chunk = chunk_in;
        if (first) {
            first = false;
            if (!std.mem.startsWith(u8, chunk, "=== ")) continue;
            chunk = chunk[4..];
        }
        const nl = std.mem.indexOfScalar(u8, chunk, '\n') orelse continue;
        var sc: Scenario = .{ .name = chunk[0..nl], .before = "", .keys = "", .after = "" };
        var rest = chunk[nl + 1 ..];
        while (std.mem.startsWith(u8, rest, "--- ")) {
            const hdr_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const name = rest[4..hdr_end];
            rest = if (hdr_end < rest.len) rest[hdr_end + 1 ..] else "";
            const end = std.mem.indexOf(u8, rest, "\n--- ") orelse rest.len;
            var body = rest[0..end];
            body = std.mem.trimEnd(u8, body, "\n");
            rest = if (end < rest.len) rest[end + 1 ..] else "";
            if (std.mem.eql(u8, name, "before")) sc.before = body else if (std.mem.eql(u8, name, "keys")) sc.keys = body else if (std.mem.eql(u8, name, "after")) sc.after = body;
        }
        try out.append(gpa, sc);
    }
}

fn runGolden(dir: []const u8, lang: *const zg_syntax.Language) !void {
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    const path = try std.fmt.allocPrint(gpa, "testdata/golden/smart_edit/{s}/cases.txt", .{dir});
    defer gpa.free(path);
    const text = try root.readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    var scenarios: std.ArrayList(Scenario) = .empty;
    defer scenarios.deinit(gpa);
    try parseScenarios(text, &scenarios);
    try std.testing.expect(scenarios.items.len >= 10);
    var actuals: std.ArrayList([]u8) = .empty;
    defer {
        for (actuals.items) |a| gpa.free(a);
        actuals.deinit(gpa);
    }
    var failed: usize = 0;
    for (scenarios.items) |sc| {
        var h: Harness = undefined;
        try h.init(lang, sc.before);
        defer h.deinit();
        // Keys may span lines; the line breaks between them are not typed.
        var keys: std.ArrayList(u8) = .empty;
        defer keys.deinit(gpa);
        var kit = std.mem.splitScalar(u8, sc.keys, '\n');
        while (kit.next()) |k| try keys.appendSlice(gpa, k);
        try h.run(keys.items);
        var out: std.ArrayList(u8) = .empty;
        try h.render(&out);
        const got = try out.toOwnedSlice(gpa);
        try actuals.append(gpa, got);
        if (!std.mem.eql(u8, got, sc.after)) {
            failed += 1;
            if (!options.update_golden) std.debug.print("smart_edit {s} \"{s}\":\n--- want\n{s}\n--- got\n{s}\n", .{ dir, sc.name, sc.after, got });
        }
    }
    if (failed > 0 and options.update_golden) {
        var w: std.ArrayList(u8) = .empty;
        defer w.deinit(gpa);
        for (scenarios.items, actuals.items, 0..) |sc, got, i| {
            if (i > 0) try w.append(gpa, '\n');
            try w.print(gpa, "=== {s}\n--- before\n{s}\n--- keys\n{s}\n--- after\n{s}\n", .{ sc.name, sc.before, sc.keys, got });
        }
        try root.writeFile(io, .{ .sub_path = path, .data = w.items });
        return;
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "smart_edit: golden zig" {
    try runGolden("zig", &langs.zig.zig_language);
}
test "smart_edit: golden c" {
    try runGolden("c", &langs.c.c_language);
}
test "smart_edit: golden rust" {
    try runGolden("rust", &langs.rust.rust_language);
}
test "smart_edit: golden go" {
    try runGolden("go", &langs.go.go_language);
}
test "smart_edit: golden python" {
    try runGolden("python", &langs.python.python_language);
}
test "smart_edit: golden ts" {
    try runGolden("ts", &langs.js.typescript_language);
}
test "smart_edit: golden json" {
    try runGolden("json", &langs.json.json_language);
}
test "smart_edit: golden html" {
    try runGolden("html", &langs.html.html_language);
}
test "smart_edit: golden css" {
    try runGolden("css", &langs.css.css_language);
}
test "smart_edit: golden markdown" {
    try runGolden("markdown", &langs.markdown.markdown_language);
}
test "smart_edit: golden yaml" {
    try runGolden("yaml", &langs.yaml.yaml_language);
}
test "smart_edit: golden shell" {
    try runGolden("shell", &langs.shell.shell_language);
}

fn expectAfter(lang: *const zg_syntax.Language, before: []const u8, keys: []const u8, after: []const u8) !void {
    var h: Harness = undefined;
    try h.init(lang, before);
    defer h.deinit();
    try h.run(keys);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try h.render(&out);
    try std.testing.expectEqualStrings(after, out.items);
}

test "pairs: overtype only auto-inserted" {
    try expectAfter(&langs.zig.zig_language, "f¦", "()", "f()¦");
    // A closer that was already there is not typed over.
    try expectAfter(&langs.zig.zig_language, "f(¦)", ")", "f()¦)");
    // A caret jump forgets the closers.
    var h: Harness = undefined;
    try h.init(&langs.zig.zig_language, "x ¦");
    defer h.deinit();
    try h.run("(");
    h.ap.clear();
    try h.run(")");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try h.render(&out);
    try std.testing.expectEqualStrings("x ()¦)", out.items);
}

test "pairs: no autoclose in string" {
    try expectAfter(&langs.zig.zig_language, "const s = \"ab¦ cd\";", "(", "const s = \"ab(¦ cd\";");
    try expectAfter(&langs.zig.zig_language, "// note ¦", "(", "// note (¦");
    try expectAfter(&langs.zig.zig_language, "x = ¦", "(", "x = (¦)");
    // Not before a word.
    try expectAfter(&langs.zig.zig_language, "x = ¦foo", "(", "x = (¦foo");
    // A quote after a word character is an apostrophe.
    try expectAfter(&langs.markdown.markdown_language, "don¦", "'", "don'¦");
}

test "pairs: backspace deletes auto-inserted pair" {
    try expectAfter(&langs.zig.zig_language, "f¦", "(<bs>", "f¦");
    // Not a pair that was already there.
    try expectAfter(&langs.zig.zig_language, "f(¦)", "<bs>", "f¦)");
    try expectAfter(&langs.zig.zig_language, "s = ¦", "\"<bs>", "s = ¦");
}

test "pairs: surround with 3 selections" {
    try expectAfter(&langs.js.typescript_language, "«a» + «b» + «c»", "(", "(«a») + («b») + («c»)");
    try expectAfter(&langs.js.typescript_language, "«x» «y» «z»", "\"", "\"«x»\" \"«y»\" \"«z»\"");
}

test "comment: mixed commented lines toggles on" {
    try expectAfter(&langs.zig.zig_language, "«    a();\n    // b();\n\n    c();»", "<lc>", "«    // a();\n    // // b();\n\n    // c();»");
    try expectAfter(&langs.zig.zig_language, "«    // a();\n    //b();\n\n    // c();»", "<lc>", "«    a();\n    b();\n\n    c();»");
}

test "comment: html falls back to block comment" {
    try expectAfter(&langs.html.html_language, "«<p>a</p>\n  <p>b</p>»", "<lc>", "«<!-- <p>a</p> -->\n  <!-- <p>b</p> -->»");
    try expectAfter(&langs.html.html_language, "«<!-- <p>a</p> -->»", "<lc>", "«<p>a</p>»");
}

test "indent: guess tabs vs 2 vs 4" {
    const cases = [_]struct { text: []const u8, want: ?indent.IndentUnit }{
        .{ .text = "a\n\tb\n\t\tc\n\td\n", .want = .{ .tabs = true } },
        .{ .text = "a {\n  b {\n    c\n  }\n  d\n}\n", .want = .{ .size = 2 } },
        .{ .text = "a:\n    b:\n        c\n    d\n", .want = .{ .size = 4 } },
        .{ .text = "a\nb\n", .want = null },
    };
    for (cases) |c| {
        const doc = try Document.initBytes(gpa, @enumFromInt(1), c.text);
        defer doc.deinit();
        var snap = doc.snapshot();
        defer snap.release();
        try std.testing.expectEqual(c.want, indent.guess(&snap));
    }
}

test "smart: every command is one change" {
    var h: Harness = undefined;
    try h.init(&langs.zig.zig_language, "fn f() {¦}\nfn g() {¦}");
    defer h.deinit();
    const v = h.doc.version;
    try h.run("<enter>");
    try std.testing.expectEqual(v + 1, h.doc.version);
    try h.run("(");
    try std.testing.expectEqual(v + 2, h.doc.version);
}
