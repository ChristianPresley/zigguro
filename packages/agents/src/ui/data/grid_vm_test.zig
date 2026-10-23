//! The data grid's view model: first screen from a partial index,
//! approximate jumps made exact, queries streaming and cancelling,
//! simple-mode queries, "Chart this" inference, copying and formatting.

const std = @import("std");
const zg_agents = @import("zg_agents");
const grid_vm = @import("grid_vm.zig");
const chart_this = @import("chart_this.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const Dataset = zg_agents.data.Dataset;
const GridVM = grid_vm.GridVM;

/// `n` rows of `id,name,amount,day` (id = row number).
fn bigCsv(n: usize) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    try w.writer.writeAll("id,name,amount,day\n");
    for (0..n) |i| try w.writer.print("{d},name {d},{d}.5,2025-{d:0>2}-{d:0>2}\n", .{ i, i % 97, (i * 7919) % 100_000, 1 + i % 12, 1 + i % 28 });
    return w.toOwnedSlice();
}

/// Stops the background index so the dataset stays partial.
fn stopIndexing(ds: *Dataset) void {
    ds.cancel.store(true, .release);
    ds.waitIndexed() catch {};
}

test "grid_first_screen_from_partial_index" {
    const bytes = try bigCsv(300_000);
    defer gpa.free(bytes);
    const ds = try Dataset.openBytes(gpa, io, bytes, .csv);
    defer ds.close();
    stopIndexing(ds);
    const vm = try GridVM.init(gpa, io, ds, "data");
    defer vm.deinit();
    // The first screen is exact.
    try testing.expectEqualStrings("0", vm.cellText(0, 0));
    try testing.expectEqualStrings("name 3", vm.cellText(3, 1));
    try testing.expectEqualStrings("23,757.5", vm.cellText(3, 2));
    try testing.expectEqualStrings("2025-04-04", vm.cellText(3, 3));
    try testing.expect(!vm.isApprox(10));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("11", vm.rowLabel(10, &buf));
    // The count is a lower bound, with an estimate to scroll over.
    const label = vm.rowCountLabel(&buf);
    try testing.expect(std.mem.startsWith(u8, label, "≥ "));
    try testing.expect(std.mem.indexOf(u8, label, "rows (indexing ") != null);
    const est = vm.rowCount();
    try testing.expect(est > 250_000 and est < 350_000);
}

test "scroll_jump_approx_then_exact" {
    const bytes = try bigCsv(300_000);
    defer gpa.free(bytes);
    const ds = try Dataset.openBytes(gpa, io, bytes, .csv);
    defer ds.close();
    stopIndexing(ds);
    const vm = try GridVM.init(gpa, io, ds, "data");
    defer vm.deinit();

    // A jump far past the first screen lands near the right row at once.
    const target: u64 = 200_000;
    try testing.expect(vm.isApprox(target));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("~200,001", vm.rowLabel(target, &buf));
    const id = try std.fmt.parseInt(u64, try strip(vm.cellText(target, 0), &buf), 10);
    try testing.expect(@abs(@as(i64, @intCast(id)) - @as(i64, @intCast(target))) < 15_000);
    // Rows after it read on from the landing: consecutive ids.
    const next = try std.fmt.parseInt(u64, try strip(vm.cellText(target + 5, 0), &buf), 10);
    try testing.expectEqual(id + 5, next);
    // Just past the first screen, rows follow its last record exactly.
    const first_approx = ds.index().count() - 1;
    const after = try std.fmt.parseInt(u64, try strip(vm.cellText(first_approx + 2, 0), &buf), 10);
    try testing.expectEqual(first_approx + 2, after);

    // Indexing completes: the grid reloads and every row is exact.
    try ds.reindex(ds.dialect, true);
    try ds.waitIndexed();
    try testing.expect(vm.poll());
    try testing.expect(!vm.isApprox(target));
    try testing.expectEqualStrings("200,000", vm.cellText(target, 0));
    try testing.expectEqualStrings("200,001", vm.rowLabel(target, &buf));
    try testing.expectEqualStrings("300,000 rows", vm.rowCountLabel(&buf));
}

fn strip(s: []const u8, buf: []u8) ![]const u8 {
    var n: usize = 0;
    for (s) |c| if (c != ',') {
        buf[n] = c;
        n += 1;
    };
    return buf[0..n];
}

fn waitDone(vm: *GridVM) !void {
    var tries: u32 = 0;
    while (vm.querying()) : (tries += 1) {
        if (tries > 20_000) return error.Timeout;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    _ = vm.poll();
}

test "filter_streams_and_cancels" {
    const bytes = try bigCsv(50_000);
    defer gpa.free(bytes);
    const ds = try Dataset.openBytes(gpa, io, bytes, .csv);
    defer ds.close();
    try ds.waitIndexed();
    const vm = try GridVM.init(gpa, io, ds, "data");
    defer vm.deinit();
    var buf: [128]u8 = undefined;

    // A slow query, replaced at once: the first is cancelled.
    try vm.setView("from data | sort -amount");
    try vm.setView("where name == 'name 5' | select id, amount");
    try waitDone(vm);
    try testing.expectEqual(2, vm.columnCount());
    try testing.expectEqualStrings("amount", vm.columnName(1));
    // ids 5, 102, 199, …
    try testing.expectEqual(@as(u64, 516), vm.rowCount());
    try testing.expectEqualStrings("5", vm.cellText(0, 0));
    try testing.expectEqualStrings("102", vm.cellText(1, 0));
    try testing.expectEqualStrings("516 rows", vm.rowCountLabel(&buf));

    // A bad query keeps the rows and says why.
    try vm.setView("from data | where nope > 1");
    try testing.expect(vm.query_error != null);
    try testing.expect(std.mem.indexOf(u8, vm.query_error.?, "nope") != null);
    try testing.expectEqual(@as(u64, 516), vm.rowCount());

    // Back to the file.
    try vm.setView(null);
    try testing.expectEqual(4, vm.columnCount());
    try testing.expectEqual(@as(u64, 50_000), vm.rowCount());
}

test "simple mode builds queries from chips and the sort" {
    const ds = try Dataset.openBytes(gpa, io, "id,name,amount,day\n1,a b,2.5,2025-01-02\n2,c,3,2025-02-03\n3,,4,2025-03-04\n", .csv);
    defer ds.close();
    const vm = try GridVM.init(gpa, io, ds, "data");
    defer vm.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(null, try vm.simpleQuery(a));
    try vm.addChip(.{ .col = 1, .op = .contains, .a = "A" });
    try vm.addChip(.{ .col = 2, .op = .range, .a = "1", .b = "" });
    try vm.addChip(.{ .col = 3, .op = .range, .a = "2025-01-01", .b = "2025-02-28" });
    try vm.setSort(.{ .col = 2, .desc = true });
    try testing.expectEqualStrings(
        "from data | where contains(lower(name), \"a\") and amount >= 1 and day between 2025-01-01 and 2025-02-28 | sort -amount",
        (try vm.simpleQuery(a)).?,
    );
    try waitDone(vm);
    try testing.expectEqual(@as(u64, 1), vm.rowCount());
    try testing.expectEqualStrings("a b", vm.cellText(0, 1));

    try vm.removeChip(0);
    try vm.addChip(.{ .col = 1, .op = .is_null });
    try testing.expectEqualStrings(
        "from data | where amount >= 1 and day between 2025-01-01 and 2025-02-28 and name is null | sort -amount",
        (try vm.simpleQuery(a)).?,
    );
    try vm.addChip(.{ .col = 1, .op = .equals, .a = "it's" });
    try testing.expect(std.mem.endsWith(u8, (try vm.simpleQuery(a)).?, "and name == \"it's\" | sort -amount"));
    try vm.clearFilters();
    try testing.expectEqual(null, try vm.simpleQuery(a));
    try testing.expectEqual(@as(u64, 3), vm.rowCount());
}

test "cells: formats, nulls and a bounded cache" {
    const ds = try Dataset.openBytes(gpa, io, "n,f,d,s\n1234567,-9876.25,2024-02-29,x\n,NA,,\n", .csv);
    defer ds.close();
    const vm = try GridVM.init(gpa, io, ds, "data");
    defer vm.deinit();
    try testing.expectEqualStrings("1,234,567", vm.cellText(0, 0));
    try testing.expectEqualStrings("-9,876.25", vm.cellText(0, 1));
    try testing.expectEqualStrings("2024-02-29", vm.cellText(0, 2));
    try testing.expect(vm.isNull(1, 0));
    try testing.expect(vm.isNull(1, 1));
    try testing.expectEqualStrings(grid_vm.null_mark, vm.cellText(1, 2));
    try testing.expect(!vm.isNull(0, 3));

    const bytes = try bigCsv(40_000);
    defer gpa.free(bytes);
    const big = try Dataset.openBytes(gpa, io, bytes, .csv);
    defer big.close();
    try big.waitIndexed();
    const v2 = try GridVM.init(gpa, io, big, "data");
    defer v2.deinit();
    for (0..30_000) |r| for (0..4) |c| {
        _ = v2.cellText(r, @intCast(c));
    };
    try testing.expect(v2.cachedCells() <= 2 * grid_vm.cache_generation);
    try testing.expectEqualStrings("29,999", v2.cellText(29_999, 0));
}

test "copy_tsv_and_markdown" {
    const ds = try Dataset.openBytes(gpa, io, "id,note,amount\n1,a|b,1000\n2,\"tab\there\",2.5\n3,c,\n", .csv);
    defer ds.close();
    const vm = try GridVM.init(gpa, io, ds, "data");
    defer vm.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "id\tnote\tamount\n1\ta|b\t1,000\n2\ttab here\t2.5\n3\tc\t\n",
        try grid_vm.copyRows(vm, a, &.{.{ 0, 2 }}, &.{ 0, 1, 2 }, .tsv),
    );
    try testing.expectEqualStrings(
        "| note | amount |\n| --- | ---: |\n| a\\|b | 1,000 |\n| c |  |\n",
        try grid_vm.copyRows(vm, a, &.{ .{ 0, 0 }, .{ 2, 2 } }, &.{ 1, 2 }, .markdown),
    );
    try testing.expectError(error.TooManyRows, grid_vm.copyRows(vm, a, &.{.{ 0, 1000 }}, &.{0}, .markdown));
}

test "chart_this_spec_inference_table" {
    const K = grid_vm.Kind;
    const Case = struct { kinds: []const K, shape: ?chart_this.Shape, x: u32 = 0, y: u32 = 0 };
    const cases = [_]Case{
        .{ .kinds = &.{.number}, .shape = .histogram },
        .{ .kinds = &.{.category}, .shape = null },
        .{ .kinds = &.{.temporal}, .shape = null },
        .{ .kinds = &.{ .temporal, .number }, .shape = .line, .x = 0, .y = 1 },
        .{ .kinds = &.{ .number, .temporal }, .shape = .line, .x = 1, .y = 0 },
        .{ .kinds = &.{ .category, .number }, .shape = .bar, .x = 0, .y = 1 },
        .{ .kinds = &.{ .number, .category }, .shape = .bar, .x = 1, .y = 0 },
        .{ .kinds = &.{ .number, .number }, .shape = .scatter, .x = 0, .y = 1 },
        .{ .kinds = &.{ .category, .temporal }, .shape = null },
        .{ .kinds = &.{ .category, .category }, .shape = null },
        .{ .kinds = &.{ .number, .number, .number }, .shape = null },
    };
    for (cases) |cs| {
        const cols = [_]u32{ 0, 1, 2 };
        const got = chart_this.infer(cols[0..cs.kinds.len], cs.kinds);
        if (cs.shape) |sh| {
            try testing.expectEqual(sh, got.?.shape);
            try testing.expectEqual(cs.x, got.?.x);
            if (sh != .histogram) try testing.expectEqual(cs.y, got.?.y);
        } else try testing.expectEqual(null, got);
    }

    // Specs read back as valid charts.
    const ds = try Dataset.openBytes(gpa, io, "region,amount,day,qty\nEU,1200.5,2025-01-02,3\nUS,30,2025-01-03,4\n", .csv);
    defer ds.close();
    const vm = try GridVM.init(gpa, io, ds, "data");
    defer vm.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: zg_agents.chart.Diagnostic = .{};
    const bar = try chart_this.spec(vm, a, &.{ 0, 1 });
    try testing.expectEqualStrings(
        \\{"title":"amount by region","data":{"values":[{"region":"EU","amount":1200.5},{"region":"US","amount":30}]},"mark":"bar","encoding":{"x":{"field":"region","type":"nominal","sort":"-y"},"y":{"field":"amount","type":"quantitative","aggregate":"sum"}}}
    , bar);
    const parsed = try zg_agents.chart.parseSpec(a, bar, &diag);
    try testing.expectEqual(zg_agents.chart.Mark.bar, parsed.mark.type);
    _ = try zg_agents.chart.parseSpec(a, try chart_this.spec(vm, a, &.{ 2, 1 }), &diag);
    _ = try zg_agents.chart.parseSpec(a, try chart_this.spec(vm, a, &.{1}), &diag);
    try testing.expectError(error.Unchartable, chart_this.spec(vm, a, &.{0}));
    // A workspace file charts from its path and the view's query.
    vm.path = "data/sales.csv";
    const sc = try chart_this.spec(vm, a, &.{ 1, 3 });
    try testing.expect(std.mem.indexOf(u8, sc, "\"data\":{\"path\":\"data/sales.csv\",\"query\":\"from data | sample 100000\"}") != null);
    _ = try zg_agents.chart.parseSpec(a, sc, &diag);
}
