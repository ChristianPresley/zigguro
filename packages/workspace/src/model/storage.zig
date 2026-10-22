//! Per-workspace storage, `<state_dir>/workspaces/<id_hex>/`: the index
//! cache, the session and history live here. One process at a time holds
//! the directory's lock; writes are atomic (temp file plus rename).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The result of `Storage.lock`.
pub const LockResult = enum {
    /// This process now owns the workspace.
    acquired,
    /// Another process (or handle) holds it; run read-only.
    held_by_other,
};

/// A workspace's state directory.
pub const Storage = struct {
    /// The open directory.
    root: std.Io.Dir,
    /// 128-bit identity hash.
    id: [16]u8,
    lock_file: ?std.Io.File = null,

    /// Opens (creating it if needed) the directory for `identity` (the
    /// canonical path of the folder or workspace file).
    pub fn open(io: std.Io, state_dir: std.Io.Dir, identity: []const u8) !Storage {
        const id = identityHash(identity);
        var name: [len_hex + "workspaces/".len]u8 = undefined;
        const sub = std.fmt.bufPrint(&name, "workspaces/{s}", .{std.fmt.bytesToHex(id, .lower)}) catch unreachable;
        const dir = try state_dir.createDirPathOpen(io, sub, .{});
        return .{ .root = dir, .id = id };
    }

    const len_hex = 32;

    /// Closes the directory and releases the lock.
    pub fn close(s: *Storage, io: std.Io) void {
        if (s.lock_file) |f| f.close(io);
        s.lock_file = null;
        s.root.close(io);
    }

    /// Tries to take the exclusive workspace lock (`<storage>/lock`). The
    /// lock is kept until `close`; the OS releases it if the process dies.
    pub fn lock(s: *Storage, io: std.Io) !LockResult {
        if (s.lock_file != null) return .acquired;
        const f = try s.root.createFile(io, "lock", .{ .truncate = false, .read = true });
        if (try f.tryLock(io, .exclusive)) {
            s.lock_file = f;
            return .acquired;
        }
        f.close(io);
        return .held_by_other;
    }

    /// Writes `bytes` to `name` atomically: readers see the old or the new
    /// content, never a mix, even if the process dies mid-write.
    pub fn atomicWrite(s: *Storage, io: std.Io, name: []const u8, bytes: []const u8) !void {
        return writeAtomic(io, s.root, name, bytes);
    }

    /// Reads `name`, or null when it does not exist.
    pub fn readAlloc(s: *Storage, io: std.Io, gpa: Allocator, name: []const u8, max: usize) !?[]u8 {
        return s.root.readFileAlloc(io, name, gpa, .limited(max)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }
};

/// Atomic replace of `dir/name` (temp file, then rename; on Windows the
/// rename is retried a few times because a reader may briefly hold it).
pub fn writeAtomic(io: std.Io, dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var af = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        af.replace(io) catch |err| switch (err) {
            error.AccessDenied => if (builtin.os.tag == .windows and attempt < 3) {
                try io.sleep(.fromMilliseconds(10), .awake);
                continue;
            } else return err,
            else => return err,
        };
        return;
    }
}

/// The 128-bit id of an identity string (two XxHash3 seeds).
pub fn identityHash(identity: []const u8) [16]u8 {
    var out: [16]u8 = undefined;
    std.mem.writeInt(u64, out[0..8], std.hash.XxHash3.hash(0, identity), .little);
    std.mem.writeInt(u64, out[8..16], std.hash.XxHash3.hash(0x9E3779B97F4A7C15, identity), .little);
    return out;
}

/// The canonical identity of a folder: its real absolute path, lowercased
/// when the filesystem folds case. Caller owns the result.
pub fn folderIdentity(gpa: Allocator, io: std.Io, abs_path: []const u8, case_insensitive: bool) ![]u8 {
    const real = try std.Io.Dir.realPathFileAbsoluteAlloc(io, abs_path, gpa);
    defer gpa.free(real);
    const out = try gpa.dupe(u8, real);
    if (case_insensitive) _ = std.ascii.lowerString(out, out);
    return out;
}

/// Environment values `stateDir` reads.
pub const StateEnv = struct {
    xdg_state_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
};

/// The path of zigguro's global state directory: `$XDG_STATE_HOME/zigguro`
/// or `~/.local/state/zigguro` on POSIX, `%LOCALAPPDATA%\zigguro\state` on
/// Windows. Caller owns the result.
pub fn stateDirPath(gpa: Allocator, env: StateEnv) ![]u8 {
    if (builtin.os.tag == .windows) {
        const base = env.local_app_data orelse return error.NoStateDir;
        return std.fs.path.join(gpa, &.{ base, "zigguro", "state" });
    }
    if (env.xdg_state_home) |x| if (x.len > 0) return std.fs.path.join(gpa, &.{ x, "zigguro" });
    const h = env.home orelse return error.NoStateDir;
    return std.fs.path.join(gpa, &.{ h, ".local", "state", "zigguro" });
}

/// Opens (creating) the global state directory. See `stateDirPath`.
pub fn stateDir(io: std.Io, gpa: Allocator, env: StateEnv) !std.Io.Dir {
    const p = try stateDirPath(gpa, env);
    defer gpa.free(p);
    return std.Io.Dir.cwd().createDirPathOpen(io, p, .{});
}

test "storage: same identity -> same dir; different case on case-insensitive root -> same dir" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = try Storage.open(io, tmp.dir, "/home/u/proj");
    defer a.close(io);
    var b = try Storage.open(io, tmp.dir, "/home/u/proj");
    defer b.close(io);
    try std.testing.expectEqualSlices(u8, &a.id, &b.id);
    try std.testing.expect(!std.mem.eql(u8, &a.id, &identityHash("/home/u/other")));
    try tmp.dir.createDirPath(io, "Proj");
    const p = try tmp.dir.realPathFileAlloc(io, "Proj", gpa);
    defer gpa.free(p);
    const up = try gpa.dupe(u8, p);
    defer gpa.free(up);
    const id1 = try folderIdentity(gpa, io, p, true);
    defer gpa.free(id1);
    _ = std.ascii.lowerString(up[up.len - 4 ..], up[up.len - 4 ..]);
    const lowered = try gpa.dupe(u8, id1);
    defer gpa.free(lowered);
    try std.testing.expectEqualSlices(u8, &identityHash(id1), &identityHash(lowered));
    const env_path = try stateDirPath(gpa, .{ .home = "/home/u" });
    defer gpa.free(env_path);
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("/home/u/.local/state/zigguro", env_path);
    try std.testing.expectError(error.NoStateDir, stateDirPath(gpa, .{}));
}

test "storage: lock held by second handle -> held_by_other" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var a = try Storage.open(io, tmp.dir, "x");
    var b = try Storage.open(io, tmp.dir, "x");
    defer b.close(io);
    try std.testing.expectEqual(LockResult.acquired, try a.lock(io));
    try std.testing.expectEqual(LockResult.held_by_other, try b.lock(io));
    a.close(io);
    try std.testing.expectEqual(LockResult.acquired, try b.lock(io));
}

test "storage: atomicWrite survives simulated crash" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Storage.open(io, tmp.dir, "crash");
    defer s.close(io);
    try s.atomicWrite(io, "session.zon", "old");
    {
        // Write the temp file but "crash" before the rename.
        var af = try s.root.createFileAtomic(io, "session.zon", .{ .replace = true });
        try af.file.writeStreamingAll(io, "new but torn");
        af.deinit(io);
    }
    const got = (try s.readAlloc(io, gpa, "session.zon", 1024)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("old", got);
    try s.atomicWrite(io, "session.zon", "new");
    const got2 = (try s.readAlloc(io, gpa, "session.zon", 1024)).?;
    defer gpa.free(got2);
    try std.testing.expectEqualStrings("new", got2);
    try std.testing.expect(try s.readAlloc(io, gpa, "missing", 10) == null);
}
