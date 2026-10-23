//! Data tools for agents (E13.F06.S02.T03).

const std = @import("std");
const zg_ai = @import("zg_ai");
const tools = @import("tools.zig");
const artifacts = @import("../artifacts/root.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const DataTools = tools.DataTools;

const Fx = struct {
    tmp: testing.TmpDir,
    clock: zg_ai.ratelimit.FakeClock,
    store_dir: std.Io.Dir,
    store: *artifacts.ArtifactStore,
    t: DataTools,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fx, policy: ?tools.PathPolicy) !void {
        f.tmp = testing.tmpDir(.{ .iterate = true });
        f.clock = .init(1_760_000_000_000);
        f.arena = .init(gpa);
        try f.tmp.dir.createDirPath(io, "store");
        f.store_dir = try f.tmp.dir.openDir(io, "store", .{ .iterate = true });
        f.store = try artifacts.ArtifactStore.open(gpa, io, f.store_dir, .{ .clock = f.clock.clock() });
        f.t = .init(.{ .gpa = gpa, .io = io, .workspace = f.tmp.dir, .policy = policy, .artifacts = f.store, .threads = 2 });
    }

    fn deinit(f: *Fx) void {
        f.t.deinit();
        f.store.close();
        f.store_dir.close(io);
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn write(f: *Fx, name: []const u8, data: []const u8) !void {
        try f.tmp.dir.writeFile(io, .{ .sub_path = name, .data = data });
    }

    /// Calls `tool` and returns its result text parsed as JSON (failing
    /// when the tool reports an error).
    fn call(f: *Fx, tool: []const u8, input: []const u8) !std.json.Value {
        const out = try f.t.run(f.arena.allocator(), tool, input);
        if (out.is_error) {
            std.debug.print("{s}: {s}\n", .{ tool, out.text });
            return error.TestUnexpectedResult;
        }
        try testing.expect(out.text.len <= tools.max_result_bytes);
        return std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(), out.text, .{});
    }

    /// Calls `tool` expecting an error; returns its message.
    fn callErr(f: *Fx, tool: []const u8, input: []const u8) ![]const u8 {
        const out = try f.t.run(f.arena.allocator(), tool, input);
        try testing.expect(out.is_error);
        return out.text;
    }
};

fn salesCsv(a: std.mem.Allocator, rows: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "id,region,amount,day,note\n");
    const regions = [_][]const u8{ "north", "south", "east", "west" };
    for (0..rows) |i| try out.print(a, "{d},{s},{d}.{d},2025-{d:0>2}-{d:0>2},\"note, {d}\"\n", .{ i, regions[i % 4], i * 3 % 1000, i % 10, i % 12 + 1, i % 28 + 1, i });
    return out.items;
}

test "tools_results_bounded_and_artifact_written" {
    var f: Fx = undefined;
    try f.init(null);
    defer f.deinit();
    const a = f.arena.allocator();
    try f.write("sales.csv", try salesCsv(a, 5000));

    const opened = try f.call("data_open", "{\"path\":\"sales.csv\"}");
    try testing.expectEqualStrings("sales", opened.object.get("dataset").?.string);
    try testing.expectEqual(@as(i64, 5000), opened.object.get("rows").?.integer);
    const cols = opened.object.get("columns").?.array.items;
    try testing.expectEqual(@as(usize, 5), cols.len);
    try testing.expectEqualStrings("float", cols[2].object.get("type").?.string);
    try testing.expectEqualStrings("date", cols[3].object.get("type").?.string);

    // Default 50 rows; the full result goes to a CSV artifact.
    const r = try f.call("data_query", "{\"query\":\"from sales | where amount > 10 | select id, region, amount, day, note\"}");
    const rows = r.object.get("rows").?.array.items;
    try testing.expectEqual(@as(usize, 50), rows.len);
    try testing.expect(r.object.get("truncated").?.bool);
    const total: usize = @intCast(r.object.get("total_rows").?.integer);
    try testing.expect(total > 4000);
    // Lossless numbers and ISO dates.
    try testing.expectEqual(@as(i64, 4), rows[0].array.items[0].integer);
    try testing.expectEqual(@as(f64, 12.4), rows[0].array.items[2].float);
    try testing.expectEqualStrings("2025-05-05", rows[0].array.items[3].string);
    const id_text = r.object.get("artifact_id").?.string;
    const id = artifacts.ArtifactId.parse(id_text).?;
    const art = (try f.store.get(id, a)).?;
    try testing.expectEqual(artifacts.ArtifactKind.table, art.kind);
    const content = try f.store.read(id, null, a);
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, content.bytes, "\n"), '\n');
    try testing.expectEqualStrings("id,region,amount,day,note", lines.next().?);
    var n: usize = 0;
    while (lines.next()) |_| n += 1;
    try testing.expectEqual(total, n);
    try testing.expect(std.mem.indexOf(u8, content.bytes, "\"note, 11\"") != null);

    // max_rows is capped at 200.
    const big = try f.call("data_query", "{\"query\":\"from sales\",\"max_rows\":100000}");
    try testing.expectEqual(@as(usize, 200), big.object.get("rows").?.array.items.len);

    // A result that fits returns no artifact.
    const small = try f.call("data_query", "{\"query\":\"from sales | group region { n = count(), total = sum(amount) } | sort region\"}");
    try testing.expect(!small.object.get("truncated").?.bool);
    try testing.expect(small.object.get("artifact_id") == null);
    try testing.expectEqual(@as(usize, 4), small.object.get("rows").?.array.items.len);
    try testing.expectEqualStrings("east", small.object.get("rows").?.array.items[0].array.items[0].string);

    // Wide rows are cut to fit the token budget.
    var wide: std.ArrayList(u8) = .empty;
    try wide.appendSlice(a, "k,text\n");
    for (0..300) |i| {
        try wide.print(a, "{d},", .{i});
        for (0..2000) |_| try wide.append(a, 'x');
        try wide.append(a, '\n');
    }
    try f.write("wide.csv", wide.items);
    _ = try f.call("data_open", "{\"path\":\"wide.csv\"}");
    const w = try f.call("data_query", "{\"query\":\"from wide\",\"max_rows\":200}");
    const wrows = w.object.get("rows").?.array.items;
    try testing.expect(wrows.len < 200 and wrows.len > 50);
    try testing.expectEqual(tools.max_cell_bytes, wrows[0].array.items[1].string.len);
    try testing.expect(w.object.get("truncated").?.bool);

    // Sample, describe and value counts.
    const s = try f.call("data_sample", "{\"dataset\":\"sales\",\"n\":7,\"where\":\"region == 'east'\"}");
    try testing.expectEqual(@as(usize, 7), s.object.get("rows").?.array.items.len);
    for (s.object.get("rows").?.array.items) |row| try testing.expectEqualStrings("east", row.array.items[1].string);
    const s2 = try f.call("data_sample", "{\"dataset\":\"sales\",\"n\":7,\"where\":\"region == 'east'\"}");
    try testing.expectEqual(s.object.get("rows").?.array.items[3].array.items[0].integer, s2.object.get("rows").?.array.items[3].array.items[0].integer);

    const d = try f.call("data_describe", "{\"dataset\":\"sales\",\"columns\":[\"amount\",\"region\"]}");
    const dc = d.object.get("columns").?.array.items;
    try testing.expectEqual(@as(usize, 2), dc.len);
    try testing.expectEqualStrings("amount", dc[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 5000), dc[0].object.get("count").?.integer);
    try testing.expect(dc[0].object.get("median") != null);
    try testing.expectEqual(@as(i64, 4), dc[1].object.get("distinct").?.integer);
    try testing.expectEqual(@as(usize, 4), dc[1].object.get("top").?.array.items.len);

    const vc = try f.call("data_value_counts", "{\"dataset\":\"sales\",\"column\":\"region\",\"k\":2}");
    const vrows = vc.object.get("rows").?.array.items;
    try testing.expectEqual(@as(usize, 2), vrows.len);
    try testing.expectEqual(@as(i64, 1250), vrows[0].array.items[1].integer);

    // Errors read well.
    try testing.expect(std.mem.indexOf(u8, try f.callErr("data_query", "{\"query\":\"from sales | where amout > 1\"}"), "unknown column") != null);
    try testing.expect(std.mem.indexOf(u8, try f.callErr("data_query", "{\"query\":\"from nope\"}"), "nope") != null);
    try testing.expect(std.mem.indexOf(u8, try f.callErr("data_describe", "{\"dataset\":\"nope\"}"), "data_open") != null);
    try testing.expect(std.mem.indexOf(u8, try f.callErr("data_value_counts", "{\"dataset\":\"sales\",\"column\":\"zone\"}"), "id, region, amount") != null);
    try testing.expect(std.mem.indexOf(u8, try f.callErr("data_open", "{\"path\":\"missing.csv\"}"), "no such file") != null);
}

test "tools_read_only_and_path_policy" {
    for (tools.tool_list) |t| try testing.expect(t.read_only);

    // The default policy keeps paths inside the workspace.
    try testing.expect(tools.workspaceOnly("data/a.csv") == null);
    try testing.expect(tools.workspaceOnly("../a.csv") != null);
    try testing.expect(tools.workspaceOnly("data/../../a.csv") != null);
    try testing.expect(tools.workspaceOnly("/etc/passwd") != null);
    try testing.expect(tools.workspaceOnly("C:\\x.csv") != null);

    // An E16 fake denies everything outside `ok/`.
    const Fake = struct {
        asked: usize = 0,
        fn check(ctx: *anyopaque, path: []const u8) ?[]const u8 {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.asked += 1;
            return if (std.mem.startsWith(u8, path, "ok/")) null else "denied by policy";
        }
    };
    var fake: Fake = .{};
    var f: Fx = undefined;
    try f.init(.{ .ctx = &fake, .check = Fake.check });
    defer f.deinit();
    try f.tmp.dir.createDirPath(io, "ok");
    try f.write("ok/a.csv", "x,y\n1,2\n3,4\n");
    try f.write("secret.csv", "x,y\n1,2\n");
    const msg = try f.callErr("data_open", "{\"path\":\"secret.csv\"}");
    try testing.expect(std.mem.indexOf(u8, msg, "denied by policy") != null);
    try testing.expect(f.t.get("secret") == null);
    const r = try f.call("data_open", "{\"path\":\"ok/a.csv\"}");
    try testing.expectEqualStrings("a", r.object.get("dataset").?.string);
    try testing.expectEqual(@as(usize, 2), fake.asked);

    // Opening the same path again reuses the dataset; another file with
    // the same stem gets a new name.
    _ = try f.call("data_open", "{\"path\":\"ok/a.csv\"}");
    try testing.expectEqual(@as(usize, 1), f.t.open.items.len);
    try f.tmp.dir.createDirPath(io, "ok/b");
    try f.write("ok/b/a.csv", "x\n1\n");
    const r2 = try f.call("data_open", "{\"path\":\"ok/b/a.csv\"}");
    try testing.expectEqualStrings("a_2", r2.object.get("dataset").?.string);

    // Queries leave the files untouched.
    _ = try f.call("data_query", "{\"query\":\"from a | derive z = x * 2 | sort -z\"}");
    const after = try f.tmp.dir.readFileAlloc(io, "ok/a.csv", f.arena.allocator(), .limited(100));
    try testing.expectEqualStrings("x,y\n1,2\n3,4\n", after);

    // Through the foreign exporter.
    const ex = f.t.exporter();
    const listed = try ex.list(ex.ctx, f.arena.allocator());
    try testing.expectEqual(@as(usize, 5), listed.len);
    const res = try ex.call(ex.ctx, io, f.arena.allocator(), "data_query", "{\"query\":\"from a | select x\"}");
    try testing.expect(std.mem.indexOf(u8, res.json, "\\\"total_rows\\\":2") != null);
}

test "cell_format" {
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2025-01-31", tools.formatTemporal(&buf, .{ .date = 20119 }));
    try testing.expectEqualStrings("1970-01-01T00:00:01Z", tools.formatTemporal(&buf, .{ .datetime = 1000 }));
    try testing.expectEqualStrings("1970-01-01T00:00:00.250Z", tools.formatTemporal(&buf, .{ .datetime = 250 }));
    const cells = [_]tools.Cell{ .{ .v = .{ .float = 0.1 } }, .{ .v = .{ .float = 1e300 } }, .{ .v = .null_ }, .{ .v = .{ .int = -3 } }, .{ .v = .{ .float = 1.5e-9 } }, .{ .v = .{ .float = 123456.789 } } };
    const json = try std.json.Stringify.valueAlloc(gpa, cells, .{});
    defer gpa.free(json);
    try testing.expectEqualStrings("[0.1,1e300,null,-3,1.5e-9,123456.789]", json);
}
