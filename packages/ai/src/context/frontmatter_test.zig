//! Tests for frontmatter.zig: the corpus goldens in
//! `testdata/frontmatter`, field-name mapping and list forms.

const std = @import("std");
const zg_core = @import("zg_core");
const fm = @import("frontmatter.zig");

const testing = std.testing;

/// Parses `src` and renders the result (or the error) as JSON.
fn dump(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var diag: fm.Diag = .{};
    const doc = fm.parse(arena, src, &diag) catch |e| {
        var s: std.json.Stringify = .{ .writer = w };
        try s.beginObject();
        try s.objectField("error");
        try s.write(@errorName(e));
        try s.objectField("message");
        try s.write(diag.message);
        try s.objectField("line");
        try s.write(diag.line);
        try s.objectField("col");
        try s.write(diag.col);
        try s.endObject();
        try w.writeByte('\n');
        return out.written();
    };
    try w.writeAll("{\"meta\":");
    if (doc.meta) |m| try m.writeJson(w) else try w.writeAll("null");
    try w.print(",\"body_line\":{d},\"body\":", .{doc.body_line});
    var s: std.json.Stringify = .{ .writer = w };
    try s.write(doc.body);
    try w.writeAll("}\n");
    return out.written();
}

test "frontmatter corpus goldens" {
    const io = testing.io;
    const root = @import("zg_options").package_root;
    var pkg = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer pkg.close(io);
    var dir = try pkg.openDir(io, "testdata/frontmatter", .{ .iterate = true });
    defer dir.close(io);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".md")) try names.append(arena, try arena.dupe(u8, e.name[0 .. e.name.len - 3]));
    }
    try testing.expect(names.items.len >= 40);
    for (names.items) |name| {
        const src = try dir.readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}.md", .{name}), arena, .limited(1 << 20));
        const got = try dump(arena, src);
        try zg_core.testkit.golden.expectGoldenOpts(io, @src(), name, got, .{ .root = root, .dir = "testdata/frontmatter", .normalize = .exact });
    }
}

const Skill = struct {
    name: []const u8,
    description: []const u8 = "",
    allowed_tools: []const []const u8 = &.{},
    disable_model_invocation: bool = false,
    model: ?[]const u8 = null,
    max_turns: u32 = 10,
    effort: enum { low, medium, high } = .medium,
};

test "kebab, camel and snake keys map to snake_case fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const doc = try fm.parse(a,
        \\---
        \\name: s
        \\allowed-tools: [Read, Grep]
        \\disableModelInvocation: yes
        \\max_turns: 0x10
        \\effort: high
        \\color: blue
        \\---
        \\body
    , null);
    var diag: fm.Diag = .{};
    const s = try fm.decode(Skill, a, doc.meta.?, &diag);
    try testing.expectEqualStrings("s", s.name);
    try testing.expectEqual(@as(usize, 2), s.allowed_tools.len);
    try testing.expectEqualStrings("Grep", s.allowed_tools[1]);
    try testing.expect(s.disable_model_invocation);
    try testing.expectEqual(@as(u32, 16), s.max_turns);
    try testing.expectEqual(.high, s.effort);
    try testing.expectEqual(@as(?[]const u8, null), s.model);
    try testing.expectEqual(@as(usize, 1), diag.unknown_keys.items.len);
    try testing.expectEqualStrings("color", diag.unknown_keys.items[0]);
    try testing.expectEqualStrings("body", doc.body);
}

test "comma list or sequence" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const L = struct { tools: []const []const u8 };
    for ([_][]const u8{ "---\ntools: Read, Glob,Grep\n---\n", "---\ntools:\n  - Read\n  - Glob\n  - Grep\n---\n", "---\ntools: [Read, Glob, Grep]\n---\n" }) |src| {
        const doc = try fm.parse(a, src, null);
        const l = try fm.decode(L, a, doc.meta.?, null);
        try testing.expectEqual(@as(usize, 3), l.tools.len);
        try testing.expectEqualStrings("Glob", l.tools[1]);
    }
}

test "crlf and bom" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const doc = try fm.parse(a, "\xEF\xBB\xBF---\r\nname: x\r\n---\r\nbody\r\n", null);
    try testing.expectEqualStrings("x", doc.meta.?.get("name").?.scalar);
    try testing.expectEqualStrings("body\r\n", doc.body);
    try testing.expectEqual(@as(u32, 4), doc.body_line);
}

test "decode errors name the field" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const doc = try fm.parse(a, "---\nname: x\nmax_turns: many\n---\n", null);
    var diag: fm.Diag = .{};
    try testing.expectError(error.TypeMismatch, fm.decode(Skill, a, doc.meta.?, &diag));
    try testing.expectEqualStrings("max_turns", diag.message);
    const doc2 = try fm.parse(a, "---\ndescription: x\n---\n", null);
    try testing.expectError(error.MissingField, fm.decode(Skill, a, doc2.meta.?, &diag));
}

test "fuzz: frontmatter" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const n = s.slice(&buf);
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var diag: fm.Diag = .{};
            const src = buf[0..n];
            if (fm.parse(arena_state.allocator(), src, &diag)) |doc| {
                if (doc.meta) |m| {
                    var out: std.Io.Writer.Allocating = .init(arena_state.allocator());
                    try m.writeJson(&out.writer);
                }
            } else |e| switch (e) {
                error.OutOfMemory => return e,
                // Every syntax error carries a position.
                else => try testing.expect(diag.line > 0 and diag.col > 0 and diag.message.len > 0),
            }
        }
    }.one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "frontmatter") });
}
