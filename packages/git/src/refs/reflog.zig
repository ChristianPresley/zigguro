//! Reflogs: `logs/<ref>` lines of
//! "<old hex> <new hex> <Name> <<email>> <time> <tz>\t<message>\n".

const std = @import("std");
const oid_mod = @import("../oid.zig");
const commit = @import("../commit.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;

/// One reflog entry; strings borrow from the log text.
pub const Entry = struct {
    /// Value before the update (zero when created).
    old: Oid,
    /// Value after the update (zero when deleted).
    new: Oid,
    /// Who made the update; `raw` holds the whole ident text.
    who: []const u8,
    /// Message after the tab (without the newline).
    message: []const u8,
};

/// Formats one reflog line. Newlines in `message` become spaces, as git does.
pub fn formatLine(w: *std.Io.Writer, old: Oid, new: Oid, who: commit.Ident, message: []const u8) std.Io.Writer.Error!void {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    try w.print("{s} {s} ", .{ old.hex(&a), new.hex(&b) });
    try who.write(w);
    try w.writeByte('\t');
    for (message) |c| try w.writeByte(if (c == '\n') ' ' else c);
    try w.writeByte('\n');
}

/// Appends a line to `logs/<ref>` in `dir`, creating directories.
pub fn append(io: std.Io, dir: std.Io.Dir, ref: []const u8, line: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "logs/{s}", .{ref});
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
    const f = dir.openFile(io, path, .{ .mode = .write_only }) catch |e| switch (e) {
        error.FileNotFound => try dir.createFile(io, path, .{ .truncate = false }),
        else => |x| return x,
    };
    defer f.close(io);
    const end = try f.length(io);
    try f.writePositionalAll(io, line, end);
}

/// Parses one line.
pub fn parseLine(fmt: ObjectFormat, line: []const u8) error{CorruptReflog}!Entry {
    const hl = fmt.hexLen();
    if (line.len < 2 * hl + 2 or line[hl] != ' ' or line[2 * hl + 1] != ' ') return error.CorruptReflog;
    const tab = std.mem.indexOfScalarPos(u8, line, 2 * hl + 2, '\t');
    return .{
        .old = Oid.parseHex(fmt, line[0..hl]) catch return error.CorruptReflog,
        .new = Oid.parseHex(fmt, line[hl + 1 .. 2 * hl + 1]) catch return error.CorruptReflog,
        .who = line[2 * hl + 2 .. tab orelse line.len],
        .message = if (tab) |i| line[i + 1 ..] else "",
    };
}

test "refs: reflog append format" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    const who: commit.Ident = .{ .name = "A U Thor", .email = "a@example.com", .time = 1700000000, .tz = "+0100" };
    const n = oid_mod.hashBytes(.sha1, "x");
    try formatLine(&aw.writer, .zero(.sha1), n, who, "commit (initial): first\nsecond");
    try append(t.io, tmp.dir, "refs/heads/main", aw.written());
    try append(t.io, tmp.dir, "refs/heads/main", aw.written());
    var buf: [1024]u8 = undefined;
    const text = try tmp.dir.readFile(t.io, "logs/refs/heads/main", &buf);
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |l| : (count += 1) {
        const e = try parseLine(.sha1, l);
        try t.expect(e.old.isZero());
        try t.expect(e.new.eql(n));
        try t.expectEqualStrings("A U Thor <a@example.com> 1700000000 +0100", e.who);
        try t.expectEqualStrings("commit (initial): first second", e.message);
    }
    try t.expectEqual(@as(usize, 2), count);
}
