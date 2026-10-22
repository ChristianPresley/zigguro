//! Data tables for the shell analyzer (E16.F02.S01.T02): commands that only
//! read, environment variables that are safe to strip before allow
//! matching, and tools that talk to the network.

const std = @import("std");

/// Commands that never write, whatever their arguments (subject to the
/// argument checks in `isReadOnlyArgv`).
pub const readonly = [_][]const u8{
    "ls",      "cat",      "head",     "tail", "wc",    "pwd",  "echo",   "printf", "which",  "type",
    "file",    "stat",     "du",       "df",   "tree",  "grep", "rg",     "egrep",  "fgrep",  "basename",
    "dirname", "realpath", "readlink", "true", "false", "date", "whoami", "uname",  "id",     "hostname",
    "env",     "printenv", "sort",     "uniq", "cut",   "tr",   "diff",   "cmp",    "md5sum", "sha256sum",
    "less",    "more",     "column",   "nl",   "seq",   "test", "[",
};

/// `git` subcommands that only read.
pub const git_readonly = [_][]const u8{ "status", "log", "diff", "show", "branch", "rev-parse", "ls-files", "blame", "remote", "describe", "shortlog", "ls-tree", "cat-file", "reflog" };

/// `zig` subcommands that only read.
pub const zig_readonly = [_][]const u8{ "version", "env", "targets", "zen" };

/// `zg` subcommands that only read.
pub const zg_readonly = [_][]const u8{ "status", "log", "diff" };

/// Leading `NAME=value` assignments stripped before allow matching. Any
/// other assignment (e.g. `LD_PRELOAD`) stays in the text, so an allow rule
/// for the bare command does not match.
pub const safe_env = [_][]const u8{ "NODE_ENV", "RUST_LOG", "RUST_BACKTRACE", "CI", "LANG", "TZ", "NO_COLOR", "FORCE_COLOR", "TERM", "PAGER", "GIT_PAGER" };

/// Prefixes of safe environment variables.
pub const safe_env_prefixes = [_][]const u8{ "LC_", "ZIG_" };

/// Tools that open network connections (risk hints).
pub const network_tools = [_][]const u8{ "curl", "wget", "nc", "ncat", "netcat", "ssh", "scp", "sftp", "rsync", "telnet", "ftp", "socat", "Invoke-WebRequest", "Invoke-RestMethod", "iwr", "irm" };

fn contains(set: []const []const u8, s: []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// True when the variable `name` may be stripped before allow matching.
pub fn isSafeEnv(name: []const u8) bool {
    if (contains(&safe_env, name)) return true;
    for (safe_env_prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    return false;
}

/// True when `name` is a network tool.
pub fn isNetworkTool(name: []const u8) bool {
    return contains(&network_tools, name);
}

/// True when `argv` only reads. `env` and `printenv` count only without a
/// command; `find` is checked by the analyzer (actions make it an exec
/// wrapper).
pub fn isReadOnlyArgv(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const cmd = argv[0];
    // Output-file options turn readers into writers.
    const o_is_output = !std.mem.eql(u8, cmd, "grep") and !std.mem.eql(u8, cmd, "rg") and !std.mem.eql(u8, cmd, "egrep");
    for (argv[1..]) |a| {
        if (std.mem.startsWith(u8, a, "--output")) return false;
        if (o_is_output and std.mem.eql(u8, a, "-o")) return false;
    }
    if (std.mem.eql(u8, cmd, "find")) return true;
    if (std.mem.eql(u8, cmd, "git")) {
        const sub = firstNonOption(argv[1..]) orelse return false;
        if (!contains(&git_readonly, sub)) return false;
        if (std.mem.eql(u8, sub, "branch") or std.mem.eql(u8, sub, "remote")) return listOnly(argv);
        return true;
    }
    if (std.mem.eql(u8, cmd, "zig")) return argv.len >= 2 and contains(&zig_readonly, argv[1]);
    if (std.mem.eql(u8, cmd, "zg")) return argv.len >= 2 and contains(&zg_readonly, argv[1]);
    if (std.mem.eql(u8, cmd, "env") or std.mem.eql(u8, cmd, "printenv")) {
        for (argv[1..]) |a| if (!std.mem.startsWith(u8, a, "-")) return std.mem.eql(u8, cmd, "printenv");
        return true;
    }
    return contains(&readonly, cmd);
}

fn firstNonOption(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-C") or std.mem.eql(u8, a, "-c")) {
            i += 1; // `git -C dir` / `git -c k=v`
            continue;
        }
        if (!std.mem.startsWith(u8, a, "-")) return a;
    }
    return null;
}

/// `git branch` / `git remote` without arguments that create, delete or
/// rename.
fn listOnly(argv: []const []const u8) bool {
    var seen_sub = false;
    for (argv[1..]) |a| {
        if (!seen_sub) {
            if (std.mem.eql(u8, a, "branch") or std.mem.eql(u8, a, "remote")) seen_sub = true;
            continue;
        }
        const ok = std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "-vv") or
            std.mem.eql(u8, a, "--list") or std.mem.eql(u8, a, "--all") or std.mem.eql(u8, a, "--show-current") or std.mem.eql(u8, a, "--verbose") or
            std.mem.eql(u8, a, "--no-color") or std.mem.eql(u8, a, "--merged") or std.mem.eql(u8, a, "--contains") or std.mem.eql(u8, a, "show") or
            std.mem.eql(u8, a, "get-url");
        if (!ok) return false;
    }
    return true;
}

test "readonly: tables" {
    try std.testing.expect(isReadOnlyArgv(&.{ "git", "status" }));
    try std.testing.expect(isReadOnlyArgv(&.{ "git", "-C", "sub", "log", "--oneline" }));
    try std.testing.expect(isReadOnlyArgv(&.{ "git", "branch", "-a" }));
    try std.testing.expect(!isReadOnlyArgv(&.{ "git", "branch", "-D", "x" }));
    try std.testing.expect(!isReadOnlyArgv(&.{ "git", "push" }));
    try std.testing.expect(!isReadOnlyArgv(&.{ "git", "diff", "--output=x.patch" }));
    try std.testing.expect(isReadOnlyArgv(&.{ "zig", "version" }));
    try std.testing.expect(!isReadOnlyArgv(&.{ "zig", "build" }));
    try std.testing.expect(isReadOnlyArgv(&.{"env"}));
    try std.testing.expect(!isReadOnlyArgv(&.{ "env", "rm", "x" }));
    try std.testing.expect(!isReadOnlyArgv(&.{ "sort", "-o", "out", "in" }));
    try std.testing.expect(isReadOnlyArgv(&.{ "grep", "-o", "x", "f" }));
    try std.testing.expect(isSafeEnv("LC_ALL") and isSafeEnv("CI") and !isSafeEnv("LD_PRELOAD"));
}
