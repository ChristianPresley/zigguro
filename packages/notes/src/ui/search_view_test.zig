//! The note search view in a headless zg_gui window over a fixture vault
//! with a BM25F search index.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_notes = @import("zg_notes");
const zg_ai_proto = @import("zg_ai_proto");
const model_mod = @import("search_view_model.zig");
const search_view = @import("search_view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const FileId = zg_notes.FileId;
const OpKind = zg_notes.search.query.OpKind;

const notes = [_][2][]const u8{
    .{ "Bread.md", "# Bread\nMix the flour with water.\nKnead for ten minutes.\n#baking\n" },
    .{ "Cake.md", "# Cake\nSugar, eggs and flour.\nBake at 180.\n#baking #dessert\n" },
    .{ "Garden.md", "# Garden\nTomatoes need sun.\n" },
    .{ "Flour.md", "# Flour\nFlour types: bread flour, cake flour, rye flour.\n" },
};

/// Holds spawned jobs until `runAll`.
const Deferred = struct {
    jobs: [8]Job = undefined,
    n: usize = 0,

    const Job = struct { f: *const fn (*anyopaque) void, arg: *anyopaque };

    fn run(ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) void {
        const d: *Deferred = @ptrCast(@alignCast(ctx));
        d.jobs[d.n] = .{ .f = f, .arg = arg };
        d.n += 1;
    }

    fn runAll(d: *Deferred) void {
        for (d.jobs[0..d.n]) |j| j.f(j.arg);
        d.n = 0;
    }
};

const Recorder = struct {
    path: [128]u8 = undefined,
    len: usize = 0,
    range: ?[2]u32 = null,
    to_side: bool = false,
    opens: u32 = 0,
    ref: [128]u8 = undefined,
    ref_len: usize = 0,
    ref_kind: ?std.meta.Tag(zg_ai_proto.ContextRef) = null,
    notified: u32 = 0,

    fn open(ctx: *anyopaque, path: []const u8, range: ?[2]u32, to_side: bool) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        @memcpy(r.path[0..path.len], path);
        r.len = path.len;
        r.range = range;
        r.to_side = to_side;
        r.opens += 1;
    }

    fn attach(ctx: *anyopaque, ref: zg_ai_proto.ContextRef) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.ref_kind = ref;
        const s = switch (ref) {
            .search => |s| s,
            else => "",
        };
        @memcpy(r.ref[0..s.len], s);
        r.ref_len = s.len;
    }

    fn notify(ctx: *anyopaque) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        r.notified += 1;
    }
};

const Fx = struct {
    vault: zg_notes.Vault,
    ix: *zg_notes.NoteIndex,
    search: *zg_notes.search.SearchIndex,
    m: *model_mod.NoteSearchViewModel,
    view: *search_view.SearchView,
    t: *TestApp,
    rec: Recorder = .{},
    deferred: Deferred = .{},

    fn init(f: *Fx, spawn: bool, debounce_ms: u32) !void {
        f.rec = .{};
        f.deferred = .{};
        f.vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = .{} };
        f.ix = try zg_notes.NoteIndex.init(gpa, io, &.{f.vault});
        f.search = try zg_notes.search.SearchIndex.attach(f.ix, .{});
        for (notes, 0..) |n, i| try f.ix.indexNote(.{ .index = @intCast(i), .gen = 0 }, .of(0), n[0], n[1]);
        try f.ix.commit();
        f.m = try model_mod.NoteSearchViewModel.init(.{
            .gpa = gpa,
            .io = io,
            .ix = f.ix,
            .retriever = zg_notes.search.bm25Retriever(f.search, .{}),
            .content = .{ .ctx = f, .read = read },
            .spawn = if (spawn) .{ .ctx = &f.deferred, .run = Deferred.run } else null,
            .notify = .{ .ctx = &f.rec, .f = Recorder.notify },
            .open = .{ .ctx = &f.rec, .open = Recorder.open },
            .debounce_ms = debounce_ms,
        });
        f.view = try search_view.SearchView.init(gpa, f.m, .{ .attach = .{ .ctx = &f.rec, .f = Recorder.attach } });
        f.t = try TestApp.init(gpa, .{ .root = .of(f.view), .size = .{ .w = 640, .h = 900 } });
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.deferred.runAll();
        f.t.deinit();
        f.view.deinit();
        f.m.deinit();
        f.search.deinit();
        f.ix.deinit();
    }

    fn read(ctx: *anyopaque, a: std.mem.Allocator, id: FileId, path: []const u8) anyerror!?[]u8 {
        _ = ctx;
        _ = path;
        if (id.index >= notes.len) return null;
        return try a.dupe(u8, notes[id.index][1]);
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn typeQuery(f: *Fx, s: []const u8) !void {
        try f.t.click(.{ .role = .textbox, .name = "Search notes" });
        f.t.typeText(s);
    }

    fn count(f: *Fx) []const u8 {
        const n = f.t.find(.{ .test_id = "note-search-count" }) orelse return "";
        return (f.t.a11yOf(n) orelse return "").name;
    }
};

test "note_search_view: typing streams ranked results; older query cancelled" {
    var f: Fx = undefined;
    try f.init(true, 1);
    defer f.deinit();
    try f.typeQuery("flo");
    try f.typeQuery("ur");
    try testing.expectEqualStrings("flour", f.m.query.items);
    try testing.expectEqual(@as(usize, 2), f.deferred.n);
    try testing.expect(f.m.running);
    f.deferred.runAll();
    try testing.expectEqual(@as(u32, 1), f.m.droppedJobs());
    try testing.expectEqual(@as(u32, 1), f.rec.notified);
    f.settle();
    const rows = f.m.rows();
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(rows.len, f.m.results().len);
    // Flour.md says "flour" most; the bar is normalised to the top score.
    try testing.expectEqualStrings("Flour.md", rows[0].path);
    try testing.expectEqual(@as(f32, 1), rows[0].relevance);
    for (rows[1..]) |r| try testing.expect(r.relevance <= 1 and r.relevance > 0);
    try testing.expect(!f.m.stale());
    // The live region and a row with its tags.
    try testing.expectEqualStrings("3 notes", f.count());
    try testing.expect(f.t.find(.{ .role = .listitem, .name = "Cake (Cake.md)" }) != null);
    try testing.expect(f.t.find(.{ .name_contains = "#dessert" }) != null);
    const cake = for (rows) |r| {
        if (std.mem.eql(u8, r.path, "Cake.md")) break r;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), cake.tags.len);
    try testing.expect(cake.snippets.len > 0);
    const s = cake.snippets[0];
    try testing.expect(s.highlights.len > 0);
    try testing.expectEqualStrings("flour", s.text[s.highlights[0][0]..s.highlights[0][1]]);
}

test "note_search_view: parse error span underlined; previous results dimmed" {
    var f: Fx = undefined;
    try f.init(false, 0);
    defer f.deinit();
    try f.typeQuery("flour");
    try testing.expectEqual(@as(usize, 3), f.m.rows().len);
    try testing.expect(f.m.parseError() == null);
    f.t.typeText(" (bread");
    const pe = f.m.parseError() orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("unclosed (", pe.msg);
    try testing.expectEqual(@as(u32, 6), pe.span[0]);
    try testing.expect(f.t.find(.{ .test_id = "note-search-error" }) != null);
    try testing.expect(f.t.find(.{ .test_id = "note-search-error-span" }) != null);
    // The previous results stay, dimmed.
    try testing.expectEqual(@as(usize, 3), f.m.rows().len);
    try testing.expect(f.m.stale());
    try testing.expect(f.t.find(.{ .role = .listitem, .name = "Flour (Flour.md)" }) != null);
    // Fixing the query clears the error.
    f.t.typeText(")");
    try testing.expect(f.m.parseError() == null);
    try testing.expect(f.t.find(.{ .test_id = "note-search-error" }) == null);
    try testing.expect(!f.m.stale());
}

test "note_search_view: enter opens at best snippet" {
    var f: Fx = undefined;
    try f.init(false, 0);
    defer f.deinit();
    try f.typeQuery("knead");
    try testing.expectEqual(@as(usize, 1), f.m.rows().len);
    f.t.press(.enter, .{});
    try testing.expectEqual(@as(u32, 1), f.rec.opens);
    try testing.expectEqualStrings("Bread.md", f.rec.path[0..f.rec.len]);
    const r = f.rec.range orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, notes[0][1][r[0]..r[1]], "Knead") != null);
    try testing.expect(!f.rec.to_side);
    // Down moves the selection; Ctrl+Enter opens to the side.
    try f.t.click(.{ .role = .textbox, .name = "Search notes" });
    f.t.typeText(" OR sun");
    try testing.expectEqual(@as(usize, 2), f.m.rows().len);
    f.t.press(.arrow_down, .{});
    try testing.expectEqual(@as(usize, 1), f.m.selected);
    f.t.press(.enter, .{ .ctrl = true });
    try testing.expect(f.rec.to_side);
    try testing.expectEqual(@as(u32, 2), f.rec.opens);
    try testing.expect(f.t.find(.{ .test_id = "note-search-selected" }) != null);
}

test "note_search_view: alt+enter yields ContextRef.search" {
    var f: Fx = undefined;
    try f.init(false, 0);
    defer f.deinit();
    try f.typeQuery("tag:#baking flour");
    f.t.press(.enter, .{ .alt = true });
    try testing.expectEqual(@as(u32, 0), f.rec.opens);
    try testing.expect(f.rec.ref_kind.? == .search);
    try testing.expectEqualStrings("notes:tag:#baking flour", f.rec.ref[0..f.rec.ref_len]);
    try testing.expectEqualStrings(model_mod.context_scope ++ "tag:#baking flour", f.m.attachToAgent().search);
}

test "note_search_view: operator help lists every OpKind" {
    var f: Fx = undefined;
    try f.init(false, 0);
    defer f.deinit();
    try testing.expect(f.t.find(.{ .test_id = "note-search-help" }) == null);
    try f.t.click(.{ .role = .textbox, .name = "Search notes" });
    f.t.press(.slash, .{ .ctrl = true });
    const help = f.t.find(.{ .test_id = "note-search-help" }) orelse return error.TestUnexpectedResult;
    inline for (std.meta.fields(OpKind)) |fl| {
        const k: OpKind = @enumFromInt(fl.value);
        const h = search_view.opHelp(k);
        try testing.expect(std.mem.startsWith(u8, h.syntax, k.text()));
        try testing.expect(f.t.find(.{ .role = .listitem, .name = h.syntax, .within = help }) != null);
    }
    for (search_view.syntax_help) |h| try testing.expect(f.t.find(.{ .role = .listitem, .name = h.syntax, .within = help }) != null);
    // The `?` button toggles it too.
    try f.t.click(.{ .role = .button, .name = "?" });
    try testing.expect(f.t.find(.{ .test_id = "note-search-help" }) == null);
}

test "note_search_view: saved searches persist per vault" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var saved: model_mod.SavedSearches = .init(gpa);
    defer saved.deinit();
    try saved.load(io, tmp.dir);
    try testing.expectEqual(@as(usize, 0), saved.items.items.len);

    var f: Fx = undefined;
    try f.init(false, 0);
    defer f.deinit();
    f.view.o.saved = &saved;
    f.view.o.storage = tmp.dir;
    f.settle();
    try f.typeQuery("flour");
    try f.t.click(.{ .role = .button, .name = "Save search" });
    try testing.expectEqual(@as(usize, 1), saved.items.items.len);
    try saved.put("Baking", "tag:#baking");
    try saved.save(io, tmp.dir);

    var again: model_mod.SavedSearches = .init(gpa);
    defer again.deinit();
    try again.load(io, tmp.dir);
    try testing.expectEqual(@as(usize, 2), again.items.items.len);
    try testing.expectEqualStrings("flour", again.items.items[0].query);
    try testing.expectEqualStrings("Baking", again.items.items[1].name);
    // Clicking a saved search runs it.
    f.settle();
    try f.t.click(.{ .role = .button, .name = "Baking" });
    try testing.expectEqualStrings("tag:#baking", f.m.query.items);
    try testing.expectEqual(@as(usize, 2), f.m.rows().len);
}

test "note_search_view: empty query clears results" {
    var f: Fx = undefined;
    try f.init(false, 0);
    defer f.deinit();
    try f.typeQuery("flour");
    try testing.expectEqual(@as(usize, 3), f.m.rows().len);
    f.m.setQuery("");
    try testing.expectEqual(@as(usize, 0), f.m.rows().len);
    try testing.expect(!f.m.running);
}
