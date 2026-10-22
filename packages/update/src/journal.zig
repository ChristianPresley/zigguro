//! The swap journal (E17.F04.S02.T01): `<root>/swap.journal`, one ZON
//! line per step, each appended and synced before the next rename. A
//! torn last line (a crash mid-write) is ignored.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const names = @import("layout.zig").names;

pub const Step = enum { begin, app_to_prev, staged_to_app, done };

pub const Entry = struct {
    step: Step,
    /// Version leaving `app/`.
    from: []const u8,
    /// Version entering it.
    to: []const u8,
    ts: i64,
};

/// Largest journal read back.
pub const max_bytes = 64 * 1024;

/// Appends `e` as one line and syncs the file (and the root directory on
/// Linux, so the journal's own creation is durable).
pub fn append(io: Io, root: Io.Dir, e: Entry) !void {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try std.zon.stringify.serialize(e, .{ .whitespace = false }, &w);
    try w.writeByte('\n');
    var file = try root.createFile(io, names.journal, .{ .truncate = false });
    defer file.close(io);
    const end = try file.length(io);
    try file.writePositionalAll(io, w.buffered(), end);
    try file.sync(io);
    if (builtin.os.tag == .linux) syncDir(io, root);
}

fn syncDir(io: Io, root: Io.Dir) void {
    // `.iterate` opens a real descriptor (not O_PATH), which fsync needs.
    var d = root.openDir(io, ".", .{ .iterate = true }) catch return;
    defer d.close(io);
    const f: Io.File = .{ .handle = d.handle, .flags = .{ .nonblocking = false } };
    f.sync(io) catch {};
}

/// The last complete entry, or null when there is no journal.
pub fn last(arena: Allocator, io: Io, root: Io.Dir) !?Entry {
    const text = root.readFileAlloc(io, names.journal, arena, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var result: ?Entry = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        // Only newline-terminated lines are complete.
        if (it.peek() == null) break;
        const z = try arena.dupeZ(u8, line);
        result = std.zon.parse.fromSliceAlloc(Entry, arena, z, null, .{}) catch continue;
    }
    return result;
}

/// Removes the journal.
pub fn remove(io: Io, root: Io.Dir) !void {
    root.deleteFile(io, names.journal) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

const testing = std.testing;

test "journal: append, last, torn last line ignored" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try last(a, io, tmp.dir) == null);
    try append(io, tmp.dir, .{ .step = .begin, .from = "0.4.0", .to = "0.5.0", .ts = 1 });
    try append(io, tmp.dir, .{ .step = .app_to_prev, .from = "0.4.0", .to = "0.5.0", .ts = 2 });
    const e = (try last(a, io, tmp.dir)).?;
    try testing.expectEqual(Step.app_to_prev, e.step);
    try testing.expectEqualStrings("0.5.0", e.to);

    // A crash mid-write leaves half a line: the previous entry stands.
    var f = try tmp.dir.openFile(io, names.journal, .{ .mode = .read_write });
    const len = try f.length(io);
    try f.writePositionalAll(io, ".{ .step = .staged_to_app, .fr", len);
    f.close(io);
    try testing.expectEqual(Step.app_to_prev, (try last(a, io, tmp.dir)).?.step);
    // A garbage complete line is skipped too.
    f = try tmp.dir.openFile(io, names.journal, .{ .mode = .read_write });
    try f.setLength(io, len);
    try f.writePositionalAll(io, "garbage\n", len);
    f.close(io);
    try testing.expectEqual(Step.app_to_prev, (try last(a, io, tmp.dir)).?.step);

    try remove(io, tmp.dir);
    try remove(io, tmp.dir);
    try testing.expect(try last(a, io, tmp.dir) == null);
}
