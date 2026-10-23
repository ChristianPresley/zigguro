//! Benchmarks for zg_notes; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_notes = @import("zg_notes");
const bench = zg_core.bench;
const gen = zg_notes.testing.gen;

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
    const gpa = std.heap.page_allocator;
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
