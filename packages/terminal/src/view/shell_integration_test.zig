//! Runs real shells on a PTY with automatic integration and checks the
//! command blocks they produce (E06.F06.S01.T01/T02). Each shell is
//! skipped when it is not installed. Linux only for now; pwsh and cmd need
//! Windows.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const gpa = testing.allocator;
const zg_terminal = @import("zg_terminal");
const zg_platform = @import("zg_platform");
const inject = zg_terminal.shell.inject;
const Blocks = zg_terminal.shell.Blocks;
const Pty = zg_platform.process.Pty;

const Case = struct {
    shell: []const u8,
    args: []const []const u8 = &.{},
    /// Typed one line at a time, each after the previous prompt.
    lines: []const []const u8,
    /// The command lines and exit codes the blocks must end with.
    want: []const struct { []const u8, i32 },
};

fn which(env: *const std.process.Environ.Map, name: []const u8) bool {
    const path = env.get("PATH") orelse return false;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |d| {
        var buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, name }) catch continue;
        if (std.Io.Dir.cwd().access(testing.io, full, .{})) |_| return true else |_| {}
    }
    return false;
}

fn run(c: Case) !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, base, gpa);
    defer gpa.free(abs);
    const home = try std.fs.path.join(gpa, &.{ abs, "home" });
    defer gpa.free(home);
    try std.Io.Dir.cwd().createDirPath(io, home);
    const cache = try std.fs.path.join(gpa, &.{ abs, "cache" });
    defer gpa.free(cache);

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    try env.put("HOME", home);
    try env.put("LANG", "C.UTF-8");
    if (!which(&env, c.shell)) return error.SkipZigTest;

    const dir = try inject.ensureExtracted(gpa, io, cache);
    defer gpa.free(dir);
    const nonce = inject.newNonce(io);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, c.shell);
    try argv.appendSlice(gpa, c.args);
    var p = (try inject.plan(gpa, argv.items, &env, dir, &nonce)).?;
    defer p.deinit();
    const policy: zg_platform.process.pty.SpawnPolicy = .{ .env_set = p.env };

    var term: zg_terminal.Terminal = try .init(gpa, .{ .cols = 100, .rows = 30, .shell_nonce = &nonce });
    defer term.deinit();
    var blocks: Blocks = .init(gpa, &term, .{});
    defer blocks.deinit();
    blocks.attach();

    var pty = try Pty.spawn(gpa, io, .{ .argv = p.argv, .env = &env, .cwd = home, .size = .{ .cols = 100, .rows = 30 }, .policy = &policy });
    defer pty.close();
    defer pty.kill(.kill_tree);

    var next_line: usize = 0;
    var read_buf: [4096]u8 = undefined;
    var waited: u32 = 0;
    while (waited < 300) : (waited += 1) {
        if (pty.waitReadable(50 * std.time.ns_per_ms)) {
            const n = pty.read(&read_buf) catch |e| switch (e) {
                error.WouldBlock => 0,
                else => break,
            };
            term.feed(read_buf[0..n]);
            if (term.replies.items.len > 0) {
                _ = pty.write(term.replies.items) catch {};
                term.clearReplies();
            }
            blocks.afterFeed();
            blocks.flush();
            continue;
        }
        // Quiet: type the next line once the shell waits at a prompt.
        const cur = blocks.current() orelse continue;
        if (cur.state != .prompt and cur.state != .typing) continue;
        if (next_line == c.lines.len) break;
        const finished = countFinished(&blocks);
        if (finished < next_line) continue;
        _ = try pty.write(c.lines[next_line]);
        _ = try pty.write("\r");
        next_line += 1;
    }

    errdefer dump(&blocks, &term);
    var got: usize = 0;
    for (blocks.items()) |b| {
        if (b.state != .finished) continue;
        if (got == c.want.len) return error.TooManyBlocks;
        try testing.expectEqualStrings(c.want[got][0], blocks.commandText(b.id));
        try testing.expect(b.trusted);
        try testing.expectEqual(@as(?i32, c.want[got][1]), b.exit);
        got += 1;
    }
    try testing.expectEqual(c.want.len, got);
    // The folder after `cd /tmp`.
    try testing.expectEqualStrings("/tmp", pathOf(blocks.current_cwd.items));
}

fn countFinished(b: *const Blocks) usize {
    var n: usize = 0;
    for (b.items()) |x| n += @intFromBool(x.state == .finished);
    return n;
}

/// The path of an OSC 7 URL (file://host/path).
fn pathOf(url: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, url, "file://")) return url;
    const rest = url["file://".len..];
    return rest[std.mem.indexOfScalar(u8, rest, '/') orelse rest.len ..];
}

fn dump(b: *const Blocks, t: *zg_terminal.Terminal) void {
    for (b.items()) |x| std.debug.print("block {d} {t} exit={?d} cmd='{s}' trusted={}\n", .{ x.id, x.state, x.exit, b.commandText(x.id), x.trusted });
    const text = t.dump(gpa) catch return;
    defer gpa.free(text);
    std.debug.print("{s}\n", .{text});
}

const posix_want = [_]struct { []const u8, i32 }{
    .{ "true", 0 },
    .{ "false", 1 },
    .{ "cd /tmp", 0 },
    .{ "echo \"a;b\\c\"", 0 },
};

test "shell integration: bash" {
    try run(.{
        .shell = "bash",
        .lines = &.{ "true", "false", "cd /tmp", "echo \"a;b\\c\"", "for i in 1 2; do echo $i; done", "exit" },
        .want = &(posix_want ++ .{.{ "for i in 1 2; do echo $i; done", 0 }}),
    });
}

test "shell integration: bash as a login shell" {
    try run(.{ .shell = "bash", .args = &.{"-l"}, .lines = &.{ "true", "false", "cd /tmp", "echo \"a;b\\c\"" }, .want = &posix_want });
}

test "shell integration: zsh" {
    try run(.{
        .shell = "zsh",
        .lines = &.{ "true", "false", "cd /tmp", "echo \"a;b\\c\"", "for i in 1 2; do echo $i; done" },
        .want = &(posix_want ++ .{.{ "for i in 1 2; do echo $i; done", 0 }}),
    });
}

test "shell integration: fish" {
    try run(.{
        .shell = "fish",
        .lines = &.{ "true", "false", "cd /tmp", "echo \"a;b\\c\"", "for i in 1 2; echo $i; end" },
        .want = &(posix_want ++ .{.{ "for i in 1 2; echo $i; end", 0 }}),
    });
}
