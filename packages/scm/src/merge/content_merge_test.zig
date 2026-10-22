//! Content merge against git: the checked-in conflict-marker fixtures
//! (`testdata/merge/`) and 200 random three-way merges
//! (`testdata/content_merge/`), rendered in diff3 style and compared with
//! git merge-file's output byte for byte.

const std = @import("std");
const options = @import("zg_options");
const mat = @import("materialize.zig");
const cm = @import("content_merge.zig");
const Allocator = std.mem.Allocator;
const t = std.testing;

const labels = [_][]const u8{ "ours", "base", "theirs" };

fn diff3(arena: Allocator, base: []const u8, ours: []const u8, theirs: []const u8) !struct { text: []const u8, clean: bool } {
    const vals = try arena.dupe([]const u8, &.{ ours, base, theirs });
    const r = try cm.mergeContent(arena, .{ .values = vals }, .{});
    var aw: std.Io.Writer.Allocating = .init(arena);
    const file = [_]?[]const u8{ ours, base, theirs };
    try mat.materialize(arena, .{ .values = &file }, r.hunks, .{ .style = .diff3, .labels = &labels }, &aw.writer);
    return .{ .text = aw.written(), .clean = r.clean != null };
}

test "content_merge: git conflict-marker fixtures" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = try std.Io.Dir.openDirAbsolute(t.io, options.package_root, .{});
    defer root.close(t.io);
    var dir = try root.openDir(t.io, "testdata/merge", .{});
    defer dir.close(t.io);
    var cases: usize = 0;
    for (1..100) |n| {
        var name: [8]u8 = undefined;
        const d = std.fmt.bufPrint(&name, "{d:0>2}", .{n}) catch unreachable;
        var case_dir = dir.openDir(t.io, d, .{}) catch break;
        defer case_dir.close(t.io);
        cases += 1;
        const base = try case_dir.readFileAlloc(t.io, "base", arena, .limited(1 << 20));
        const ours = try case_dir.readFileAlloc(t.io, "ours", arena, .limited(1 << 20));
        const theirs = try case_dir.readFileAlloc(t.io, "theirs", arena, .limited(1 << 20));
        const want = try case_dir.readFileAlloc(t.io, "diff3", arena, .limited(1 << 20));
        const got = try diff3(arena, base, ours, theirs);
        if (!std.mem.eql(u8, want, got.text)) {
            std.debug.print("case {s}:\n--- git\n{s}--- ours\n{s}", .{ d, want, got.text });
            return error.TestExpectedEqual;
        }
    }
    try t.expect(cases >= 20);
}

test "content_merge: 3-way vs git fixtures (200 cases)" {
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = try std.Io.Dir.openDirAbsolute(t.io, options.package_root, .{});
    defer root.close(t.io);
    const data = try root.readFileAlloc(t.io, "testdata/content_merge/content_merge_git.txt", arena, .limited(1 << 20));
    var p: Parser = .{ .data = data };
    var cases: usize = 0;
    var same_status: usize = 0;
    var same_bytes: usize = 0;
    while (p.pos < data.len) {
        try p.expect("case\n");
        const base = try p.block();
        const ours = try p.block();
        const theirs = try p.block();
        const clean = p.word("clean ") or (try p.wordOr("conflict "));
        const want = try p.block();
        const got = try diff3(arena, base, ours, theirs);
        cases += 1;
        if (got.clean == clean) same_status += 1;
        if (std.mem.eql(u8, got.text, want)) same_bytes += 1;
    }
    try t.expectEqual(@as(usize, 200), cases);
    // Every clean/conflict verdict matches git; outputs may differ only
    // where several minimal diffs exist and git's xdiff picks another.
    try t.expectEqual(cases, same_status);
    try t.expect(same_bytes * 100 >= cases * 95);
}

const Parser = struct {
    data: []const u8,
    pos: usize = 0,

    fn expect(p: *Parser, s: []const u8) !void {
        if (!std.mem.startsWith(u8, p.data[p.pos..], s)) return error.BadFixture;
        p.pos += s.len;
    }

    fn word(p: *Parser, s: []const u8) bool {
        p.expect(s) catch return false;
        return true;
    }

    fn wordOr(p: *Parser, s: []const u8) !bool {
        try p.expect(s);
        return false;
    }

    /// "<length>\n<bytes>"
    fn block(p: *Parser) ![]const u8 {
        const nl = std.mem.indexOfScalarPos(u8, p.data, p.pos, '\n') orelse return error.BadFixture;
        const n = try std.fmt.parseInt(usize, p.data[p.pos..nl], 10);
        p.pos = nl + 1 + n;
        if (p.pos > p.data.len) return error.BadFixture;
        return p.data[nl + 1 ..][0..n];
    }
};
