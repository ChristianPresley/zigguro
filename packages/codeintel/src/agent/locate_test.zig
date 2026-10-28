//! Symbol addressing: names on or near a line, columns in characters,
//! and qualified names picked from workspace symbols.

const std = @import("std");
const zg_editor = @import("zg_editor");
const locate = @import("locate.zig");
const position = @import("../features/position.zig");

const testing = std.testing;
const Document = zg_editor.model.document.Document;

const source =
    \\const std = @import("std");
    \\
    \\pub fn main() void {
    \\    const x = foo(1) + foo(2);
    \\    _ = x;
    \\}
    \\
    \\fn foo(n: u32) u32 {
    \\    return n;
    \\}
    \\
;

const Fx = struct {
    doc: *Document,
    m: position.Mapper,

    fn init(text: []const u8) !Fx {
        const doc = try Document.initBytes(testing.allocator, @enumFromInt(1), text);
        return .{ .doc = doc, .m = .{ .gpa = testing.allocator, .tree = &doc.tree, .enc = .utf8 } };
    }
    fn deinit(f: *Fx) void {
        f.m.deinit();
        f.doc.deinit();
    }
    /// The hit as 1-based line:column (bytes).
    fn at(f: *Fx, ref: locate.SymbolRef) ![2]u64 {
        f.m.tree = &f.doc.tree;
        return switch (try locate.inDocument(&f.m, ref)) {
            .hit => |h| blk: {
                const p = try f.m.positionOf(h.offset);
                break :blk .{ h.line + 1, p.character + 1 };
            },
            .past_end => error.PastEnd,
            .not_found => error.NotFound,
        };
    }
};

fn name(line: u32, n: []const u8, occ: u32) locate.SymbolRef {
    return .{ .name_on_line = .{ .path = "a.zig", .line = line, .name = n, .occurrence = occ } };
}

test "locate: name_on_line exact / ±3 / occurrence / ambiguous" {
    var f: Fx = try .init(source);
    defer f.deinit();
    try testing.expectEqual([2]u64{ 4, 15 }, try f.at(name(4, "foo", 1)));
    try testing.expectEqual([2]u64{ 4, 24 }, try f.at(name(4, "foo", 2)));
    // Nearby lines count their first match; the line before wins a tie.
    try testing.expectEqual([2]u64{ 4, 15 }, try f.at(name(2, "foo", 1)));
    try testing.expectEqual([2]u64{ 8, 4 }, try f.at(name(7, "foo", 1)));
    try testing.expectError(error.NotFound, f.at(name(4, "foo", 3)));
    // One line off, before and after: the closest wins, earlier first.
    try testing.expectEqual([2]u64{ 3, 8 }, try f.at(name(4, "main", 1)));
    try testing.expectEqual([2]u64{ 3, 8 }, try f.at(name(2, "main", 1)));
    try testing.expectEqual([2]u64{ 4, 15 }, try f.at(name(1, "foo", 1)));
    // Whole words only.
    try testing.expectEqual([2]u64{ 4, 11 }, try f.at(name(4, "x", 1)));
    try testing.expectError(error.NotFound, f.at(name(4, "fo", 1)));
    try testing.expectError(error.NotFound, f.at(name(4, "", 1)));
    try testing.expectError(error.PastEnd, f.at(name(40, "foo", 1)));
    // Operators and builtins match without word boundaries at their ends.
    try testing.expectEqual([2]u64{ 1, 13 }, try f.at(name(1, "@import", 1)));
    try testing.expectEqual([2]u64{ 4, 22 }, try f.at(name(4, "+", 1)));
}

test "locate: column in scalar values with emoji line" {
    // An emoji is one character to an agent: 4 bytes, 2 UTF-16 units.
    var f: Fx = try .init("const s = \"\u{1F600}\u{e9}\"; const t = s;\n");
    defer f.deinit();
    const ref = struct {
        fn col(c: ?u32) locate.SymbolRef {
            return .{ .position = .{ .path = "a.zig", .line = 1, .column = c } };
        }
    }.col;
    // Column 14 is `"`, after the emoji (12) and the e-acute (13).
    try testing.expectEqual([2]u64{ 1, 1 + 10 + 1 + 4 + 2 }, try f.at(ref(14)));
    try testing.expectEqual([2]u64{ 1, 1 }, try f.at(ref(null)));
    // In UTF-16 the same character is column 15 (the emoji is two units).
    f.m.enc = .utf16;
    const p = try f.m.positionOf(10 + 1 + 4 + 2);
    try testing.expectEqual(@as(u32, 14), p.character);
    // Indented lines start at their first non-blank character.
    var g: Fx = try .init("\t  x = 1;\n");
    defer g.deinit();
    try testing.expectEqual([2]u64{ 1, 4 }, try g.at(ref(null)));
}

test "locate: forward from a symbol's range start" {
    var f: Fx = try .init(source);
    defer f.deinit();
    // `fn foo` from the start of its line; from inside the word's line
    // after it, the next lines.
    const line8 = f.m.cursor.seek(f.m.tree, 7);
    try testing.expectEqual(line8 + 3, (try locate.forward(&f.m, line8, "foo", 3)).?);
    try testing.expect(try locate.forward(&f.m, line8 + 4, "foo", 1) == null);
    try testing.expect(try locate.forward(&f.m, 0, "foo", 1) == null);
    try testing.expect(try locate.forward(&f.m, 0, "foo", 3) != null);
}

fn cand(n: []const u8, container: ?[]const u8, uri: []const u8) locate.Candidate {
    return .{ .name = n, .container = container, .uri = uri };
}

test "locate: qualified via workspace/symbol with container filter" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cands = [_]locate.Candidate{
        cand("Allocator", "mem", "file:///zig/lib/std/mem.zig"),
        cand("Allocator", "heap.ArenaAllocator", "file:///zig/lib/std/heap/arena_allocator.zig"),
        cand("init", "Pool", "file:///w/src/pool.zig"),
        cand("init", "Queue", "file:///w/src/queue.zig"),
        cand("deinit", null, "file:///w/src/Manager.zig"),
        cand("Store.prune", null, "file:///w/src/store.zig"),
        cand("Foo::bar", "", "file:///w/x.cpp"),
    };
    // The container's tail, or a longer qualifier ending in it.
    try testing.expectEqual(locate.Pick{ .one = 0 }, try locate.pick(a, &cands, "std.mem.Allocator"));
    try testing.expectEqual(locate.Pick{ .one = 0 }, try locate.pick(a, &cands, "mem.Allocator"));
    try testing.expectEqual(locate.Pick{ .one = 1 }, try locate.pick(a, &cands, "ArenaAllocator.Allocator"));
    try testing.expectEqual(locate.Pick{ .one = 2 }, try locate.pick(a, &cands, "Pool.init"));
    try testing.expectEqual(locate.Pick{ .one = 3 }, try locate.pick(a, &cands, "Queue::init"));
    // A Zig file is a struct: its name is a container.
    try testing.expectEqual(locate.Pick{ .one = 4 }, try locate.pick(a, &cands, "Manager.deinit"));
    // Servers that send qualified names.
    try testing.expectEqual(locate.Pick{ .one = 5 }, try locate.pick(a, &cands, "Store.prune"));
    try testing.expectEqual(locate.Pick{ .one = 6 }, try locate.pick(a, &cands, "Foo::bar"));
    // Several, or none.
    switch (try locate.pick(a, &cands, "init")) {
        .ambiguous => |at| try testing.expectEqualSlices(usize, &.{ 2, 3 }, at),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(locate.Pick.none, try locate.pick(a, &cands, "Deque.init"));
    try testing.expectEqual(locate.Pick.none, try locate.pick(a, &cands, "nothing"));
    try testing.expectEqual(locate.Pick.none, try locate.pick(a, &cands, ""));
    // At most ten candidates.
    var many: [15]locate.Candidate = undefined;
    for (&many, 0..) |*c, i| c.* = cand("run", try std.fmt.allocPrint(a, "T{d}", .{i}), "file:///w/t.zig");
    switch (try locate.pick(a, &many, "run")) {
        .ambiguous => |at| try testing.expectEqual(@as(usize, locate.max_candidates), at.len),
        else => return error.TestUnexpectedResult,
    }
    // An exact container beats a partial one.
    const two = [_]locate.Candidate{ cand("x", "a.b", "file:///w/1.zig"), cand("x", "b", "file:///w/2.zig") };
    try testing.expectEqual(locate.Pick{ .one = 1 }, try locate.pick(a, &two, "b.x"));
}
