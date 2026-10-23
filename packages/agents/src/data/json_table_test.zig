//! JSON and NDJSON tables, and that they look like CSV to the grid.

const std = @import("std");
const json_table = @import("json_table.zig");
const dataset = @import("dataset.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const array_doc =
    \\[
    \\  {"id": 1, "name": "Ann", "geo": {"city": "Oslo", "pos": {"lat": 59.9, "lon": 10.7, "deep": {"x": 1}}}, "tags": ["a", "b"]},
    \\  {"id": 2, "name": "Bo \"B\"", "geo": {"city": "Lima"}, "tags": [], "ok": true},
    \\  {"id": 3, "name": null, "extra": 1.50}
    \\]
;

const ndjson_doc = "{\"id\":1,\"v\":\"a\"}\n\n{\"id\":2,\"v\":\"b\"}\r\n{\"id\": 3,\n{\"id\":4,\"v\":\"d\",\"late\":true}\n";

fn names(t: *const json_table.JsonTable, a: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (t.columns(), 0..) |c, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, c.name);
    }
    return out.items;
}

test "json_array_and_ndjson_columns" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var progress: std.atomic.Value(u64) = .init(0);
    {
        var t = try json_table.JsonTable.open(io, gpa, array_doc, .array, &progress);
        defer t.deinit();
        try testing.expectEqual(@as(u64, 3), t.rowCount());
        try testing.expectEqual(@as(u64, 3), progress.load(.acquire));
        // Nested objects to depth 3; deeper ones as JSON; arrays as [n].
        try testing.expectEqualStrings("id name geo.city geo.pos.lat geo.pos.lon geo.pos.deep tags ok extra", try names(&t, a));
        try testing.expectEqualStrings("59.9", try t.cell(0, 3, a));
        try testing.expectEqualStrings("{\"x\":1}", try t.cell(0, 5, a));
        try testing.expectEqualStrings("[2]", try t.cell(0, 6, a));
        try testing.expectEqualStrings("[0]", try t.cell(1, 6, a));
        try testing.expectEqualStrings("Bo \"B\"", try t.cell(1, 1, a));
        try testing.expectEqualStrings("1.50", try t.cell(2, 8, a));
        try testing.expect(try t.isNull(2, 1, a));
        try testing.expect(try t.isNull(2, 2, a));
        try testing.expect(!try t.isNull(1, 7, a));
        const cols = t.columns();
        try testing.expectEqual(.int, cols[0].ty);
        try testing.expectEqual(.bool_, cols[7].ty);
        try testing.expect(cols[1].null_pct > 33 and cols[1].null_pct < 34);
        try testing.expectEqual(@as(u64, 3), cols[0].distinct_est);
        // The full row for the detail view.
        const v = try t.rowValue(0, a);
        try testing.expectEqual(@as(usize, 2), v.object.get("tags").?.array.items.len);
    }
    {
        // Late keys are added lazily.
        var t = try json_table.JsonTable.openWith(io, gpa, ndjson_doc, .ndjson, &progress, .{ .sample_rows = 2 });
        defer t.deinit();
        try testing.expectEqual(@as(u64, 3), t.rowCount());
        try testing.expectEqualStrings("id v", try names(&t, a));
        try testing.expectEqual(@as(usize, 1), try t.discover(2, 10));
        try testing.expectEqualStrings("id v late", try names(&t, a));
        try testing.expectEqualStrings("true", try t.cell(2, 2, a));
        try testing.expectEqualStrings("", try t.cell(0, 2, a));
        try testing.expectEqual(@as(usize, 0), try t.discover(0, 10));
    }
}

test "ndjson_bad_line_reported_not_fatal" {
    var progress: std.atomic.Value(u64) = .init(0);
    var t = try json_table.JsonTable.open(io, gpa, ndjson_doc, .ndjson, &progress);
    defer t.deinit();
    try testing.expectEqual(@as(u64, 3), t.rowCount());
    try testing.expectEqual(@as(usize, 1), t.bad.items.len);
    try testing.expectEqual(@as(u64, 4), t.bad.items[0].line);
    // A broken array keeps the rows before the damage.
    var u = try json_table.JsonTable.open(io, gpa, "[{\"a\":1},{\"a\":2},{\"a\":", .array, &progress);
    defer u.deinit();
    try testing.expectEqual(@as(u64, 2), u.rowCount());
    try testing.expectEqual(@as(usize, 1), u.bad.items.len);
    // A single object is a one-row table; scalars are a "value" column.
    var w = try json_table.JsonTable.open(io, gpa, "{\"k\":\"v\"}", .array, &progress);
    defer w.deinit();
    try testing.expectEqual(@as(u64, 1), w.rowCount());
    var s = try json_table.JsonTable.open(io, gpa, "[1, 2.5, \"x\", null]", .array, &progress);
    defer s.deinit();
    try testing.expectEqual(@as(u64, 4), s.rowCount());
    try testing.expectEqualStrings("value", s.columns()[0].name);
}

test "json and csv datasets look the same" {
    const csv_doc = "id,name,score\n1,Ann,3.5\n2,Bo,\n3,Cy,7\n";
    const json_doc = "[{\"id\":1,\"name\":\"Ann\",\"score\":3.5},{\"id\":2,\"name\":\"Bo\",\"score\":null},{\"id\":3,\"name\":\"Cy\",\"score\":7}]";
    const nd_doc = "{\"id\":1,\"name\":\"Ann\",\"score\":3.5}\n{\"id\":2,\"name\":\"Bo\",\"score\":null}\n{\"id\":3,\"name\":\"Cy\",\"score\":7}\n";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sets = [_]*dataset.Dataset{
        try dataset.Dataset.openBytes(gpa, io, csv_doc, .csv),
        try dataset.Dataset.openBytes(gpa, io, json_doc, .json_array),
        try dataset.Dataset.openBytes(gpa, io, nd_doc, .ndjson),
    };
    defer for (sets) |d| d.close();
    for (sets) |d| {
        try testing.expectEqual(dataset.RowCount{ .exact = 3 }, d.rowCount());
        try testing.expectEqual(@as(usize, 3), d.columnCount());
        try testing.expectEqualStrings("score", d.columns[2]);
        try testing.expectEqualStrings("Bo", try d.cell(1, 1, a));
        try testing.expectEqualStrings("3.5", try d.cell(0, 2, a));
        try testing.expect(try d.isNull(1, 2, a));
        try testing.expectEqual(.int, d.types[0]);
        try testing.expectEqual(.string, d.types[1]);
        try testing.expectEqual(.float, d.types[2]);
        try testing.expectEqual(dataset.Format.ndjson, dataset.formatOf("a.jsonl"));
    }
}
