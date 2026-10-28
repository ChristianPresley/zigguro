const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const inject = @import("inject.zig");

test "inject: shell kinds from argv[0]" {
    try testing.expectEqual(inject.ShellKind.bash, inject.kindOf("/usr/bin/bash"));
    try testing.expectEqual(inject.ShellKind.bash, inject.kindOf("-bash"));
    try testing.expectEqual(inject.ShellKind.zsh, inject.kindOf("zsh"));
    try testing.expectEqual(inject.ShellKind.fish, inject.kindOf("/opt/homebrew/bin/fish"));
    try testing.expectEqual(inject.ShellKind.pwsh, inject.kindOf("C:\\Program Files\\PowerShell\\7\\pwsh.exe"));
    try testing.expectEqual(inject.ShellKind.powershell, inject.kindOf("PowerShell.EXE"));
    try testing.expectEqual(inject.ShellKind.cmd, inject.kindOf("C:\\Windows\\System32\\cmd.exe"));
    try testing.expectEqual(inject.ShellKind.other, inject.kindOf("/bin/sh"));
    try testing.expectEqual(inject.ShellKind.other, inject.kindOf("nu"));
}

test "inject: shouldInject skips commands, scripts and skipped startup files" {
    const T = struct { inject.ShellKind, []const []const u8, bool };
    const cases = [_]T{
        .{ .bash, &.{}, true },
        .{ .bash, &.{"-l"}, true },
        .{ .bash, &.{ "-c", "ls" }, false },
        .{ .bash, &.{"script.sh"}, false },
        .{ .bash, &.{"--norc"}, false },
        .{ .bash, &.{ "--rcfile", "x" }, false },
        .{ .bash, &.{"--posix"}, false },
        .{ .zsh, &.{"-l"}, true },
        .{ .zsh, &.{"-f"}, false },
        .{ .zsh, &.{ "-c", "ls" }, false },
        .{ .fish, &.{}, true },
        .{ .fish, &.{"--no-config"}, false },
        .{ .fish, &.{ "-c", "ls" }, false },
        .{ .pwsh, &.{"-NoLogo"}, true },
        .{ .pwsh, &.{ "-command", "dir" }, false },
        .{ .pwsh, &.{ "-File", "x.ps1" }, false },
        .{ .cmd, &.{}, true },
        .{ .cmd, &.{ "/C", "dir" }, false },
        .{ .other, &.{}, false },
    };
    for (cases) |c| {
        errdefer std.debug.print("{t} {any}\n", .{ c[0], c[1] });
        try testing.expectEqual(c[2], inject.shouldInject(c[0], c[1]));
    }
}

fn joined(p: *const inject.Plan) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (p.argv, 0..) |a, i| {
        if (i > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, a);
    }
    for (p.env) |kv| try out.print(gpa, "\n{s}={s}", .{ kv[0], kv[1] });
    return out.toOwnedSlice(gpa);
}

fn expectPlan(argv: []const []const u8, env: *const std.process.Environ.Map, dir: []const u8, want: []const u8) !void {
    var p = (try inject.plan(gpa, argv, env, dir, "n0")).?;
    defer p.deinit();
    const got = try joined(&p);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

test "inject: argv and environment per shell" {
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try expectPlan(&.{"bash"}, &env, "/c/si",
        \\bash --init-file /c/si/zigguro.bash -i
        \\ZIGGURO_NONCE=n0
        \\ZIGGURO_SHELL_LOGIN=0
    );
    try expectPlan(&.{ "/bin/bash", "--login", "-o", "vi" }, &env, "/c/si",
        \\/bin/bash --init-file /c/si/zigguro.bash -o vi -i
        \\ZIGGURO_NONCE=n0
        \\ZIGGURO_SHELL_LOGIN=1
    );
    try expectPlan(&.{ "zsh", "-l" }, &env, "/c/si",
        \\zsh -l
        \\ZIGGURO_NONCE=n0
        \\ZIGGURO_USER_ZDOTDIR=
        \\ZDOTDIR=/c/si/zsh
    );
    try expectPlan(&.{"fish"}, &env, "/c/si",
        \\fish
        \\ZIGGURO_NONCE=n0
        \\ZIGGURO_XDG_DATA_DIRS_ORIG=__unset__
        \\XDG_DATA_DIRS=/c/si:/usr/local/share:/usr/share
    );
    try env.put("ZDOTDIR", "/home/u/.config/zsh");
    try env.put("XDG_DATA_DIRS", "/nix/share");
    try env.put("PROMPT", "[$T] ");
    try expectPlan(&.{"zsh"}, &env, "/c/si",
        \\zsh
        \\ZIGGURO_NONCE=n0
        \\ZIGGURO_USER_ZDOTDIR=/home/u/.config/zsh
        \\ZDOTDIR=/c/si/zsh
    );
    try expectPlan(&.{"fish"}, &env, "/c/si",
        \\fish
        \\ZIGGURO_NONCE=n0
        \\ZIGGURO_XDG_DATA_DIRS_ORIG=/nix/share
        \\XDG_DATA_DIRS=/c/si:/nix/share
    );
    try expectPlan(&.{ "pwsh.exe", "-NoLogo" }, &env, "C:\\Users\\o'neil\\si",
        \\pwsh.exe -NoLogo -NoExit -Command . 'C:\Users\o''neil\si\zigguro.ps1'
        \\ZIGGURO_NONCE=n0
    );
    try expectPlan(&.{"cmd.exe"}, &env, "C:\\si", "cmd.exe\nZIGGURO_NONCE=n0\nPROMPT=[$T] " ++ @embedFile("scripts/cmd_prompt.txt"));
    try testing.expect(try inject.plan(gpa, &.{ "bash", "-c", "ls" }, &env, "/c/si", "n0") == null);
}

test "inject: extraction writes every script once and survives a half-written folder" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [256]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}/si", .{&tmp.sub_path});
    const dir = try inject.ensureExtracted(gpa, io, root);
    defer gpa.free(dir);
    for (inject.files) |f| {
        const path = try std.fs.path.join(gpa, &.{ dir, f.path });
        defer gpa.free(path);
        const got = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(got);
        try testing.expectEqualStrings(f.bytes, got);
    }
    // A crash before the marker: a stale file and no `.complete`.
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    try d.deleteFile(io, ".complete");
    try d.writeFile(io, .{ .sub_path = "zigguro.bash", .data = "garbage" });
    const again = try inject.ensureExtracted(gpa, io, root);
    defer gpa.free(again);
    try testing.expectEqualStrings(dir, again);
    const bash = try d.readFileAlloc(io, "zigguro.bash", gpa, .unlimited);
    defer gpa.free(bash);
    try testing.expectEqualStrings(inject.script("zigguro.bash").?, bash);
}

test "inject: activity is inactive 5 s after the first output without a mark" {
    var a: inject.Activity = .{};
    try testing.expect(a.status(0) == .pending);
    a.onFirstOutput(1000);
    try testing.expect(a.status(5999) == .pending);
    try testing.expect(a.status(6000) == .inactive);
    a.onMark();
    try testing.expect(a.status(9000) == .active);
}

test "inject: nonces are 32 hex digits and differ" {
    const a = inject.newNonce(testing.io);
    const b = inject.newNonce(testing.io);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    for (a) |c| try testing.expect(std.ascii.isHex(c));
}
