const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const Terminal = @import("../term/Terminal.zig");
const blocks = @import("../shell/blocks.zig");
const Blocks = blocks.Blocks;
const BlockEvent = blocks.BlockEvent;
const run = @import("run.zig");
const Run = run.Run;

const A = "\x1b]133;A\x07";
const B = "\x1b]133;B\x07";
const C = "\x1b]133;C\x07";

fn E(comptime cmd: []const u8) *const [cmd.len + 15:0]u8 {
    return "\x1b]633;E;" ++ cmd ++ ";n0nce\x07";
}

fn D(comptime code: []const u8) *const [code.len + 9:0]u8 {
    return "\x1b]133;D;" ++ code ++ "\x07";
}

/// A terminal with blocks attached that feeds every event to one run.
const Fixture = struct {
    t: Terminal,
    b: Blocks,
    r: Run,
    changes: u32 = 0,

    fn init(f: *Fixture, cols: u16, command: []const u8) !void {
        f.* = .{ .t = try .init(gpa, .{ .cols = cols, .rows = 10, .shell_nonce = "n0nce" }), .b = undefined, .r = try .init(gpa, command) };
        f.b = .init(gpa, &f.t, .{});
        f.b.attach();
        try f.b.addListener(.{ .ctx = f, .onEvent = onEvent });
    }

    fn deinit(f: *Fixture) void {
        f.r.deinit();
        f.b.deinit();
        f.t.deinit();
    }

    fn feed(f: *Fixture, bytes: []const u8) void {
        f.t.feed(bytes);
        f.b.afterFeed();
        f.b.flush();
    }

    fn onEvent(ctx: *anyopaque, ev: BlockEvent) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        if (f.r.onEvent(&f.b, ev)) f.changes += 1;
    }
};

test "agent run: binds to the next block, collects lines and the exit code" {
    var f: Fixture = undefined;
    try f.init(40, "make  test");
    defer f.deinit();
    f.feed(A ++ "$ " ++ B);
    try testing.expectEqual(run.Readiness.ready, run.readiness(&f.b));
    f.feed("make test\r\n" ++ E("make test") ++ C);
    try testing.expectEqual(Run.State.running, f.r.state);
    try testing.expectEqual(run.Readiness.busy, run.readiness(&f.b));
    try testing.expect(!f.r.mismatch);
    try testing.expectEqual(blocks.Owner.agent, f.b.get(f.r.block.?).?.owner);
    f.feed("ok 1   \r\n");
    try testing.expectEqual(@as(usize, 1), f.r.lines.items.len);
    try testing.expectEqualStrings("ok 1", f.r.lines.items[0]);
    f.feed("fail 2\r\n" ++ D("2") ++ A ++ "$ " ++ B);
    try testing.expect(f.r.done());
    try testing.expectEqual(Run.State.finished, f.r.state);
    try testing.expectEqual(@as(?i32, 2), f.r.exit);
    try testing.expectEqual(@as(usize, 2), f.r.lines.items.len);
    try testing.expectEqualStrings("fail 2", f.r.lines.items[1]);
    try testing.expectEqual(run.Readiness.ready, run.readiness(&f.b));
}

test "agent run: soft-wrapped output is one line, a last line without newline is kept" {
    var f: Fixture = undefined;
    try f.init(10, "x");
    defer f.deinit();
    f.feed(A ++ "$ " ++ B ++ "x\r\n" ++ E("x") ++ C);
    f.feed("0123456789abcdef\r\ntail");
    try testing.expectEqual(@as(usize, 1), f.r.lines.items.len);
    try testing.expectEqualStrings("0123456789abcdef", f.r.lines.items[0]);
    f.feed(D("0") ++ "\r\n" ++ A ++ "$ " ++ B);
    try testing.expectEqual(@as(?i32, 0), f.r.exit);
    try testing.expectEqual(@as(usize, 2), f.r.lines.items.len);
    try testing.expectEqualStrings("tail", f.r.lines.items[1]);
}

test "agent run: a different command line is flagged, a run never binds twice" {
    var f: Fixture = undefined;
    try f.init(40, "ls");
    defer f.deinit();
    f.feed(A ++ "$ " ++ B ++ "pwd\r\n" ++ E("pwd") ++ C ++ D("0") ++ A ++ "$ " ++ B);
    try testing.expect(f.r.mismatch);
    try testing.expectEqual(@as(?blocks.BlockId, 1), f.r.block);
    f.feed("ls\r\n" ++ E("ls") ++ C ++ D("0") ++ A ++ "$ " ++ B);
    try testing.expectEqual(@as(?blocks.BlockId, 1), f.r.block);
}

test "agent run: readiness is busy when the user typed at the prompt" {
    var f: Fixture = undefined;
    try f.init(40, "ls");
    defer f.deinit();
    try testing.expectEqual(run.Readiness.inactive, run.readiness(&f.b));
    f.feed(A ++ "$ " ++ B);
    try testing.expectEqual(run.Readiness.ready, run.readiness(&f.b));
    f.feed("rm -");
    try testing.expectEqual(run.Readiness.busy, run.readiness(&f.b));
}

test "agent run: command bytes are bracketed when the shell asked, controls stripped" {
    var t: Terminal = try .init(gpa, .{ .cols = 20, .rows = 4 });
    defer t.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try run.commandBytes(gpa, &t, "echo a\nb\x1b[201~\x03", &out);
    try testing.expectEqualStrings("echo a b[201~\r", out.items);
    out.clearRetainingCapacity();
    t.feed("\x1b[?2004h");
    try run.commandBytes(gpa, &t, "echo a\nb\x1b[201~", &out);
    try testing.expectEqualStrings("\x1b[200~echo a\nb[201~\x1b[201~\r", out.items);
}

test "agent run: lines past the cap are dropped and noted once" {
    var f: Fixture = undefined;
    try f.init(20, "y");
    defer f.deinit();
    f.r.max_lines = 2;
    f.feed(A ++ "$ " ++ B ++ "y\r\n" ++ E("y") ++ C);
    f.feed("1\r\n2\r\n3\r\n4\r\n" ++ D("0") ++ A ++ "$ " ++ B);
    try testing.expectEqual(@as(usize, 3), f.r.lines.items.len);
    try testing.expectEqualStrings("2", f.r.lines.items[1]);
    try testing.expect(f.r.dropped);
    try testing.expectEqual(@as(?i32, 0), f.r.exit);
}
