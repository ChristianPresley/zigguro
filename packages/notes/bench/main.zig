//! Benchmarks for zg_notes; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_notes = @import("zg_notes");
const bench = zg_core.bench;
const gen = zg_notes.testing.gen;
const search_model = @import("notes_search_model");

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn register(b: *bench.Bench) !void {
    const a = arena_state.allocator();

    // Budget: a 4 KB frontmatter parses in < 20 µs (E08.F06.S01.T03).
    var fm_src: std.Io.Writer.Allocating = .init(a);
    var k: u32 = 0;
    while (fm_src.written().len < 4096) : (k += 1) switch (k % 5) {
        0 => try fm_src.writer.print("key{d}: plain value number {d}\n", .{ k, k }),
        1 => try fm_src.writer.print("list{d}:\n  - one\n  - \"two\"\n  - 3\n", .{k}),
        2 => try fm_src.writer.print("flow{d}: [a, b, c, {d}]\n", .{ k, k }),
        3 => try fm_src.writer.print("date{d}: 2024-05-{d:0>2}\n", .{ k, k % 28 + 1 }),
        else => try fm_src.writer.print("quoted{d}: 'it''s {d}' # comment\n", .{ k, k }),
    };
    try b.run("notes/frontmatter_4kb", fm_src.written(), struct {
        fn f(src: []const u8, s: *bench.State) void {
            var arena: std.heap.ArenaAllocator = .init(s.allocator());
            defer arena.deinit();
            for (0..s.iterations()) |_| {
                _ = arena.reset(.retain_capacity);
                const n = zg_notes.frontmatter.parseFrontmatter(arena.allocator(), src, null) catch @panic("oom");
                bench.doNotOptimizeAway(n.value.map.len);
            }
            s.setBytes(src.len);
        }
    }.f);

    // Budget: extracting a 20 KB note takes < 0.5 ms (E08.F06.S01.T01).
    const note20 = try gen.sizedNote(a, 20 * 1024, 7);
    try b.run("notes/extract_20kb", note20, struct {
        fn f(src: []const u8, s: *bench.State) void {
            var arena: std.heap.ArenaAllocator = .init(s.allocator());
            defer arena.deinit();
            const cfg: zg_notes.VaultConfig = .{};
            for (0..s.iterations()) |_| {
                _ = arena.reset(.retain_capacity);
                const m = zg_notes.extract(arena.allocator(), src, "f/n.md", &cfg) catch @panic("oom");
                bench.doNotOptimizeAway(m.links.len);
            }
            s.setBytes(src.len);
        }
    }.f);

    // Budget: a 10 k note vault (50 k links, 2 k tags) indexes cold in
    // < 1.5 s; a backlinks query takes < 1 ms (E08.F06.S01.T02).
    const v10k = try gen.vault(a, .{ .notes = 10_000, .links_per_note = 5, .tags = 2000 });
    try b.run("notes/index_10k", &v10k, struct {
        fn f(v: *const gen.Vault, s: *bench.State) void {
            var bytes: usize = 0;
            for (v.notes) |n| bytes += n.len;
            for (0..s.iterations()) |_| {
                const ix = buildIndex(s.allocator(), s.ioHandle(), v) catch @panic("index");
                ix.deinit();
            }
            s.setBytes(bytes);
        }
    }.f);
    const ix10k = try buildIndex(std.heap.page_allocator, b.io, &v10k);
    const view10k = try ix10k.reader();
    try b.run("notes/backlinks_10k", view10k, struct {
        fn f(v: *const zg_notes.IndexView, s: *bench.State) void {
            var total: usize = 0;
            for (0..s.iterations()) |i| {
                const id: zg_notes.FileId = .{ .index = @intCast(i % 10_000), .gen = 0 };
                total += v.backlinks(id).len;
            }
            bench.doNotOptimizeAway(total);
        }
    }.f);

    // Budget: the `[[` completion list in < 16 ms for a 10 k-note vault
    // (E08.F06.S02.T02).
    try b.run("notes/complete_10k", view10k, struct {
        fn f(v: *const zg_notes.IndexView, s: *bench.State) void {
            var arena: std.heap.ArenaAllocator = .init(s.allocator());
            defer arena.deinit();
            const docs = [_][]const u8{ "see [[n12", "[[proj", "tags #t4", "[[n77#" };
            for (0..s.iterations()) |_| {
                _ = arena.reset(.retain_capacity);
                const d = docs[complete_turn % docs.len];
                complete_turn += 1;
                const items = zg_notes.lang.completion.complete(arena.allocator(), v, .{ .text = d, .cursor = @intCast(d.len), .path = "f1/n1.md", .vault = &whole_vault }) catch @panic("complete");
                bench.doNotOptimizeAway(items.len);
            }
        }
    }.f);

    // Budget: a hover preview of a 20 KB note in < 50 ms to first paint
    // (E08.F06.S02.T02; this is the slicing, before rendering).
    const hix = try zg_notes.NoteIndex.init(std.heap.page_allocator, b.io, &.{whole_vault});
    try hix.indexNote(.{ .index = 0, .gen = 0 }, .of(0), "Big.md", note20);
    try hix.commit();
    hover_note = note20;
    try b.run("notes/hover_20kb", try hix.reader(), struct {
        fn f(v: *const zg_notes.IndexView, s: *bench.State) void {
            var arena: std.heap.ArenaAllocator = .init(s.allocator());
            defer arena.deinit();
            const doc = "see [[Big]] here";
            for (0..s.iterations()) |_| {
                _ = arena.reset(.retain_capacity);
                const p = zg_notes.lang.hover.preview(arena.allocator(), v, &whole_vault, "x.md", doc, 7, .{ .ctx = undefined, .read = hoverRead }, 64 << 10) catch @panic("hover");
                bench.doNotOptimizeAway(p.?.text.len);
            }
        }
    }.f);

    // Budget: p95 < 20 ms over 20 mixed queries on the 10 k vault, and
    // the index ≤ 1.5× the vault text (E08.F06.S03.T01).
    const sx = try buildSearch(b.io, &v10k);
    var text_bytes: usize = 0;
    for (v10k.notes) |n| text_bytes += n.len;
    std.debug.print("notes search index: {d} KB for {d} KB of text ({d:.2}x)\n", .{ sx.s.memoryBytes() / 1024, text_bytes / 1024, @as(f64, @floatFromInt(sx.s.memoryBytes())) / @as(f64, @floatFromInt(text_bytes)) });
    const queries = [_][]const u8{
        "zig",               "project review",              "\"design notes\"",                 "meeting OR plan",
        "budget -release",   "tag:#t42",                    "tag:#area/3 zig",                  "[status:done] graph",
        "[rating:>3]",       "[created:>2024-06-01] agent", "file:n12",                         "path:f3/ index",
        "line:(zig editor)", "section:(section vault)",     "task-todo:open",                   "/rel+ease/",
        "content:workspace", "match-case:Note",             "(alpha OR beta) (gamma OR delta)", "lat",
    };
    const asts = try a.alloc(zg_notes.search.QueryAst, queries.len);
    for (queries, asts) |q, *ast| ast.* = zg_notes.search.parseQuery(a, q).ok;
    try b.run("notes/search_10k", asts, struct {
        fn f(qs: []const zg_notes.search.QueryAst, s: *bench.State) void {
            var out: std.ArrayList(zg_notes.search.Scored) = .empty;
            defer out.deinit(s.allocator());
            for (0..s.iterations()) |i| {
                out.clearRetainingCapacity();
                zg_notes.search.run(search_ctx.s, s.allocator(), &qs[i % qs.len], 50, &out) catch @panic("search");
                bench.doNotOptimizeAway(out.items.len);
            }
        }
    }.f);

    // Budget: results for a 10 k-note vault appear < 20 ms after the
    // debounce: parse, retrieve and resolve the first 50 rows with their
    // snippet text, which render at once (the top 200 follow; measured
    // as notes/search_view_200) (E08.F06.S03.T02).
    view_model = try search_model.NoteSearchViewModel.init(.{
        .gpa = std.heap.smp_allocator,
        .io = b.io,
        .ix = sx.ix,
        .retriever = zg_notes.search.bm25Retriever(sx.s, .{}),
        .content = .{ .ctx = @constCast(&v10k), .read = readNote },
        .debounce_ms = 0,
        .k = 50,
    });
    try b.run("notes/search_view", &queries, viewBench);
    view_model.o.k = 200;
    try b.run("notes/search_view_200", &queries, viewBench);

    // Budget: p95 < 100 ms per read tool call (search_notes, read_note,
    // note_links) on the 10 k vault (E08.F08.S02.T01).
    tools_src = .{
        .gpa = std.heap.page_allocator,
        .ix = sx.ix,
        .search = sx.s,
        .vault = &whole_vault,
        .files = .{ .ctx = @constCast(&v10k), .read = readByPath, .create = noCreate },
        .changes = .{ .ctx = undefined, .propose = noPropose },
        .tz = &utc_tz,
        .io = b.io,
    };
    const calls = [_][2][]const u8{
        .{ "search_notes", "{\"query\": \"project review\", \"limit\": 20}" },
        .{ "read_note", "{\"path\": \"f23/n123.md\"}" },
        .{ "note_links", "{\"path\": \"f17/n4567.md\", \"direction\": \"both\", \"depth\": 2}" },
        .{ "search_notes", "{\"query\": \"tag:#t42 zig\"}" },
    };
    try b.run("notes/tools_read_10k", &calls, struct {
        fn f(cs: *const [4][2][]const u8, s: *bench.State) void {
            var arena: std.heap.ArenaAllocator = .init(s.allocator());
            defer arena.deinit();
            for (0..s.iterations()) |_| {
                _ = arena.reset(.retain_capacity);
                const c = cs[tools_turn % cs.len];
                tools_turn += 1;
                const r = zg_notes.ai.tools.run(&tools_src, arena.allocator(), c[0], c[1]) catch @panic("tool");
                if (r.is_error) @panic(r.json);
                bench.doNotOptimizeAway(r.json.len);
            }
        }
    }.f);

    // Budget: opening today's (existing) daily note in the 10 k vault
    // takes < 50 ms (E08.F07.S02.T01).
    try ix10k.indexNote(.{ .index = 10_000, .gen = 0 }, .of(0), "daily/2026-10-21.md", "# today\n");
    try ix10k.commit();
    daily_ctx = .{ .gpa = std.heap.page_allocator, .io = b.io, .ix = ix10k, .vault = &whole_vault, .files = .{ .ctx = undefined, .read = noRead, .create = noCreate }, .tz = &utc_tz };
    try b.run("notes/daily_open_10k", &daily_ctx, struct {
        fn f(c: *zg_notes.daily.NotesCtx, s: *bench.State) void {
            for (0..s.iterations()) |_| {
                var o = c.openDaily(.{ .date = .{ .y = 2026, .m = 10, .d = 21 }, .h = 9, .min = 0, .s = 0, .utc_offset_s = 0 }) catch @panic("open");
                if (o.created) @panic("not found");
                o.deinit(c.gpa);
            }
        }
    }.f);

    // Budget: planning a rename with 500 inbound links takes < 100 ms
    // (E08.F06.S02.T01).
    const rix = try zg_notes.NoteIndex.init(std.heap.page_allocator, b.io, &.{whole_vault});
    for (0..500) |i| {
        const p = try std.fmt.allocPrint(a, "f{d}/src{d}.md", .{ i % 20, i });
        const body = try std.fmt.allocPrint(a, "see [[Target]] and [t](../Projects/Target.md) and [[Projects/Target#H|x]] {d}\n", .{i});
        try rix.indexNote(.{ .index = @intCast(i), .gen = 0 }, .of(0), p, body);
    }
    try rix.indexNote(.{ .index = 500, .gen = 0 }, .of(0), "Projects/Target.md", "# H\n");
    try rix.commit();
    const rview = try rix.reader();
    try b.run("notes/rename_500", rview, struct {
        fn f(v: *const zg_notes.IndexView, s: *bench.State) void {
            for (0..s.iterations()) |_| {
                var plan = zg_notes.refactor.planMoves(s.allocator(), v, &whole_vault, &.{.{ .from = "Projects/Target.md", .to = "Archive/Renamed.md" }}) catch @panic("plan");
                bench.doNotOptimizeAway(plan.edits.len);
                plan.deinit();
            }
        }
    }.f);
}

var utc_tz: zg_notes.daily.LocalTz = .utc(std.heap.page_allocator);
var daily_ctx: zg_notes.daily.NotesCtx = undefined;

fn noRead(ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
    _ = ctx;
    _ = gpa;
    _ = path;
    return null;
}

fn noCreate(ctx: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
    _ = ctx;
    _ = path;
    _ = bytes;
    return error.Unexpected;
}

var tools_src: zg_notes.ai.tools.Source = undefined;
var tools_turn: usize = 0;
var complete_turn: usize = 0;
var hover_note: []const u8 = "";

fn hoverRead(ctx: *anyopaque, gpa: std.mem.Allocator, id: zg_notes.FileId, path: []const u8) anyerror!?[]u8 {
    _ = ctx;
    _ = id;
    _ = path;
    return try gpa.dupe(u8, hover_note);
}

/// A generated note by its `f<k>/n<i>.md` path.
fn readByPath(ctx: *anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
    const v: *const gen.Vault = @ptrCast(@alignCast(ctx));
    const base = std.fs.path.basename(path);
    if (base.len < 5 or base[0] != 'n') return null;
    const i = std.fmt.parseInt(usize, base[1 .. base.len - 3], 10) catch return null;
    if (i >= v.notes.len) return null;
    return try gpa.dupe(u8, v.notes[i]);
}

fn noPropose(ctx: *anyopaque, label: []const u8, tool: []const u8, changes: []const zg_notes.ai.tools.FileChange) anyerror!u64 {
    _ = ctx;
    _ = label;
    _ = tool;
    _ = changes;
    return error.Unexpected;
}

var view_model: *search_model.NoteSearchViewModel = undefined;
var view_turn: usize = 0;

fn viewBench(qs: *const [20][]const u8, s: *bench.State) void {
    for (0..s.iterations()) |_| {
        view_model.setQuery(qs[view_turn % qs.len]);
        view_turn += 1;
        if (view_model.parseError() != null) @panic("parse");
        bench.doNotOptimizeAway(view_model.rows().len);
    }
}

const SearchCtx = struct { ix: *zg_notes.NoteIndex, s: *zg_notes.search.SearchIndex, vault: *const gen.Vault };
var search_ctx: SearchCtx = undefined;

/// Note text for verification, as an editor or disk would supply it.
fn readNote(ctx: *anyopaque, gpa: std.mem.Allocator, id: zg_notes.FileId, path: []const u8) anyerror!?[]u8 {
    _ = path;
    const v: *const gen.Vault = @ptrCast(@alignCast(ctx));
    if (id.index >= v.notes.len) return null;
    return try gpa.dupe(u8, v.notes[id.index]);
}

fn buildSearch(io: std.Io, v: *const gen.Vault) !SearchCtx {
    // The app runs the index on a general-purpose allocator.
    const gpa = std.heap.smp_allocator;
    const ix = try zg_notes.NoteIndex.init(gpa, io, &.{whole_vault});
    const s = try zg_notes.search.SearchIndex.attach(ix, .{ .content = .{ .ctx = @constCast(v), .read = readNote } });
    for (v.paths, v.notes, 0..) |p, n, i| try ix.indexNote(.{ .index = @intCast(i), .gen = 0 }, .of(0), p, n);
    try ix.commit();
    search_ctx = .{ .ix = ix, .s = s, .vault = v };
    return search_ctx;
}

const whole_vault: zg_notes.Vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = .{} };

fn buildIndex(gpa: std.mem.Allocator, io: std.Io, v: *const gen.Vault) !*zg_notes.NoteIndex {
    const ix = try zg_notes.NoteIndex.init(gpa, io, &.{whole_vault});
    errdefer ix.deinit();
    for (v.paths, v.notes, 0..) |p, n, i| try ix.indexNote(.{ .index = @intCast(i), .gen = 0 }, .of(0), p, n);
    try ix.commit();
    return ix;
}
