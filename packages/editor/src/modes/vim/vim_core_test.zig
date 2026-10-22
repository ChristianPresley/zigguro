//! Vim core conformance: scenario tables whose expectations come from
//! real Vim (testdata/vim/oracle.py), plus multi-cursor, undo grouping
//! and cw/column-1 cases.

const std = @import("std");
const golden = @import("../../model/edit/golden_testing.zig");
const key_mod = @import("../key.zig");
const mode_mod = @import("../mode.zig");
const state_mod = @import("state.zig");
const document = @import("../../model/document.zig");
const sel_mod = @import("../../model/edit/selection.zig");
const undo_mod = @import("../../model/edit/undo.zig");

const gpa = std.testing.allocator;
const Document = document.Document;
const VimState = state_mod.VimState;

/// A document, its selections and undo tree, and Vim driving them.
pub const Harness = struct {
    doc: *Document,
    sels: sel_mod.SelectionSet,
    undo: undo_mod.UndoTree,
    vs: VimState,
    host: mode_mod.Host,

    pub fn init(h: *Harness, marked: []const u8) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        var sels: std.ArrayList(sel_mod.Selection) = .empty;
        defer sels.deinit(gpa);
        try golden.parseMarked(marked, &text, &sels);
        h.doc = try Document.initBytes(gpa, @enumFromInt(1), text.items);
        h.sels = try .init(gpa, sels.items[0]);
        try h.sels.set(sels.items, 0);
        h.undo = .init(gpa, .{});
        h.vs = .init(gpa);
        h.host = .{ .doc = h.doc, .sels = &h.sels, .undo = &h.undo, .edit = .{ .auto_close = .never, .tab_size = 4, .insert_spaces = true } };
    }

    pub fn deinit(h: *Harness) void {
        h.vs.deinit();
        h.undo.deinit();
        h.sels.deinit();
        h.doc.deinit();
    }

    pub fn keys(h: *Harness, notation: []const u8) !void {
        var buf: [256]key_mod.Key = undefined;
        const n = try key_mod.parse(notation, &buf);
        for (buf[0..n]) |k| _ = try h.vs.handleKey(k, &h.host);
    }

    /// The text with the cursors or Visual area marked, then the mode,
    /// then the registers the scenario `name` asks for: the unnamed one
    /// for a name ending in `+reg`, each of X, Y, Z for `+reg:XYZ`.
    pub fn render(h: *Harness, name: []const u8) ![]u8 {
        const text = try h.doc.tree.copyRange(gpa, .{ .start = 0, .end = h.doc.len() });
        defer gpa.free(text);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try golden.renderMarked(text, h.sels.slice(), &out);
        const m: ?[]const u8 = switch (h.vs.mode) {
            .normal, .op_pending => null,
            .insert => "insert",
            .replace => "replace",
            .visual => "visual",
            .visual_line => "visual_line",
            .visual_block => "visual_block",
            .cmdline => "cmdline",
        };
        if (m) |mode_name| try out.print(gpa, "\n[{s}]", .{mode_name});
        if (std.mem.endsWith(u8, name, "+reg")) {
            try out.appendSlice(gpa, "\n[reg ");
            try h.renderReg(&out, '"');
        } else if (std.mem.lastIndexOf(u8, name, "+reg:")) |i| {
            for (name[i + 5 ..]) |r| {
                try out.print(gpa, "\n[reg:{c} ", .{r});
                try h.renderReg(&out, r);
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// `TYPE] "TEXT"` for register `name`; TYPE is `-` when it is empty.
    fn renderReg(h: *Harness, out: *std.ArrayList(u8), name: u8) !void {
        const r = h.vs.sh().regs.get(name) orelse {
            if (name == '"') return out.appendSlice(gpa, "v] \"\"");
            return out.appendSlice(gpa, "-] \"\"");
        };
        const kind = switch (r.kind) {
            .charwise => "v",
            .linewise => "V",
            .blockwise => "b",
        };
        const joined = try r.joined(gpa);
        defer gpa.free(joined);
        try out.print(gpa, "{s}] ", .{kind});
        try writeJson(out, joined);
    }
};

/// `s` as Python's `json.dumps(s, ensure_ascii=False)` writes it.
pub fn writeJson(out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '\n' => try out.appendSlice(gpa, "\\n"),
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        0x08 => try out.appendSlice(gpa, "\\b"),
        0x0C => try out.appendSlice(gpa, "\\f"),
        0...0x07, 0x0B, 0x0E...0x1F => try out.print(gpa, "\\u{x:0>4}", .{c}),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

pub fn runScenario(_: void, sc: golden.Scenario) anyerror![]u8 {
    var h: Harness = undefined;
    try h.init(sc.before);
    defer h.deinit();
    // An error shows as the scenario's result, naming the scenario.
    h.keys(sc.keys) catch |e| return std.fmt.allocPrint(gpa, "error: {t}", .{e});
    return h.render(sc.name);
}

test "vim: core conformance table" {
    // Expectations recorded from Vim 9.1; at least 300 scenarios in all.
    var failed = false;
    inline for (.{ .{ "motions", 90 }, .{ "operators", 120 }, .{ "text_objects", 55 }, .{ "visual", 75 }, .{ "insert_undo", 50 } }) |f| {
        golden.runGolden("testdata/vim/core/" ++ f[0] ++ ".txt", f[1], {}, runScenario) catch {
            failed = true;
        };
    }
    try std.testing.expect(!failed);
}

pub fn expectAfter(before: []const u8, keys: []const u8, after: []const u8) !void {
    var h: Harness = undefined;
    try h.init(before);
    defer h.deinit();
    try h.keys(keys);
    const got = try h.render("");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(after, got);
}

test "vim: cw special case" {
    // On a word "cw" changes to its end, like "ce"; on white space it
    // changes the white space up to the next word.
    try expectAfter("¦foo bar", "cwX<Esc>", "¦X bar");
    try expectAfter("fo¦o bar", "cwX<Esc>", "fo¦X bar");
    try expectAfter("foo¦  bar", "cwX<Esc>", "foo¦Xbar");
    try expectAfter("¦foo bar", "dwx", "¦ar");
}

test "vim: exclusive→inclusive column-1 rule" {
    // "dw" over a line break stops at the end of the line...
    try expectAfter("foo ¦bar\nbaz", "dw", "foo¦ \nbaz");
    // ...an exclusive motion ending in column 1 ends on the line before.
    try expectAfter("a¦b\ncd\n\nef", "d}", "¦a\n\nef");
    // ...and from within the indent it becomes linewise.
    try expectAfter("¦ab\ncd\n\nef", "d}", "¦\nef");
}

test "vim: visual block insert/append" {
    try expectAfter("a¦bc\ndef\nghi", "<C-v>jjIX<Esc>", "a¦Xbc\ndXef\ngXhi");
    try expectAfter("a¦bc\nd\nghi", "<C-v>jjlAX<Esc>", "a¦bcX\nd  X\nghiX");
}

test "vim: one undo group per change incl. insert session" {
    var h: Harness = undefined;
    try h.init("a¦bc");
    defer h.deinit();
    try h.keys("ione<CR>two<Esc>");
    try h.keys("x");
    try h.keys("cwnew<Esc>");
    // Three changes, three steps.
    try std.testing.expectEqual(@as(usize, 3), h.undo.nodes().len - 1);
    try h.keys("uuu");
    const got = try h.render("");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a¦bc", got);
}

test "vim: multi-cursor operators" {
    try expectAfter("¦foo bar\n¦baz qux", "dw", "¦bar\n¦qux");
    try expectAfter("¦foo bar\n¦baz qux", "cwX<Esc>", "¦X bar\n¦X qux");
    try expectAfter("¦one\ntwo\n¦three\nfour", "dd", "¦two\n¦four");
    try expectAfter("a¦b\nc¦d", "x", "¦a\n¦c");
    try expectAfter("¦ab\n¦cd", "AX<Esc>", "ab¦X\ncd¦X");
    try expectAfter("¦ab\n¦cd", "yyp", "ab\n¦ab\ncd\n¦cd");
    try expectAfter("¦one two\n¦three four", "w", "one ¦two\nthree ¦four");
    try expectAfter("¦one two\n¦three four", "viwU", "¦ONE two\n¦THREE four");
}

test "vim: status text and caret shape" {
    var h: Harness = undefined;
    try h.init("a¦bc");
    defer h.deinit();
    try std.testing.expectEqual(mode_mod.CaretShape.block, h.vs.caretShape());
    try h.keys("2d");
    try std.testing.expectEqualStrings("2d", h.vs.statusText());
    try std.testing.expectEqual(mode_mod.CaretShape.half_block, h.vs.caretShape());
    try h.keys("<Esc>i");
    try std.testing.expectEqualStrings("-- INSERT --", h.vs.statusText());
    try std.testing.expectEqual(mode_mod.CaretShape.bar, h.vs.caretShape());
    // Keys Vim does not handle go to the editor.
    var k: [1]key_mod.Key = undefined;
    _ = try key_mod.parse("<Esc>", &k);
    _ = try h.vs.handleKey(k[0], &h.host);
    _ = try key_mod.parse("<C-p>", &k);
    try std.testing.expectEqual(mode_mod.KeyResult.passthrough, try h.vs.handleKey(k[0], &h.host));
}
