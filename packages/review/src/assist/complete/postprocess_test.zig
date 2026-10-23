const std = @import("std");
const pp = @import("postprocess.zig");
const telemetry = @import("telemetry.zig");
const context = @import("context.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn req(prefix: []const u8, suffix: []const u8, multiline: bool) context.CompletionRequest {
    return .{ .path = "a.zig", .language = "zig", .prefix = prefix, .suffix = suffix, .multiline = multiline, .max_tokens = 32, .stop = &.{} };
}

fn run(r: context.CompletionRequest, raw: []const u8, final: bool) !pp.PostResult {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    // The tests compare inside the arena's life via `expectShow`.
    errdefer arena.deinit();
    const out = try pp.postprocess(arena.allocator(), &r, raw, final);
    Keep.arena = arena;
    return out;
}

const Keep = struct {
    var arena: ?std.heap.ArenaAllocator = null;
    fn free() void {
        if (arena) |*a| a.deinit();
        arena = null;
    }
};

fn expectShow(want: []const u8, r: context.CompletionRequest, raw: []const u8, final: bool) !void {
    defer Keep.free();
    const got = try run(r, raw, final);
    switch (got) {
        .show => |s| try testing.expectEqualStrings(want, s),
        .drop => |d| {
            std.debug.print("dropped ({t}) for {s}\n", .{ d, raw });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectDrop(want: pp.Drop, r: context.CompletionRequest, raw: []const u8, final: bool) !void {
    defer Keep.free();
    const got = try run(r, raw, final);
    try testing.expectEqual(pp.PostResult{ .drop = want }, got);
}

test "postprocess: suffix overlap trims" {
    const cases = [_]struct { prefix: []const u8, suffix: []const u8, raw: []const u8, want: []const u8 }{
        .{ .prefix = "foo(", .suffix = ")\n", .raw = "bar)", .want = "bar" },
        .{ .prefix = "foo(", .suffix = ");\n", .raw = "bar);", .want = "bar" },
        .{ .prefix = "print(\"", .suffix = "\")\n", .raw = "hi\")", .want = "hi" },
        .{ .prefix = "f(", .suffix = " )\n", .raw = "x)", .want = "x" },
        .{ .prefix = "if (", .suffix = ") {\n", .raw = "a, b) {", .want = "a, b" },
        .{ .prefix = "a[", .suffix = "]", .raw = "i]", .want = "i" },
        .{ .prefix = "s = {", .suffix = "}", .raw = "1 }", .want = "1 " },
        .{ .prefix = "f('", .suffix = "')", .raw = "a')", .want = "a" },
        .{ .prefix = "f(", .suffix = ")", .raw = "x )", .want = "x " },
        .{ .prefix = "foo(", .suffix = ")\n", .raw = "bar", .want = "bar" },
        .{ .prefix = "g(", .suffix = ") + 1;", .raw = "y) + 1;", .want = "y" },
    };
    for (cases) |c| try expectShow(c.want, req(c.prefix, c.suffix, false), c.raw, true);
}

test "postprocess: single-line cut, multi-line dedent stop, two blank lines stop" {
    try expectShow("a", req("x = ", "\n", false), "a\nb", true);
    // Dedent below the cursor line's indentation (4) stops.
    try expectShow("x();\n    y();", req("fn f() {\n    ", "\n}\n", true), "x();\n    y();\n}\nfn g() {}", true);
    // A line that closes a bracket the completion opened is kept.
    try expectShow("call(\n        a,\n)", req("    ", "\n", true), "call(\n        a,\n)\nnext", true);
    try expectShow("a();\n    b();", req("    ", "\n", true), "a();\n    b();\n\n\n    c();", true);
    // At most 30 lines.
    var many: std.ArrayList(u8) = .empty;
    defer many.deinit(gpa);
    for (0..40) |i| try many.print(gpa, "x{d};\n", .{i});
    defer Keep.free();
    const got = try run(req("", "", true), many.items, true);
    try testing.expectEqual(@as(usize, 29), std.mem.count(u8, got.show, "\n"));
}

test "postprocess: bracket excess trimmed only when suffix has closers" {
    try expectShow("bar", req("foo(", ")\n", false), "bar))", true);
    try expectShow("bar)", req("foo(", "\n", false), "bar)", true);
    try expectShow("(a)", req("x = ", ";\n", false), "(a)", true);
}

test "postprocess: drops whitespace/duplicate/prev-line repeats" {
    try expectDrop(.empty, req("x", "", false), "", true);
    try expectDrop(.whitespace_only, req("x", "", true), "  \n\t", true);
    try expectDrop(.duplicate_of_suffix, req("    ", "\n    return x;\n", false), "return x;", true);
    try expectDrop(.duplicate_of_prev_line, req("    a = 1;\n    ", "\n", false), "a = 1;", true);
    try expectDrop(.too_long, req("", "", false), "x" ** 1200, true);
}

test "postprocess: streaming shows first complete line early" {
    try expectShow("x();", req("    ", "\n", true), "x();\n    y(", false);
    try expectDrop(.empty, req("    ", "\n", true), "x()", false);
    // End-token remnants and CRLF documents.
    try expectShow("x;", req("a = ", "\n", false), "x;<|endoftext", true);
    try expectShow("x\r\n    y", req("a\r\n    ", "\r\n", true), "x\n    y", true);
}

test "telemetry: counts and histogram buckets" {
    try testing.expectEqual(@as(usize, 0), telemetry.Telemetry.bucketOf(0));
    try testing.expectEqual(@as(usize, 0), telemetry.Telemetry.bucketOf(1));
    try testing.expectEqual(@as(usize, 1), telemetry.Telemetry.bucketOf(3));
    try testing.expectEqual(@as(usize, 2), telemetry.Telemetry.bucketOf(4));
    try testing.expectEqual(@as(usize, 9), telemetry.Telemetry.bucketOf(1000));
    try testing.expectEqual(@as(usize, 15), telemetry.Telemetry.bucketOf(1 << 40));

    var t: telemetry.Telemetry = .{};
    try testing.expect(t.p50Ms() == null);
    for ([_]u64{ 100, 120, 130, 900 }) |l| t.recordShown(l);
    t.recordAccept(true, 12);
    t.recordAccept(false, 3);
    try testing.expectEqual(@as(u64, 4), t.shown);
    try testing.expectEqual(@as(u64, 15), t.chars_accepted);
    try testing.expectApproxEqAbs(@as(f64, 0.5), t.acceptanceRate(), 1e-9);
    try testing.expectEqual(@as(?u64, 64), t.p50Ms());

    // Persisted per day, counts only.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [10]u8 = undefined;
    const day = telemetry.dayString(&buf, 1_792_627_200);
    try testing.expectEqualStrings("2026-10-22", day);
    try telemetry.persist(gpa, testing.io, tmp.dir, day, t.snapshot());
    try telemetry.persist(gpa, testing.io, tmp.dir, day, t.snapshot());
    try telemetry.persist(gpa, testing.io, tmp.dir, "2026-10-23", .{ .shown = 1 });
    const bytes = try tmp.dir.readFileAlloc(testing.io, telemetry.stats_path, gpa, .limited(1 << 16));
    defer gpa.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, ".shown = 8") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "2026-10-23") != null);
    for ([_][]const u8{ "a.zig", "/", "fn " }) |leak| try testing.expect(std.mem.indexOf(u8, bytes, leak) == null);
}
