//! JSON arrays of objects and NDJSON as tables (E13.F06.S01.T03).
//!
//! `open` indexes every row in one streaming pass: the top-level elements
//! of an array (`std.json.Scanner` over the mapping), or the non-blank
//! lines of NDJSON (each validated; a bad line is reported in `bad` and
//! skipped, never fatal). Columns are the union of keys in the first 10 k
//! rows, nested objects flattened to dotted paths up to depth 3 (deeper
//! values show as compact JSON); arrays are one column whose cells read
//! `[n]` (the full value is in `rowValue`). Keys first seen later are
//! added by `discover`. Rows are parsed again when a cell is read.

const std = @import("std");
const infer = @import("infer.zig");
const sketches = @import("sketches.zig");
const row_index = @import("row_index.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ColType = infer.ColType;

pub const Kind = enum { array, ndjson };

pub const Column = struct {
    name: []const u8,
    ty: ColType,
    null_pct: f32,
    distinct_est: u64,
};

pub const BadLine = struct { line: u64, offset: u64, message: []const u8 };

pub const Options = struct {
    sample_rows: usize = 10_000,
    max_depth: u8 = 3,
};

const parse_opts: std.json.ParseOptions = .{ .parse_numbers = false, .duplicate_field_behavior = .use_last };

pub const JsonTable = struct {
    gpa: Allocator,
    bytes: []const u8,
    kind: Kind,
    opts: Options,
    starts: row_index.RowIndex,
    ends: row_index.RowIndex,
    arena: std.heap.ArenaAllocator,
    cols: std.ArrayList(Column) = .empty,
    paths: std.ArrayList([]const []const u8) = .empty,
    bad: std.ArrayList(BadLine) = .empty,

    pub fn open(io: std.Io, gpa: Allocator, bytes: []const u8, kind: Kind, progress: *std.atomic.Value(u64)) !JsonTable {
        return openWith(io, gpa, bytes, kind, progress, .{});
    }

    pub fn openWith(io: std.Io, gpa: Allocator, bytes: []const u8, kind: Kind, progress: *std.atomic.Value(u64), opts: Options) !JsonTable {
        _ = io;
        var t: JsonTable = .{ .gpa = gpa, .bytes = bytes, .kind = kind, .opts = opts, .starts = .init(gpa), .ends = .init(gpa), .arena = .init(gpa) };
        errdefer t.deinit();
        switch (kind) {
            .ndjson => try t.indexLines(progress),
            .array => try t.indexArray(progress),
        }
        try t.starts.finish();
        try t.ends.finish();
        progress.store(t.starts.count(), .release);
        try t.learnColumns(0, @min(t.rowCount(), opts.sample_rows), true);
        return t;
    }

    pub fn deinit(t: *JsonTable) void {
        t.starts.deinit();
        t.ends.deinit();
        t.cols.deinit(t.gpa);
        t.paths.deinit(t.gpa);
        t.bad.deinit(t.gpa);
        t.arena.deinit();
    }

    fn indexLines(t: *JsonTable, progress: *std.atomic.Value(u64)) !void {
        var pos: usize = 0;
        var line: u64 = 0;
        while (pos < t.bytes.len) {
            line += 1;
            const nl = std.mem.indexOfScalarPos(u8, t.bytes, pos, '\n') orelse t.bytes.len;
            const text = std.mem.trim(u8, t.bytes[pos..nl], " \t\r");
            if (text.len > 0) {
                const start = @intFromPtr(text.ptr) - @intFromPtr(t.bytes.ptr);
                if (try std.json.validate(t.gpa, text)) {
                    try t.starts.append(start);
                    try t.ends.append(start + text.len);
                } else try t.bad.append(t.gpa, .{ .line = line, .offset = start, .message = "invalid JSON" });
            }
            pos = nl + 1;
            if (line % 65536 == 0) progress.store(t.starts.count(), .release);
        }
    }

    fn indexArray(t: *JsonTable, progress: *std.atomic.Value(u64)) !void {
        var sc: std.json.Scanner = .initCompleteInput(t.gpa, t.bytes);
        defer sc.deinit();
        const first = sc.peekNextTokenType() catch return t.badAt(sc.cursor, "invalid JSON");
        if (first != .array_begin) {
            // A single top-level value is a one-row table.
            const start = sc.cursor;
            sc.skipValue() catch return t.badAt(start, "invalid JSON");
            try t.starts.append(start);
            try t.ends.append(sc.cursor);
            return;
        }
        _ = try sc.next();
        while (true) {
            const tt = sc.peekNextTokenType() catch return t.badAt(sc.cursor, "invalid JSON");
            if (tt == .array_end or tt == .end_of_document) break;
            const start = sc.cursor;
            sc.skipValue() catch return t.badAt(start, "invalid JSON");
            try t.starts.append(start);
            try t.ends.append(sc.cursor);
            if (t.starts.count() % 65536 == 0) progress.store(t.starts.count(), .release);
        }
    }

    fn badAt(t: *JsonTable, offset: usize, message: []const u8) !void {
        var line: u64 = 1;
        for (t.bytes[0..@min(offset, t.bytes.len)]) |c| line += @intFromBool(c == '\n');
        try t.bad.append(t.gpa, .{ .line = line, .offset = offset, .message = message });
    }

    pub fn rowCount(t: *const JsonTable) u64 {
        return t.starts.count();
    }

    pub fn columns(t: *const JsonTable) []const Column {
        return t.cols.items;
    }

    /// The row's JSON text.
    pub fn rowText(t: *const JsonTable, row: u64) []const u8 {
        return t.bytes[@intCast(t.starts.offset(row))..@intCast(t.ends.offset(row))];
    }

    /// The row's parsed value (for the row detail view).
    pub fn rowValue(t: *const JsonTable, row: u64, arena: Allocator) !Value {
        return std.json.parseFromSliceLeaky(Value, arena, t.rowText(row), parse_opts);
    }

    fn leaf(t: *const JsonTable, row: u64, col: u32, arena: Allocator) !?Value {
        if (row >= t.rowCount() or col >= t.paths.items.len) return null;
        var v = try t.rowValue(row, arena);
        for (t.paths.items[col]) |seg| {
            v = switch (v) {
                .object => |o| o.get(seg) orelse return null,
                else => return null,
            };
        }
        return v;
    }

    /// The cell's text ("" for null or missing).
    pub fn cell(t: *const JsonTable, row: u64, col: u32, arena: Allocator) ![]const u8 {
        const v = (try t.leaf(row, col, arena)) orelse return "";
        return render(arena, v);
    }

    pub fn isNull(t: *const JsonTable, row: u64, col: u32, arena: Allocator) !bool {
        const v = (try t.leaf(row, col, arena)) orelse return true;
        return v == .null;
    }

    /// Adds columns for keys first seen in rows `first..first+n`; returns
    /// how many were added.
    pub fn discover(t: *JsonTable, first: u64, n: u64) !usize {
        const before = t.cols.items.len;
        try t.learnColumns(first, @min(first + n, t.rowCount()), false);
        return t.cols.items.len - before;
    }

    /// Collects the paths in rows `from..to` (and, at open, infers types
    /// from them).
    fn learnColumns(t: *JsonTable, from: u64, to: u64, with_types: bool) !void {
        var tmp: std.heap.ArenaAllocator = .init(t.gpa);
        defer tmp.deinit();
        const a = tmp.allocator();
        var samples: std.ArrayList(std.ArrayList([]const u8)) = .empty;
        var row = from;
        while (row < to) : (row += 1) {
            const v = t.rowValue(row, a) catch continue;
            try t.walk(a, v, &.{}, 0, &samples, with_types);
        }
        if (!with_types) return;
        const n = to - from;
        for (t.cols.items, 0..) |*c, i| {
            const s = if (i < samples.items.len) samples.items[i].items else &.{};
            c.ty = infer.inferColumn(s, .{});
            var hll: sketches.HyperLogLog = .{};
            var nonnull: u64 = 0;
            for (s) |x| if (!infer.isNullText(x)) {
                hll.addBytes(x);
                nonnull += 1;
            };
            c.null_pct = if (n == 0) 0 else 100 * @as(f32, @floatFromInt(n - @min(n, nonnull))) / @as(f32, @floatFromInt(n));
            c.distinct_est = hll.estimate();
        }
    }

    fn walk(t: *JsonTable, a: Allocator, v: Value, prefix: []const []const u8, depth: u8, samples: *std.ArrayList(std.ArrayList([]const u8)), with_types: bool) !void {
        if (v == .object and depth < t.opts.max_depth) {
            var it = v.object.iterator();
            while (it.next()) |kv| {
                const path = try a.alloc([]const u8, prefix.len + 1);
                @memcpy(path[0..prefix.len], prefix);
                path[prefix.len] = kv.key_ptr.*;
                try t.walk(a, kv.value_ptr.*, path, depth + 1, samples, with_types);
            }
            return;
        }
        const col = try t.columnFor(prefix);
        if (!with_types) return;
        while (samples.items.len <= col) try samples.append(a, .empty);
        try samples.items[col].append(a, if (v == .null) "" else try render(a, v));
    }

    fn columnFor(t: *JsonTable, path: []const []const u8) !u32 {
        for (t.paths.items, 0..) |p, i| {
            if (p.len != path.len) continue;
            for (p, path) |x, y| {
                if (!std.mem.eql(u8, x, y)) break;
            } else return @intCast(i);
        }
        const a = t.arena.allocator();
        const owned = try a.alloc([]const u8, path.len);
        for (path, owned) |s, *o| o.* = try a.dupe(u8, s);
        const name = if (path.len == 0) "value" else try std.mem.join(a, ".", owned);
        try t.paths.append(t.gpa, owned);
        try t.cols.append(t.gpa, .{ .name = name, .ty = .string, .null_pct = 0, .distinct_est = 0 });
        return @intCast(t.cols.items.len - 1);
    }
};

/// A leaf as cell text: strings as they are, numbers as written, arrays
/// as `[n]`, objects as compact JSON.
pub fn render(a: Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .null => "",
        .bool => |b| if (b) "true" else "false",
        .integer => |i| std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| s,
        .string => |s| s,
        .array => |arr| std.fmt.allocPrint(a, "[{d}]", .{arr.items.len}),
        .object => std.json.Stringify.valueAlloc(a, v, .{}),
    };
}
