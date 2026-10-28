//! The completion engine against the scripted fake server
//! (completion.script), and decoding and ranking on their own.

const std = @import("std");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Harness = @import("../Manager_test.zig").Harness;
const CompletionService = @import("completion.zig");
const rank = @import("completion_rank.zig");
const SnippetSession = @import("../snippet/Session.zig");

const testing = std.testing;
const gpa = testing.allocator;
const protocol = zg_lsp.protocol;
const EditorView = zg_editor.view.EditorView;

fn running(h: *Harness) bool {
    for (h.mgr.serverList()) |s| if (s.status == .running and s.sync != null and s.docs.items.len > 0 and s.sync.?.isTracked(s.docs.items[s.docs.items.len - 1])) return true;
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

/// Ticks until `pred` holds.
fn waitFor(h: *Harness, c: *CompletionService, comptime pred: fn (*CompletionService) bool) !void {
    for (0..2000) |_| {
        h.mgr.tick();
        _ = c.tick();
        if (pred(c)) return;
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

fn answered(c: *CompletionService) bool {
    const s = c.active() orelse return false;
    return c.req.done() and s.next == null and s.items.items.len > 0;
}

fn selectedResolved(c: *CompletionService) bool {
    const s = c.active() orelse return false;
    return s.item(s.selected.?).resolved;
}

fn labels(s: *const CompletionService.Session, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (0..s.list().len) |i| {
        if (i > 0) w.writeByte(' ') catch {};
        w.writeAll(s.item(@intCast(i)).label) catch {};
    }
    return w.buffered();
}

fn expectText(v: *EditorView, want: []const u8) !void {
    const t = try v.allText(gpa);
    defer gpa.free(t);
    try testing.expectEqualStrings(want, t);
}

test "completion: itemDefaults, merge and dedup, ranking, resolve, refilter, accept with additional edits in one undo step" {
    var h: Harness = undefined;
    try h.init("completion.script", &.{});
    defer h.deinit();
    const d = try h.open("main.zig", "const foo = 1;\nconst x = fo\n");
    defer {
        h.mgr.closeDoc(d);
        h.docs.release(d);
    }
    try waitRunning(&h);
    const view = try EditorView.init(gpa, h.docs.get(d).?, .{});
    defer view.deinit();
    var c = CompletionService.init(&h.mgr, .noop, .{ .resolve_delay = .fromMilliseconds(0) });
    defer c.deinit();
    var buf: [256]u8 = undefined;

    // Triggers: the server's characters, identifier characters in code.
    try testing.expectEqual(CompletionService.Trigger{ .character = '.' }, c.shouldTrigger(d, '.', .string).?);
    try testing.expectEqual(CompletionService.Trigger.invoked, c.shouldTrigger(d, 'a', .code).?);
    try testing.expect(c.shouldTrigger(d, 'a', .comment) == null);
    try testing.expect(c.shouldTrigger(d, '(', .code) == null);

    view.setSelection(.caret(27));
    try testing.expect(try c.start(d, 27, .invoked));
    try waitFor(&h, &c, answered);
    var s = c.active().?;
    // "bar" filtered out, the second "foo" merged; sortText orders the
    // ties and the deprecated item comes last.
    try testing.expectEqualStrings("forEach format fold foo fooBar", labels(s, &buf));
    const fe = s.item(0);
    try testing.expectEqual(rank.InsertFormat.snippet, fe.insert_format);
    try testing.expectEqualStrings("forEach(${1:x})$0", fe.edit.newText());
    try testing.expect(fe.edit == .insert_replace);
    try testing.expectEqualStrings(";", fe.commit_chars[0]);
    try testing.expectEqual(@as(usize, 0), s.item(2).commit_chars.len);
    try testing.expect(s.item(4).deprecated);

    // The top item is resolved: detail and documentation merged, the
    // edit kept.
    try waitFor(&h, &c, selectedResolved);
    try testing.expectEqualStrings("fn forEach(x)", fe.detail.?);
    try testing.expectEqualStrings("Calls *x*.", fe.doc.?.markdown);
    try testing.expectEqualStrings("forEach(${1:x})$0", fe.edit.newText());

    // Extending the pattern scores the survivors only; the exact match
    // ranks first.
    try view.insertText("o");
    try testing.expectEqual(CompletionService.Action.refilter, try c.update(d, 28));
    s = c.active().?;
    try testing.expectEqual(@as(usize, 5), s.ranker.scored);
    try testing.expectEqualStrings("foo fooBar", labels(s, &buf));
    try waitFor(&h, &c, selectedResolved);
    try testing.expectEqualStrings("const foo: comptime_int", s.item(0).detail.?);
    // Deleting scores everything again.
    try view.backspace(.char);
    try testing.expectEqual(CompletionService.Action.refilter, try c.update(d, 27));
    try testing.expectEqual(@as(usize, 6), s.ranker.scored);
    try testing.expectEqualStrings("foo", s.item(s.selected.?).label);
    try view.insertText("l");
    _ = try c.update(d, 28);
    try testing.expectEqualStrings("fold", labels(s, &buf));
    try waitFor(&h, &c, selectedResolved);

    // Accept: the typed "fol" replaced, the import added, one undo step.
    const acc = try c.accept(view, 0, .insert, null, null, .none);
    try testing.expectEqual(@as(u32, 1), acc.carets);
    try testing.expect(c.active() == null);
    try expectText(view, "// x\nconst foo = 1;\nconst x = fold\n");
    try testing.expectEqual(@as(u64, 34), view.primarySel().head);
    try testing.expect(try view.undoStep());
    try expectText(view, "const foo = 1;\nconst x = fol\n");

    // A trigger character; the list is incomplete, so typing re-queries
    // and keeps the old list (filtered) until the answer.
    c.opts.resolve_delay = .fromSeconds(3600);
    view.setSelection(.caret(29));
    try view.insertText("s.en");
    view.setSelection(.caret(31));
    try testing.expect(try c.start(d, 31, .{ .character = '.' }));
    try waitFor(&h, &c, answered);
    s = c.active().?;
    try testing.expectEqualStrings("len ptr", labels(s, &buf));
    try view.insertText("l");
    try testing.expectEqual(CompletionService.Action.requery, try c.update(d, 32));
    try testing.expectEqualStrings("len", labels(s, &buf));
    try waitFor(&h, &c, answered);
    try testing.expectEqualStrings("len lenient", labels(s, &buf));
    // Replace mode overwrites the word after the caret; "(" commits
    // (typed, so it is auto-closed).
    try testing.expect(c.isCommit(1, "("));
    try testing.expect(!c.isCommit(1, ";"));
    _ = try c.accept(view, 1, .replace, "(", null, .none);
    try expectText(view, "const foo = 1;\nconst x = fol\ns.lenient()");

    // A snippet at two carets: one undo step, its stops at both.
    const d2 = try h.open("snip.zig", "fo\nfo\n");
    defer {
        h.mgr.closeDoc(d2);
        h.docs.release(d2);
    }
    try waitRunning(&h);
    const v2 = try EditorView.init(gpa, h.docs.get(d2).?, .{});
    defer v2.deinit();
    try v2.setSelections(&.{ .caret(2), .caret(5) }, 0);
    var stack: SnippetSession.Stack = .init(gpa);
    defer stack.deinit();
    try testing.expect(try c.start(d2, 2, .invoked));
    try waitFor(&h, &c, answered);
    // Moving within the word refilters; a caret in another document
    // closes.
    try testing.expectEqual(CompletionService.Action.refilter, try c.update(d2, 1));
    try testing.expectEqual(CompletionService.Action.close, try c.update(d, 1));
    try testing.expect(c.active() == null);
    try testing.expect(try c.start(d2, 2, .invoked));
    try waitFor(&h, &c, answered);
    const sa = try c.accept(v2, 0, .insert, null, &stack, .none);
    try testing.expectEqual(@as(u32, 2), sa.carets);
    try testing.expect(sa.snippet);
    try expectText(v2, "for (it) {\n\t\n}\nfor (it) {\n\t\n}\n");
    const sels = v2.selections();
    try testing.expectEqual(@as(usize, 2), sels.len);
    try testing.expectEqual(@as(u64, 5), sels[0].start());
    try testing.expectEqual(@as(u64, 7), sels[0].end());
    try testing.expectEqual(@as(u64, 20), sels[1].start());
    try testing.expect(try stack.next());
    try testing.expectEqual(@as(u64, 12), v2.selections()[0].head);
    try testing.expect(try v2.undoStep());
    try expectText(v2, "fo\nfo\n");
}

test "completion: decode applies itemDefaults; item values win" {
    const json =
        \\{"isIncomplete": true, "itemDefaults": {"editRange": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 3}},
        \\ "commitCharacters": ["."], "insertTextFormat": 2, "insertTextMode": 2, "data": 7},
        \\ "items": [{"label": "a"}, {"label": "b", "insertTextFormat": 1, "commitCharacters": [], "data": 8, "textEditText": "bb", "filterText": "", "sortText": "0"},
        \\  {"label": "c", "textEdit": {"newText": "cc", "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}}, "deprecated": true, "documentation": "plain"}]}
    ;
    const parsed = try std.json.parseFromSlice(protocol.TextDocumentCompletionResult, gpa, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var items: std.ArrayList(rank.Item) = .empty;
    defer items.deinit(gpa);
    try testing.expect(try rank.decode(gpa, parsed.value, 2, &.{"("}, &items));
    const a = items.items[0];
    try testing.expectEqual(rank.InsertFormat.snippet, a.insert_format);
    try testing.expectEqual(rank.InsertMode.adjust_indentation, a.insert_mode);
    try testing.expectEqualStrings(".", a.commit_chars[0]);
    try testing.expectEqual(@as(i64, 7), a.data.?.integer);
    try testing.expectEqual(@as(u32, 1), a.edit.text_edit.range.start.character);
    try testing.expectEqualStrings("a", a.edit.newText());
    try testing.expectEqual(@as(u8, 2), a.server);
    const b = items.items[1];
    try testing.expectEqual(rank.InsertFormat.plain, b.insert_format);
    try testing.expectEqual(@as(usize, 0), b.commit_chars.len);
    try testing.expectEqual(@as(i64, 8), b.data.?.integer);
    try testing.expectEqualStrings("bb", b.edit.newText());
    // An empty filterText falls back to the label.
    try testing.expectEqualStrings("b", b.filter_text);
    try testing.expectEqualStrings("0", b.sort_text);
    const c = items.items[2];
    try testing.expectEqualStrings("cc", c.edit.newText());
    try testing.expectEqual(@as(u32, 0), c.edit.text_edit.range.end.character);
    try testing.expect(c.deprecated);
    try testing.expectEqualStrings("plain", c.doc.?.plain);

    // A plain array: no defaults, the client's commit characters.
    const arr = try std.json.parseFromSlice(protocol.TextDocumentCompletionResult, gpa, "[{\"label\": \"x\", \"insertText\": \"xx\"}]", .{ .ignore_unknown_fields = true });
    defer arr.deinit();
    items.clearRetainingCapacity();
    try testing.expect(!try rank.decode(gpa, arr.value, 0, &.{"("}, &items));
    try testing.expectEqualStrings("xx", items.items[0].edit.insert_text);
    try testing.expectEqualStrings("(", items.items[0].commit_chars[0]);
    try testing.expect(!try rank.decode(gpa, null, 0, &.{}, &items));
}

fn plainItem(label: []const u8, sort: ?[]const u8) rank.Item {
    return .{ .label = label, .sort_text = sort orelse label, .sort_key = rank.sortKey(sort orelse label), .filter_text = label, .edit = .{ .insert_text = label } };
}

test "completion: ranking by score, preselect, deprecation, recency and sortText" {
    var r = try rank.Ranker.init(gpa);
    defer r.deinit();
    var items = [_]rank.Item{
        plainItem("parseNode", "b"),
        plainItem("parse", "c"),
        plainItem("xparse", "a"),
        plainItem("parser", "a"),
        plainItem("Parse", "d"),
    };
    items[4].deprecated = true;
    items[2].preselect = true;
    var rec: rank.Recency = .{};
    defer rec.deinit(gpa);

    // Empty pattern: preselect first, then by sortText.
    try r.refilter(&items, "", null);
    try testing.expectEqual(@as(u32, 2), r.ranked.items[0].item);
    try testing.expectEqual(@as(u32, 3), r.ranked.items[1].item);
    try testing.expectEqual(@as(u32, 4), r.ranked.items[4].item);

    // The exact match first; the deprecated exact match after the others
    // with its score... and xparse (no first-character bonus) last.
    try r.refilter(&items, "parse", null);
    try testing.expectEqual(@as(u32, 1), r.ranked.items[0].item);
    try testing.expectEqual(@as(u32, 2), r.ranked.items[r.ranked.items.len - 1].item);

    // Recently accepted labels go before equal scores.
    try rec.note(gpa, "zig", "parseNode");
    try rec.note(gpa, "c", "parser");
    try r.refilter(&items, "pars", rec.view("zig"));
    try testing.expectEqual(@as(u32, 0), r.ranked.items[0].item);
    try r.refilter(&items, "pars", rec.view("c"));
    try testing.expectEqual(@as(u32, 3), r.ranked.items[0].item);

    // Survivors only when extending; everything after deleting.
    try r.refilter(&items, "parseN", null);
    try testing.expectEqual(@as(usize, 1), r.ranked.items.len);
    try r.refilter(&items, "parseNo", null);
    try testing.expectEqual(@as(usize, 1), r.scored);
    try r.refilter(&items, "pa", null);
    try testing.expectEqual(@as(usize, 5), r.scored);
    var m: [zg_lsp.fuzzy.max_pattern]u16 = undefined;
    try testing.expectEqual(@as(u8, 2), r.matches(&items[0], &m));
    try testing.expectEqual(@as(u16, 1), m[1]);
}

test "completion: recency keeps 64 labels per language" {
    var rec: rank.Recency = .{};
    defer rec.deinit(gpa);
    var name: [8]u8 = undefined;
    for (0..70) |i| try rec.note(gpa, "zig", try std.fmt.bufPrint(&name, "n{d}", .{i}));
    try rec.note(gpa, "c", "n0");
    const v = rec.view("zig");
    try testing.expectEqual(rank.Recency.View.none, v.rank("n0"));
    try testing.expectEqual(@as(u8, 0), v.rank("n69"));
    try testing.expectEqual(@as(u8, 63), v.rank("n6"));
    try testing.expectEqual(@as(u8, 0), rec.view("c").rank("n0"));
    // Noting again moves a label to the front.
    try rec.note(gpa, "zig", "n10");
    try testing.expectEqual(@as(u8, 0), rec.view("zig").rank("n10"));
}

test "completion: dedup key is label, kind and inserted text" {
    var a = plainItem("x", null);
    var b = plainItem("x", "other");
    try testing.expectEqual(rank.dedupKey(&a), rank.dedupKey(&b));
    b.kind = .Function;
    try testing.expect(rank.dedupKey(&a) != rank.dedupKey(&b));
    a.edit = .{ .insert_text = "y" };
    b.kind = null;
    try testing.expect(rank.dedupKey(&a) != rank.dedupKey(&b));
}

test "fuzz: completion accept never lands at stale offsets" {
    try std.testing.fuzz({}, struct {
        const Document = zg_editor.model.document.Document;
        const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;

        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            const doc = try Document.initBytes(gpa, @enumFromInt(1), "let x = foo;\n");
            defer doc.deinit();
            const v0 = doc.version;
            // The request: "foo" at 8..11, the caret after it.
            var cursor: u64 = 11;
            var fs: u64 = 8;
            var fe: u64 = 11;
            var touched = false;
            var n: usize = 0;
            while (!smith.eos() and n < 8) : (n += 1) {
                const len = doc.len();
                const a = smith.valueRangeAtMost(u64, 0, len);
                const b = smith.valueRangeAtMost(u64, a, @min(len, a + 4));
                const text = "zzz"[0..smith.valueRangeAtMost(u8, 0, 3)];
                if (a == b and text.len == 0) continue;
                // Typing at the caret is the one edit that keeps the word.
                const typing = a == b and a == fe;
                if (!typing and a <= fe and b >= fs and !(b == fs and a < b)) touched = true;
                var cs = try ChangeSet.fromEdits(gpa, len, &.{.{ .range = .{ .start = a, .end = b }, .text = text }});
                defer cs.deinit();
                try doc.applyChangeSet(&cs, .{ .user = 0 });
                cursor = cs.mapPos(cursor, .right);
                if (!touched) {
                    fs = cs.mapPos(fs, .left);
                    fe = cs.mapPos(fe, .left);
                }
            }
            const got = CompletionService.mainRange(doc, v0, .{ .start = 8, .end = 11 }, 11, cursor) orelse return;
            try testing.expect(got.start <= got.end and got.end <= doc.len());
            if (touched) return;
            const t = try doc.tree.copyRange(gpa, .{ .start = got.start, .end = @min(doc.len(), got.start + 3) });
            defer gpa.free(t);
            try testing.expectEqualStrings("foo", t);
        }
    }.f, .{});
}
