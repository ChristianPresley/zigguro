const std = @import("std");
const exec = @import("exec.zig");
const query = @import("query.zig");
const search_index = @import("search_index.zig");
const retriever = @import("retriever.zig");
const postings_mod = @import("postings.zig");
const note_index = @import("../index/note_index.zig");
const vault_mod = @import("../vault/vault.zig");
const gen = @import("../testing/gen.zig");

const testing = std.testing;
const FileId = @import("../vault/note.zig").FileId;
const NoteIndex = note_index.NoteIndex;
const SearchIndex = search_index.SearchIndex;

const whole_root: vault_mod.Vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = .{} };

fn fid(i: u32) FileId {
    return .{ .index = i, .gen = 0 };
}

const Fixture = struct {
    ix: *NoteIndex,
    s: *SearchIndex,
    paths: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,

    fn init(notes: []const [2][]const u8) !Fixture {
        const ix = try NoteIndex.init(testing.allocator, testing.io, &.{whole_root});
        var f: Fixture = .{ .ix = ix, .s = try SearchIndex.attach(ix, .{}), .arena = .init(testing.allocator) };
        for (notes) |n| try f.add(n[0], n[1]);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.s.deinit();
        f.ix.deinit();
        f.paths.deinit(testing.allocator);
        f.arena.deinit();
    }

    fn add(f: *Fixture, path: []const u8, bytes: []const u8) !void {
        const id = fid(@intCast(f.paths.items.len));
        try f.paths.append(testing.allocator, path);
        try f.ix.indexNote(id, .of(0), path, bytes);
    }

    /// The paths matching `q`, best first.
    fn run(f: *Fixture, q: []const u8) ![]const []const u8 {
        const a = f.arena.allocator();
        const ast = switch (query.parseQuery(a, q)) {
            .ok => |x| x,
            .err => |e| {
                std.debug.print("parse error in '{s}': {s}\n", .{ q, e.msg });
                return error.TestUnexpectedResult;
            },
        };
        var out: std.ArrayList(retriever.Scored) = .empty;
        defer out.deinit(testing.allocator);
        try exec.search(f.s, testing.allocator, &ast, 100, &out);
        const paths = try a.alloc([]const u8, out.items.len);
        for (out.items, paths) |r, *p| p.* = f.paths.items[r.note.index];
        return paths;
    }

    fn expect(f: *Fixture, q: []const u8, want: []const []const u8) !void {
        const got = try f.run(q);
        const a = f.arena.allocator();
        const sorted = try a.dupe([]const u8, got);
        std.mem.sort([]const u8, sorted, {}, lessStr);
        const w = try a.dupe([]const u8, want);
        std.mem.sort([]const u8, w, {}, lessStr);
        errdefer std.debug.print("query '{s}': got {d} results\n", .{ q, got.len });
        try testing.expectEqual(w.len, sorted.len);
        for (w, sorted) |x, y| try testing.expectEqualStrings(x, y);
    }
};

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "exec: terms, phrases, OR, negation and ranking" {
    var f = try Fixture.init(&.{
        .{ "zig.md", "# Zig\nZig is a systems language. Zig zig.\n" },
        .{ "rust.md", "# Rust\nRust is a systems language too.\n" },
        .{ "meeting.md", "Notes from the meeting about zig and rust.\n" },
        .{ "other.md", "Nothing to see here, foo-bar baz.\n" },
    });
    defer f.deinit();
    try f.expect("zig", &.{ "zig.md", "meeting.md" });
    try f.expect("systems language", &.{ "zig.md", "rust.md" });
    try f.expect("zig OR rust", &.{ "zig.md", "rust.md", "meeting.md" });
    try f.expect("language -rust", &.{"zig.md"});
    try f.expect("\"systems language\"", &.{ "zig.md", "rust.md" });
    try f.expect("\"language systems\"", &.{});
    try f.expect("meet", &.{"meeting.md"});
    try f.expect("foo-bar", &.{"other.md"});
    try f.expect("bar-foo", &.{});
    try f.expect("/fo+-ba./", &.{"other.md"});
    try f.expect("match-case:Zig", &.{"zig.md"});
    try f.expect("match-case:ZIG", &.{});
    try f.expect("ignore-case:/RUST IS/", &.{"rust.md"});
    try f.expect("file:rust", &.{"rust.md"});
    try f.expect("content:meeting", &.{"meeting.md"});
    try f.expect("nonexistent", &.{});
    // Titles and repeated terms rank first.
    const r = try f.run("zig");
    try testing.expectEqualStrings("zig.md", r[0]);
}

test "exec: tag filter includes child tags" {
    var f = try Fixture.init(&.{
        .{ "a.md", "#proj/alpha work\n" },
        .{ "b.md", "---\ntags: [proj]\n---\nbody\n" },
        .{ "c.md", "#project not nested\n" },
        .{ "d.md", "#Proj/Beta/Deep\n" },
    });
    defer f.deinit();
    try f.expect("tag:#proj", &.{ "a.md", "b.md", "d.md" });
    try f.expect("tag:proj/beta", &.{"d.md"});
    try f.expect("tag:#project", &.{"c.md"});
    try f.expect("tag:(#proj/alpha OR #project)", &.{ "a.md", "c.md" });
    try f.expect("-tag:#proj", &.{"c.md"});
    try f.expect("tag:#proj work", &.{"a.md"});
}

test "exec: property comparisons for number/date/string" {
    var f = try Fixture.init(&.{
        .{ "a.md", "---\nrating: 3\ndue: 2024-03-01\nstatus: Done\n---\n" },
        .{ "b.md", "---\nrating: 7.5\ndue: 2023-12-31T10:00\nstatus: open\n---\n" },
        .{ "c.md", "---\nrating:\nstatus: [open, blocked]\n---\n" },
        .{ "d.md", "no props\n" },
    });
    defer f.deinit();
    try f.expect("[rating]", &.{ "a.md", "b.md", "c.md" });
    try f.expect("[rating:null]", &.{"c.md"});
    try f.expect("[rating:<5]", &.{"a.md"});
    try f.expect("[rating:>5]", &.{"b.md"});
    try f.expect("[rating:3]", &.{"a.md"});
    try f.expect("[due:>2024-01-01]", &.{"a.md"});
    try f.expect("[due:<2024-01-01]", &.{"b.md"});
    try f.expect("[status:done]", &.{"a.md"});
    try f.expect("[status:open]", &.{ "b.md", "c.md" });
    try f.expect("[status:>n]", &.{ "b.md", "c.md" });
    try f.expect("[Status:blocked]", &.{"c.md"});
    try f.expect("-[rating]", &.{"d.md"});
}

test "exec: task-todo and section operators" {
    var f = try Fixture.init(&.{
        .{ "a.md", "# Groceries\n- [ ] buy milk\n- [x] buy bread\n# Work\nmix flour and water\n\nanother block milk\n" },
        .{ "b.md", "# Plan\n- [x] call bob\nmilk mentioned\n" },
        .{ "c.md", "mix the paint\nflour later\n" },
    });
    defer f.deinit();
    try f.expect("task-todo:milk", &.{"a.md"});
    try f.expect("task-done:bread", &.{"a.md"});
    try f.expect("task-done:milk", &.{});
    try f.expect("task:call", &.{"b.md"});
    try f.expect("task-todo:\"\"", &.{"a.md"});
    try f.expect("line:(mix flour)", &.{"a.md"});
    try f.expect("mix flour", &.{ "a.md", "c.md" });
    try f.expect("section:(groceries milk)", &.{"a.md"});
    try f.expect("section:(groceries flour)", &.{});
    try f.expect("block:(bread water)", &.{"a.md"});
    try f.expect("block:(water another)", &.{});
    try f.expect("block:(another milk)", &.{"a.md"});
    // A task query's snippet is the task line.
    const a = f.arena.allocator();
    const ast = query.parseQuery(a, "task-todo:milk").ok;
    var out: std.ArrayList(retriever.Scored) = .empty;
    defer out.deinit(testing.allocator);
    try exec.search(f.s, testing.allocator, &ast, 10, &out);
    try testing.expectEqual(@as(u8, 1), out.items[0].n_snippets);
    const sn = out.items[0].snippets[0];
    try testing.expectEqualStrings("- [ ] buy milk", "# Groceries\n- [ ] buy milk\n- [x] buy bread\n"[sn.range[0]..sn.range[1]]);
    try testing.expectEqual(@as(u32, 1), sn.line);
}

test "exec: removal, re-index and the retriever" {
    var f = try Fixture.init(&.{
        .{ "a.md", "alpha beta\n" },
        .{ "b.md", "beta gamma\n" },
    });
    defer f.deinit();
    try f.expect("beta", &.{ "a.md", "b.md" });
    try f.ix.removeFile(fid(0));
    try f.expect("beta", &.{"b.md"});
    try f.ix.indexNote(fid(1), .of(0), "b.md", "delta\n");
    try f.expect("beta", &.{});
    try f.expect("delta", &.{"b.md"});
    const r = retriever.bm25Retriever(f.s, .{});
    const ast = query.parseQuery(f.arena.allocator(), "delta").ok;
    var out: std.ArrayList(retriever.Scored) = .empty;
    defer out.deinit(testing.allocator);
    try r.retrieve(r.ctx, &ast, "delta", 5, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expect(out.items[0].score > 0);
}

/// (term, field, tf) triples of a doc, sorted.
fn docTriples(a: std.mem.Allocator, p: *const postings_mod.Postings, id: FileId) ![]const [3]u64 {
    var out: std.ArrayList([3]u64) = .empty;
    const doc = p.docOf(id) orelse return out.items;
    for (p.docs.items[doc].terms) |t| for (p.lists.items[t].items) |post| {
        if (post.doc != doc) continue;
        try out.append(a, .{ std.hash.Wyhash.hash(0, p.term_text.items[t]), @intFromEnum(post.field), post.tf });
    };
    std.mem.sort([3]u64, out.items, {}, struct {
        fn lt(_: void, x: [3]u64, y: [3]u64) bool {
            return std.mem.order(u64, &x, &y) == .lt;
        }
    }.lt);
    return out.items;
}

test "exec: incremental postings equal rebuild" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    const n = 60;
    const opts: gen.Options = .{ .notes = n, .links_per_note = 3, .tags = 20, .folders = 4, .paragraphs = 1 };
    var bodies: [n]?[]const u8 = undefined;
    for (&bodies, 0..) |*b, i| b.* = try gen.note(a, r, @intCast(i), opts);
    const inc_ix = try NoteIndex.init(testing.allocator, testing.io, &.{whole_root});
    defer inc_ix.deinit();
    const inc = try SearchIndex.attach(inc_ix, .{});
    defer inc.deinit();
    for (bodies, 0..) |b, i| try inc_ix.indexNote(fid(@intCast(i)), .of(0), try gen.notePath(a, @intCast(i), 4), b.?);
    for (0..400) |step| {
        const i = r.uintLessThan(u32, n);
        if (r.boolean() and bodies[i] != null) {
            bodies[i] = null;
            try inc_ix.removeFile(fid(i));
        } else {
            bodies[i] = try gen.note(a, r, i, opts);
            try inc_ix.indexNote(fid(i), .of(0), try gen.notePath(a, i, 4), bodies[i].?);
        }
        if (step % 50 != 49) continue;
        const full_ix = try NoteIndex.init(testing.allocator, testing.io, &.{whole_root});
        defer full_ix.deinit();
        const full = try SearchIndex.attach(full_ix, .{});
        defer full.deinit();
        for (bodies, 0..) |b, k| if (b) |x| try full_ix.indexNote(fid(@intCast(k)), .of(0), try gen.notePath(a, @intCast(k), 4), x);
        try testing.expectEqual(full.postings.live, inc.postings.live);
        try testing.expectEqual(full.postings.total_len, inc.postings.total_len);
        for (0..n) |k| {
            const x = try docTriples(a, &inc.postings, fid(@intCast(k)));
            const y = try docTriples(a, &full.postings, fid(@intCast(k)));
            try testing.expectEqual(y.len, x.len);
            for (x, y) |p, q| try testing.expectEqual(q, p);
        }
        // Document frequencies agree term by term.
        for (full.postings.term_text.items, 0..) |t, ft| {
            const it = inc.postings.termId(t).?;
            try testing.expectEqual(full.postings.df.items[ft], inc.postings.df.items[it]);
        }
    }
}
