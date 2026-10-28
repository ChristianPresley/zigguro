const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const Terminal = @import("../term/Terminal.zig");
const Blocks = @import("../shell/blocks.zig").Blocks;
const persist = @import("persist.zig");

const A = "\x1b]133;A\x07";
const B = "\x1b]133;B\x07";
const C = "\x1b]133;C\x07";

const Term = struct {
    t: Terminal,
    b: Blocks,

    fn init(f: *Term, cols: u16, rows: u16, nonce: ?[]const u8) !void {
        f.* = .{ .t = try .init(gpa, .{ .cols = cols, .rows = rows, .shell_nonce = nonce }), .b = undefined };
        f.b = .init(gpa, &f.t, .{});
        f.b.attach();
    }

    fn deinit(f: *Term) void {
        f.b.deinit();
        f.t.deinit();
    }

    fn feed(f: *Term, bytes: []const u8) void {
        f.t.feed(bytes);
        f.b.afterFeed();
        f.b.flush();
    }

    fn capture(f: *Term, o: persist.CaptureOptions) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try persist.capture(gpa, &f.t, &f.b, o, &out);
        return out.toOwnedSlice(gpa);
    }
};

const session =
    A ++ "$ " ++ B ++ "ls\r\n" ++ "\x1b]633;E;ls;n0nce\x07" ++ C ++
    "\x1b[1;31mred\x1b[0m \x1b]8;;https://example.com\x07link\x1b]8;;\x07\r\n" ++
    "\x1b]133;D;0\x07" ++
    A ++ "$ " ++ B ++ "false\r\n" ++ "\x1b]633;E;false;n0nce\x07" ++ C ++
    "\x1b]133;D;1\x07" ++
    A ++ "$ " ++ B;

test "persist: captured content redraws the same screen, styles and blocks" {
    var src: Term = undefined;
    try src.init(30, 8, "n0nce");
    defer src.deinit();
    src.feed(session);
    const bytes = try src.capture(.{});
    defer gpa.free(bytes);

    var dst: Term = undefined;
    try dst.init(30, 8, null);
    defer dst.deinit();
    dst.feed(bytes);

    const a = try src.t.dump(gpa);
    defer gpa.free(a);
    const b = try dst.t.dump(gpa);
    defer gpa.free(b);
    try testing.expectEqualStrings(a, b);
    try testing.expectEqual(src.t.primary.cursor.y, dst.t.primary.cursor.y);
    try testing.expectEqual(src.t.primary.cursor.x, dst.t.primary.cursor.x);

    // The same blocks, with the same exit codes, untrusted.
    const sb = src.b.items();
    const db = dst.b.items();
    try testing.expectEqual(sb.len, db.len);
    for (sb, db) |x, y| {
        try testing.expectEqual(x.prompt, y.prompt);
        try testing.expectEqual(x.output, y.output);
        try testing.expectEqual(x.end, y.end);
        try testing.expectEqual(x.exit, y.exit);
        try testing.expectEqual(x.state, y.state);
        try testing.expect(!y.trusted);
    }
    try testing.expectEqualStrings("ls", dst.b.commandText(db[0].id));

    // Capturing the restored terminal gives the same bytes.
    const again = try dst.capture(.{});
    defer gpa.free(again);
    try testing.expectEqualStrings(bytes, again);

    // Styles and links survive.
    const row = dst.t.primary.rowPin(1);
    const page = &row.node.page;
    const st = page.styleOf(row.cells()[0]).*;
    try testing.expect(st.flags.bold);
    try testing.expectEqual(@as(u8, 1), st.fg.r);
    try testing.expectEqualStrings("https://example.com", page.hyperlinkOf(&row.cells()[4]).?.uri);
}

test "persist: soft-wrapped lines rejoin and re-wrap at another width" {
    var src: Term = undefined;
    try src.init(10, 4, null);
    defer src.deinit();
    src.feed("abcdefghijklmnop\r\nxy");
    const bytes = try src.capture(.{});
    defer gpa.free(bytes);
    try testing.expectEqualStrings("abcdefghijklmnop\r\nxy", bytes);

    var dst: Term = undefined;
    try dst.init(20, 4, null);
    defer dst.deinit();
    dst.feed(bytes);
    const d = try dst.t.dump(gpa);
    defer gpa.free(d);
    try testing.expect(std.mem.startsWith(u8, d, "abcdefghijklmnop"));
}

test "persist: only the last lines are kept, and none when lines is 0" {
    var src: Term = undefined;
    try src.init(10, 4, null);
    defer src.deinit();
    src.feed("1\r\n2\r\n3\r\n4\r\n5\r\n6");
    const bytes = try src.capture(.{ .lines = 3 });
    defer gpa.free(bytes);
    try testing.expectEqualStrings("4\r\n5\r\n6", bytes);
    const none = try src.capture(.{ .lines = 0 });
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "persist: the primary screen is saved while a full-screen program runs" {
    var src: Term = undefined;
    try src.init(10, 4, null);
    defer src.deinit();
    src.feed("before\r\n\x1b[?1049hFULLSCREEN");
    const bytes = try src.capture(.{});
    defer gpa.free(bytes);
    try testing.expect(std.mem.indexOf(u8, bytes, "before") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "FULLSCREEN") == null);
}

test "persist: snapshots round-trip and corrupt files are refused" {
    var recs = [_]persist.TerminalRecord{
        .{ .id = 1, .group = 0, .cols = 80, .rows = 24, .shell = "/bin/bash", .cwd = "/home/me/src", .title = "bash", .content = "hello\r\n" ** 200 },
        .{ .id = 2, .group = 0, .cols = 40, .rows = 24, .owner = .agent, .name = "build", .agent_name = "fixer" },
    };
    const snap: persist.Snapshot = .{ .saved_s = 1_761_609_600, .terminals = &recs };
    const bytes = try persist.encode(gpa, &snap);
    defer gpa.free(bytes);
    try testing.expect(bytes.len < 200);

    var back = (try persist.decode(gpa, bytes)).?;
    defer back.deinit();
    try testing.expectEqual(snap.saved_s, back.saved_s);
    try testing.expectEqual(@as(usize, 2), back.terminals.len);
    for (recs, back.terminals) |x, y| {
        try testing.expectEqual(x.id, y.id);
        try testing.expectEqual(x.group, y.group);
        try testing.expectEqual(x.cols, y.cols);
        try testing.expectEqual(x.owner, y.owner);
        try testing.expectEqualStrings(x.shell, y.shell);
        try testing.expectEqualStrings(x.cwd, y.cwd);
        try testing.expectEqualStrings(x.title, y.title);
        try testing.expectEqualStrings(x.name, y.name);
        try testing.expectEqualStrings(x.agent_name, y.agent_name);
        try testing.expectEqualStrings(x.content, y.content);
    }

    const bad = try gpa.dupe(u8, bytes);
    defer gpa.free(bad);
    for (0..bad.len) |i| {
        bad[i] ^= 0x40;
        try testing.expect((try persist.decode(gpa, bad)) == null);
        bad[i] ^= 0x40;
    }
    for (0..bytes.len) |n| try testing.expect((try persist.decode(gpa, bytes[0..n])) == null);
    try testing.expect((try persist.decode(gpa, "")) == null);
}

test "persist: write, read and remove a snapshot file" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect((try persist.read(gpa, io, tmp.dir)) == null);
    var recs = [_]persist.TerminalRecord{.{ .id = 7, .cols = 80, .rows = 24, .content = "x" }};
    try persist.write(gpa, io, tmp.dir, &.{ .terminals = &recs });
    var s = (try persist.read(gpa, io, tmp.dir)).?;
    defer s.deinit();
    try testing.expectEqual(@as(u32, 7), s.terminals[0].id);
    persist.remove(io, tmp.dir);
    try testing.expect((try persist.read(gpa, io, tmp.dir)) == null);
}

test "persist: the separator names the save time" {
    var buf: [256]u8 = undefined;
    const s = persist.separator(&buf, 1_761_609_600 + 3 * 3600 + 4 * 60);
    try testing.expect(std.mem.indexOf(u8, s, "saved 2025-10-28 03:04 UTC") != null);
}
