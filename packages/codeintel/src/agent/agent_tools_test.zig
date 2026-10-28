//! The `lsp_*` tool contract: schemas, the listing and the renderer's
//! goldens (testdata/agent/*.txt).

const std = @import("std");
const options = @import("zg_options");
const tools = @import("tools.zig");
const render = @import("render.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn golden(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ options.package_root, "testdata", "agent", name });
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20));
    // Goldens end with a newline; the output does not.
    return std.mem.trimEnd(u8, text, "\r\n");
}

fn expectGolden(a: std.mem.Allocator, name: []const u8, got: []const u8) !void {
    const want = try golden(a, name);
    // CRLF checkouts compare the same.
    const norm = try std.mem.replaceOwned(u8, a, want, "\r\n", "\n");
    try testing.expectEqualStrings(norm, got);
}

test "agent_tools: schemas parse and have additionalProperties false" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (tools.specs) |s| {
        try testing.expect(std.mem.startsWith(u8, s.name, "lsp_"));
        try testing.expect(!(try names.fetchPut(a, s.name, {}) != null));
        try testing.expect(s.description.len > 40);
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, s.input_schema_json, .{});
        const o = v.object;
        try testing.expectEqualStrings("object", o.get("type").?.string);
        try testing.expect(o.get("additionalProperties").? == .bool and !o.get("additionalProperties").?.bool);
        const props = o.get("properties").?.object;
        if (o.get("required")) |req| for (req.array.items) |r| try testing.expect(props.get(r.string) != null);
        for (props.values()) |p| try testing.expect(p.object.get("description") != null);
    }
    try testing.expectEqual(@as(usize, 14), names.count());
}

test "agent_tools: mutating tools flagged control" {
    for (tools.specs) |s| {
        const control = std.mem.eql(u8, s.name, "lsp_rename_apply") or std.mem.eql(u8, s.name, "lsp_apply_code_action");
        try testing.expectEqual(control, s.permission == .control);
        if (control) try testing.expect(std.mem.indexOf(u8, s.description, "review") != null);
    }
}

const Files = struct {
    fn get(_: *anyopaque, path: []const u8) ?[]const u8 {
        if (std.mem.endsWith(u8, path, "pool.zig")) return pool_zig;
        if (std.mem.endsWith(u8, path, "main.zig")) return main_zig;
        return null;
    }
    const pool_zig =
        \\const std = @import("std");
        \\
        \\pub const Pool = struct {
        \\    items: std.ArrayList(u32) = .empty,
        \\
        \\    pub fn init() Pool {
        \\        return .{};
        \\    }
        \\
        \\    pub fn reset(p: *Pool) void {
        \\        p.* = init();
        \\    }
        \\};
        \\
    ;
    const main_zig =
        \\const Pool = @import("pool.zig").Pool;
        \\
        \\pub fn main() void {
        \\    var p = Pool.init();
        \\    p.reset();
        \\    var q = Pool.init();
        \\    q.reset();
        \\}
        \\
    ;
};

fn t(path: []const u8, line: u32, col: u32, len: u32) render.Target {
    return .{ .path = path, .line = line, .column = col, .end_line = line, .end_column = col + len };
}

/// References to `Pool.init`, in no order, with a duplicate.
const refs = [_]render.Target{
    t("/w/src/main.zig", 5, 17, 4),
    t("/w/src/pool.zig", 10, 13, 4),
    t("/w/src/main.zig", 3, 17, 4),
    t("/w/src/pool.zig", 5, 11, 4),
    t("/w/src/main.zig", 3, 17, 4),
    t("/w/lib/other.zig", 40, 2, 4),
};

test "agent_tools: render references grouped and truncated (golden)" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var dummy: u8 = 0;
    const files: render.TextLookup = .{ .ctx = &dummy, .get = Files.get };
    const noun: render.Noun = .{ .one = "reference", .many = "references" };
    try expectGolden(a, "references.txt", try render.renderTargets(a, &refs, .{ .root = "/w", .context_lines = 1 }, files, noun, 0));
    // A budget for one file: the cut is at a file boundary.
    try expectGolden(a, "references_truncated.txt", try render.renderTargets(a, &refs, .{ .root = "/w", .context_lines = 1, .token_budget = 30 }, files, noun, 0));
    // Past a limit, the count says how many there are.
    try expectGolden(a, "references_limited.txt", try render.renderTargets(a, refs[0..2], .{ .root = "/w/" }, null, noun, 9));
    try testing.expectEqualStrings("No references.", try render.renderTargets(a, &.{}, .{}, null, noun, 0));
    try testing.expectEqualStrings(
        \\[{"path":"lib/other.zig","line":41,"column":3,"end_line":41,"end_column":7,"kind":"","name":""},{"path":"src/main.zig","line":4,"column":18,"end_line":4,"end_column":22,"kind":"","name":""}]
    , try render.structuredJson(a, &.{ refs[2], refs[5] }, .{ .root = "/w" }));
}

test "agent_tools: render diagnostics compiler-style (golden)" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ds = [_]render.AgentDiag{
        .{ .path = "/w/src/b.zig", .line = 11, .column = 4, .severity = "error", .message = "expected type 'u32', found '[]const u8'\nnote: here", .source = "zls" },
        .{ .path = "/w/src/a.zig", .line = 2, .column = 0, .severity = "warning", .message = "unused local constant", .source = "zls", .code = "unused" },
        .{ .path = "C:\\w\\src\\c.zig", .line = 0, .column = 0, .severity = "hint", .message = "style", .code = "E9" },
        .{ .path = "/w/src/a.zig", .line = 1, .column = 8, .severity = "error", .message = "use of undeclared identifier 'x'" },
    };
    try expectGolden(a, "diagnostics.txt", try render.renderDiagnostics(a, &ds, .{ .root = "/w" }));
}

test "agent_tools: hover markdown to text (golden)" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const md =
        \\```zig
        \\pub fn init(gpa: *Allocator) **Pool
        \\```
        \\
        \\
        \\
        \\# Pool
        \\
        \\Creates a **new** pool, see [the guide](https://example.com/guide) and _Pool.reset_.
        \\Keeps `snake_case`, a_b and 2*3 \*as is\*.
        \\
        \\---
        \\* first
        \\* second
        \\
    ;
    try expectGolden(a, "hover.txt", try render.markdownToText(a, md));
}

test "agent_tools: deterministic output across runs" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var dummy: u8 = 0;
    const files: render.TextLookup = .{ .ctx = &dummy, .get = Files.get };
    const noun: render.Noun = .{ .one = "reference", .many = "references" };
    const first = try render.renderTargets(a, &refs, .{ .root = "/w" }, files, noun, 0);
    var shuffled = refs;
    var prng: std.Random.DefaultPrng = .init(7);
    for (0..20) |_| {
        prng.random().shuffle(render.Target, &shuffled);
        try testing.expectEqualStrings(first, try render.renderTargets(a, &shuffled, .{ .root = "/w" }, files, noun, 0));
    }
    // Windows paths render with `/`.
    var win = refs;
    for (&win) |*x| x.path = try std.mem.replaceOwned(u8, a, try std.mem.concat(a, u8, &.{ "C:", x.path }), "/", "\\");
    const on_windows = try render.renderTargets(a, &win, .{ .root = "C:\\w" }, files, noun, 0);
    try testing.expectEqualStrings(first, on_windows);
}

test "agent_tools: columns in characters" {
    // An emoji is 2 UTF-16 units, 4 bytes, 1 character.
    const line = "x = \"\u{1F600}\"; y";
    try testing.expectEqual(@as(u32, 8), render.charColumn(line, 9, .utf16));
    try testing.expectEqual(@as(u32, 8), render.charColumn(line, 11, .utf8));
    try testing.expectEqual(@as(u32, 8), render.charColumn(line, 8, .utf32));
    try testing.expectEqualStrings("b", render.lineOf("a\r\nb\nc", 1));
    try testing.expectEqualStrings("", render.lineOf("a\nb", 5));
}
