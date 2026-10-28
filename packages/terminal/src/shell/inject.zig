//! Automatic shell integration (E06.F06.S01.T02): the scripts in
//! `scripts/` are embedded, written once to a versioned cache folder
//! (`ensureExtracted`), and loaded by changing how the shell is started
//! (`plan`):
//!
//! | Shell | How |
//! |---|---|
//! | bash | `--init-file <dir>/zigguro.bash -i`; `-l`/`--login` is dropped and `ZIGGURO_SHELL_LOGIN=1` set instead (the script reads the login files itself) |
//! | zsh | `ZDOTDIR=<dir>/zsh`, the user's in `ZIGGURO_USER_ZDOTDIR` (the shims source the user's files) |
//! | fish | `<dir>` first in `XDG_DATA_DIRS`, the old value in `ZIGGURO_XDG_DATA_DIRS_ORIG` (`__unset__` when unset) |
//! | pwsh, powershell | `-NoExit -Command ". '<dir>/zigguro.ps1'"` |
//! | cmd | `PROMPT` from `cmd_prompt.txt` (the user's `PROMPT` kept in front) |
//!
//! Shells started to run a command or script (`-c`, a script path,
//! `--norc`, `-NoProfile -File`, ...) and other shells are left alone.
//! Each session gets its own nonce (`ZIGGURO_NONCE`, read and unset by the
//! script) so the terminal can tell the shell's command lines from text a
//! program prints. `Activity` reports a shell that never sent a prompt
//! mark, so the view can say integration is inactive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const ShellKind = enum { bash, zsh, fish, pwsh, powershell, cmd, other };

/// An embedded script and where it goes in the integration folder.
pub const File = struct { path: []const u8, bytes: []const u8 };

pub const files = [_]File{
    .{ .path = "zigguro.bash", .bytes = @embedFile("scripts/zigguro.bash") },
    .{ .path = "zsh/.zshenv", .bytes = @embedFile("scripts/zsh/.zshenv") },
    .{ .path = "zsh/.zprofile", .bytes = @embedFile("scripts/zsh/.zprofile") },
    .{ .path = "zsh/.zshrc", .bytes = @embedFile("scripts/zsh/.zshrc") },
    .{ .path = "zsh/.zlogin", .bytes = @embedFile("scripts/zsh/.zlogin") },
    .{ .path = "zsh/zigguro-hooks.zsh", .bytes = @embedFile("scripts/zsh/zigguro-hooks.zsh") },
    .{ .path = "fish/vendor_conf.d/zigguro.fish", .bytes = @embedFile("scripts/fish/vendor_conf.d/zigguro.fish") },
    .{ .path = "zigguro.ps1", .bytes = @embedFile("scripts/zigguro.ps1") },
    .{ .path = "cmd_prompt.txt", .bytes = @embedFile("scripts/cmd_prompt.txt") },
};

/// The script `name` (a `files` path), for `zg shell-integration --print`.
pub fn script(name: []const u8) ?[]const u8 {
    for (files) |f| if (std.mem.eql(u8, f.path, name)) return f.bytes;
    return null;
}

/// Hash of every script, naming the cache folder (scripts change only
/// with a new build, so a folder never needs rewriting).
pub fn version() u64 {
    return comptime blk: {
        @setEvalBranchQuota(10_000_000);
        var h = std.hash.Wyhash.init(1);
        for (files) |f| {
            h.update(f.path);
            h.update(f.bytes);
        }
        break :blk h.final();
    };
}

/// What kind of shell `argv0` starts (by file name, case and `.exe`
/// ignored).
pub fn kindOf(argv0: []const u8) ShellKind {
    var base = argv0;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
    if (base.len > 4 and std.ascii.eqlIgnoreCase(base[base.len - 4 ..], ".exe")) base = base[0 .. base.len - 4];
    // A login shell may be named "-bash".
    if (base.len > 0 and base[0] == '-') base = base[1..];
    const names = [_]struct { []const u8, ShellKind }{
        .{ "bash", .bash }, .{ "zsh", .zsh },           .{ "fish", .fish },
        .{ "pwsh", .pwsh }, .{ "pwsh-preview", .pwsh }, .{ "powershell", .powershell },
        .{ "cmd", .cmd },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(base, n[0])) return n[1];
    return .other;
}

fn has(args: []const []const u8, comptime opts: []const []const u8) bool {
    for (args) |a| inline for (opts) |o| if (std.mem.eql(u8, a, o)) return true;
    return false;
}

fn hasIgnoreCase(args: []const []const u8, comptime opts: []const []const u8) bool {
    for (args) |a| inline for (opts) |o| if (std.ascii.eqlIgnoreCase(a, o)) return true;
    return false;
}

/// Whether the shell is interactive in a way the scripts can hook into:
/// false when it runs a command or script or skips its startup files.
/// `args` excludes argv[0].
pub fn shouldInject(kind: ShellKind, args: []const []const u8) bool {
    return switch (kind) {
        .bash => !has(args, &.{ "-c", "--posix", "--norc", "--rcfile", "--init-file", "-s" }) and !hasOperand(args),
        .zsh => !has(args, &.{ "-c", "-f", "--no-rcs", "-s" }) and !hasOperand(args),
        .fish => !has(args, &.{ "-c", "--command", "-N", "--no-config", "--no-execute", "-n" }) and !hasOperand(args),
        .pwsh, .powershell => !hasIgnoreCase(args, &.{ "-Command", "-c", "-File", "-f", "-EncodedCommand", "-e", "-ec" }),
        .cmd => !hasIgnoreCase(args, &.{ "/c", "/k" }),
        .other => false,
    };
}

/// A script path (an argument that is not an option) makes bash, zsh and
/// fish run it instead of being interactive.
fn hasOperand(args: []const []const u8) bool {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        // Options with a value: `-o vi`, `+O extglob`.
        if (a.len == 2 and (a[0] == '-' or a[0] == '+') and (a[1] == 'o' or a[1] == 'O')) {
            i += 1;
            continue;
        }
        if (a.len > 0 and a[0] != '-' and a[0] != '+') return true;
    }
    return false;
}

/// A shell's argv and the environment changes that load the integration.
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    argv: []const []const u8,
    /// Variables to set in the child (name, value).
    env: []const [2][]const u8,

    pub fn deinit(p: *Plan) void {
        p.arena.deinit();
    }
};

/// How to start `argv` (the shell first) with the integration in `dir`
/// (from `ensureExtracted`) and `nonce`; null when `shouldInject` says no.
/// `env` is the environment the shell would get.
pub fn plan(gpa: Allocator, argv: []const []const u8, env: *const std.process.Environ.Map, dir: []const u8, nonce: []const u8) !?Plan {
    if (argv.len == 0) return null;
    const kind = kindOf(argv[0]);
    const args = argv[1..];
    if (!shouldInject(kind, args)) return null;
    var p: Plan = .{ .arena = .init(gpa), .argv = &.{}, .env = &.{} };
    errdefer p.arena.deinit();
    const a = p.arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    var vars: std.ArrayList([2][]const u8) = .empty;
    try out.append(a, argv[0]);
    try vars.append(a, .{ "ZIGGURO_NONCE", nonce });
    const sep = if (std.mem.indexOfScalar(u8, dir, '\\') != null) "\\" else "/";
    switch (kind) {
        .bash => {
            var login = false;
            var interactive = false;
            for (args) |x| {
                if (std.mem.eql(u8, x, "-l") or std.mem.eql(u8, x, "--login")) {
                    login = true;
                    continue;
                }
                if (std.mem.eql(u8, x, "-i")) interactive = true;
                try out.append(a, x);
            }
            // Long options must come before single-letter ones.
            try out.insert(a, 1, try std.mem.concat(a, u8, &.{ dir, sep, "zigguro.bash" }));
            try out.insert(a, 1, "--init-file");
            if (!interactive) try out.append(a, "-i");
            try vars.append(a, .{ "ZIGGURO_SHELL_LOGIN", if (login) "1" else "0" });
        },
        .zsh => {
            try out.appendSlice(a, args);
            try vars.append(a, .{ "ZIGGURO_USER_ZDOTDIR", env.get("ZDOTDIR") orelse "" });
            try vars.append(a, .{ "ZDOTDIR", try std.mem.concat(a, u8, &.{ dir, sep, "zsh" }) });
        },
        .fish => {
            try out.appendSlice(a, args);
            const orig = env.get("XDG_DATA_DIRS");
            try vars.append(a, .{ "ZIGGURO_XDG_DATA_DIRS_ORIG", orig orelse "__unset__" });
            try vars.append(a, .{ "XDG_DATA_DIRS", try std.mem.concat(a, u8, &.{ dir, ":", orig orelse "/usr/local/share:/usr/share" }) });
        },
        .pwsh, .powershell => {
            try out.appendSlice(a, args);
            const path = try std.mem.concat(a, u8, &.{ dir, sep, "zigguro.ps1" });
            const quoted = try std.mem.replaceOwned(u8, a, path, "'", "''");
            try out.appendSlice(a, &.{ "-NoExit", "-Command", try std.mem.concat(a, u8, &.{ ". '", quoted, "'" }) });
        },
        .cmd => {
            try out.appendSlice(a, args);
            const ours = script("cmd_prompt.txt").?;
            const user = env.get("PROMPT") orelse "";
            try vars.append(a, .{ "PROMPT", try std.mem.concat(a, u8, &.{ user, ours }) });
        },
        .other => unreachable,
    }
    p.argv = out.items;
    p.env = vars.items;
    return p;
}

/// A fresh nonce: 16 random bytes as 32 hex digits.
pub fn newNonce(io: Io) [32]u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    return std.fmt.bytesToHex(b, .lower);
}

/// Where the integration folders live: `$XDG_CACHE_HOME`, `~/.cache`, or
/// `%LOCALAPPDATA%`, plus `zigguro/shell-integration` (caller frees).
pub fn cacheRoot(gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    const sub = "zigguro" ++ std.fs.path.sep_str ++ "shell-integration";
    if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return try std.fs.path.join(gpa, &.{ x, sub });
    if (env.get("LOCALAPPDATA")) |x| if (x.len > 0) return try std.fs.path.join(gpa, &.{ x, sub });
    if (env.get("HOME")) |x| if (x.len > 0) return try std.fs.path.join(gpa, &.{ x, ".cache", sub });
    return null;
}

/// Writes the scripts to `<root>/<version>/` unless a finished copy is
/// there, and returns that folder (caller frees). Each file is written
/// atomically and a `.complete` marker last, so a crash midway leaves a
/// folder that is written again next time.
pub fn ensureExtracted(gpa: Allocator, io: Io, root: []const u8) ![]u8 {
    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{x:0>16}", .{version()}) catch unreachable;
    const path = try std.fs.path.join(gpa, &.{ root, name });
    errdefer gpa.free(path);
    var dir = try Io.Dir.cwd().createDirPathOpen(io, path, .{});
    defer dir.close(io);
    if (dir.access(io, ".complete", .{})) |_| return path else |_| {}
    try dir.createDirPath(io, "zsh");
    try dir.createDirPath(io, "fish/vendor_conf.d");
    for (files) |f| try writeAtomic(io, dir, f.path, f.bytes);
    try writeAtomic(io, dir, ".complete", "");
    return path;
}

fn writeAtomic(io: Io, dir: Io.Dir, sub: []const u8, bytes: []const u8) !void {
    var af = try dir.createFileAtomic(io, sub, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

/// Whether integration came up: `inactive` when no prompt mark arrived
/// within `timeout_ms` of the shell's first output.
pub const Activity = struct {
    first_output_ms: ?u64 = null,
    marked: bool = false,
    timeout_ms: u64 = 5000,

    pub fn onFirstOutput(a: *Activity, now_ms: u64) void {
        if (a.first_output_ms == null) a.first_output_ms = now_ms;
    }

    pub fn onMark(a: *Activity) void {
        a.marked = true;
    }

    pub fn status(a: *const Activity, now_ms: u64) enum { pending, active, inactive } {
        if (a.marked) return .active;
        const t = a.first_output_ms orelse return .pending;
        return if (now_ms -| t >= a.timeout_ms) .inactive else .pending;
    }
};
