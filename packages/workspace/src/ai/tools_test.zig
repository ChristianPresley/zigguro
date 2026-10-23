const std = @import("std");
const tools = @import("tools.zig");
const ps_mod = @import("../paths/path_store.zig");

const testing = std.testing;
const Io = std.Io;

const FakeForeign = struct {
    pub const Kind = enum { lsp, debug, tasks, workspace, notes, scm, mcp };
    pub const ForeignTool = struct {
        name: []const u8,
        description: []const u8,
        input_schema_json: []const u8,
        read_only: bool = false,
        mutates: bool = false,
    };
    pub const Result = struct { json: []const u8, changeset: ?u64 = null };
    pub const Exporter = struct {
        name: []const u8,
        kind: Kind,
        ctx: *anyopaque,
        list: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror![]const ForeignTool,
        call: *const fn (ctx: *anyopaque, io: Io, arena: std.mem.Allocator, tool: []const u8, input_json: []const u8) anyerror!Result,
    };
};

const file: ps_mod.NodeInfo = .{ .kind = .file, .size = 3 };

fn denySecrets(_: *anyopaque, path: []const u8, write: bool) ?[]const u8 {
    _ = write;
    return if (std.mem.indexOf(u8, path, "secrets") != null) "secret files are excluded by policy" else null;
}

const Env = struct {
    ps: *ps_mod.PathStore,
    arena: std.heap.ArenaAllocator,

    fn init(roots: u16) !Env {
        const ps = try ps_mod.PathStore.init(testing.allocator, testing.io);
        for (0..roots) |r| try ps.addRoot(.of(@intCast(r)), false);
        return .{ .ps = ps, .arena = .init(testing.allocator) };
    }

    fn deinit(e: *Env) void {
        e.arena.deinit();
        e.ps.deinit();
    }

    fn add(e: *Env, root: u16, rel: []const u8, info: ps_mod.NodeInfo) !void {
        var ch: std.ArrayList(ps_mod.Change) = .empty;
        defer ch.deinit(testing.allocator);
        try e.ps.apply(&.{ .ops = &.{.{ .upsert = .{ .root = .of(root), .rel = rel, .info = info } }} }, &ch);
    }

    fn call(e: *Env, src: *const tools.Source, tool: []const u8, input: []const u8, want_error: bool) ![]const u8 {
        const a = e.arena.allocator();
        const out = try tools.run(src, a, tool, input);
        const R = struct { content: []const struct { type: []const u8, text: []const u8 }, isError: bool };
        const r = try std.json.parseFromSliceLeaky(R, a, out.json, .{});
        if (r.isError != want_error) {
            std.debug.print("{s} -> {s}\n", .{ tool, r.content[0].text });
            return error.TestUnexpectedResult;
        }
        return r.content[0].text;
    }

    fn paths(e: *Env, text: []const u8) ![]const []const u8 {
        const a = e.arena.allocator();
        // `glob` lists strings, the others objects with a `path`.
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        const items = v.object.get("items").?.array.items;
        const out = try a.alloc([]const u8, items.len);
        for (items, out) |x, *o| o.* = if (x == .string) x.string else x.object.get("path").?.string;
        return out;
    }
};

fn expectPaths(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn fixture(e: *Env) !void {
    try e.add(0, "src/main.zig", file);
    try e.add(0, "src/ws/model.zig", file);
    try e.add(0, "src/ws/workspace_model.zig", file);
    try e.add(0, "src/ws/README.md", file);
    try e.add(0, "docs/guide.md", file);
    try e.add(0, "config/secrets.env", file);
    try e.add(0, "zig-out/bin/app", .{ .kind = .file, .flags = .{ .ignored = true } });
    try e.add(0, "zig-out", .{ .kind = .dir, .flags = .{ .ignored = true } });
    try e.add(0, "build.zig", file);
}

test "tools: schemas are valid JSON and the exporter lists read-only tools" {
    inline for (.{ tools.schemas.list_dir, tools.schemas.glob, tools.schemas.find_files }) |s| {
        const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, s, .{});
        defer v.deinit();
        try testing.expectEqualStrings("object", v.value.object.get("type").?.string);
    }
    var e: Env = try .init(1);
    defer e.deinit();
    var x: tools.ToolExporter(FakeForeign) = .{ .src = .{ .store = e.ps, .roots = &.{.{ .id = .of(0), .name = "app" }} } };
    const ex = x.exporter();
    try testing.expectEqual(FakeForeign.Kind.workspace, ex.kind);
    const ts = try ex.list(ex.ctx, e.arena.allocator());
    try testing.expectEqual(@as(usize, 3), ts.len);
    for (ts) |t| try testing.expect(t.read_only and !t.mutates);
    try testing.expectError(error.UnknownTool, ex.call(ex.ctx, testing.io, e.arena.allocator(), "grep", "{}"));
}

test "tools: list_dir, glob and find_files skip ignored and denied paths" {
    var e: Env = try .init(1);
    defer e.deinit();
    try fixture(&e);
    const src: tools.Source = .{ .store = e.ps, .roots = &.{.{ .id = .of(0), .name = "app" }}, .policy = .{ .ctx = &e, .check = denySecrets } };

    try expectPaths(&.{ "build.zig", "config", "docs", "src" }, try e.paths(try e.call(&src, "list_dir", "{\"path\": \"\"}", false)));
    try expectPaths(&.{ "src/main.zig", "src/ws", "src/ws/README.md", "src/ws/model.zig", "src/ws/workspace_model.zig" }, try e.paths(try e.call(&src, "list_dir", "{\"path\": \"src\", \"depth\": 2}", false)));
    try expectPaths(&.{}, try e.paths(try e.call(&src, "list_dir", "{\"path\": \"config\"}", false)));
    try std.testing.expect(std.mem.indexOf(u8, try e.call(&src, "list_dir", "{\"path\": \"config/\", \"depth\": 9}", true), "depth") != null);
    _ = try e.call(&src, "list_dir", "{\"path\": \"nope\"}", true);
    _ = try e.call(&src, "list_dir", "{\"path\": \"../x\"}", true);
    _ = try e.call(&src, "list_dir", "{\"path\": \"build.zig\"}", true);

    try expectPaths(&.{ "build.zig", "src/main.zig", "src/ws/model.zig", "src/ws/workspace_model.zig" }, try e.paths(try e.call(&src, "glob", "{\"pattern\": \"**/*.zig\"}", false)));
    try expectPaths(&.{ "docs/guide.md", "src/ws/README.md" }, try e.paths(try e.call(&src, "glob", "{\"pattern\": \"{docs,src}/**/*.md\"}", false)));
    try expectPaths(&.{}, try e.paths(try e.call(&src, "glob", "{\"pattern\": \"zig-out/**\"}", false)));
    try expectPaths(&.{"zig-out/bin/app"}, try e.paths(try e.call(&src, "glob", "{\"pattern\": \"zig-out/**\", \"include_ignored\": true}", false)));
    try expectPaths(&.{}, try e.paths(try e.call(&src, "glob", "{\"pattern\": \"**/*.env\"}", false)));
    const lim = try e.call(&src, "glob", "{\"pattern\": \"**\", \"limit\": 2}", false);
    try testing.expectEqual(@as(usize, 2), (try e.paths(lim)).len);
    try testing.expect(std.mem.indexOf(u8, lim, "\"truncated\":true") != null);
    _ = try e.call(&src, "glob", "{\"pattern\": \"{a,b\"}", true);

    const ff = try e.paths(try e.call(&src, "find_files", "{\"query\": \"model\"}", false));
    try expectPaths(&.{ "src/ws/model.zig", "src/ws/workspace_model.zig" }, ff);
    try testing.expectEqualStrings("src/ws/workspace_model.zig", (try e.paths(try e.call(&src, "find_files", "{\"query\": \"wsmodel\"}", false)))[0]);
    try expectPaths(&.{}, try e.paths(try e.call(&src, "find_files", "{\"query\": \"secrets\"}", false)));
    try expectPaths(&.{}, try e.paths(try e.call(&src, "find_files", "{\"query\": \"app\"}", false)));
    _ = try e.call(&src, "find_files", "{\"query\": \" \"}", true);
}

test "tools: multi-root paths carry the root name; output is capped" {
    var e: Env = try .init(2);
    defer e.deinit();
    try e.add(0, "a.txt", file);
    try e.add(1, "lib/b.txt", file);
    var src: tools.Source = .{ .store = e.ps, .roots = &.{ .{ .id = .of(0), .name = "front" }, .{ .id = .of(1), .name = "back" } } };
    try expectPaths(&.{ "front", "back" }, try e.paths(try e.call(&src, "list_dir", "{\"path\": \"\"}", false)));
    try expectPaths(&.{"back/lib/b.txt"}, try e.paths(try e.call(&src, "list_dir", "{\"path\": \"back/lib\"}", false)));
    try expectPaths(&.{ "back/lib/b.txt", "front/a.txt" }, try e.paths(try e.call(&src, "glob", "{\"pattern\": \"**/*.txt\"}", false)));
    try expectPaths(&.{"back/lib/b.txt"}, try e.paths(try e.call(&src, "glob", "{\"pattern\": \"**\", \"root\": \"back\"}", false)));

    var buf: [64]u8 = undefined;
    for (0..400) |i| try e.add(0, try std.fmt.bufPrint(&buf, "gen/file_with_a_long_name_{d}.txt", .{i}), file);
    src.max_output = 4096;
    const big = try e.call(&src, "glob", "{\"pattern\": \"gen/**\", \"limit\": 2000}", false);
    try testing.expect(big.len <= 4096);
    try testing.expect(std.mem.indexOf(u8, big, "\"truncated\":true") != null);
    try testing.expect(std.mem.indexOf(u8, big, "narrow the pattern") != null);
}

test "tools: fuzzyScore prefers basename and run matches" {
    const s1 = tools.fuzzyScore("model", "src/ws/model.zig", 7).?;
    const s2 = tools.fuzzyScore("model", "src/ws/workspace_model.zig", 7).?;
    const s3 = tools.fuzzyScore("model", "m/o/d/e/l.txt", 8);
    try testing.expect(s1 > s2);
    try testing.expect(s3 == null or s3.? < s2);
    try testing.expect(tools.fuzzyScore("xyz", "src/main.zig", 4) == null);
    try testing.expect(tools.fuzzyScore("MAIN", "src/main.zig", 4) != null);
}
