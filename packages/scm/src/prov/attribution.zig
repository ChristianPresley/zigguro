//! Attribution maps (E09.F05): which provenance record wrote each line of
//! a file, as run-length line ranges. A run whose record is
//! `ObjectId.zero` was not written by this change: it is inherited from
//! the parent, and blame answers for it. Maps are stored compactly inside
//! a change's manifest (`manifest.zig`): the distinct records once, then
//! runs as varint (length, record index) pairs.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const materialize = @import("../merge/materialize.zig");
const ObjectId = id_mod.ObjectId;
const Allocator = std.mem.Allocator;

/// The record of lines this change did not write.
pub const inherited: ObjectId = .zero;

pub const Run = struct {
    start_line: u32,
    len: u32,
    prov: ObjectId,
    /// Human edits of lines another actor wrote.
    mixed: bool = false,
};

/// A run without its position, for building maps.
pub const Seg = struct {
    len: u32,
    prov: ObjectId,
    mixed: bool = false,

    fn same(a: Seg, b: Seg) bool {
        return a.prov.eql(b.prov) and a.mixed == b.mixed;
    }
};

/// Runs in line order, covering lines 0..lineCount() without gaps;
/// adjacent runs differ.
pub const AttributionMap = struct {
    runs: []const Run = &.{},

    pub fn lineCount(m: AttributionMap) u32 {
        if (m.runs.len == 0) return 0;
        const last = m.runs[m.runs.len - 1];
        return last.start_line + last.len;
    }

    /// The run holding `line`, or null past the end.
    pub fn at(m: AttributionMap, line: u32) ?Run {
        var lo: usize = 0;
        var hi: usize = m.runs.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const r = m.runs[mid];
            if (line < r.start_line) hi = mid else if (line >= r.start_line + r.len) lo = mid + 1 else return r;
        }
        return null;
    }

    pub fn eql(a: AttributionMap, b: AttributionMap) bool {
        if (a.runs.len != b.runs.len) return false;
        for (a.runs, b.runs) |x, y| {
            if (x.start_line != y.start_line or x.len != y.len or x.mixed != y.mixed or !x.prov.eql(y.prov)) return false;
        }
        return true;
    }

    /// Whether every line is inherited.
    pub fn allInherited(m: AttributionMap) bool {
        for (m.runs) |r| if (!r.prov.eql(inherited)) return false;
        return true;
    }

    pub fn validate(m: AttributionMap) object.ValidateError!void {
        var next: u32 = 0;
        for (m.runs, 0..) |r, i| {
            if (r.len == 0 or r.start_line != next) return error.InvalidAttribution;
            if (i > 0 and Seg.same(.{ .len = 0, .prov = m.runs[i - 1].prov, .mixed = m.runs[i - 1].mixed }, .{ .len = 0, .prov = r.prov, .mixed = r.mixed })) return error.InvalidAttribution;
            next = std.math.add(u32, next, r.len) catch return error.InvalidAttribution;
        }
    }
};

/// A mutable map. Splices are O(runs).
pub const Builder = struct {
    gpa: Allocator,
    segs: std.ArrayList(Seg) = .empty,

    pub fn init(gpa: Allocator) Builder {
        return .{ .gpa = gpa };
    }

    /// `lines` inherited lines.
    pub fn initInherited(gpa: Allocator, lines: u32) !Builder {
        var b: Builder = .init(gpa);
        try b.push(.{ .len = lines, .prov = inherited });
        return b;
    }

    pub fn initFrom(gpa: Allocator, m: AttributionMap) !Builder {
        var b: Builder = .init(gpa);
        errdefer b.deinit();
        try b.segs.ensureTotalCapacity(gpa, m.runs.len);
        for (m.runs) |r| try b.push(.{ .len = r.len, .prov = r.prov, .mixed = r.mixed });
        return b;
    }

    pub fn deinit(b: *Builder) void {
        b.segs.deinit(b.gpa);
    }

    pub fn lineCount(b: *const Builder) u32 {
        var n: u32 = 0;
        for (b.segs.items) |s| n += s.len;
        return n;
    }

    /// Appends `s`, merging it into the last run when they match.
    pub fn push(b: *Builder, s: Seg) !void {
        if (s.len == 0) return;
        if (b.segs.items.len > 0) {
            const last = &b.segs.items[b.segs.items.len - 1];
            if (last.same(s)) {
                last.len += s.len;
                return;
            }
        }
        try b.segs.append(b.gpa, s);
    }

    /// The runs over lines start..start+len, cut to that range, into
    /// `arena`.
    pub fn slice(b: *const Builder, arena: Allocator, start: u32, len: u32) ![]Seg {
        var out: std.ArrayList(Seg) = .empty;
        var pos: u32 = 0;
        const end = start + len;
        for (b.segs.items) |s| {
            const s_end = pos + s.len;
            defer pos = s_end;
            if (s_end <= start) continue;
            if (pos >= end) break;
            const lo = @max(pos, start);
            const hi = @min(s_end, end);
            try out.append(arena, .{ .len = hi - lo, .prov = s.prov, .mixed = s.mixed });
        }
        return out.items;
    }

    /// Replaces lines start..start+old_len with `new` (in order).
    pub fn replace(b: *Builder, start: u32, old_len: u32, new: []const Seg) !void {
        const count = b.lineCount();
        if (start > count or old_len > count - start) return error.OutOfRange;
        var out: Builder = .init(b.gpa);
        errdefer out.deinit();
        try out.segs.ensureTotalCapacity(b.gpa, b.segs.items.len + new.len + 1);
        var pos: u32 = 0;
        var placed = false;
        const end = start + old_len;
        for (b.segs.items) |s| {
            const s_end = pos + s.len;
            defer pos = s_end;
            if (pos < start) try out.push(.{ .len = @min(s_end, start) - pos, .prov = s.prov, .mixed = s.mixed });
            if (!placed and s_end >= start) {
                for (new) |n| try out.push(n);
                placed = true;
            }
            if (s_end > end) try out.push(.{ .len = s_end - @max(pos, end), .prov = s.prov, .mixed = s.mixed });
        }
        if (!placed) for (new) |n| try out.push(n);
        b.segs.deinit(b.gpa);
        b.segs = out.segs;
    }

    /// Replaces lines start..start+old_len with new_len lines of `prov`.
    pub fn splice(b: *Builder, start: u32, old_len: u32, new_len: u32, prov: ObjectId, mixed: bool) !void {
        return b.replace(start, old_len, &.{.{ .len = new_len, .prov = prov, .mixed = mixed }});
    }

    /// The map, allocated in `arena`.
    pub fn toMap(b: *const Builder, arena: Allocator) !AttributionMap {
        const runs = try arena.alloc(Run, b.segs.items.len);
        var pos: u32 = 0;
        for (runs, b.segs.items) |*r, s| {
            r.* = .{ .start_line = pos, .len = s.len, .prov = s.prov, .mixed = s.mixed };
            pos += s.len;
        }
        return .{ .runs = runs };
    }
};

/// Lines of `text` as attribution counts them: a final line without a
/// newline counts, an empty text has none.
pub fn lineCountOf(text: []const u8) u32 {
    if (text.len == 0) return 0;
    var n: u32 = @intCast(std.mem.count(u8, text, "\n"));
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

/// `old_map` (over `old_text`) carried to `new_text`: lines the line diff
/// keeps copy their run, changed and inserted lines get `filler`. With
/// no content change the map is copied exactly.
pub fn mapThroughDiff(gpa: Allocator, arena: Allocator, old_map: AttributionMap, old_text: []const u8, new_text: []const u8, filler: Seg) !AttributionMap {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const s = scratch.allocator();
    const a = try materialize.splitLines(s, old_text);
    const b = try materialize.splitLines(s, new_text);
    if (old_map.lineCount() != a.len) return error.MapMismatch;
    var out: Builder = .init(gpa);
    defer out.deinit();
    const ops = try materialize.diffLines(s, a, b);
    for (ops) |op| switch (op.kind) {
        .equal => {
            const r = old_map.at(@intCast(op.index)).?;
            try out.push(.{ .len = 1, .prov = r.prov, .mixed = r.mixed });
        },
        .insert => try out.push(.{ .len = 1, .prov = filler.prov, .mixed = filler.mixed }),
        .delete => {},
    };
    return out.toMap(arena);
}

const testing = std.testing;

fn idN(n: u8) ObjectId {
    var o: ObjectId = .zero;
    o.bytes[0] = n;
    return o;
}

test "attribution: splice, slice and lookup" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var b = try Builder.initInherited(gpa, 10);
    defer b.deinit();
    try b.splice(2, 3, 4, idN(1), false); // 0-1 inh, 2-5 #1, 6-10 inh
    try b.splice(4, 0, 2, idN(2), false); // insert inside the #1 run
    try b.splice(0, 0, 1, idN(1), false);
    const m = try b.toMap(a);
    try m.validate();
    try testing.expectEqual(@as(u32, 14), m.lineCount());
    try testing.expect(m.at(0).?.prov.eql(idN(1)));
    try testing.expect(m.at(1).?.prov.eql(inherited));
    try testing.expect(m.at(5).?.prov.eql(idN(2)));
    try testing.expect(m.at(7).?.prov.eql(idN(1)));
    try testing.expect(m.at(13).?.prov.eql(inherited));
    try testing.expect(m.at(14) == null);
    const sl = try b.slice(a, 4, 4);
    try testing.expectEqual(@as(usize, 3), sl.len);
    try testing.expectEqual(@as(u32, 1), sl[0].len);
    try testing.expect(sl[1].prov.eql(idN(2)));

    // Deleting a run merges its neighbours.
    try b.splice(5, 2, 0, idN(9), false);
    const m2 = try b.toMap(a);
    try m2.validate();
    try testing.expectEqual(@as(u32, 12), m2.lineCount());
    try testing.expectError(error.OutOfRange, b.splice(12, 1, 0, idN(1), false));
}

test "attribution: through a diff" {
    const gpa = testing.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var b = try Builder.initInherited(gpa, 3);
    defer b.deinit();
    try b.splice(1, 1, 1, idN(1), false);
    const m = try b.toMap(a);
    const same = try mapThroughDiff(gpa, a, m, "a\nb\nc\n", "a\nb\nc\n", .{ .len = 0, .prov = idN(5) });
    try testing.expect(same.eql(m));
    const moved = try mapThroughDiff(gpa, a, m, "a\nb\nc\n", "x\na\nb\nc2\n", .{ .len = 0, .prov = idN(5) });
    try testing.expectEqual(@as(u32, 4), moved.lineCount());
    try testing.expect(moved.at(0).?.prov.eql(idN(5)));
    try testing.expect(moved.at(1).?.prov.eql(inherited));
    try testing.expect(moved.at(2).?.prov.eql(idN(1)));
    try testing.expect(moved.at(3).?.prov.eql(idN(5)));
    try testing.expectEqual(@as(u32, 2), lineCountOf("a\nb"));
}
