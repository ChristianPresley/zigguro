//! Windows command-line tails (E17.F02.S01.T03): the app hands its
//! arguments to `zigguro-setup --apply --relaunch <tail>` as one string,
//! and setup splits them again for the relaunched app. Quoting follows
//! the C runtime's rules, which `std.process.Args.Iterator.Windows`
//! parses. Pure code; runs on every OS.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// `args` as one command-line string, each argument quoted when needed.
pub fn join(arena: Allocator, args: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (args, 0..) |a, i| {
        if (i > 0) try out.append(arena, ' ');
        try quote(arena, &out, a);
    }
    return out.items;
}

fn quote(arena: Allocator, out: *std.ArrayList(u8), a: []const u8) Allocator.Error!void {
    const plain = a.len > 0 and std.mem.indexOfAny(u8, a, " \t\n\x0b\"") == null;
    if (plain) return out.appendSlice(arena, a);
    try out.append(arena, '"');
    var slashes: usize = 0;
    for (a) |c| {
        switch (c) {
            '\\' => slashes += 1,
            '"' => {
                // Backslashes before a quote double, and the quote escapes.
                try out.appendNTimes(arena, '\\', slashes * 2 + 1);
                slashes = 0;
                try out.append(arena, '"');
                continue;
            },
            else => {
                try out.appendNTimes(arena, '\\', slashes);
                slashes = 0;
            },
        }
        if (c != '\\') try out.append(arena, c);
    }
    // Backslashes before the closing quote double too.
    try out.appendNTimes(arena, '\\', slashes * 2);
    try out.append(arena, '"');
}

/// Splits a tail made by `join` (or typed by a user) into arguments.
pub fn split(arena: Allocator, tail: []const u8) error{ OutOfMemory, InvalidUtf8 }![]const []const u8 {
    // The parser treats the first word as the program name, which has
    // other quoting rules: give it a dummy one.
    const line = try std.fmt.allocPrint(arena, "x {s}", .{tail});
    const wide = std.unicode.wtf8ToWtf16LeAlloc(arena, line) catch return error.InvalidUtf8;
    var it: std.process.Args.Iterator.Windows = try .init(arena, wide);
    _ = it.skip();
    var out: std.ArrayList([]const u8) = .empty;
    while (it.next()) |a| try out.append(arena, try arena.dupe(u8, a));
    return out.items;
}

const testing = std.testing;

test "cmdline: join quotes only what needs it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("--new-window C:\\x.zig", try join(a, &.{ "--new-window", "C:\\x.zig" }));
    try testing.expectEqualStrings("\"\" \"a b\"", try join(a, &.{ "", "a b" }));
    try testing.expectEqualStrings("\"C:\\dir with space\\\\\"", try join(a, &.{"C:\\dir with space\\"}));
    try testing.expectEqualStrings("\"say \\\"hi\\\"\"", try join(a, &.{"say \"hi\""}));
    try testing.expectEqualStrings("", try join(a, &.{}));
}

test "cmdline: split undoes join" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const []const u8{
        &.{},
        &.{"x.zig"},
        &.{ "--new-window", "C:\\Users\\zïg\\my file.zig", "" },
        &.{ "a\\\\b", "c\\\"d", "trailing\\", "tab\there", "\"" },
    };
    for (cases) |args| {
        const back = try split(a, try join(a, args));
        try testing.expectEqual(args.len, back.len);
        for (args, back) |x, y| try testing.expectEqualStrings(x, y);
    }
    const typed = try split(a, "  one \"two three\"   four");
    try testing.expectEqual(@as(usize, 3), typed.len);
    try testing.expectEqualStrings("two three", typed[1]);
}
