//! The workspace files review writes (E12.F02.S03.T02): the `Files` port
//! the applier and checkpoint restore go through, `DirFiles` over a
//! workspace directory, and `MemFiles` for tests (with fault injection).
//!
//! Paths are workspace-relative and `/`-separated, as in changesets.
//!
//! E08's journaled FileOps transaction (trash, case collisions, name
//! validation) does not exist yet; the applier keeps its own rollback
//! log, and `DirFiles` replaces each file atomically.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Permissions = Io.File.Permissions;

pub const Entry = struct {
    bytes: []const u8,
    executable: bool = false,
};

pub const Files = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The file at `path`, its bytes allocated in `arena`; null when
        /// there is none.
        read: *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8) anyerror!?Entry,
        /// Replaces (or creates, with parent directories) the file at
        /// `path`. `executable` null keeps the current mode, or the
        /// default for a new file.
        write: *const fn (ctx: *anyopaque, path: []const u8, bytes: []const u8, executable: ?bool) anyerror!void,
        /// Deletes the file at `path`; a missing file is not an error.
        delete: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void,
    };

    pub fn read(f: Files, arena: Allocator, path: []const u8) anyerror!?Entry {
        return f.vtable.read(f.ctx, arena, path);
    }
    pub fn write(f: Files, path: []const u8, bytes: []const u8, executable: ?bool) anyerror!void {
        return f.vtable.write(f.ctx, path, bytes, executable);
    }
    pub fn delete(f: Files, path: []const u8) anyerror!void {
        return f.vtable.delete(f.ctx, path);
    }
};

/// Files under a workspace directory. Each write goes to a temporary file
/// that is synced and renamed over the target, keeping the target's
/// permissions.
pub const DirFiles = struct {
    dir: Io.Dir,
    io: Io,

    pub fn files(d: *DirFiles) Files {
        return .{ .ctx = d, .vtable = &.{ .read = read, .write = write, .delete = delete } };
    }

    fn cast(ctx: *anyopaque) *DirFiles {
        return @ptrCast(@alignCast(ctx));
    }

    fn read(ctx: *anyopaque, arena: Allocator, path: []const u8) anyerror!?Entry {
        const d = cast(ctx);
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = try native(&buf, path);
        const bytes = d.dir.readFileAlloc(d.io, p, arena, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return null,
            else => return e,
        };
        const st = try d.dir.statFile(d.io, p, .{});
        return .{ .bytes = bytes, .executable = isExecutable(st.permissions) };
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8, executable: ?bool) anyerror!void {
        const d = cast(ctx);
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = try native(&buf, path);
        const old: ?Permissions = if (d.dir.statFile(d.io, p, .{})) |st| st.permissions else |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        var af = try d.dir.createFileAtomic(d.io, p, .{ .make_path = true, .replace = true });
        defer af.deinit(d.io);
        try af.file.writeStreamingAll(d.io, bytes);
        try af.file.sync(d.io);
        if (comptime @hasDecl(Permissions, "has_executable_bit") and Permissions.has_executable_bit) {
            const mode = if (old) |o| o.toMode() else (try af.file.stat(d.io)).permissions.toMode();
            const exec = executable orelse (mode & 0o111 != 0);
            try af.file.setPermissions(d.io, .fromMode(withExecutable(mode, exec)));
        }
        try af.replace(d.io);
    }

    fn delete(ctx: *anyopaque, path: []const u8) anyerror!void {
        const d = cast(ctx);
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        d.dir.deleteFile(d.io, try native(&buf, path)) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
};

/// `path` with the platform's separators.
fn native(buf: []u8, path: []const u8) error{NameTooLong}![]const u8 {
    if (std.fs.path.sep == '/') return path;
    if (path.len > buf.len) return error.NameTooLong;
    for (path, buf[0..path.len]) |c, *o| o.* = if (c == '/') std.fs.path.sep else c;
    return buf[0..path.len];
}

fn isExecutable(p: Permissions) bool {
    if (comptime @hasDecl(Permissions, "has_executable_bit") and Permissions.has_executable_bit) {
        return p.toMode() & 0o111 != 0;
    } else return false;
}

/// `mode` with execute set where read is (as git does), or cleared.
fn withExecutable(mode: std.posix.mode_t, on: bool) std.posix.mode_t {
    return if (on) mode | ((mode & 0o444) >> 2) else mode & ~@as(std.posix.mode_t, 0o111);
}

/// Files in memory for tests. `fail_at` makes the write or delete with that
/// 0-based index fail with `error.InjectedFault` (once).
pub const MemFiles = struct {
    gpa: Allocator,
    map: std.StringArrayHashMapUnmanaged(Stored) = .empty,
    mutations: u32 = 0,
    fail_at: ?u32 = null,

    const Stored = struct { bytes: []u8, executable: bool };

    pub fn init(gpa: Allocator) MemFiles {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *MemFiles) void {
        for (m.map.keys(), m.map.values()) |k, v| {
            m.gpa.free(k);
            m.gpa.free(v.bytes);
        }
        m.map.deinit(m.gpa);
    }

    pub fn files(m: *MemFiles) Files {
        return .{ .ctx = m, .vtable = &.{ .read = read, .write = write, .delete = delete } };
    }

    /// The bytes at `path`, or null.
    pub fn get(m: *const MemFiles, path: []const u8) ?[]const u8 {
        return if (m.map.get(path)) |v| v.bytes else null;
    }

    pub fn isExec(m: *const MemFiles, path: []const u8) bool {
        return if (m.map.get(path)) |v| v.executable else false;
    }

    /// Sets a file directly (no fault counting).
    pub fn put(m: *MemFiles, path: []const u8, bytes: []const u8, executable: bool) !void {
        const v = try m.gpa.dupe(u8, bytes);
        errdefer m.gpa.free(v);
        const gop = try m.map.getOrPut(m.gpa, path);
        if (gop.found_existing) {
            m.gpa.free(gop.value_ptr.bytes);
        } else {
            gop.key_ptr.* = m.gpa.dupe(u8, path) catch |e| {
                _ = m.map.pop();
                return e;
            };
        }
        gop.value_ptr.* = .{ .bytes = v, .executable = executable };
    }

    fn cast(ctx: *anyopaque) *MemFiles {
        return @ptrCast(@alignCast(ctx));
    }

    fn fault(m: *MemFiles) error{InjectedFault}!void {
        const n = m.mutations;
        m.mutations += 1;
        if (m.fail_at == n) return error.InjectedFault;
    }

    fn read(ctx: *anyopaque, arena: Allocator, path: []const u8) anyerror!?Entry {
        const m = cast(ctx);
        const v = m.map.get(path) orelse return null;
        return .{ .bytes = try arena.dupe(u8, v.bytes), .executable = v.executable };
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8, executable: ?bool) anyerror!void {
        const m = cast(ctx);
        try m.fault();
        try m.put(path, bytes, executable orelse m.isExec(path));
    }

    fn delete(ctx: *anyopaque, path: []const u8) anyerror!void {
        const m = cast(ctx);
        try m.fault();
        const kv = m.map.fetchSwapRemove(path) orelse return;
        m.gpa.free(kv.key);
        m.gpa.free(kv.value.bytes);
    }
};

const testing = std.testing;

test "files: dir files replace atomically and keep or set the executable bit" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var d: DirFiles = .{ .dir = tmp.dir, .io = testing.io };
    const f = d.files();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?Entry, null), try f.read(a, "sub/x.sh"));
    try f.write("sub/x.sh", "echo 1\n", true);
    var e = (try f.read(a, "sub/x.sh")).?;
    try testing.expectEqualStrings("echo 1\n", e.bytes);
    const has_x = comptime @hasDecl(Permissions, "has_executable_bit") and Permissions.has_executable_bit;
    try testing.expectEqual(has_x, e.executable);
    try f.write("sub/x.sh", "echo 2\n", null);
    e = (try f.read(a, "sub/x.sh")).?;
    try testing.expectEqualStrings("echo 2\n", e.bytes);
    try testing.expectEqual(has_x, e.executable);
    try f.write("sub/x.sh", "echo 2\n", false);
    try testing.expect(!(try f.read(a, "sub/x.sh")).?.executable);
    try f.delete("sub/x.sh");
    try f.delete("sub/x.sh");
    try testing.expectEqual(@as(?Entry, null), try f.read(a, "sub/x.sh"));
}

test "files: memory files fail the chosen mutation once" {
    var m: MemFiles = .init(testing.allocator);
    defer m.deinit();
    m.fail_at = 1;
    const f = m.files();
    try f.write("a", "1", null);
    try testing.expectError(error.InjectedFault, f.write("b", "2", null));
    try testing.expectEqual(@as(?[]const u8, null), m.get("b"));
    try f.delete("a");
    try testing.expectEqual(@as(?[]const u8, null), m.get("a"));
}
