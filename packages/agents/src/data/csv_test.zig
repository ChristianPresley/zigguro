//! CSV records: the RFC 4180 grammar, real-world deviations, encodings
//! and the dataset API.

const std = @import("std");
const csv = @import("csv.zig");
const encoding = @import("encoding.zig");
const dataset = @import("dataset.zig");
const row_index = @import("row_index.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

/// The records of `bytes` as text, fields joined by `|`, records by `/`;
/// null fields print as `∅`.
fn render(a: std.mem.Allocator, bytes: []const u8, d: csv.Dialect) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var r: csv.CsvReader = .init(bytes, d);
    var fields: std.ArrayList(csv.Field) = .empty;
    var first = true;
    while (try r.nextRecord(&fields, a)) |_| {
        if (!first) try out.append(a, '/');
        first = false;
        for (fields.items, 0..) |f, i| {
            if (i > 0) try out.append(a, '|');
            if (r.isNull(f)) {
                try out.appendSlice(a, "∅");
            } else try out.appendSlice(a, try r.fieldText(f, a));
        }
    }
    return out.items;
}

fn expectRecords(d: csv.Dialect, input: []const u8, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const got = try render(arena.allocator(), input, d);
    testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("input: {f}\n", .{std.zig.fmtString(input)});
        return e;
    };
}

const keep_empty: csv.Dialect = .{ .empty_is_null = false, .null_tokens = &.{} };

test "rfc4180_grammar_cases" {
    // file = [header CRLF] record *(CRLF record) [CRLF]
    try expectRecords(keep_empty, "aaa,bbb,ccc\r\nzzz,yyy,xxx\r\n", "aaa|bbb|ccc/zzz|yyy|xxx");
    try expectRecords(keep_empty, "aaa,bbb,ccc\r\nzzz,yyy,xxx", "aaa|bbb|ccc/zzz|yyy|xxx");
    try expectRecords(keep_empty, "field_name,field_name\r\naaa,bbb\r\n", "field_name|field_name/aaa|bbb");
    // escaped = DQUOTE *(TEXTDATA / COMMA / CR / LF / 2DQUOTE) DQUOTE
    try expectRecords(keep_empty, "\"aaa\",\"bbb\",\"ccc\"\r\n", "aaa|bbb|ccc");
    try expectRecords(keep_empty, "\"aaa\",\"b\r\nbb\",\"ccc\"\r\nzzz,yyy,xxx", "aaa|b\r\nbb|ccc/zzz|yyy|xxx");
    try expectRecords(keep_empty, "\"aaa\",\"b\"\"bb\",\"ccc\"", "aaa|b\"bb|ccc");
    try expectRecords(keep_empty, "\"a,b\",\"\",c", "a,b||c");
    try expectRecords(keep_empty, "\"\"\"\"", "\"");
    // non-escaped = *TEXTDATA (empty fields)
    try expectRecords(keep_empty, ",,\r\n", "||");
    try expectRecords(keep_empty, "a,,c", "a||c");
    // An empty file has no records.
    try expectRecords(keep_empty, "", "");
}

test "deviation_cases" {
    // LF and CR-only line ends, blank lines skipped.
    try expectRecords(keep_empty, "a,b\nc,d\n", "a|b/c|d");
    try expectRecords(keep_empty, "a,b\rc,d\r", "a|b/c|d");
    try expectRecords(keep_empty, "a,b\n\n\r\nc,d\n\n", "a|b/c|d");
    // A trailing delimiter makes an empty last field; shape accepts it.
    try expectRecords(keep_empty, "a,b,\n1,2,\n", "a|b|/1|2|");
    {
        var r: csv.CsvReader = .init("1,2,\n", .{});
        var fields: std.ArrayList(csv.Field) = .empty;
        defer fields.deinit(gpa);
        _ = try r.nextRecord(&fields, gpa);
        try testing.expectEqual(csv.Shape.ok, csv.shape(fields.items, 2));
        try testing.expectEqual(csv.Shape.padded, csv.shape(fields.items, 4));
        try testing.expectEqual(csv.Shape.truncated, csv.shape(fields.items[0..2], 1));
    }
    // Ragged rows read as they are.
    try expectRecords(keep_empty, "a,b,c\n1\n1,2,3,4\n", "a|b|c/1/1|2|3|4");
    // Stray quotes inside an unquoted field are literal.
    try expectRecords(keep_empty, "5\" screen,ok\nit's,\"q\"\n", "5\" screen|ok/it's|q");
    // Spaces around a quoted field are dropped; inside they stay.
    try expectRecords(keep_empty, "a,  \" b \"  ,c\n", "a| b |c");
    // Text after a closing quote keeps the raw field.
    try expectRecords(keep_empty, "\"ab\"cd,e\n", "\"ab\"cd|e");
    // An unterminated quote runs to the end.
    try expectRecords(keep_empty, "a,\"bc\nd,e", "a|bc\nd,e");
    // Null tokens: \N and (by default) empty unquoted fields; "" is text.
    try expectRecords(.{}, "1,\\N,,\"\"\n", "1|∅|∅|");
    try expectRecords(.{ .null_tokens = &.{ "NULL", "NA" }, .empty_is_null = false }, "NULL,NA,x,\n", "∅|∅|x|");
    // Backslash escapes.
    try expectRecords(.{ .escape = .backslash }, "\"a \\\"b\\\"\",\"x\\ny\"\n", "a \"b\"|x\ny");
    // Other delimiters and no quoting.
    try expectRecords(.{ .delimiter = '\t' }, "a\tb, c\t\"d\te\"\n", "a|b, c|d\te");
    try expectRecords(.{ .quote = null }, "a,\"b\nc", "a|\"b/c");
}

test "fieldText copies only escaped fields" {
    const bytes = "plain,\"quoted\",\"esc\"\"aped\"\n";
    var r: csv.CsvReader = .init(bytes, .{});
    var fields: std.ArrayList(csv.Field) = .empty;
    defer fields.deinit(gpa);
    try testing.expectEqual(@as(?u64, 0), try r.nextRecord(&fields, gpa));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const t0 = try r.fieldText(fields.items[0], a);
    const t1 = try r.fieldText(fields.items[1], a);
    try testing.expect(t0.ptr == bytes.ptr);
    try testing.expect(t1.ptr == bytes.ptr + 7);
    try testing.expect(fields.items[1].quoted and !fields.items[1].has_escapes);
    try testing.expect(fields.items[2].has_escapes);
    try testing.expectEqualStrings("esc\"aped", try r.fieldText(fields.items[2], a));
}

test "utf16_bom_transcoded" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    // "﻿id;ciudad\nx;Bogotá 𝄞\n" in UTF-16 LE and BE.
    const text = "id;ciudad\n1;Bogotá 𝄞\n";
    for ([_]bool{ false, true }) |be| {
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, if (be) "\xFE\xFF" else "\xFF\xFE");
        var it = (try std.unicode.Utf8View.init(text)).iterator();
        while (it.nextCodepoint()) |cp| {
            var units: [2]u16 = undefined;
            const n: usize = if (cp >= 0x10000) blk: {
                const v = cp - 0x10000;
                units = .{ @intCast(0xD800 + (v >> 10)), @intCast(0xDC00 + (v & 0x3FF)) };
                break :blk 2;
            } else blk: {
                units[0] = @intCast(cp);
                break :blk 1;
            };
            for (units[0..n]) |u| {
                const hi: u8 = @intCast(u >> 8);
                const lo: u8 = @intCast(u & 0xFF);
                try buf.appendSlice(gpa, if (be) &.{ hi, lo } else &.{ lo, hi });
            }
        }
        const ds = try dataset.Dataset.openBytes(gpa, io, buf.items, .csv);
        defer ds.close();
        try testing.expectEqual(if (be) encoding.Encoding.utf16be else .utf16le, ds.encoding);
        try testing.expectEqual(@as(u8, ';'), ds.dialect.delimiter);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try testing.expectEqualStrings("ciudad", ds.columns[1]);
        try testing.expectEqualStrings("Bogotá 𝄞", try ds.cell(0, 1, arena.allocator()));
        try testing.expectEqual(dataset.RowCount{ .exact = 1 }, ds.rowCount());
    }
    // Unpaired surrogates become U+FFFD.
    const bad = try encoding.utf16ToUtf8(gpa, "\x00\xD8a\x00", false);
    defer gpa.free(bad);
    try testing.expectEqualStrings("\u{FFFD}a", bad);
}

test "latin1_fallback_flagged" {
    const bytes = "name,city\nJos\xe9,M\xfcnchen\nAnn,Oslo\n";
    const ds = try dataset.Dataset.openBytes(gpa, io, bytes, .csv);
    defer ds.close();
    try testing.expect(ds.latin1());
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqualStrings("José", try ds.cell(0, 0, arena.allocator()));
    try testing.expectEqualStrings("München", try ds.cell(0, 1, arena.allocator()));
    // UTF-8 files aren't flagged; a sequence cut at 64 KiB doesn't count.
    try testing.expectEqual(encoding.Encoding.utf8, encoding.detect("a,b\nJosé,x\n"));
    try testing.expect(encoding.validUtf8Prefix("ab\xc3", true));
    try testing.expect(!encoding.validUtf8Prefix("ab\xc3", false));
}

test "dataset: header, cells, nulls and shapes" {
    const bytes = "id,name,score\n1,Ann,3.5\n2,\"Lee, Bo\",\\N\n3,Cy\n";
    const ds = try dataset.Dataset.openBytes(gpa, io, bytes, .csv);
    defer ds.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(ds.sniffed.header);
    try testing.expectEqual(@as(usize, 3), ds.columnCount());
    try testing.expectEqualStrings("name", ds.columns[1]);
    try testing.expectEqual(dataset.RowCount{ .exact = 3 }, ds.rowCount());
    try testing.expectEqualStrings("Lee, Bo", try ds.cell(1, 1, a));
    try testing.expect(try ds.isNull(1, 2, a));
    try testing.expectEqualStrings("", try ds.cell(2, 2, a));
    try testing.expectEqual(csv.Shape.padded, try ds.rowShape(2, a));
    try testing.expectEqualStrings("", try ds.cell(9, 0, a));
    // The user overrides the header guess.
    try ds.reindex(ds.dialect, false);
    try testing.expectEqual(dataset.RowCount{ .exact = 4 }, ds.rowCount());
    try testing.expectEqualStrings("Column 2", ds.columns[1]);
    try testing.expectEqualStrings("id", try ds.cell(0, 0, a));
    try testing.expectEqual(dataset.Format.tsv, dataset.formatOf("x/y.TSV"));
}

test "dataset: first screen before the full index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "n,text,value\n");
    var i: usize = 0;
    while (text.items.len < 3 << 20) : (i += 1) {
        if (i % 7 == 0) {
            try text.print(gpa, "{d},\"multi\nline, {d}\",{d}\n", .{ i, i, i * 3 });
        } else try text.print(gpa, "{d},row {d},{d}\n", .{ i, i, i * 3 });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "big.csv", .data = text.items });
    const ds = try dataset.Dataset.open(gpa, io, tmp.dir, "big.csv", null);
    defer ds.close();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // The first screen reads from the head index.
    try testing.expectEqualStrings("multi\nline, 7", try ds.cell(7, 1, a));
    try ds.waitIndexed();
    try testing.expectEqual(dataset.RowCount{ .exact = i }, ds.rowCount());
    const last = i - 1;
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{d}", .{last * 3}), try ds.cell(last, 2, a));
    // Approximate jumps land on record starts.
    const s = row_index.seekApprox(ds.bytes, ds.dialect, 0.5);
    const v = try ds.cellAt(s.offset, 0, a);
    const n = try std.fmt.parseInt(u64, v, 10);
    try testing.expectEqual(s.offset, ds.full.offset(n + 1));
}

test "fuzz_csv_reader" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            for ([_]csv.Dialect{ .{}, .{ .escape = .backslash }, .{ .delimiter = '\t', .quote = '\'' }, .{ .quote = null } }) |d| {
                // The reader never crashes or loops, and its record starts
                // agree with the SIMD index whenever quotes balance.
                var r: csv.CsvReader = .init(input, d);
                var fields: std.ArrayList(csv.Field) = .empty;
                var starts: std.ArrayList(u64) = .empty;
                while (try r.nextRecord(&fields, a)) |at| {
                    try starts.append(a, at);
                    for (fields.items) |f| _ = try r.fieldText(f, a);
                }
                try checkIndexAgainst(a, input, d, starts.items);
            }
        }
    }.one, .{});
}

/// Whether quotes in `bytes` are used the RFC way, so parity indexing
/// and the reader must agree.
fn wellQuoted(bytes: []const u8, d: csv.Dialect) bool {
    const q = d.quote orelse return true;
    var inq = false;
    for (bytes, 0..) |c, i| {
        if (c != q) continue;
        const before: u8 = if (i == 0) '\n' else bytes[i - 1];
        const after: u8 = if (i + 1 < bytes.len) bytes[i + 1] else '\n';
        if (!inq) {
            if (!(before == d.delimiter or csv.isTerminator(before))) return false;
        } else if (after != q and !(after == d.delimiter or csv.isTerminator(after))) {
            // Doubled quotes are fine; anything else after a close isn't.
            if (before != q) return false;
        }
        inq = !inq;
    }
    return !inq;
}

pub fn checkIndexAgainst(a: std.mem.Allocator, bytes: []const u8, d: csv.Dialect, starts: []const u64) !void {
    var ix: row_index.RowIndex = .init(a);
    var progress: std.atomic.Value(u64) = .init(0);
    const cancel: std.atomic.Value(bool) = .init(false);
    try row_index.buildIndexChunks(io, bytes, d, &ix, &progress, &cancel, 1);
    try testing.expect(ix.complete());
    if (d.escape == .backslash or wellQuoted(bytes, d)) {
        try testing.expectEqual(@as(u64, starts.len), ix.count());
        for (starts, 0..) |s, k| try testing.expectEqual(s, ix.offset(k));
    }
}
