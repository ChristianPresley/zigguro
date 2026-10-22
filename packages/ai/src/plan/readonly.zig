//! What plan mode lets run (E10.F09.S02.T01): read-only tools, the
//! plan-mode tools and shell commands on the read-only allowlist. The
//! toolset filter and the invoke pipeline both check it, so a call the
//! model makes up is refused even when the tool is not declared.

const std = @import("std");
const proto = @import("zg_ai_proto");

/// Tools plan mode keeps besides the read-only ones.
pub const plan_mode_tools = [_][]const u8{ "exit_plan_mode", "todo_write", "ask_user" };

/// Command tools kept in plan mode; their commands must pass
/// `readOnlyCommand`.
pub const command_tools = [_][]const u8{ "run_command", "command_output" };

/// Whether plan mode keeps `spec` in the toolset.
pub fn planKeeps(spec: *const proto.ToolSpec, commands: bool) bool {
    if (spec.effectiveEffects().read_only) return true;
    for (plan_mode_tools) |n| if (std.mem.eql(u8, n, spec.name)) return true;
    if (commands) for (command_tools) |n| if (std.mem.eql(u8, n, spec.name)) return true;
    return false;
}

/// Whether plan mode lets this call run.
pub fn planAllows(spec: *const proto.ToolSpec, input_json: []const u8) bool {
    if (spec.effectiveEffects().read_only) return true;
    for (plan_mode_tools) |n| if (std.mem.eql(u8, n, spec.name)) return true;
    if (std.mem.eql(u8, spec.name, "command_output")) return true;
    if (std.mem.eql(u8, spec.name, "run_command")) {
        var buf: [16 * 1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buf);
        const v = std.json.parseFromSliceLeaky(std.json.Value, fba.allocator(), input_json, .{}) catch return false;
        if (v != .object) return false;
        if (v.object.get("background")) |b| if (b == .bool and b.bool) return false;
        const cmd = v.object.get("command") orelse return false;
        return cmd == .string and readOnlyCommand(cmd.string);
    }
    return false;
}

/// Programs that only read, and the git subcommands that only read.
const programs = [_][]const u8{
    "ls",      "cat",      "head", "tail", "wc",   "grep",  "rg",       "find", "pwd",  "echo",
    "tree",    "stat",     "file", "du",   "df",   "which", "sort",     "uniq", "cut",  "basename",
    "dirname", "realpath", "diff", "cmp",  "date", "env",   "printenv", "true", "test", "type",
};
const git_subcommands = [_][]const u8{ "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "grep", "describe", "shortlog", "branch", "tag", "remote" };

/// A conservative check that `cmd` cannot write: no redirections,
/// command substitution or chaining other than pipes, and every
/// pipeline stage an allowlisted program with no writing flags.
pub fn readOnlyCommand(cmd: []const u8) bool {
    if (std.mem.trim(u8, cmd, " \t").len == 0) return false;
    for ([_][]const u8{ ">", "<", ";", "&", "`", "$(", "\n", "\r" }) |bad| if (std.mem.indexOf(u8, cmd, bad) != null) return false;
    var stages = std.mem.splitScalar(u8, cmd, '|');
    while (stages.next()) |stage| if (!readOnlyStage(stage)) return false;
    return true;
}

fn readOnlyStage(stage: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, stage, " \t");
    const prog = words.next() orelse return false;
    if (std.mem.eql(u8, prog, "git")) {
        const sub = words.next() orelse return false;
        for (git_subcommands) |g| if (std.mem.eql(u8, g, sub)) {
            // Listing only: no -d/-D/-m/-c, and no new names.
            if (std.mem.eql(u8, sub, "branch") or std.mem.eql(u8, sub, "tag") or std.mem.eql(u8, sub, "remote")) {
                while (words.next()) |w| if (!(std.mem.eql(u8, w, "-a") or std.mem.eql(u8, w, "-v") or std.mem.eql(u8, w, "-vv") or std.mem.eql(u8, w, "--list") or std.mem.eql(u8, w, "-l") or std.mem.eql(u8, w, "-r"))) return false;
            }
            return true;
        };
        return false;
    }
    for (programs) |p| if (std.mem.eql(u8, p, prog)) {
        while (words.next()) |w| {
            if (std.mem.eql(u8, prog, "find")) for ([_][]const u8{ "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf", "-fls" }) |bad| if (std.mem.eql(u8, w, bad)) return false;
            if (std.mem.eql(u8, prog, "sort") and (std.mem.eql(u8, w, "-o") or std.mem.startsWith(u8, w, "--output"))) return false;
            if (std.mem.eql(u8, prog, "env") and std.mem.indexOfScalar(u8, w, '=') == null and w[0] != '-') return false;
        }
        return true;
    };
    return false;
}

test "read-only commands" {
    const t = std.testing;
    for ([_][]const u8{ "ls -la", "git status", "git log --oneline -5", "grep -rn foo src | head -20", "find . -name '*.zig'", "git branch -a", "cat a.txt | wc -l", "env" }) |c| {
        t.expect(readOnlyCommand(c)) catch |e| {
            std.debug.print("should pass: {s}\n", .{c});
            return e;
        };
    }
    for ([_][]const u8{ "", "rm -rf x", "echo hi > a.txt", "ls; rm a", "cat a && rm a", "find . -delete", "find . -exec rm {} +", "git commit -m x", "git branch new", "sort -o out a", "ls $(rm x)", "zig build", "env FOO=1 rm x", "git" }) |c| {
        t.expect(!readOnlyCommand(c)) catch |e| {
            std.debug.print("should fail: {s}\n", .{c});
            return e;
        };
    }
}
