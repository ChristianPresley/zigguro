//! FaultIo: an `std.Io` for tests that fails or tears writes at chosen
//! points, to check that the store survives a crash anywhere.
//!
//! Every mutating file operation (streaming and positional writes, syncs,
//! creating, linking, renaming and deleting files) counts down `budget`.
//! When it runs out the operation fails, and a write first lands a prefix
//! of its data, as a torn write would. After that the process counts as
//! dead: every later mutation fails too, while reads keep working so the
//! code under test can unwind. A fresh store over a normal `Io` then
//! plays the part of the restarted process.
//!
//! The wrapped calls receive the inner `Io`'s userdata, so the fault state
//! is process-global: one FaultIo at a time.

const std = @import("std");
const Io = std.Io;

pub const FaultIo = struct {
    inner: Io,
    vtable: Io.VTable,
    /// Mutations allowed before the fault.
    budget: u64,
    /// Bytes of the faulting write that still land.
    torn_len: usize = 0,
    /// Fail deletes of files whose name starts with this, without counting
    /// them or dying, as Windows does for files still mapped.
    fail_deletes_of: ?[]const u8 = null,
    dead: bool = false,
    mutations: u64 = 0,

    var active: ?*FaultIo = null;

    pub fn init(f: *FaultIo, inner: Io, budget: u64) void {
        std.debug.assert(active == null);
        f.* = .{ .inner = inner, .vtable = inner.vtable.*, .budget = budget };
        f.vtable.operate = operate;
        f.vtable.fileWritePositional = fileWritePositional;
        f.vtable.fileSync = fileSync;
        f.vtable.dirCreateFileAtomic = dirCreateFileAtomic;
        f.vtable.fileHardLink = fileHardLink;
        f.vtable.dirRename = dirRename;
        f.vtable.dirRenamePreserve = dirRenamePreserve;
        f.vtable.dirDeleteFile = dirDeleteFile;
        active = f;
    }

    pub fn deinit(f: *FaultIo) void {
        std.debug.assert(active == f);
        active = null;
    }

    pub fn io(f: *FaultIo) Io {
        return .{ .userdata = f.inner.userdata, .vtable = &f.vtable };
    }

    fn get() *FaultIo {
        return active.?;
    }

    /// Whether the next mutation may proceed; counts it.
    fn allow(f: *FaultIo) bool {
        if (f.dead) return false;
        f.mutations += 1;
        if (f.budget == 0) {
            f.dead = true;
            return false;
        }
        f.budget -= 1;
        return true;
    }

    fn operate(ud: ?*anyopaque, op: Io.Operation) Io.Cancelable!Io.Operation.Result {
        const f = get();
        switch (op) {
            .file_write_streaming => |w| {
                if (f.allow()) return f.inner.vtable.operate(ud, op);
                f.tear(w.file, w.header, w.data, null);
                return .{ .file_write_streaming = error.InputOutput };
            },
            else => return f.inner.vtable.operate(ud, op),
        }
    }

    fn fileWritePositional(ud: ?*anyopaque, file: Io.File, header: []const u8, data: []const []const u8, splat: usize, offset: u64) Io.File.WritePositionalError!usize {
        const f = get();
        if (f.allow()) return f.inner.vtable.fileWritePositional(ud, file, header, data, splat, offset);
        f.tear(file, header, data, offset);
        return error.InputOutput;
    }

    /// Lands up to `torn_len` bytes of the faulting write (only the first
    /// failed write tears).
    fn tear(f: *FaultIo, file: Io.File, header: []const u8, data: []const []const u8, offset: ?u64) void {
        var left = f.torn_len;
        f.torn_len = 0;
        if (left == 0) return;
        var parts: [2][]const u8 = .{ header, if (data.len > 0) data[0] else &.{} };
        var done: usize = 0;
        for (&parts) |*p| {
            const n = @min(left, p.len);
            if (n == 0) continue;
            const chunk: []const []const u8 = &.{p.*[0..n]};
            const wrote = if (offset) |o|
                f.inner.vtable.fileWritePositional(f.inner.userdata, file, &.{}, chunk, 1, o + done) catch return
            else blk: {
                const r = f.inner.vtable.operate(f.inner.userdata, .{ .file_write_streaming = .{ .file = file, .data = chunk } }) catch return;
                break :blk r.file_write_streaming catch return;
            };
            done += wrote;
            left -= wrote;
            if (wrote < n) return;
        }
    }

    fn fileSync(ud: ?*anyopaque, file: Io.File) Io.File.SyncError!void {
        const f = get();
        if (!f.allow()) return error.InputOutput;
        return f.inner.vtable.fileSync(ud, file);
    }

    fn dirCreateFileAtomic(ud: ?*anyopaque, dir: Io.Dir, path: []const u8, o: Io.Dir.CreateFileAtomicOptions) Io.Dir.CreateFileAtomicError!Io.File.Atomic {
        const f = get();
        if (!f.allow()) return error.NoSpaceLeft;
        return f.inner.vtable.dirCreateFileAtomic(ud, dir, path, o);
    }

    fn fileHardLink(ud: ?*anyopaque, file: Io.File, dir: Io.Dir, path: []const u8, o: Io.File.HardLinkOptions) Io.File.HardLinkError!void {
        const f = get();
        if (!f.allow()) return error.NoSpaceLeft;
        return f.inner.vtable.fileHardLink(ud, file, dir, path, o);
    }

    fn dirRename(ud: ?*anyopaque, old_dir: Io.Dir, old_path: []const u8, new_dir: Io.Dir, new_path: []const u8) Io.Dir.RenameError!void {
        const f = get();
        if (!f.allow()) return error.NoSpaceLeft;
        return f.inner.vtable.dirRename(ud, old_dir, old_path, new_dir, new_path);
    }

    fn dirRenamePreserve(ud: ?*anyopaque, old_dir: Io.Dir, old_path: []const u8, new_dir: Io.Dir, new_path: []const u8) Io.Dir.RenamePreserveError!void {
        const f = get();
        if (!f.allow()) return error.NoSpaceLeft;
        return f.inner.vtable.dirRenamePreserve(ud, old_dir, old_path, new_dir, new_path);
    }

    fn dirDeleteFile(ud: ?*anyopaque, dir: Io.Dir, path: []const u8) Io.Dir.DeleteFileError!void {
        const f = get();
        if (f.fail_deletes_of) |prefix| {
            if (std.mem.startsWith(u8, path, prefix)) return error.AccessDenied;
        }
        if (!f.allow()) return error.AccessDenied;
        return f.inner.vtable.dirDeleteFile(ud, dir, path);
    }
};
