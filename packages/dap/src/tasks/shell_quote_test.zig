//! Shell quoting, table-driven per style, and the argv per shell.

const std = @import("std");
const sq = @import("shell_quote.zig");
const testing = std.testing;

test "shell_quote: table (linux sh, windows cmd, pwsh)" {
    const Row = struct { arg: []const u8, posix: []const u8, cmd: []const u8, pwsh: []const u8 };
    const rows = [_]Row{
        .{ .arg = "plain", .posix = "plain", .cmd = "plain", .pwsh = "plain" },
        .{ .arg = "src/main.zig", .posix = "src/main.zig", .cmd = "src/main.zig", .pwsh = "src/main.zig" },
        .{ .arg = "-Doptimize=ReleaseFast", .posix = "-Doptimize=ReleaseFast", .cmd = "-Doptimize=ReleaseFast", .pwsh = "-Doptimize=ReleaseFast" },
        .{ .arg = "", .posix = "''", .cmd = "\"\"", .pwsh = "''" },
        .{ .arg = "a b", .posix = "'a b'", .cmd = "\"a b\"", .pwsh = "'a b'" },
        .{ .arg = "it's", .posix = "'it'\\''s'", .cmd = "it's", .pwsh = "'it''s'" },
        .{ .arg = "say \"hi\"", .posix = "'say \"hi\"'", .cmd = "\"say \"\"hi\"\"\"", .pwsh = "'say \"hi\"'" },
        .{ .arg = "$HOME", .posix = "'$HOME'", .cmd = "$HOME", .pwsh = "'$HOME'" },
        .{ .arg = "a&b", .posix = "'a&b'", .cmd = "\"a&b\"", .pwsh = "'a&b'" },
        .{ .arg = "x|y>z", .posix = "'x|y>z'", .cmd = "\"x|y>z\"", .pwsh = "'x|y>z'" },
        .{ .arg = "*.zig", .posix = "'*.zig'", .cmd = "*.zig", .pwsh = "'*.zig'" },
        .{ .arg = "C:\\Program Files\\x", .posix = "'C:\\Program Files\\x'", .cmd = "\"C:\\Program Files\\x\"", .pwsh = "'C:\\Program Files\\x'" },
        .{ .arg = "line\nbreak", .posix = "'line\nbreak'", .cmd = "\"line\nbreak\"", .pwsh = "'line\nbreak'" },
        .{ .arg = "%PATH%", .posix = "%PATH%", .cmd = "%PATH%", .pwsh = "%PATH%" },
        .{ .arg = "(group)", .posix = "'(group)'", .cmd = "\"(group)\"", .pwsh = "'(group)'" },
    };
    var buf: [128]u8 = undefined;
    for (rows) |row| {
        inline for (.{ .{ sq.Style.posix, "posix" }, .{ sq.Style.cmd, "cmd" }, .{ sq.Style.pwsh, "pwsh" } }) |s| {
            var w: std.Io.Writer = .fixed(&buf);
            try sq.quote(&w, row.arg, s[0]);
            testing.expectEqualStrings(@field(row, s[1]), w.buffered()) catch |e| {
                std.debug.print("arg {s} style {s}\n", .{ row.arg, s[1] });
                return e;
            };
        }
    }
}

test "shell_quote: shells and their argv" {
    const a = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    try testing.expectEqual(sq.Style.posix, sq.styleOf(null, .linux));
    try testing.expectEqual(sq.Style.cmd, sq.styleOf(null, .windows));
    try testing.expectEqual(sq.Style.cmd, sq.styleOf("C:\\Windows\\System32\\CMD.EXE", .windows));
    try testing.expectEqual(sq.Style.pwsh, sq.styleOf("pwsh.exe", .windows));
    try testing.expectEqual(sq.Style.pwsh, sq.styleOf("/usr/bin/pwsh", .linux));
    try testing.expectEqual(sq.Style.posix, sq.styleOf("/bin/bash", .linux));

    const line = try sq.commandLine(ar, "make -j8", &.{ "a b", "c" }, .posix);
    try testing.expectEqualStrings("make -j8 'a b' c", line);

    const sh = try sq.shellArgv(ar, line, null, null, .linux);
    try testing.expectEqual(@as(usize, 3), sh.len);
    try testing.expectEqualStrings("/bin/sh", sh[0]);
    try testing.expectEqualStrings("-c", sh[1]);
    try testing.expectEqualStrings(line, sh[2]);

    const cmd = try sq.shellArgv(ar, "build.bat x", null, null, .windows);
    try testing.expectEqualStrings("cmd.exe", cmd[0]);
    try testing.expectEqualStrings("/d", cmd[1]);
    try testing.expectEqualStrings("/s", cmd[2]);
    try testing.expectEqualStrings("/c", cmd[3]);
    try testing.expectEqualStrings("build.bat x", cmd[4]);

    const pw = try sq.shellArgv(ar, "./build.ps1", "pwsh.exe", null, .windows);
    try testing.expectEqualStrings("pwsh.exe", pw[0]);
    try testing.expectEqualStrings("-NoProfile", pw[1]);
    try testing.expectEqualStrings("-Command", pw[2]);

    const custom = try sq.shellArgv(ar, "ls", "/bin/zsh", &.{ "-l", "-c" }, .linux);
    try testing.expectEqual(@as(usize, 4), custom.len);
    try testing.expectEqualStrings("-l", custom[1]);
    try testing.expectEqualStrings("ls", custom[3]);
}
