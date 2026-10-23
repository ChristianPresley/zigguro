//! Approved automation contents (E13.F02.S01.T03): the trust gate's
//! store until E16's pinned approvals (E16.F07, `PinKind.automation`)
//! take over. One ZON file in the user's state directory, never in the
//! workspace (a repository must not be able to approve its own
//! automations), listing `(workspace, name, SHA-256 of the file)` triples.
//! A changed file needs approving again.

const std = @import("std");
const loader = @import("loader.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// In `<state>/pins/`.
pub const file_name = "automations.zon";

const Entry = struct {
    workspace: []const u8,
    name: []const u8,
    /// Lowercase hex.
    sha256: []const u8,
};

const File = struct {
    version: u32 = 1,
    approved: []const Entry = &.{},
};

const Approvals = @This();

gpa: Allocator,
io: Io,
/// `<state>/pins`; null keeps approvals in memory only.
dir: ?Io.Dir,
workspace: []u8,
mutex: Io.Mutex = .init,
arena: std.heap.ArenaAllocator,
entries: std.ArrayList(Entry) = .empty,

/// Loads the approvals of every workspace (they are written back whole).
pub fn open(gpa: Allocator, io: Io, dir: ?Io.Dir, workspace: []const u8) !*Approvals {
    const a = try gpa.create(Approvals);
    errdefer gpa.destroy(a);
    a.* = .{ .gpa = gpa, .io = io, .dir = dir, .workspace = try gpa.dupe(u8, workspace), .arena = .init(gpa) };
    errdefer a.close();
    const d = dir orelse return a;
    const ar = a.arena.allocator();
    const bytes = d.readFileAllocOptions(io, file_name, ar, .limited(4 << 20), .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return a,
    };
    const f = std.zon.parse.fromSliceAlloc(File, ar, bytes, null, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return a,
    };
    try a.entries.appendSlice(a.gpa, f.approved);
    return a;
}

pub fn close(a: *Approvals) void {
    a.entries.deinit(a.gpa);
    a.arena.deinit();
    a.gpa.free(a.workspace);
    a.gpa.destroy(a);
}

pub fn trust(a: *Approvals) loader.TrustPort {
    return .{ .ctx = a, .isApproved = isApprovedFn };
}

pub fn isApproved(a: *Approvals, name: []const u8, hash: loader.Hash) bool {
    const hex = std.fmt.bytesToHex(hash, .lower);
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    for (a.entries.items) |e| {
        if (std.mem.eql(u8, e.workspace, a.workspace) and std.mem.eql(u8, e.name, name) and std.mem.eql(u8, e.sha256, &hex)) return true;
    }
    return false;
}

fn isApprovedFn(ctx: *anyopaque, name: []const u8, hash: loader.Hash) bool {
    const a: *Approvals = @ptrCast(@alignCast(ctx));
    return a.isApproved(name, hash);
}

/// Approves `hash` for `name` in this workspace (replacing an older
/// approval of the same automation) and saves.
pub fn approve(a: *Approvals, name: []const u8, hash: loader.Hash) !void {
    const hex = std.fmt.bytesToHex(hash, .lower);
    a.mutex.lockUncancelable(a.io);
    defer a.mutex.unlock(a.io);
    var i: usize = 0;
    while (i < a.entries.items.len) {
        const e = a.entries.items[i];
        if (std.mem.eql(u8, e.workspace, a.workspace) and std.mem.eql(u8, e.name, name)) {
            _ = a.entries.orderedRemove(i);
        } else i += 1;
    }
    const ar = a.arena.allocator();
    try a.entries.append(a.gpa, .{ .workspace = a.workspace, .name = try ar.dupe(u8, name), .sha256 = try ar.dupe(u8, &hex) });
    const d = a.dir orelse return;
    var out: Io.Writer.Allocating = .init(a.gpa);
    defer out.deinit();
    try std.zon.stringify.serialize(File{ .approved = a.entries.items }, .{}, &out.writer);
    try out.writer.writeByte('\n');
    var af = try d.createFileAtomic(a.io, file_name, .{ .replace = true });
    defer af.deinit(a.io);
    try af.file.writeStreamingAll(a.io, out.written());
    try af.replace(a.io);
}

test "approvals persist per workspace and content" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const h1: loader.Hash = @splat(1);
    const h2: loader.Hash = @splat(2);
    {
        const a = try open(testing.allocator, io, tmp.dir, "/ws/one");
        defer a.close();
        try testing.expect(!a.isApproved("digest", h1));
        try a.approve("digest", h1);
        try testing.expect(a.isApproved("digest", h1));
        try testing.expect(!a.isApproved("digest", h2));
    }
    {
        const a = try open(testing.allocator, io, tmp.dir, "/ws/one");
        defer a.close();
        try testing.expect(a.trust().isApproved(a, "digest", h1));
        // A new approval replaces the old one.
        try a.approve("digest", h2);
        try testing.expect(!a.isApproved("digest", h1));
    }
    const other = try open(testing.allocator, io, tmp.dir, "/ws/two");
    defer other.close();
    try testing.expect(!other.isApproved("digest", h2));
}
