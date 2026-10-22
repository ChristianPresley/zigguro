//! The content-addressed object store: append-only segments under
//! `<root>/seg/`, each published by atomically linking its index.
//!
//! Writers never lock: a `WriteBatch` streams its records into a private
//! temporary file, links it as `<stem>.zgs`, then writes and links
//! `<stem>.zgi`. Stems are `<16 hex ns>-<16 hex random>`, unique across
//! processes and ordered by time, so lookups search newest first. After
//! publishing, the writer replaces `seg/GEN` with a fresh random value so
//! other processes notice and rescan (best effort; a read miss always
//! rescans).
//!
//! Reads are zero-copy views into mapped segments, except for deflated
//! records, which are inflated into the shared decode cache. Either way the
//! caller gets an `ObjectRef` and must `release` it.

const std = @import("std");
const zg_core = @import("zg_core");
const id_mod = @import("id.zig");
const seg = @import("segment.zig");
const cache_mod = @import("cache.zig");
const MappedFile = @import("mapped.zig").MappedFile;
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Store tuning.
pub const Options = struct {
    /// Decode cache budget.
    cache_bytes: usize = 64 << 20,
    /// Deflate records as they are written. Off by default: std 0.16's
    /// deflate costs ~110 µs of setup per object and runs at ~130 MB/s,
    /// far below the write budget, so compaction (T03) compresses instead.
    deflate_on_write: bool = false,
    /// Payloads at least this long are deflated when that saves >= 12.5%.
    compress_min: usize = 512,
    /// Payloads longer than this are stored raw (zero-copy reads, and
    /// deflate would cap write throughput).
    compress_max: usize = 256 << 10,
    /// fsync segment and index files before publishing.
    fsync: bool = true,
    /// Minimum time between `seg/GEN` checks on a `contains` miss.
    rescan_interval_ms: u32 = 250,
    /// When set, blocking calls assert they are not on its UI thread.
    runtime: ?*const zg_core.Runtime = null,
};

/// Errors from reading.
pub const ReadError = error{ NotFound, CorruptSegment, CorruptObject } || Allocator.Error || std.Io.Cancelable;

/// A segment the store has mapped. Reference counted: the store holds one
/// reference, and every `ObjectRef` into it holds another.
pub const Segment = struct {
    gpa: Allocator,
    io: std.Io,
    /// File name without extension.
    stem: []u8,
    data: MappedFile,
    index_file: MappedFile,
    index: seg.SegmentIndex,
    refs: std.atomic.Value(u32),

    /// Maps `<stem>.zgs` and `<stem>.zgi` in `dir` and checks that they
    /// belong together. Does not hash the index (fsck does).
    pub fn open(gpa: Allocator, io: std.Io, dir: std.Io.Dir, stem: []const u8) !*Segment {
        var name_buf: [64]u8 = undefined;
        var index_file = try MappedFile.open(gpa, io, dir, try std.fmt.bufPrint(&name_buf, "{s}.zgi", .{stem}));
        errdefer index_file.close(gpa, io);
        var data = try MappedFile.open(gpa, io, dir, try std.fmt.bufPrint(&name_buf, "{s}.zgs", .{stem}));
        errdefer data.close(gpa, io);
        const index = try seg.SegmentIndex.parse(index_file.bytes);
        const uid = try seg.parseSegmentHeader(data.bytes);
        if (!std.mem.eql(u8, &uid, &index.uid())) return error.CorruptSegment;
        const s = try gpa.create(Segment);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .io = io,
            .stem = try gpa.dupe(u8, stem),
            .data = data,
            .index_file = index_file,
            .index = index,
            .refs = .init(1),
        };
        return s;
    }

    pub fn retain(s: *Segment) void {
        _ = s.refs.fetchAdd(1, .monotonic);
    }

    /// Drops a reference; unmaps and frees with the last one.
    pub fn release(s: *Segment) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        s.data.close(s.gpa, s.io);
        s.index_file.close(s.gpa, s.io);
        s.gpa.free(s.stem);
        s.gpa.destroy(s);
    }

    /// The kind of index entry `i`.
    pub fn kindAt(s: *const Segment, i: u32) error{CorruptSegment}!Kind {
        return Kind.fromInt(s.index.kindByte(i)) orelse error.CorruptSegment;
    }

    /// The record of index entry `i`.
    pub fn record(s: *const Segment, i: u32) error{CorruptSegment}!seg.Record {
        const r = try seg.readRecord(s.data.bytes, s.index.offset(i));
        if (r.kind != try s.kindAt(i)) return error.CorruptSegment;
        return r;
    }
};

/// A read object. `bytes` stays valid until `release`.
pub const ObjectRef = struct {
    kind: Kind,
    bytes: []const u8,
    owner: union(enum) {
        segment: *Segment,
        cached: *cache_mod.Entry,
    },

    pub fn release(self: ObjectRef) void {
        switch (self.owner) {
            .segment => |s| s.release(),
            .cached => |e| e.release(),
        }
    }
};

const Location = struct { segment: *Segment, index: u32 };

/// Inflates a raw-deflate payload that must expand to exactly `out.len`.
pub fn inflateRaw(payload: []const u8, out: []u8) error{CorruptObject}!void {
    var in: std.Io.Reader = .fixed(payload);
    var dec: flate.Decompress = .init(&in, .raw, &.{});
    var w: std.Io.Writer = .fixed(out);
    // Always stream unlimited: 0.16's decoder makes no progress when the
    // limit is shorter than a pending match.
    var stalls: u32 = 0;
    while (true) {
        const n = dec.reader.stream(&w, .unlimited) catch |e| switch (e) {
            error.EndOfStream => break,
            error.WriteFailed, error.ReadFailed => return error.CorruptObject,
        };
        stalls = if (n == 0) stalls + 1 else 0;
        if (stalls > 64) return error.CorruptObject;
    }
    if (w.end != out.len) return error.CorruptObject;
}

/// The object store. Safe for concurrent use from many threads; many
/// stores (in many processes) may share one directory.
pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    seg_dir: std.Io.Dir,
    opts: Options,
    /// Guards `segments`.
    lock: std.Io.RwLock = .init,
    /// Newest first.
    segments: std.ArrayList(*Segment) = .empty,
    /// Serialises rescans.
    scan_mutex: std.Io.Mutex = .init,
    cache: cache_mod.Cache,
    /// Last `seg/GEN` value seen.
    gen: std.atomic.Value(u64) = .init(0),
    last_check_ns: std.atomic.Value(u64) = .init(0),

    /// Opens (creating if needed) the store rooted at `dir`. Maps every
    /// published segment; nothing beyond headers is parsed.
    pub fn open(gpa: Allocator, io: std.Io, dir: std.Io.Dir, opts: Options) !*Store {
        if (opts.runtime) |rt| rt.assertNotUi();
        const seg_dir = try dir.createDirPathOpen(io, "seg", .{ .open_options = .{ .iterate = true } });
        errdefer seg_dir.close(io);
        const s = try gpa.create(Store);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .io = io, .seg_dir = seg_dir, .opts = opts, .cache = .init(gpa, io, opts.cache_bytes) };
        s.gen.store(s.readGen(), .monotonic);
        try s.rescan();
        return s;
    }

    /// Unmaps everything. Every `ObjectRef` must have been released.
    pub fn close(s: *Store) void {
        for (s.segments.items) |sg| sg.release();
        s.segments.deinit(s.gpa);
        s.cache.deinit();
        s.seg_dir.close(s.io);
        s.gpa.destroy(s);
    }

    fn assertNotUi(s: *const Store) void {
        if (s.opts.runtime) |rt| rt.assertNotUi();
    }

    fn readGen(s: *Store) u64 {
        const f = s.seg_dir.openFile(s.io, "GEN", .{}) catch return 0;
        defer f.close(s.io);
        var b: [8]u8 = undefined;
        const n = f.readPositionalAll(s.io, &b, 0) catch return 0;
        if (n != 8) return 0;
        return std.mem.readInt(u64, &b, .little);
    }

    /// Tells other processes that a segment was published.
    fn bumpGen(s: *Store) void {
        var b: [8]u8 = undefined;
        s.io.random(&b);
        var af = s.seg_dir.createFileAtomic(s.io, "GEN", .{ .replace = true }) catch return;
        defer af.deinit(s.io);
        af.file.writePositionalAll(s.io, &b, 0) catch return;
        af.replace(s.io) catch return;
        s.gen.store(std.mem.readInt(u64, &b, .little), .monotonic);
    }

    /// Re-lists `seg/`: maps newly published segments and drops ones whose
    /// index disappeared. Segments that fail to parse are skipped (fsck
    /// reports them).
    pub fn rescan(s: *Store) !void {
        s.scan_mutex.lockUncancelable(s.io);
        defer s.scan_mutex.unlock(s.io);
        const gpa = s.gpa;
        var stems: std.ArrayList([]u8) = .empty;
        defer {
            for (stems.items) |n| gpa.free(n);
            stems.deinit(gpa);
        }
        var it = s.seg_dir.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zgi")) continue;
            try stems.append(gpa, try gpa.dupe(u8, e.name[0 .. e.name.len - 4]));
        }

        s.lock.lockSharedUncancelable(s.io);
        const old = try gpa.dupe(*Segment, s.segments.items);
        s.lock.unlockShared(s.io);
        defer gpa.free(old);

        var next: std.ArrayList(*Segment) = .empty;
        errdefer {
            for (next.items) |sg| sg.release();
            next.deinit(gpa);
        }
        for (stems.items) |stem| {
            const existing = for (old) |sg| {
                if (std.mem.eql(u8, sg.stem, stem)) break sg;
            } else null;
            if (existing) |sg| {
                sg.retain();
                try next.append(gpa, sg);
                continue;
            }
            const sg = Segment.open(gpa, s.io, s.seg_dir, stem) catch |e| switch (e) {
                error.OutOfMemory, error.Canceled => |x| return x,
                else => continue,
            };
            next.append(gpa, sg) catch |e| {
                sg.release();
                return e;
            };
        }
        std.mem.sort(*Segment, next.items, {}, struct {
            fn newer(_: void, a: *Segment, b: *Segment) bool {
                return std.mem.order(u8, a.stem, b.stem) == .gt;
            }
        }.newer);

        s.lock.lockUncancelable(s.io);
        const dropped = s.segments;
        s.segments = next;
        s.lock.unlock(s.io);
        for (dropped.items) |sg| sg.release();
        var d = dropped;
        d.deinit(gpa);
        s.last_check_ns.store(zg_core.time.nowNs(s.io), .monotonic);
    }

    /// Rescans when `seg/GEN` changed, at most every `rescan_interval_ms`.
    fn maybeRescan(s: *Store) bool {
        const now = zg_core.time.nowNs(s.io);
        const last = s.last_check_ns.load(.monotonic);
        if (now -% last < @as(u64, s.opts.rescan_interval_ms) * std.time.ns_per_ms) return false;
        s.last_check_ns.store(now, .monotonic);
        const g = s.readGen();
        if (g == s.gen.load(.monotonic)) return false;
        s.gen.store(g, .monotonic);
        s.rescan() catch return false;
        return true;
    }

    fn findLocal(s: *Store, id: ObjectId) ?Location {
        s.lock.lockSharedUncancelable(s.io);
        defer s.lock.unlockShared(s.io);
        for (s.segments.items) |sg| {
            if (sg.index.find(id)) |i| {
                sg.retain();
                return .{ .segment = sg, .index = i };
            }
        }
        return null;
    }

    /// Whether the store has `id`. Index-only.
    pub fn contains(s: *Store, id: ObjectId) bool {
        if (s.findLocal(id)) |loc| {
            loc.segment.release();
            return true;
        }
        if (!s.maybeRescan()) return false;
        if (s.findLocal(id)) |loc| {
            loc.segment.release();
            return true;
        }
        return false;
    }

    fn locate(s: *Store, id: ObjectId) ReadError!Location {
        if (s.findLocal(id)) |loc| return loc;
        s.rescan() catch |e| switch (e) {
            error.OutOfMemory, error.Canceled => |x| return x,
            else => return error.NotFound,
        };
        return s.findLocal(id) orelse error.NotFound;
    }

    /// The kind of `id` from the index alone.
    pub fn readKind(s: *Store, id: ObjectId) ReadError!Kind {
        s.assertNotUi();
        const loc = try s.locate(id);
        defer loc.segment.release();
        return loc.segment.kindAt(loc.index);
    }

    /// Reads `id`. Release the result.
    pub fn read(s: *Store, id: ObjectId) ReadError!ObjectRef {
        s.assertNotUi();
        if (s.cache.get(id)) |e| return .{ .kind = e.kind, .bytes = e.data, .owner = .{ .cached = e } };
        const loc = try s.locate(id);
        const sg = loc.segment;
        const rec = sg.record(loc.index) catch |e| {
            sg.release();
            return e;
        };
        if (!rec.deflated()) return .{ .kind = rec.kind, .bytes = rec.payload, .owner = .{ .segment = sg } };
        defer sg.release();
        const out = try s.gpa.alloc(u8, rec.raw_len);
        inflateRaw(rec.payload, out) catch |e| {
            s.gpa.free(out);
            return e;
        };
        const entry = try s.cache.put(id, rec.kind, out);
        return .{ .kind = entry.kind, .bytes = entry.data, .owner = .{ .cached = entry } };
    }

    /// Reads `id` and checks that it hashes to `id`.
    pub fn readVerified(s: *Store, id: ObjectId) ReadError!ObjectRef {
        const r = try s.read(id);
        if (!id_mod.hashObject(r.kind, r.bytes).eql(id)) {
            r.release();
            return error.CorruptObject;
        }
        return r;
    }

    /// Starts a write batch.
    pub fn batch(s: *Store) WriteBatch {
        return .{ .store = s };
    }

    /// Number of published segments currently mapped.
    pub fn segmentCount(s: *Store) usize {
        s.lock.lockSharedUncancelable(s.io);
        defer s.lock.unlockShared(s.io);
        return s.segments.items.len;
    }

    fn publish(s: *Store, stem: []const u8) !void {
        s.bumpGen();
        const sg = try Segment.open(s.gpa, s.io, s.seg_dir, stem);
        s.lock.lockUncancelable(s.io);
        defer s.lock.unlock(s.io);
        s.segments.insert(s.gpa, 0, sg) catch |e| {
            sg.release();
            return e;
        };
    }
};

/// Test hook: where `WriteBatch.commit` fails.
pub const FailPoint = enum { none, after_records, after_segment_link, before_index_link };

/// Many writes, one segment, durable when `commit` returns. Deduplicates
/// against the store and within the batch. Not thread-safe; use one batch
/// per thread.
pub const WriteBatch = struct {
    store: *Store,
    seen: std.AutoHashMapUnmanaged(ObjectId, void) = .empty,
    entries: std.ArrayList(seg.IndexEntry) = .empty,
    file: ?std.Io.File.Atomic = null,
    fw: std.Io.File.Writer = undefined,
    wbuf: []u8 = &.{},
    offset: u64 = 0,
    uid: [16]u8 = undefined,
    stem_buf: [33]u8 = undefined,
    /// "<stem>.zgs" and "<stem>.zgi"; heap-allocated because File.Atomic
    /// keeps a pointer to its destination name.
    names: ?*[2][37]u8 = null,
    window: []u8 = &.{},
    scratch: std.Io.Writer.Allocating = undefined,
    fail_at: FailPoint = .none,

    const buffer_len = 256 << 10;

    fn stem(b: *const WriteBatch) []const u8 {
        return &b.stem_buf;
    }

    fn begin(b: *WriteBatch) !void {
        const s = b.store;
        const io = s.io;
        io.random(&b.uid);
        var r: [8]u8 = undefined;
        io.random(&r);
        const ns: u64 = @intCast(@max(0, std.Io.Timestamp.now(io, .real).nanoseconds));
        _ = std.fmt.bufPrint(&b.stem_buf, "{x:0>16}-{x:0>16}", .{ ns, std.mem.readInt(u64, &r, .little) }) catch unreachable;
        b.wbuf = try s.gpa.alloc(u8, buffer_len);
        errdefer {
            s.gpa.free(b.wbuf);
            b.wbuf = &.{};
        }
        const names = try s.gpa.create([2][37]u8);
        b.names = names;
        _ = std.fmt.bufPrint(&names[0], "{s}.zgs", .{b.stem()}) catch unreachable;
        _ = std.fmt.bufPrint(&names[1], "{s}.zgi", .{b.stem()}) catch unreachable;
        b.file = try s.seg_dir.createFileAtomic(io, &names[0], .{ .replace = false });
        b.fw = b.file.?.file.writerStreaming(io, b.wbuf);
        try seg.writeSegmentHeader(&b.fw.interface, b.uid);
        b.offset = seg.segment_header_len;
        b.scratch = .init(s.gpa);
    }

    /// Compresses `bytes` into `scratch` with fast raw deflate.
    fn deflate(b: *WriteBatch, bytes: []const u8) ![]const u8 {
        if (b.window.len == 0) b.window = try b.store.gpa.alloc(u8, flate.max_window_len);
        b.scratch.clearRetainingCapacity();
        _ = try b.scratch.writer.writableSliceGreedy(16);
        var c: flate.Compress = try .init(&b.scratch.writer, b.window, .raw, .fastest);
        try c.writer.writeAll(bytes);
        try c.finish();
        return b.scratch.written();
    }

    /// For large payloads, deflates a 4 KiB sample first so incompressible
    /// data (media, archives) skips the full attempt.
    fn worthDeflating(b: *WriteBatch, bytes: []const u8) !bool {
        const sample_len = 4096;
        if (bytes.len < 4 * sample_len) return true;
        const mid = bytes.len / 2;
        const z = try b.deflate(bytes[mid - sample_len / 2 ..][0..sample_len]);
        return z.len <= sample_len - sample_len / 8;
    }

    /// Adds an object and returns its ID. A no-op when the batch or the
    /// store already has it.
    pub fn put(b: *WriteBatch, kind: Kind, bytes: []const u8) !ObjectId {
        const s = b.store;
        s.assertNotUi();
        const id = id_mod.hashObject(kind, bytes);
        if (b.seen.contains(id)) return id;
        if (s.contains(id)) return id;
        if (b.file == null) try b.begin();
        try b.seen.put(s.gpa, id, {});
        try b.entries.ensureUnusedCapacity(s.gpa, 1);
        var payload = bytes;
        var flags: u8 = 0;
        if (s.opts.deflate_on_write and bytes.len >= s.opts.compress_min and bytes.len <= s.opts.compress_max and
            try b.worthDeflating(bytes))
        {
            const z = try b.deflate(bytes);
            if (z.len <= bytes.len - bytes.len / 8) {
                payload = z;
                flags = seg.flag_deflate;
            }
        }
        const w = &b.fw.interface;
        const start = b.offset;
        var hdr_buf: [32]u8 = undefined;
        var hw: std.Io.Writer = .fixed(&hdr_buf);
        seg.writeRecordHeader(&hw, kind, flags, payload.len, bytes.len) catch unreachable;
        w.writeAll(hw.buffered()) catch return b.fw.err orelse error.WriteFailed;
        w.writeAll(payload) catch return b.fw.err orelse error.WriteFailed;
        b.offset += hw.end + payload.len;
        b.entries.appendAssumeCapacity(.{ .id = id, .kind = kind, .offset = start });
        return id;
    }

    /// Publishes the batch: segment, then index. Durable when it returns.
    /// The batch is finished afterwards either way.
    pub fn commit(b: *WriteBatch) !void {
        defer b.abort();
        const s = b.store;
        s.assertNotUi();
        const io = s.io;
        if (b.file == null) return;
        const af = &b.file.?;
        b.fw.interface.flush() catch return b.fw.err orelse error.WriteFailed;
        if (s.opts.fsync) try af.file.sync(io);
        if (b.fail_at == .after_records) return error.InjectedFailure;
        try af.link(io);
        if (b.fail_at == .after_segment_link) return error.InjectedFailure;

        var ix = try s.seg_dir.createFileAtomic(io, &b.names.?[1], .{ .replace = false });
        defer ix.deinit(io);
        var iw = ix.file.writerStreaming(io, b.wbuf);
        seg.writeIndex(&iw.interface, b.entries.items, b.uid) catch return iw.err orelse error.WriteFailed;
        iw.interface.flush() catch return iw.err orelse error.WriteFailed;
        if (s.opts.fsync) try ix.file.sync(io);
        if (b.fail_at == .before_index_link) return error.InjectedFailure;
        try ix.link(io);
        try s.publish(b.stem());
    }

    /// Discards the batch (removing its unpublished temporary file).
    pub fn abort(b: *WriteBatch) void {
        const gpa = b.store.gpa;
        if (b.file) |*f| {
            f.deinit(b.store.io);
            b.scratch.deinit();
        }
        b.file = null;
        if (b.names) |n| gpa.destroy(n);
        b.names = null;
        if (b.wbuf.len > 0) gpa.free(b.wbuf);
        if (b.window.len > 0) gpa.free(b.window);
        b.wbuf = &.{};
        b.window = &.{};
        b.seen.deinit(gpa);
        b.entries.deinit(gpa);
        b.seen = .empty;
        b.entries = .empty;
    }
};
