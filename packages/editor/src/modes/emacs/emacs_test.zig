//! Emacs mode conformance: scripted key sequences whose expectations come
//! from GNU Emacs (testdata/emacs/oracle.py runs each in `emacs --batch`
//! as a keyboard macro), plus multi-cursor, isearch, argument and host
//! command cases.
//!
//! Scenario text marks point with `¦` and an active mark with `«`. A name
//! ending in `+kill` adds the newest kill, `+ring` the whole kill ring
//! (newest first), `+mark` the mark's offset (active or not).

const std = @import("std");
const options = @import("zg_options");
const key_mod = @import("../key.zig");
const mode_mod = @import("../mode.zig");
const emacs = @import("emacs.zig");
const document = @import("../../model/document.zig");
const sel_mod = @import("../../model/edit/selection.zig");
const undo_mod = @import("../../model/edit/undo.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;
const Document = document.Document;
const EmacsState = emacs.EmacsState;

const point_mark = "¦";
const mark_mark = "«";

const Harness = struct {
    doc: *Document,
    sels: sel_mod.SelectionSet,
    undo: undo_mod.UndoTree,
    es: EmacsState,
    host: mode_mod.Host,

    fn init(h: *Harness, marked: []const u8) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        var points: std.ArrayList(sel_mod.Selection) = .empty;
        defer points.deinit(gpa);
        var mark: ?u64 = null;
        var i: usize = 0;
        while (i < marked.len) {
            if (std.mem.startsWith(u8, marked[i..], point_mark)) {
                try points.append(gpa, .caret(text.items.len));
                i += point_mark.len;
            } else if (std.mem.startsWith(u8, marked[i..], mark_mark)) {
                mark = text.items.len;
                i += mark_mark.len;
            } else {
                try text.append(gpa, marked[i]);
                i += 1;
            }
        }
        if (mark) |m| points.items[0].anchor = m;
        h.doc = try Document.initBytes(gpa, @enumFromInt(1), text.items);
        h.sels = try .init(gpa, points.items[0]);
        try h.sels.set(points.items, 0);
        h.undo = .init(gpa, .{});
        h.es = .init(gpa);
        h.host = .{ .doc = h.doc, .sels = &h.sels, .undo = &h.undo, .edit = .{ .auto_close = .never, .tab_size = 8, .insert_spaces = false } };
    }

    fn deinit(h: *Harness) void {
        h.es.deinit();
        h.undo.deinit();
        h.sels.deinit();
        h.doc.deinit();
    }

    /// Feeds keys until one fails, as a keyboard macro stops.
    fn keys(h: *Harness, notation: []const u8) !void {
        var buf: [256]key_mod.Key = undefined;
        const n = try key_mod.parse(notation, &buf);
        for (buf[0..n]) |k| {
            _ = try h.es.handleKey(k, &h.host);
            if (h.es.failed) break;
        }
    }

    fn render(h: *Harness, name: []const u8) ![]u8 {
        const text = try h.doc.tree.copyRange(gpa, .{ .start = 0, .end = h.doc.len() });
        defer gpa.free(text);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const Mark = struct { at: u64, s: []const u8 };
        var marks: std.ArrayList(Mark) = .empty;
        defer marks.deinit(gpa);
        for (h.es.cursors.items) |c| {
            if (h.es.mark_active) if (c.mark) |m| try marks.append(gpa, .{ .at = m, .s = mark_mark });
            try marks.append(gpa, .{ .at = c.point, .s = point_mark });
        }
        std.sort.insertion(Mark, marks.items, {}, struct {
            fn lt(_: void, a: Mark, b: Mark) bool {
                return a.at < b.at;
            }
        }.lt);
        var prev: usize = 0;
        for (marks.items) |m| {
            try out.appendSlice(gpa, text[prev..@intCast(m.at)]);
            try out.appendSlice(gpa, m.s);
            prev = @intCast(m.at);
        }
        try out.appendSlice(gpa, text[prev..]);
        if (std.mem.endsWith(u8, name, "+kill")) {
            try out.appendSlice(gpa, "\n[kill] ");
            const r = &h.es.kill_ring;
            if (r.len() == 0) try out.append(gpa, '-') else try writeJson(&out, r.entries.items[r.entries.items.len - 1].joined);
        } else if (std.mem.endsWith(u8, name, "+ring")) {
            try out.appendSlice(gpa, "\n[ring] [");
            const items = h.es.kill_ring.entries.items;
            var i = items.len;
            while (i > 0) {
                i -= 1;
                try writeJson(&out, items[i].joined);
                if (i > 0) try out.appendSlice(gpa, ", ");
            }
            try out.append(gpa, ']');
        } else if (std.mem.endsWith(u8, name, "+mark")) {
            if (h.es.cursors.items[0].mark) |m| try out.print(gpa, "\n[mark {d}]", .{m}) else try out.appendSlice(gpa, "\n[mark -]");
        }
        return out.toOwnedSlice(gpa);
    }
};

/// `s` as Python's `json.dumps(s, ensure_ascii=False)` writes it.
fn writeJson(out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(gpa, '"');
    for (s) |c| switch (c) {
        '\n' => try out.appendSlice(gpa, "\\n"),
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        0...0x08, 0x0B, 0x0C, 0x0E...0x1F => try out.print(gpa, "\\u{x:0>4}", .{c}),
        else => try out.append(gpa, c),
    };
    try out.append(gpa, '"');
}

const Case = struct { name: []const u8, before: []const u8, keys: []const u8, after: []const u8 };

fn run(c: Case) ![]u8 {
    var h: Harness = undefined;
    try h.init(c.before);
    defer h.deinit();
    h.keys(c.keys) catch |e| return std.fmt.allocPrint(gpa, "error: {t}", .{e});
    return h.render(c.name);
}

/// Runs every case of a scenario file; at least `min` of them.
fn runTable(path: []const u8, min: usize) !usize {
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    const text = try root.readFileAllocOptions(io, path, gpa, .limited(1 << 20), .of(u8), 0);
    defer gpa.free(text);
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(gpa);
    const cases = std.zon.parse.fromSliceAlloc([]const Case, gpa, text, &diag, .{}) catch |e| {
        std.debug.print("{s}: {f}\n", .{ path, diag });
        return e;
    };
    defer std.zon.parse.free(gpa, cases);
    try std.testing.expect(cases.len >= min);
    var failed: usize = 0;
    for (cases) |c| {
        const got = try run(c);
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, c.after)) {
            failed += 1;
            std.debug.print("{s} \"{s}\" ({s}):\n--- want\n{s}\n--- got\n{s}\n", .{ path, c.name, c.keys, c.after, got });
        }
    }
    return failed;
}

test "emacs: scripted cases" {
    // Expectations recorded from GNU Emacs 29; at least 80 cases in all.
    var failed: usize = 0;
    inline for (.{ .{ "motion", 15 }, .{ "kill", 20 }, .{ "mark", 10 }, .{ "isearch", 10 }, .{ "arg", 10 }, .{ "edit", 10 }, .{ "undo", 6 }, .{ "query", 6 } }) |f| {
        failed += try runTable("testdata/emacs/" ++ f[0] ++ ".zon", f[1]);
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

fn expectAfter(before: []const u8, keys: []const u8, after: []const u8) !void {
    var h: Harness = undefined;
    try h.init(before);
    defer h.deinit();
    try h.keys(keys);
    const got = try h.render("");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(after, got);
}

test "emacs: isearch incremental and C-g restore" {
    var h: Harness = undefined;
    try h.init("¦foo bar baz bar");
    defer h.deinit();
    try h.keys("<C-s>ba");
    try std.testing.expectEqualStrings("I-search: ba", h.es.statusText());
    try std.testing.expectEqual(@as(u64, 6), h.es.cursors.items[0].point);
    // The match is the host selection while searching.
    try std.testing.expectEqual(@as(u64, 4), h.sels.primary().anchor);
    try h.keys("z");
    try std.testing.expectEqual(@as(u64, 11), h.es.cursors.items[0].point);
    try h.keys("<BS>");
    try std.testing.expectEqual(@as(u64, 6), h.es.cursors.items[0].point);
    try h.keys("<C-s>");
    try std.testing.expectEqual(@as(u64, 10), h.es.cursors.items[0].point);
    try h.keys("q");
    try std.testing.expectEqualStrings("Failing I-search: baq", h.es.statusText());
    // C-g first drops what fails, then gives up and goes back.
    try h.keys("<C-g>");
    try std.testing.expectEqualStrings("I-search: ba", h.es.statusText());
    try h.keys("<C-g>");
    try std.testing.expect(h.es.failed);
    try std.testing.expect(h.es.isearch == null);
    try std.testing.expectEqual(@as(u64, 0), h.es.cursors.items[0].point);
    // C-s C-s searches for the last string again.
    try expectAfter("¦ab ab ab", "<C-s>ab<CR><C-s><C-s><CR>", "ab ab¦ ab");
    // Regexp search.
    try expectAfter("¦x1 y22 z", "<C-M-s>[0-9]+<CR>", "x1¦ y22 z");
    try expectAfter("¦x1 y22 z", "<C-M-s>y[0-9]\\{2\\}<CR>", "x1 y22¦ z");
}

test "emacs: universal argument" {
    try expectAfter("¦abcdefgh", "<C-u><C-f>", "abcd¦efgh");
    try expectAfter("¦", "<C-u><C-u>x", "xxxxxxxxxxxxxxxx¦");
    try expectAfter("¦abcdefgh", "<C-u>3<C-f>", "abc¦defgh");
    try expectAfter("¦abcdefghijklmn", "<C-u>12<C-f>", "abcdefghijkl¦mn");
    try expectAfter("¦abcdefgh", "<M-5><C-f>", "abcde¦fgh");
    try expectAfter("abcd¦efgh", "<M-->2<C-f>", "ab¦cdefgh");
    try expectAfter("abcd¦efgh", "<C-u>-<C-f>", "abc¦defgh");
    var h: Harness = undefined;
    try h.init("¦");
    defer h.deinit();
    try h.keys("<C-u>");
    try std.testing.expectEqualStrings("C-u 4-", h.es.statusText());
    try h.keys("2");
    try std.testing.expectEqualStrings("C-u 2-", h.es.statusText());
}

test "emacs: region kill" {
    try expectAfter("¦foo bar", "<C-Space><M-f><C-w>", "¦ bar");
    try expectAfter("foo bar¦", "<C-Space><M-b><M-b><C-w><C-y>", "foo bar¦");
    // Without a mark there is no region.
    var h: Harness = undefined;
    try h.init("¦foo");
    defer h.deinit();
    try h.keys("<C-w>");
    try std.testing.expect(h.es.failed);
    try std.testing.expectEqualStrings("The mark is not set now, so there is no region", h.es.statusText());
}

test "emacs: multi-cursor kills and yanks" {
    var h: Harness = undefined;
    try h.init("¦one two\n¦three four");
    defer h.deinit();
    try h.keys("<M-d>");
    const e = h.es.kill_ring.entries.items[0];
    try std.testing.expectEqual(@as(usize, 2), e.pieces.len);
    try std.testing.expectEqualStrings("one\nthree", e.joined);
    // Each cursor yanks its own piece back.
    try h.keys("<C-e><C-y>");
    const got = try h.render("");
    defer gpa.free(got);
    try std.testing.expectEqualStrings(" twoone¦\n fourthree¦", got);
}

const FakeActions = struct {
    log: std.ArrayList(u8) = .empty,

    fn runFn(ctx: *anyopaque, a: mode_mod.Action) anyerror!void {
        const f: *FakeActions = @ptrCast(@alignCast(ctx));
        switch (a) {
            .command => |c| try f.log.print(gpa, "{s};", .{c}),
            else => try f.log.appendSlice(gpa, "other;"),
        }
    }
};

test "emacs: C-x chords and M-x run workbench commands" {
    var h: Harness = undefined;
    try h.init("¦abc");
    defer h.deinit();
    var fake: FakeActions = .{};
    defer fake.log.deinit(gpa);
    h.host.actions = .{ .ctx = &fake, .runFn = FakeActions.runFn };
    try h.keys("<C-x><C-s><C-x><C-f><C-x>b<C-x>k<M-x>");
    try std.testing.expectEqualStrings("file.save;file.open;quickOpen.editors;workbench.closeEditor;workbench.showCommands;", fake.log.items);
    // The chords agree with the E15 keymap layer.
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    const src = try root.readFileAllocOptions(io, "data/keymaps/emacs.zon", gpa, .limited(1 << 16), .of(u8), 0);
    defer gpa.free(src);
    const Binding = struct { key: []const u8, command: []const u8, when: ?[]const u8 = null };
    const layer = try std.zon.parse.fromSliceAlloc([]const Binding, gpa, src, null, .{ .ignore_unknown_fields = true });
    defer std.zon.parse.free(gpa, layer);
    const want = [_][2][]const u8{
        .{ "ctrl+x ctrl+s", emacs.commands.save },
        .{ "ctrl+x ctrl+f", emacs.commands.find_file },
        .{ "ctrl+x b", emacs.commands.switch_buffer },
        .{ "ctrl+x k", emacs.commands.kill_buffer },
        .{ "alt+x", emacs.commands.execute_command },
    };
    for (want) |w| {
        const found = for (layer) |b| {
            if (std.mem.eql(u8, b.key, w[0])) break b.command;
        } else "";
        try std.testing.expectEqualStrings(w[1], found);
    }
}

test "emacs: self-inserts amalgamate up to 20 per undo step" {
    var h: Harness = undefined;
    try h.init("¦");
    defer h.deinit();
    try h.keys("abc<C-f>");
    try h.keys("<C-a>xyz");
    try std.testing.expectEqual(@as(usize, 2), h.undo.nodes().len - 1);
    try h.keys("<C-/>");
    const got = try h.render("");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("¦abc", got);
    // The 21st character starts a new step.
    var h2: Harness = undefined;
    try h2.init("¦");
    defer h2.deinit();
    try h2.keys("abcdefghijklmnopqrstuvwxy");
    try std.testing.expectEqual(@as(usize, 2), h2.undo.nodes().len - 1);
}
