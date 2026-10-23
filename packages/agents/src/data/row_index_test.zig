//! The row index: SIMD against scalar scanning, parallel stitching,
//! approximate seeks and the memory budget.

const std = @import("std");
const csv = @import("csv.zig");
const scan = @import("scan_simd.zig");
const row_index = @import("row_index.zig");
const csv_test = @import("csv_test.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const Starts = struct {
    list: std.ArrayList(u64) = .empty,
    a: std.mem.Allocator,
    fn add(s: *Starts, off: u64) error{OutOfMemory}!void {
        try s.list.append(s.a, off);
    }
    fn sink(s: *Starts) scan.Sink(*Starts) {
        return .{ .ctx = s, .add = add };
    }
};

/// Random CSV: quoted fields with delimiters, doubled quotes, CR, LF and
/// CRLF inside them, blank lines, mixed line ends.
fn randomCsv(a: std.mem.Allocator, rnd: std.Random, size: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const ends = [_][]const u8{ "\n", "\r\n", "\r", "\n\n", "\r\n\r\n" };
    while (out.items.len < size) {
        const nf = rnd.intRangeAtMost(usize, 1, 5);
        for (0..nf) |f| {
            if (f > 0) try out.append(a, ',');
            if (rnd.boolean()) {
                try out.append(a, '"');
                for (0..rnd.intRangeAtMost(usize, 0, 12)) |_| {
                    const c = "ab,\n\r\" xyz"[rnd.uintLessThan(usize, 11)];
                    if (c == '"') try out.appendSlice(a, "\"\"") else try out.append(a, c);
                }
                try out.append(a, '"');
            } else {
                for (0..rnd.intRangeAtMost(usize, 0, 10)) |_| try out.append(a, "abc 123"[rnd.uintLessThan(usize, 7)]);
            }
        }
        try out.appendSlice(a, ends[rnd.uintLessThan(usize, ends.len)]);
    }
    return out.items;
}

test "prefix xor" {
    try testing.expectEqual(@as(u64, 0b0111_1000), scan.prefixXor(0b1000_1000));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), scan.prefixXor(1));
}

test "simd_index_equals_scalar" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rnd = prng.random();
    for (0..60) |round| {
        const bytes = try randomCsv(a, rnd, 50 + round * 97);
        // Chunk boundaries everywhere: every split point, both states.
        var from: usize = 0;
        while (from < bytes.len) : (from += 1 + rnd.uintLessThan(usize, 40)) {
            const to = @min(bytes.len, from + rnd.uintLessThan(usize, 300));
            var s0: Starts = .{ .a = a };
            var s1: Starts = .{ .a = a };
            var v0: Starts = .{ .a = a };
            var v1: Starts = .{ .a = a };
            const odd_s = try scan.scanScalar(*Starts, bytes, from, to, '"', s0.sink(), s1.sink());
            const odd_v = try scan.scanSimd(*Starts, bytes, from, to, '"', v0.sink(), v1.sink());
            try testing.expectEqual(odd_s, odd_v);
            try testing.expectEqualSlices(u64, s0.list.items, v0.list.items);
            try testing.expectEqualSlices(u64, s1.list.items, v1.list.items);
        }
        // The whole file agrees with the reader.
        var r: csv.CsvReader = .init(bytes, .{});
        var fields: std.ArrayList(csv.Field) = .empty;
        var starts: std.ArrayList(u64) = .empty;
        while (try r.nextRecord(&fields, a)) |at| try starts.append(a, at);
        try csv_test.checkIndexAgainst(a, bytes, .{}, starts.items);
    }
}

test "parallel_stitch_equals_sequential" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(42);
    const rnd = prng.random();
    for ([_]usize{ 1_000, 20_000, 300_000 }) |size| {
        const bytes = try randomCsv(a, rnd, size);
        var seq: row_index.RowIndex = .init(a);
        var progress: std.atomic.Value(u64) = .init(0);
        const cancel: std.atomic.Value(bool) = .init(false);
        try row_index.buildIndexChunks(io, bytes, .{}, &seq, &progress, &cancel, 1);
        try testing.expectEqual(seq.count(), progress.load(.acquire));
        for ([_]usize{ 2, 3, 7, 16, 61 }) |n| {
            var par: row_index.RowIndex = .init(a);
            try row_index.buildIndexChunks(io, bytes, .{}, &par, &progress, &cancel, n);
            try testing.expectEqual(seq.count(), par.count());
            var k: u64 = 0;
            while (k < seq.count()) : (k += 1) try testing.expectEqual(seq.offset(k), par.offset(k));
        }
    }
}

test "unbalanced quotes fall back to the reader" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = "a,b\n5\" screen,x\nc,d\n";
    var r: csv.CsvReader = .init(bytes, .{});
    var fields: std.ArrayList(csv.Field) = .empty;
    var starts: std.ArrayList(u64) = .empty;
    while (try r.nextRecord(&fields, a)) |at| try starts.append(a, at);
    var ix: row_index.RowIndex = .init(a);
    var progress: std.atomic.Value(u64) = .init(0);
    var cancel: std.atomic.Value(bool) = .init(false);
    try row_index.buildIndex(io, bytes, .{}, &ix, &progress, &cancel);
    try testing.expectEqual(@as(u64, 3), ix.count());
    for (starts.items, 0..) |s, k| try testing.expectEqual(s, ix.offset(k));
    // Canceled work stops.
    cancel.store(true, .release);
    try testing.expectError(error.Canceled, row_index.buildIndex(io, bytes, .{}, &ix, &progress, &cancel));
}

test "approx_seek_resync" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(9);
    const rnd = prng.random();
    // Rows with long multi-line quoted fields, so jumps often land inside
    // quotes.
    var text: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (text.items.len < 400_000) : (i += 1) {
        if (rnd.uintLessThan(u8, 3) == 0) {
            try text.print(a, "{d},\"note {d}\nsecond line, still \"\"quoted\"\"\nthird\",x\n", .{ i, i });
        } else try text.print(a, "{d},plain {d},y\n", .{ i, i });
    }
    const bytes = text.items;
    var ix: row_index.RowIndex = .init(a);
    var progress: std.atomic.Value(u64) = .init(0);
    const cancel: std.atomic.Value(bool) = .init(false);
    try row_index.buildIndex(io, bytes, .{}, &ix, &progress, &cancel);
    var exact: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    var k: u64 = 0;
    while (k < ix.count()) : (k += 1) try exact.put(a, ix.offset(k), k);
    for (0..200) |_| {
        const f = rnd.float(f64);
        const s = row_index.seekApprox(bytes, .{}, f);
        const row = exact.get(s.offset) orelse {
            std.debug.print("fraction {d} gave {d}, not a record start\n", .{ f, s.offset });
            return error.TestUnexpectedResult;
        };
        // The estimate is in the right neighbourhood.
        const diff = if (row > s.approx_row) row - s.approx_row else s.approx_row - row;
        try testing.expect(diff * 4 < ix.count());
    }
    try testing.expectEqual(@as(u64, 0), row_index.seekApprox(bytes, .{}, 0).offset);
}

test "index memory stays near 2.2 bytes a row" {
    var ix: row_index.RowIndex = .init(gpa);
    defer ix.deinit();
    var off: u64 = 0;
    for (0..100_000) |n| {
        try ix.append(off);
        off += 20 + n % 50;
    }
    // A row longer than 64 KiB makes its block wide.
    try ix.append(off + 200_000);
    try ix.finish();
    try testing.expectEqual(@as(u64, 100_001), ix.count());
    try testing.expectEqual(off + 200_000, ix.offset(100_000));
    try testing.expectEqual(@as(u64, 20), ix.offset(1));
    const per_row = @as(f64, @floatFromInt(ix.bytesUsed())) / 100_001.0;
    try testing.expect(per_row < 2.25);
    // So 100 M rows fit in 250 MB.
    try testing.expect(per_row * 100_000_000 < 250_000_000);
}
