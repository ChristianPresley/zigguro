//! The scheduler's persistent state (E13.F02.S01.T02):
//! `.zigguro/state/scheduler.zon` with the next fire id and, per
//! automation, the last due time fired, its fire id and status, and
//! whether a one-off automation has completed. Written atomically after
//! each fire.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "scheduler.zon";
pub const format_version = 1;

pub const Status = enum { none, fired, skipped, failed };

pub const Entry = struct {
    name: []const u8,
    /// The nominal due time (unix ms) last handled, fired or not.
    last_due_ms: i64 = 0,
    last_fire_id: u64 = 0,
    last_status: Status = .none,
    /// A `once` automation that has fired.
    completed: bool = false,
};

pub const File = struct {
    version: u32 = format_version,
    next_fire_id: u64 = 1,
    automations: []const Entry = &.{},
};

/// The state in `arena`; empty when the file is missing or unreadable (a
/// corrupt file must not stop automations).
pub fn load(arena: Allocator, io: Io, dir: Io.Dir) Allocator.Error!File {
    const bytes = dir.readFileAllocOptions(io, file_name, arena, .limited(16 << 20), .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{},
    };
    const f = std.zon.parse.fromSliceAlloc(File, arena, bytes, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return .{},
    };
    if (f.version != format_version) return .{};
    return f;
}

/// Replaces the file atomically.
pub fn save(gpa: Allocator, io: Io, dir: Io.Dir, f: File) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.zon.stringify.serialize(f, .{}, &out.writer);
    try out.writer.writeByte('\n');
    var af = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, out.written());
    try af.replace(io);
}

pub fn find(f: File, name: []const u8) ?Entry {
    for (f.automations) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

const testing = std.testing;

test "state_roundtrip_atomic" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Missing: empty.
    const empty = try load(a, io, tmp.dir);
    try testing.expectEqual(@as(u64, 1), empty.next_fire_id);
    const entries = [_]Entry{
        .{ .name = "daily-digest", .last_due_ms = 1_790_000_000_000, .last_fire_id = 7, .last_status = .fired },
        .{ .name = "once-off", .last_due_ms = 5, .last_fire_id = 8, .last_status = .skipped, .completed = true },
    };
    try save(testing.allocator, io, tmp.dir, .{ .next_fire_id = 9, .automations = &entries });
    const back = try load(a, io, tmp.dir);
    try testing.expectEqual(@as(u64, 9), back.next_fire_id);
    try testing.expectEqual(@as(usize, 2), back.automations.len);
    try testing.expectEqualStrings("daily-digest", back.automations[0].name);
    try testing.expectEqual(entries[0].last_due_ms, back.automations[0].last_due_ms);
    try testing.expect(find(back, "once-off").?.completed);
    try testing.expectEqual(Status.skipped, find(back, "once-off").?.last_status);
    // Overwrite: no temp files left behind.
    try save(testing.allocator, io, tmp.dir, .{ .next_fire_id = 10 });
    var it = tmp.dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 1), n);
    // Corrupt: empty, not an error.
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = ".{ .version = " });
    try testing.expectEqual(@as(u64, 1), (try load(a, io, tmp.dir)).next_fire_id);
}
