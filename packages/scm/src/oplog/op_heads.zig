//! The op heads directory: one empty file per current head operation,
//! named by its hex ID. Publishing an operation adds its file and then
//! deletes its parents' files. There are no locks: concurrent writers each
//! add their own head, and the next load merges what it finds. A parent
//! file that survives (a crash, or a racing writer) is harmless, because
//! load drops heads that are ancestors of other heads.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const ObjectId = id_mod.ObjectId;
const Allocator = std.mem.Allocator;

/// Lists the head IDs, sorted. Names that are not 64 hex digits (temporary
/// files, editor droppings) are ignored.
pub fn list(gpa: Allocator, io: std.Io, dir: std.Io.Dir) ![]ObjectId {
    var out: std.ArrayList(ObjectId) = .empty;
    errdefer out.deinit(gpa);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const id = ObjectId.parseHex(e.name) catch continue;
        try out.append(gpa, id);
    }
    std.mem.sort(ObjectId, out.items, {}, ObjectId.lessThan);
    return out.toOwnedSlice(gpa);
}

/// Adds `id` as a head. Creating a file that exists is fine: the same
/// operation was published twice.
pub fn add(io: std.Io, dir: std.Io.Dir, id: ObjectId) !void {
    var buf: [64]u8 = undefined;
    const f = dir.createFile(io, id.hex(&buf), .{ .exclusive = true }) catch |e| switch (e) {
        error.PathAlreadyExists => return,
        else => return e,
    };
    f.close(io);
}

/// Removes `id` as a head; failures are ignored (see the file comment).
pub fn remove(io: std.Io, dir: std.Io.Dir, id: ObjectId) void {
    var buf: [64]u8 = undefined;
    dir.deleteFile(io, id.hex(&buf)) catch {};
}

/// Publishes `id`, replacing `parents`.
pub fn publish(io: std.Io, dir: std.Io.Dir, id: ObjectId, parents: []const ObjectId) !void {
    try add(io, dir, id);
    for (parents) |p| {
        if (!p.eql(id)) remove(io, dir, p);
    }
}
