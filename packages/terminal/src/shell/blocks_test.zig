const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const Terminal = @import("../term/Terminal.zig");
const blocks = @import("blocks.zig");
const Blocks = blocks.Blocks;
const BlockEvent = blocks.BlockEvent;

const A = "\x1b]133;A\x07";
const B = "\x1b]133;B\x07";
const C = "\x1b]133;C\x07";

fn E(comptime cmd: []const u8) *const [cmd.len + 15:0]u8 {
    return "\x1b]633;E;" ++ cmd ++ ";n0nce\x07";
}

fn D(comptime code: []const u8) *const [code.len + 9:0]u8 {
    return "\x1b]133;D;" ++ code ++ "\x07";
}

/// A terminal with blocks attached that records events as text.
const Fixture = struct {
    t: Terminal,
    b: Blocks,
    log: std.ArrayList(u8) = .empty,

    fn init(f: *Fixture, o: Terminal.Options) !void {
        var opts = o;
        opts.shell_nonce = "n0nce";
        f.* = .{ .t = try .init(gpa, opts), .b = undefined };
        f.b = .init(gpa, &f.t, .{});
        f.b.attach();
        try f.b.addListener(.{ .ctx = f, .onEvent = onEvent });
    }

    fn deinit(f: *Fixture) void {
        f.b.deinit();
        f.t.deinit();
        f.log.deinit(gpa);
    }

    fn feed(f: *Fixture, bytes: []const u8) void {
        f.t.feed(bytes);
        f.b.afterFeed();
        f.b.flush();
    }

    fn onEvent(ctx: *anyopaque, ev: BlockEvent) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .started => |id| f.log.print(gpa, "started {d}\n", .{id}) catch {},
            .output => |o| f.log.print(gpa, "output {d} {d}\n", .{ o.id, o.row }) catch {},
            .finished => |x| if (x.exit) |e| f.log.print(gpa, "finished {d} {d}\n", .{ x.id, e }) catch {} else f.log.print(gpa, "finished {d} -\n", .{x.id}) catch {},
            .abandoned => |id| f.log.print(gpa, "abandoned {d}\n", .{id}) catch {},
        }
    }
};

test "blocks: a normal command runs, reports output rows and finishes" {
    var f: Fixture = undefined;
    try f.init(.{ .cols = 40, .rows = 10 });
    defer f.deinit();
    f.t.now_ms = 100;
    f.feed(A ++ "$ " ++ B ++ "ls\r\n" ++ E("ls") ++ C);
    f.t.now_ms = 150;
    f.feed("a\r\nb\r\n" ++ D("0") ++ A ++ "$ " ++ B);
    try testing.expectEqualStrings("started 1\noutput 1 1\noutput 1 2\nfinished 1 0\n", f.log.items);
    const blk = f.b.get(1).?;
    try testing.expectEqual(blocks.State.finished, blk.state);
    try testing.expectEqual(@as(u64, 0), blk.prompt);
    try testing.expectEqual(@as(?u64, 1), blk.output);
    try testing.expectEqual(@as(?u64, 3), blk.end);
    try testing.expectEqual(@as(?i32, 0), blk.exit);
    try testing.expectEqual(@as(?u64, 100), blk.started_ms);
    try testing.expectEqual(@as(?u64, 150), blk.finished_ms);
    try testing.expect(blk.trusted);
    try testing.expectEqualStrings("ls", f.b.commandText(1));
    try testing.expectEqual([2]u64{ 1, 3 }, f.b.outputRange(1).?);
    try testing.expectEqual(blocks.State.typing, f.b.current().?.state);
    try testing.expectEqual(@as(u32, 1), f.b.at(2).?.id);
    try testing.expectEqual(@as(u32, 2), f.b.at(3).?.id);
    try testing.expectEqual(@as(u32, 2), f.b.nextAfter(0).?.id);
    try testing.expectEqual(@as(u32, 1), f.b.prevBefore(3).?.id);
}

test "blocks: Ctrl+C at the prompt abandons; a command without D finishes at the next A" {
    var f: Fixture = undefined;
    try f.init(.{ .cols = 40, .rows = 10 });
    defer f.deinit();
    f.feed(A ++ "$ " ++ B ++ "^C\r\n" ++ A ++ "$ " ++ B ++ "x\r\n" ++ C ++ "out\r\n" ++ A ++ "$ ");
    try testing.expectEqualStrings("abandoned 1\nstarted 2\noutput 2 2\nfinished 2 -\n", f.log.items);
    try testing.expectEqual(blocks.State.abandoned, f.b.get(1).?.state);
    try testing.expectEqual(@as(?i32, null), f.b.get(2).?.exit);
    try testing.expectEqual(blocks.State.prompt, f.b.get(3).?.state);
}

test "blocks: D before the first A is ignored; non-numeric exit is null" {
    var f: Fixture = undefined;
    try f.init(.{ .cols = 40, .rows = 10 });
    defer f.deinit();
    f.feed(D("0") ++ A ++ "$ " ++ B ++ "y\r\n" ++ C ++ D("oops") ++ A);
    try testing.expectEqual(@as(usize, 2), f.b.items().len);
    try testing.expectEqualStrings("started 1\nfinished 1 -\n", f.log.items);
}

test "blocks: untrusted E keeps the text; no E reads the command from the screen" {
    var f: Fixture = undefined;
    try f.init(.{ .cols = 12, .rows = 10 });
    defer f.deinit();
    f.feed(A ++ "$ " ++ B ++ "rm x\r\n\x1b]633;E;rm x;wrong\x07" ++ C ++ D("1"));
    try testing.expect(!f.b.get(1).?.trusted);
    try testing.expectEqualStrings("rm x", f.b.commandText(1));
    // A command that wraps (12 columns) is joined back.
    f.feed(A ++ "$ " ++ B ++ "echo 1234567890  \r\n" ++ C ++ D("0"));
    try testing.expect(!f.b.get(2).?.trusted);
    try testing.expectEqualStrings("echo 1234567890", f.b.commandText(2));
}

test "blocks: progress bars redrawn with CR commit only their last row" {
    var f: Fixture = undefined;
    try f.init(.{ .cols = 40, .rows = 10 });
    defer f.deinit();
    f.feed(A ++ "$ " ++ B ++ "dl\r\n" ++ C);
    f.feed("10%\r50%\r");
    f.feed("100%\r\ndone");
    try testing.expectEqualStrings("started 1\noutput 1 1\n", f.log.items);
}

test "blocks: ED 3 drops blocks above the screen; eviction truncates the straddling one" {
    var f: Fixture = undefined;
    try f.init(.{ .cols = 20, .rows = 4 });
    defer f.deinit();
    f.feed(A ++ "$ " ++ B ++ "a\r\n" ++ C ++ "1\r\n2\r\n3\r\n4\r\n5\r\n" ++ D("0"));
    f.feed(A ++ "$ " ++ B ++ "b\r\n" ++ C ++ "x\r\ny\r\n");
    f.feed("z\r\n");
    try testing.expectEqual(@as(usize, 2), f.b.items().len);
    // The screen is rows 7..10 now; ED 3 drops rows 0..6.
    f.feed("\x1b[3J");
    try testing.expectEqual(@as(usize, 1), f.b.items().len);
    const blk = f.b.items()[0];
    try testing.expectEqual(@as(u32, 2), blk.id);
    try testing.expect(blk.truncated);
    try testing.expect(blk.running());
    try testing.expectEqual(@as(u64, 7), blk.prompt);
    try testing.expectEqual(@as(?u64, 7), blk.output);
}

test "blocks: marks on the alternate screen are ignored" {
    var f: Fixture = undefined;
    try f.init(.{ .cols = 20, .rows = 4 });
    defer f.deinit();
    f.feed("\x1b[?1049h" ++ A ++ B ++ C ++ "\x1b[?1049l");
    try testing.expectEqual(@as(usize, 0), f.b.items().len);
}

test "blocks: rows stay on their marks after a reflowing resize" {
    var f: Fixture = undefined;
    try f.init(.{ .cols = 20, .rows = 12 });
    defer f.deinit();
    // Output wider than 10 columns wraps when the terminal narrows.
    f.feed(A ++ "$ " ++ B ++ "a\r\n" ++ C ++ "0123456789abcdef\r\n" ++ D("0"));
    f.feed(A ++ "$ " ++ B ++ "b\r\n" ++ C ++ "x\r\n" ++ D("3"));
    f.feed(A ++ "$ ");
    try testing.expectEqual(@as(u64, 2), f.b.get(2).?.prompt);
    try f.t.resize(10, 12);
    f.b.resync();
    const b1 = f.b.get(1).?;
    const b2 = f.b.get(2).?;
    try testing.expectEqual(@as(u64, 0), b1.prompt);
    try testing.expectEqual(@as(?u64, 1), b1.output);
    try testing.expectEqual(@as(?u64, 3), b1.end);
    try testing.expectEqual(@as(u64, 3), b2.prompt);
    try testing.expectEqual(@as(?u64, 4), b2.output);
    try testing.expectEqual(@as(?u64, 5), b2.end);
    try testing.expectEqual(@as(u64, 5), f.b.get(3).?.prompt);
}

test "blocks: the oldest blocks go past the cap; strings are compacted" {
    var f: Fixture = undefined;
    try f.init(.{ .cols = 40, .rows = 4 });
    defer f.deinit();
    f.b.opts.max_blocks = 3;
    for (0..400) |_| f.feed(A ++ "$ " ++ B ++ E("some longer command line here") ++ C ++ D("0"));
    try testing.expectEqual(@as(usize, 3), f.b.items().len);
    try testing.expectEqual(@as(u32, 400), f.b.current().?.id);
    try testing.expectEqualStrings("some longer command line here", f.b.commandText(399));
    try testing.expect(f.b.strings.items.len < 8192);
}
