//! `.zgui` scripts (E04.F01.S03.T01): every script in `scripts/` runs
//! against the views in `examples.zig` (snapshots compare with golden files
//! under `testdata/golden/scripts`), and the interpreter's own behavior:
//! parse errors with positions, query candidates, virtual time.

const std = @import("std");
const script = @import("script.zig");
const examples = @import("examples.zig");

const testing = std.testing;
const gpa = testing.allocator;

const views = examples.views;

fn golden(_: ?*anyopaque, kind: script.SnapshotKind, name: []const u8, text: []const u8) anyerror!void {
    var buf: [128]u8 = undefined;
    const file = try std.fmt.bufPrint(&buf, "{s}.{t}", .{ name, kind });
    try @import("zg_core").testkit.golden.expectGoldenOpts(testing.io, @src(), file, text, .{
        .root = @import("zg_options").package_root,
        .dir = "testdata/golden/scripts",
    });
}

fn runScript(src: []const u8) !void {
    var diag: script.Diag = .{};
    script.run(gpa, src, .{ .views = &views, .snapshot = .{ .f = golden } }, &diag) catch |e| {
        std.debug.print("script failed: {s}\n", .{diag.message()});
        return e;
    };
}

test "zgui scripts" {
    inline for (.{ "counter", "form", "tooltip", "dock" }) |name| {
        runScript(@embedFile("scripts/" ++ name ++ ".zgui")) catch |e| {
            std.debug.print("in scripts/{s}.zgui\n", .{name});
            return e;
        };
    }
}

test "click button example" {
    try runScript(
        \\open Counter
        \\click role=button name="Increment"
        \\expect role=text name="Count: 1"
    );
}

test "type and select-all delete" {
    try runScript(
        \\open Form
        \\click role=textbox
        \\type "hello"
        \\press ctrl+a
        \\press delete
        \\expect role=textbox text=""
    );
}

test "query not found lists candidates" {
    var diag: script.Diag = .{};
    try testing.expectError(error.ScriptFailed, script.run(gpa,
        \\open Counter
        \\click role=button name="Incremnet"
    , .{ .views = &views }, &diag));
    try testing.expectEqual(@as(u32, 2), diag.line);
    const msg = diag.message();
    try testing.expect(std.mem.indexOf(u8, msg, "nothing matches role=button name=\"Incremnet\"") != null);
    // The closest name comes first.
    try testing.expect(std.mem.indexOf(u8, msg, "closest: button \"Increment\"") != null);
}

test "script parse errors have positions" {
    const cases = [_]struct { src: []const u8, line: u32, col: u32, has: []const u8 }{
        .{ .src = "open Counter\nclik role=button", .line = 2, .col = 1, .has = "unknown command \"clik\"" },
        .{ .src = "open Counter\n\n  click role=buton", .line = 3, .col = 9, .has = "unknown role \"buton\"" },
        .{ .src = "type \"unterminated", .line = 1, .col = 6, .has = "unterminated string" },
        .{ .src = "press ctrl+nokey", .line = 1, .col = 7, .has = "unknown key chord" },
        .{ .src = "wait soon", .line = 1, .col = 6, .has = "expected a duration" },
        .{ .src = "expect role=button sideways", .line = 1, .col = 20, .has = "unknown expectation" },
        .{ .src = "click within(role=list", .line = 1, .col = 23, .has = "expected )" },
        .{ .src = "snapshot layout name", .line = 1, .col = 17, .has = "in quotes" },
        .{ .src = "ime \"ni\"", .line = 1, .col = 1, .has = "ime is not supported" },
    };
    for (cases) |c| {
        var diag: script.Diag = .{};
        try testing.expectError(error.ScriptSyntax, script.run(gpa, c.src, .{ .views = &views }, &diag));
        testing.expectEqual(c.line, diag.line) catch |e| {
            std.debug.print("{s}\n", .{diag.message()});
            return e;
        };
        testing.expectEqual(c.col, diag.col) catch |e| {
            std.debug.print("{s}\n", .{diag.message()});
            return e;
        };
        try testing.expect(std.mem.indexOf(u8, diag.message(), c.has) != null);
    }
}

test "virtual time tooltip after 500ms" {
    try runScript(
        \\open Form
        \\hover role=button name="Clear"
        \\wait 499ms
        \\expect role=tooltip absent
        \\wait 1ms
        \\expect role=tooltip
    );
}

test "failures stop at their line; commands need an open view" {
    var diag: script.Diag = .{};
    try testing.expectError(error.ScriptFailed, script.run(gpa, "click role=button", .{ .views = &views }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "no view is open") != null);
    try testing.expectError(error.ScriptFailed, script.run(gpa,
        \\open Counter
        \\expect role=button count=3
    , .{ .views = &views }, &diag));
    try testing.expectEqual(@as(u32, 2), diag.line);
    try testing.expect(std.mem.indexOf(u8, diag.message(), "expected 3 of role=button, found 2") != null);
    try testing.expectError(error.ScriptFailed, script.run(gpa, "open Nope", .{ .views = &views }, &diag));
}
