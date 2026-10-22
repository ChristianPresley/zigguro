//! E09.F01.S01.T03 budgets that take seconds, so they print their numbers
//! instead of going through the harness:
//!
//! - `store.gc_10M`: GC over 10M objects (1M trees of 9 blobs in ten
//!   segments; two segments fully live, ... two unreachable) must finish
//!   in under 60 s with under 400 MB of heap.
//! - `chunker.edit_1GiB`: a 1-byte edit in a 1 GiB file, stored with the
//!   default chunk sizes, must re-store at most 3 chunks.

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const bench = zg_core.bench;
const Allocator = std.mem.Allocator;

const names = [_][]const u8{ "store.gc_10M", "chunker.edit_1GiB" };

fn wanted(b: *bench.Bench, name: []const u8) bool {
    const f = b.opts.filter orelse return true;
    return std.mem.indexOf(u8, name, f) != null;
}

const bench_dir = ".zig-cache/scm-gc-bench";

pub fn register(b: *bench.Bench) !void {
    for (names) |n| {
        if (wanted(b, n)) break;
    } else return;
    const io = b.io;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, bench_dir) catch {};
    defer cwd.deleteTree(io, bench_dir) catch {};
    var root = try cwd.createDirPathOpen(io, bench_dir, .{});
    defer root.close(io);
    if (wanted(b, "chunker.edit_1GiB")) try edit1GiB(b, root);
    if (wanted(b, "store.gc_10M")) try gc10M(b, root);
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
}

/// Counts live and peak heap bytes of everything allocated through it.
const Counting = struct {
    child: Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(c: *Counting) Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn note(c: *Counting, add: usize, sub: usize) void {
        const live = c.live.fetchAdd(add, .monotonic) + add;
        _ = c.peak.fetchMax(live, .monotonic);
        _ = c.live.fetchSub(sub, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawAlloc(len, a, ra) orelse return null;
        c.note(len, 0);
        return p;
    }

    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (!c.child.rawResize(m, a, new_len, ra)) return false;
        c.note(new_len, m.len);
        return true;
    }

    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        const p = c.child.rawRemap(m, a, new_len, ra) orelse return null;
        c.note(new_len, m.len);
        return p;
    }

    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.child.rawFree(m, a, ra);
        c.note(0, m.len);
    }
};

const trees_per_segment = 100_000;
const blobs_per_tree = 9;
const segments = 10;
/// Share of each segment's trees that stay reachable, in tenths.
const live_tenths = [segments]u32{ 10, 10, 10, 10, 10, 10, 3, 3, 0, 0 };

const Roots = struct {
    ids: []const scm.ObjectId,

    fn forEach(ctx: *anyopaque, sink: *scm.gc.RootSink) anyerror!void {
        const r: *Roots = @ptrCast(@alignCast(ctx));
        for (r.ids) |id| try sink.add(id);
    }
};

fn gc10M(b: *bench.Bench, root: std.Io.Dir) !void {
    const gpa = b.gpa;
    const io = b.io;
    var d = try root.createDirPathOpen(io, "gc", .{});
    defer d.close(io);

    var roots: std.ArrayList(scm.ObjectId) = .empty;
    defer roots.deinit(gpa);
    var t0 = now(io);
    {
        const s = try scm.Store.open(gpa, io, d, .{ .fsync = false });
        defer s.close();
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var entries: [blobs_per_tree]scm.TreeEntry = undefined;
        var names_buf: [blobs_per_tree][2]u8 = undefined;
        for (&names_buf, 0..) |*n, k| n.* = .{ 'f', '0' + @as(u8, @intCast(k)) };
        var blob: [48]u8 = undefined;
        var serial: u64 = 0;
        for (0..segments) |seg| {
            var batch = s.batch();
            defer batch.abort();
            for (0..trees_per_segment) |t| {
                for (&entries, 0..) |*e, k| {
                    serial += 1;
                    @memset(&blob, @truncate(serial));
                    std.mem.writeInt(u64, blob[0..8], serial, .little);
                    e.* = .{ .name = &names_buf[k], .kind = .file, .id = try batch.put(.blob, &blob) };
                }
                aw.clearRetainingCapacity();
                try scm.encode.encode(scm.Tree, .{ .entries = &entries }, &aw.writer);
                const tree = try batch.put(.tree, aw.written());
                if (t % 10 < live_tenths[seg]) try roots.append(gpa, tree);
            }
            try batch.commit();
        }
    }
    const objects = segments * trees_per_segment * (blobs_per_tree + 1);
    std.debug.print("store.gc_10M: wrote {d} objects in {d} ms\n", .{ objects, (now(io) - t0) / std.time.ns_per_ms });

    var counting: Counting = .{ .child = gpa };
    const s = try scm.Store.open(counting.allocator(), io, d, .{ .fsync = false });
    defer s.close();
    var r: Roots = .{ .ids = roots.items };
    const provider: scm.gc.RootProvider = .{ .ctx = &r, .forEachRoot = Roots.forEach };
    const base = counting.live.load(.monotonic);
    counting.peak.store(base, .monotonic);
    t0 = now(io);
    const report = try scm.gc.gc(s, &.{provider}, .{ .grace_ns = 0, .deflate = false });
    const ms = (now(io) - t0) / std.time.ns_per_ms;
    const heap_mb = (counting.peak.load(.monotonic) - base) >> 20;
    std.debug.print(
        "store.gc_10M: {d} ms, peak heap {d} MB (budget 60000 ms, 400 MB): marked {d}, removed {d} objects, rewrote {d} and deleted {d} segments, freed {d} MB\n",
        .{ ms, heap_mb, report.marked, report.objects_removed, report.segments_rewritten, report.segments_deleted, report.bytes_freed >> 20 },
    );
}

/// 1 GiB of incompressible bytes, generated in 64 KiB blocks, with an
/// optional single flipped byte.
const Synthetic = struct {
    len: u64,
    flip: ?u64,
    pos: u64 = 0,
    interface: std.Io.Reader,

    fn init(len: u64, flip: ?u64, buf: []u8) Synthetic {
        return .{ .len = len, .flip = flip, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buf, .seek = 0, .end = 0 } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const sy: *Synthetic = @fieldParentPtr("interface", r);
        if (sy.pos == sy.len) return error.EndOfStream;
        const block_len = 64 << 10;
        const in_block = sy.pos % block_len;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n: usize = @intCast(@min(dest.len, block_len - in_block, sy.len - sy.pos));
        var block: [block_len]u8 = undefined;
        var prng: std.Random.DefaultPrng = .init(sy.pos / block_len);
        prng.random().bytes(&block);
        @memcpy(dest[0..n], block[@intCast(in_block)..][0..n]);
        if (sy.flip) |f| {
            if (f >= sy.pos and f < sy.pos + n) dest[@intCast(f - sy.pos)] ^= 0xff;
        }
        sy.pos += n;
        w.advance(n);
        return n;
    }
};

fn edit1GiB(b: *bench.Bench, root: std.Io.Dir) !void {
    const gpa = b.gpa;
    const io = b.io;
    var d = try root.createDirPathOpen(io, "edit", .{});
    defer d.close(io);
    const s = try scm.Store.open(gpa, io, d, .{ .fsync = false });
    defer s.close();
    const len: u64 = 1 << 30;
    var rbuf: [64 << 10]u8 = undefined;

    var t0 = now(io);
    var orig: Synthetic = .init(len, null, &rbuf);
    _ = try scm.chunker.writeBlobStreaming(s, &orig.interface, .{});
    const first_ms = (now(io) - t0) / std.time.ns_per_ms;
    const before = s.segments.items[0].index.count;

    t0 = now(io);
    var edited: Synthetic = .init(len, len / 2 + 12345, &rbuf);
    _ = try scm.chunker.writeBlobStreaming(s, &edited.interface, .{});
    const second_ms = (now(io) - t0) / std.time.ns_per_ms;
    // The new segment holds the re-stored chunks plus the chunk list.
    const restored = s.segments.items[0].index.count - 1;
    std.debug.print(
        "chunker.edit_1GiB: 1-byte edit re-stored {d} of {d} chunks (budget 3); store 1 GiB {d} ms, store edited {d} ms\n",
        .{ restored, before - 1, first_ms, second_ms },
    );
}
