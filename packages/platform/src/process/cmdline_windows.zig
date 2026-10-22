//! The two strings `CreateProcessW` takes apart from handles: the command
//! line, quoted so the child's MSVCRT (`CommandLineToArgvW`) splits it back
//! into the same argv, and the UTF-16 environment block. Pure functions;
//! they build and test on every OS.

const std = @import("std");
const SpawnPolicy = @import("pty.zig").SpawnPolicy;
const env_mod = @import("env.zig");

/// Appends `arg` quoted per the MSVCRT rules: arguments with spaces, tabs,
/// newlines or quotes (and empty ones) are wrapped in quotes; inside,
/// backslashes are doubled only before a quote or the closing quote, and
/// quotes are escaped.
pub fn appendArg(gpa: std.mem.Allocator, out: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) {
        try out.appendSlice(gpa, arg);
        return;
    }
    try out.append(gpa, '"');
    var i: usize = 0;
    while (true) {
        var slashes: usize = 0;
        while (i < arg.len and arg[i] == '\\') : (i += 1) slashes += 1;
        if (i == arg.len) {
            // Before the closing quote: every backslash doubled.
            try out.appendNTimes(gpa, '\\', slashes * 2);
            break;
        }
        if (arg[i] == '"') {
            try out.appendNTimes(gpa, '\\', slashes * 2 + 1);
            try out.append(gpa, '"');
        } else {
            try out.appendNTimes(gpa, '\\', slashes);
            try out.append(gpa, arg[i]);
        }
        i += 1;
    }
    try out.append(gpa, '"');
}

/// The NUL-terminated UTF-16 command line for `argv`.
pub fn commandLine(gpa: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (argv, 0..) |a, i| {
        if (i > 0) try out.append(gpa, ' ');
        try appendArg(gpa, &out, a);
    }
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, out.items) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf8,
    };
}

fn lessIgnoreCase(_: void, a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const ux = std.ascii.toUpper(x);
        const uy = std.ascii.toUpper(y);
        if (ux != uy) return ux < uy;
    }
    return a.len < b.len;
}

/// The `CREATE_UNICODE_ENVIRONMENT` block: the caller's map filtered by
/// the policy (and without `ZG_*`), `env_set` applied, `TERM` set, sorted
/// case-insensitively by name, `NAME=VALUE\0`… then a final `\0`.
pub fn envBlock(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, policy: ?*const SpawnPolicy, term: ?[]const u8) ![]u16 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var merged: std.process.Environ.Map = .init(arena);
    for (env.keys(), env.values()) |k, v| {
        if (env_mod.allowed(k, policy)) try merged.put(k, v);
    }
    if (policy) |p| for (p.env_set) |kv| try merged.put(kv[0], kv[1]);
    if (term) |t| try merged.put("TERM", t);
    const names = try arena.dupe([]const u8, merged.keys());
    std.mem.sort([]const u8, names, {}, lessIgnoreCase);
    var utf8: std.ArrayList(u8) = .empty;
    for (names) |k| {
        try utf8.print(arena, "{s}={s}", .{ k, merged.get(k).? });
        try utf8.append(arena, 0);
    }
    // An empty block still needs its two NULs.
    if (names.len == 0) try utf8.append(arena, 0);
    try utf8.append(arena, 0);
    return std.unicode.utf8ToUtf16LeAlloc(gpa, utf8.items) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidUtf8,
    };
}

const testing = std.testing;

/// `CommandLineToArgvW`'s splitting rules for arguments after the first,
/// to check that quoting round-trips.
fn split(gpa: std.mem.Allocator, line: []const u8) !std.ArrayList([]u8) {
    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |a| gpa.free(a);
        args.deinit(gpa);
    }
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i == line.len) break;
        var cur: std.ArrayList(u8) = .empty;
        errdefer cur.deinit(gpa);
        var quoted = false;
        while (i < line.len) {
            const c = line[i];
            if (!quoted and (c == ' ' or c == '\t')) break;
            if (c == '\\') {
                var n: usize = 0;
                while (i < line.len and line[i] == '\\') : (i += 1) n += 1;
                if (i < line.len and line[i] == '"') {
                    try cur.appendNTimes(gpa, '\\', n / 2);
                    if (n % 2 == 1) {
                        try cur.append(gpa, '"');
                        i += 1;
                    }
                } else try cur.appendNTimes(gpa, '\\', n);
                continue;
            }
            if (c == '"') {
                quoted = !quoted;
                i += 1;
                continue;
            }
            try cur.append(gpa, c);
            i += 1;
        }
        try args.append(gpa, try cur.toOwnedSlice(gpa));
    }
    return args;
}

test "command-line quoting table" {
    const gpa = testing.allocator;
    const cases = [_]struct { arg: []const u8, quoted: []const u8 }{
        .{ .arg = "plain", .quoted = "plain" },
        .{ .arg = "", .quoted = "\"\"" },
        .{ .arg = "two words", .quoted = "\"two words\"" },
        .{ .arg = "tab\there", .quoted = "\"tab\there\"" },
        .{ .arg = "say \"hi\"", .quoted = "\"say \\\"hi\\\"\"" },
        .{ .arg = "C:\\Program Files\\", .quoted = "\"C:\\Program Files\\\\\"" },
        .{ .arg = "C:\\no\\spaces\\", .quoted = "C:\\no\\spaces\\" },
        .{ .arg = "a\\\\\"b", .quoted = "\"a\\\\\\\\\\\"b\"" },
        .{ .arg = "back\\slash mid", .quoted = "\"back\\slash mid\"" },
        .{ .arg = "\"", .quoted = "\"\\\"\"" },
        .{ .arg = "x\\\\ y", .quoted = "\"x\\\\ y\"" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try appendArg(gpa, &out, c.arg);
        try testing.expectEqualStrings(c.quoted, out.items);
        // And the child splits it back to the same argument.
        var back = try split(gpa, out.items);
        defer {
            for (back.items) |a| gpa.free(a);
            back.deinit(gpa);
        }
        try testing.expectEqual(@as(usize, 1), back.items.len);
        try testing.expectEqualStrings(c.arg, back.items[0]);
    }
    const line = try commandLine(gpa, &.{ "cmd.exe", "/c", "echo hello world", "ü" });
    defer gpa.free(line);
    const want = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe /c \"echo hello world\" ü");
    try testing.expectEqualSlices(u16, want, line);
}

test "env block: sorted case-insensitively, filtered, double-NUL" {
    const gpa = testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("path", "C:\\Windows");
    try env.put("ZG_SECRET", "x");
    try env.put("Home", "C:\\Users\\zg");
    try env.put("ComSpec", "cmd.exe");
    const block = try envBlock(gpa, &env, null, "xterm-256color");
    defer gpa.free(block);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(gpa, block);
    defer gpa.free(utf8);
    try testing.expectEqualStrings("ComSpec=cmd.exe\x00Home=C:\\Users\\zg\x00path=C:\\Windows\x00TERM=xterm-256color\x00\x00", utf8);

    var empty: std.process.Environ.Map = .init(gpa);
    defer empty.deinit();
    const none = try envBlock(gpa, &empty, null, null);
    defer gpa.free(none);
    try testing.expectEqualSlices(u16, &.{ 0, 0 }, none);
}
