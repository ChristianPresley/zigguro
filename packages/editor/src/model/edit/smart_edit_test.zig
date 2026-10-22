//! Smart typing: per-language golden scenarios
//! (`testdata/golden/smart_edit/<lang>/cases.txt`) and unit tests for
//! pairs, comments and indentation guessing.
//!
//! Golden files use golden_testing.zig's format; keys are typed text,
//! with <enter> <bs> <lc> (line comment) <bc> (block comment) <lt> (a
//! literal '<') <tab>.

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const smart = @import("smart_edit.zig");
const indent = @import("indent.zig");
const pairs = @import("pairs.zig");
const sel_mod = @import("selection.zig");
const golden = @import("golden_testing.zig");
const document = @import("../document.zig");
const syntax_mod = @import("../syntax.zig");

const gpa = std.testing.allocator;
const Selection = sel_mod.Selection;
const SelectionSet = sel_mod.SelectionSet;
const Document = document.Document;
const langs = zg_syntax.langs;

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
        try golden.parseMarked(marked, &text, &sels);
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
        try golden.renderMarked(text, h.sels.slice(), out);
    }
};

fn runScenario(lang: *const zg_syntax.Language, sc: golden.Scenario) ![]u8 {
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
    return out.toOwnedSlice(gpa);
}

fn runGolden(dir: []const u8, lang: *const zg_syntax.Language) !void {
    const path = try std.fmt.allocPrint(gpa, "testdata/golden/smart_edit/{s}/cases.txt", .{dir});
    defer gpa.free(path);
    try golden.runGolden(path, 10, lang, runScenario);
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
