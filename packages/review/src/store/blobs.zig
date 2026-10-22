//! The on-disk blob store (E12.F01.S02.T01): `blobs/<2 hex>/<62 hex>`,
//! content-addressed by BLAKE3.
//!
//! `put` only hashes and keeps a copy; `flush` (on the store's worker)
//! writes the new blobs, each through an unnamed temporary file that is
//! synced and then linked into place, before the journal frames that
//! reference them. An existing blob is a dedup hit.

const std = @import("std");
const model = @import("../model/root.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const BlobHash = model.BlobHash;

pub const DiskBlobs = struct {
    gpa: Allocator,
    io: Io,
    /// The review directory (holds `blobs/`).
    dir: Io.Dir,
    mutex: Io.Mutex = .init,
    /// Put but not yet written.
    pending: std.AutoArrayHashMapUnmanaged(BlobHash, []u8) = .empty,

    pub fn deinit(d: *DiskBlobs) void {
        for (d.pending.values()) |v| d.gpa.free(v);
        d.pending.deinit(d.gpa);
    }

    pub fn blobs(d: *DiskBlobs) model.Blobs {
        return .{ .ctx = d, .vtable = &.{ .put = put, .get = get } };
    }

    /// `blobs/ab/cdef...` for `h`.
    pub fn pathOf(h: BlobHash) [6 + 2 + 1 + 62]u8 {
        const x = std.fmt.bytesToHex(h, .lower);
        var out: [71]u8 = undefined;
        @memcpy(out[0..6], "blobs/");
        @memcpy(out[6..8], x[0..2]);
        out[8] = '/';
        @memcpy(out[9..], x[2..]);
        return out;
    }

    fn put(ctx: *anyopaque, bytes: []const u8) anyerror!BlobHash {
        const d: *DiskBlobs = @ptrCast(@alignCast(ctx));
        const h = model.blobHash(bytes);
        d.mutex.lockUncancelable(d.io);
        defer d.mutex.unlock(d.io);
        if (d.pending.contains(h)) return h;
        const copy = try d.gpa.dupe(u8, bytes);
        errdefer d.gpa.free(copy);
        try d.pending.put(d.gpa, h, copy);
        return h;
    }

    fn get(ctx: *anyopaque, arena: Allocator, h: BlobHash) anyerror!?[]const u8 {
        const d: *DiskBlobs = @ptrCast(@alignCast(ctx));
        {
            d.mutex.lockUncancelable(d.io);
            defer d.mutex.unlock(d.io);
            if (d.pending.get(h)) |v| return try arena.dupe(u8, v);
        }
        const p = pathOf(h);
        return d.dir.readFileAlloc(d.io, &p, arena, .unlimited) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }

    /// Writes the pending blobs; they are durable when this returns.
    pub fn flush(d: *DiskBlobs) !void {
        d.mutex.lockUncancelable(d.io);
        var batch = d.pending;
        d.pending = .empty;
        d.mutex.unlock(d.io);
        defer {
            for (batch.values()) |v| d.gpa.free(v);
            batch.deinit(d.gpa);
        }
        errdefer {
            // Put them back for the next attempt.
            d.mutex.lockUncancelable(d.io);
            defer d.mutex.unlock(d.io);
            for (batch.keys(), batch.values()) |k, *v| {
                if (d.pending.contains(k)) continue;
                d.pending.put(d.gpa, k, v.*) catch continue;
                v.* = &.{};
            }
        }
        for (batch.keys(), batch.values()) |h, v| try d.write(h, v);
    }

    /// Deletes the blobs on disk that are not in `keep`, not pending and
    /// not modified at or after `before` (GC). Returns how many.
    pub fn sweep(d: *DiskBlobs, keep: *const std.AutoHashMapUnmanaged(BlobHash, void), before: Io.Timestamp) !u32 {
        var n: u32 = 0;
        var root = d.dir.openDir(d.io, "blobs", .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return 0,
            else => return e,
        };
        defer root.close(d.io);
        var it = root.iterate();
        while (try it.next(d.io)) |e| {
            if (e.kind != .directory or e.name.len != 2) continue;
            var hi: [1]u8 = undefined;
            _ = std.fmt.hexToBytes(&hi, e.name) catch continue;
            var sub = try root.openDir(d.io, e.name, .{ .iterate = true });
            defer sub.close(d.io);
            var it2 = sub.iterate();
            while (try it2.next(d.io)) |f| {
                if (f.kind != .file or f.name.len != 62) continue;
                var h: BlobHash = undefined;
                h[0] = hi[0];
                _ = std.fmt.hexToBytes(h[1..], f.name) catch continue;
                if (keep.contains(h)) continue;
                {
                    d.mutex.lockUncancelable(d.io);
                    defer d.mutex.unlock(d.io);
                    if (d.pending.contains(h)) continue;
                }
                const st = sub.statFile(d.io, f.name, .{}) catch continue;
                if (st.mtime.nanoseconds >= before.nanoseconds) continue;
                sub.deleteFile(d.io, f.name) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                n += 1;
            }
        }
        return n;
    }

    fn write(d: *DiskBlobs, h: BlobHash, bytes: []const u8) !void {
        const p = pathOf(h);
        if (d.dir.access(d.io, &p, .{})) |_| return else |_| {}
        var af = try d.dir.createFileAtomic(d.io, &p, .{ .make_path = true });
        defer af.deinit(d.io);
        try af.file.writeStreamingAll(d.io, bytes);
        try af.file.sync(d.io);
        af.link(d.io) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
    }
};
