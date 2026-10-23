const std = @import("std");
const store_mod = @import("store.zig");
const tools = @import("tools.zig");
const runs = @import("../runs/root.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;

test "tools_schema_strict" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (tools.tool_list) |t| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, t.input_schema_json, .{});
        const o = v.object;
        try testing.expectEqualStrings("object", o.get("type").?.string);
        try testing.expectEqual(false, o.get("additionalProperties").?.bool);
        const props = o.get("properties").?.object;
        if (o.get("required")) |req| for (req.array.items) |r| try testing.expect(props.contains(r.string));
        try testing.expect(std.mem.startsWith(u8, t.name, "artifact_"));
    }
    // No save tool: agents write files with E10's tools.
    for (tools.tool_list) |t| try testing.expect(std.mem.indexOf(u8, t.name, "save") == null);
}

const Fx = struct {
    tmp: testing.TmpDir,
    s: *store_mod.ArtifactStore,
    src: tools.Source,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fx) !void {
        f.tmp = testing.tmpDir(.{ .iterate = true });
        f.s = try store_mod.ArtifactStore.open(gpa, io, f.tmp.dir, .{});
        var prng: std.Random.DefaultPrng = .init(9);
        f.src = .{ .store = f.s, .run = runs.RunId.generateAt(1_760_000_000_000, prng.random()), .session = "S-9" };
        f.arena = .init(gpa);
    }

    fn deinit(f: *Fx) void {
        f.arena.deinit();
        f.s.close();
        f.tmp.cleanup();
    }

    fn call(f: *Fx, tool: []const u8, input: []const u8) !tools.Output {
        return tools.run(&f.src, f.arena.allocator(), tool, input);
    }

    fn ok(f: *Fx, tool: []const u8, input: []const u8) !std.json.Value {
        const r = try f.call(tool, input);
        if (r.is_error) {
            std.debug.print("{s}: {s}\n", .{ tool, r.text });
            return error.TestUnexpectedResult;
        }
        return std.json.parseFromSliceLeaky(std.json.Value, f.arena.allocator(), r.text, .{});
    }

    fn err(f: *Fx, tool: []const u8, input: []const u8, want: []const u8) !void {
        const r = try f.call(tool, input);
        try testing.expect(r.is_error);
        try testing.expectEqualStrings(want, r.text);
    }
};

test "create, update, read and list through tools" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();

    const c = try f.ok("artifact_create", "{\"kind\":\"markdown\",\"title\":\"Plan\",\"content\":\"# Plan\\n\"}");
    const id = c.object.get("id").?.string;
    try testing.expectEqual(@as(i64, 1), c.object.get("version").?.integer);

    const u = try f.ok("artifact_update", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"content\":\"# Plan v2\\n\",\"note\":\"tighter\"}}", .{id}));
    try testing.expectEqual(@as(i64, 2), u.object.get("version").?.integer);
    try testing.expectEqual(false, u.object.get("unchanged").?.bool);
    const same = try f.ok("artifact_update", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"content\":\"# Plan v2\\n\"}}", .{id}));
    try testing.expectEqual(true, same.object.get("unchanged").?.bool);

    const r1 = try f.ok("artifact_read", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"version\":1}}", .{id}));
    try testing.expectEqualStrings("# Plan\n", r1.object.get("content").?.string);
    try testing.expectEqual(@as(i64, 2), r1.object.get("versions").?.integer);
    const r2 = try f.ok("artifact_read", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{id}));
    try testing.expectEqualStrings("# Plan v2\n", r2.object.get("content").?.string);
    try testing.expectEqualStrings("tighter", r2.object.get("note").?.string);

    // Charts take the spec as an object or as JSON text.
    const ch = try f.ok("artifact_create", "{\"kind\":\"chart\",\"title\":\"Sales\",\"spec\":{\"mark\":\"bar\",\"data\":[1,2]}}");
    const ch_id = ch.object.get("id").?.string;
    const rc = try f.ok("artifact_read", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{ch_id}));
    try testing.expectEqualStrings("{\"mark\":\"bar\",\"data\":[1,2]}", rc.object.get("content").?.string);
    _ = try f.ok("artifact_create", "{\"kind\":\"diagram\",\"title\":\"Flow\",\"source\":\"graph TD; A-->B\"}");
    const img = try f.ok("artifact_create", "{\"kind\":\"image\",\"title\":\"Logo\",\"content\":\"<svg width='8' height='4'/>\"}");
    const ri = try f.ok("artifact_read", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{img.object.get("id").?.string}));
    try testing.expectEqual(@as(i64, 8), ri.object.get("width").?.integer);
    try testing.expectEqualStrings("image/svg+xml", ri.object.get("mime").?.string);

    // Listing defaults to the current run.
    _ = try f.s.create(.{ .kind = .text, .title = "elsewhere", .content = "x" });
    const l = try f.ok("artifact_list", "{}");
    try testing.expectEqual(@as(usize, 4), l.array.items.len);
    try testing.expectEqualStrings("Plan", l.array.items[0].object.get("title").?.string);
    try testing.expectEqual(@as(i64, 2), l.array.items[0].object.get("versions").?.integer);
    const all = try f.ok("artifact_list", "{\"run\":\"all\"}");
    try testing.expectEqual(@as(usize, 5), all.array.items.len);

    // Created by the tool: the run and session are recorded.
    const meta = (try f.s.get(store_mod.ArtifactId.parse(id).?, a)).?;
    try testing.expectEqualStrings(&f.src.run.?.text(), meta.run.?);
    try testing.expectEqualStrings("S-9", meta.versions[1].session.?);
}

test "tool errors" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.err("artifact_create", "{\"kind\":\"chart\",\"title\":\"x\",\"spec\":\"{bad\"}", "invalid artifact: the chart spec is not valid JSON");
    try f.err("artifact_create", "{\"kind\":\"markdown\",\"title\":\"x\",\"content\":\"a\",\"source\":\"b\"}", "`source` is for kind diagram");
    try f.err("artifact_create", "{\"kind\":\"markdown\",\"title\":\"x\"}", "give exactly one of `content`, `spec` or `source`");
    try f.err("artifact_create", "{\"kind\":\"markdown\",\"title\":\"  \",\"content\":\"a\"}", "`title` is empty");
    try f.err("artifact_create", "{\"kind\":\"video\",\"title\":\"x\",\"content\":\"a\"}", "invalid input: InvalidEnumTag");
    try f.err("artifact_create", "{\"kind\":\"table\",\"title\":\"x\",\"content\":\"a\",\"extra\":1}", "invalid input: UnknownField");
    try f.err("artifact_read", "{\"id\":\"nope\"}", "`nope` is not an artifact id (like A-0123456789ABC); see artifact_list");
    try f.err("artifact_read", "{\"id\":\"A-0000000000001\"}", "no artifact A-0000000000001; see artifact_list");
    try f.err("artifact_update", "{\"id\":\"A-0000000000001\",\"content\":\"x\"}", "no artifact A-0000000000001; see artifact_list");
    try f.err("artifact_list", "{\"run\":\"zzz\"}", "`run` is not a run id");
    const c = try f.ok("artifact_create", "{\"kind\":\"table\",\"title\":\"t\",\"content\":\"a,b\\n1,2\\n\"}");
    const id = c.object.get("id").?.string;
    try f.err("artifact_read", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"version\":5}}", .{id}), try std.fmt.allocPrint(a, "{s} has versions 1..1", .{id}));
    try f.err("artifact_update", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"content\":\"[1,\"}}", .{id}), "invalid artifact: the table is not valid JSON");
    try testing.expectError(error.UnknownTool, f.call("artifact_save", "{}"));
}

test "long content is cut on read" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const big = try a.alloc(u8, tools.max_read + 10);
    @memset(big, 'a');
    // A multi-byte character straddles the cut.
    @memcpy(big[tools.max_read - 1 ..][0..3], "\xe2\x82\xac");
    const id = try f.s.create(.{ .kind = .text, .title = "long", .content = big });
    const r = try f.ok("artifact_read", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{&id.text()}));
    try testing.expectEqual(true, r.object.get("truncated").?.bool);
    try testing.expectEqual(@as(usize, tools.max_read - 1), r.object.get("content").?.string.len);
    try testing.expectEqual(@as(i64, @intCast(big.len)), r.object.get("size").?.integer);
}
