//! `TrigramIndex`: the trigram inverted index over the workspace's text
//! files, fed by the indexer as an `IndexPlugin`.
//!
//! Indexed files accumulate in an in-memory `Builder`; `commit` turns the
//! batch into an immutable segment (written to `<storage>/index/trigram/`
//! when persistent) once it holds 32 MB of text or is 5 s old. A changed or
//! removed file tombstones its old document. Small segments are merged
//! (8 at a time) and segments with > 30 % deleted docs are rewritten.
//! Readers are refcounted, immutable views: a search keeps its reader while
//! the index moves on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileId = @import("../../ids.zig").FileId;
const plugin_mod = @import("../plugin.zig");
const IndexPlugin = plugin_mod.IndexPlugin;
const FileRef = plugin_mod.FileRef;
const PluginOutput = plugin_mod.PluginOutput;
const ContentClass = @import("../content_class.zig").ContentClass;
const segment = @import("segment.zig");
const Segment = segment.Segment;
const Builder = segment.Builder;
const Trigram = segment.Trigram;
const query = @import("query.zig");
const writeAtomic = @import("../../model/storage.zig").writeAtomic;

const log = std.log.scoped(.trigram);

/// Index options.
pub const Options = struct {
    /// Commit a segment once the batch holds this much text (the builder
    /// needs about 16 bytes per byte of text while sorting)...
    commit_bytes: u64 = 8 << 20,
    /// ...or is this old.
    commit_ns: u64 = 5 * std.time.ns_per_s,
    /// Merge this many similar-sized segments at once.
    merge_factor: u32 = 8,
    /// Rewrite a segment once this fraction of its docs is deleted.
    max_deleted: f32 = 0.30,
};

const pending_seg = std.math.maxInt(u32);

const Loc = struct { seg: u32, local: u32 };

/// One immutable segment with its tombstones.
const Seg = struct {
    refs: std.atomic.Value(u32) = .init(1),
    /// File number (`seg-<no>.zgt`).
    no: u32,
    owned: ?[]u8 = null,
    mm: ?Io.File.MemoryMap = null,
    seg: Segment,
    deleted: std.DynamicBitSetUnmanaged,
    deleted_count: u32 = 0,

    fn unref(s: *Seg, gpa: Allocator, io: Io) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        if (s.owned) |o| gpa.free(o);
        if (s.mm) |*m| m.destroy(io);
        s.deleted.deinit(gpa);
        gpa.destroy(s);
    }
};

/// An immutable view of the committed segments.
pub const Reader = struct {
    gpa: Allocator,
    io: Io,
    refs: std.atomic.Value(u32) = .init(1),
    segs: []*Seg,
    /// Tombstones as of this view (segments' bits keep changing).
    deleted: []std.DynamicBitSetUnmanaged,
    bases: []u32,
    doc_total: u32,
    /// Global doc -> current FileId (`.none` when the file is unknown).
    files: []FileId,

    /// Total documents, deleted ones included (ids are `0..docCount()`).
    pub fn docCount(r: *const Reader) u32 {
        return r.doc_total;
    }

    /// Upper bound of the posting count of `t`.
    pub fn count(r: *const Reader, t: Trigram) u32 {
        var n: u32 = 0;
        for (r.segs) |s| n += s.seg.count(t);
        return n;
    }

    /// Appends the live docs containing `t`, sorted.
    pub fn postings(r: *const Reader, t: Trigram, out: *std.ArrayList(u32), gpa: Allocator) !void {
        for (r.segs, r.deleted, r.bases) |s, del, base| {
            const start = out.items.len;
            try s.seg.postings(t, base, out, gpa);
            var n = start;
            for (out.items[start..]) |d| {
                if (del.isSet(d - base)) continue;
                out.items[n] = d;
                n += 1;
            }
            out.shrinkRetainingCapacity(n);
        }
    }

    /// The file of global doc `doc`, or null when it is deleted or stale.
    pub fn docToFile(r: *const Reader, doc: u32) ?FileId {
        if (doc >= r.doc_total) return null;
        const f = r.files[doc];
        return if (f.eql(.none)) null else f;
    }

    /// Runs a query against this view.
    pub fn execute(r: *const Reader, q: query.Query, gpa: Allocator) !query.Candidates {
        return query.execute(r, q, gpa);
    }

    /// Takes another reference.
    pub fn acquire(r: *const Reader) *const Reader {
        _ = @constCast(r).refs.fetchAdd(1, .monotonic);
        return r;
    }

    /// Drops a reference.
    pub fn release(r: *const Reader) void {
        const self = @constCast(r);
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = self.gpa;
        for (self.segs) |s| s.unref(gpa, self.io);
        for (self.deleted) |*d| d.deinit(gpa);
        gpa.free(self.segs);
        gpa.free(self.deleted);
        gpa.free(self.bases);
        gpa.free(self.files);
        gpa.destroy(self);
    }
};

/// The index.
pub const TrigramIndex = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    /// Persistence directory; null keeps everything in memory.
    dir: ?Io.Dir,
    lock: Io.Mutex = .init,
    segs: std.ArrayList(*Seg) = .empty,
    pending: Builder,
    pending_deleted: std.DynamicBitSetUnmanaged = .{},
    pending_files: std.ArrayList(FileId) = .empty,
    pending_since: ?Io.Timestamp = null,
    /// path_hash -> where its live doc is.
    locs: std.AutoHashMapUnmanaged(u64, Loc) = .empty,
    /// path_hash -> current FileId (bound by `index`/`has`).
    files: std.AutoHashMapUnmanaged(u64, FileId) = .empty,
    next_no: u32 = 0,
    current: ?*Reader = null,
    extractors: std.ArrayList(*segment.Extractor) = .empty,
    /// True when `open` found a damaged index and started over.
    rebuilt: bool = false,

    /// Opens the index stored in `dir` (or an empty in-memory one when
    /// null). A damaged index is discarded (`rebuilt` is set).
    pub fn open(gpa: Allocator, io: Io, dir: ?Io.Dir, opts: Options) !*TrigramIndex {
        const ix = try gpa.create(TrigramIndex);
        ix.* = .{ .gpa = gpa, .io = io, .opts = opts, .dir = dir, .pending = .init(gpa) };
        if (dir != null) ix.load() catch |err| switch (err) {
            error.OutOfMemory => {
                ix.deinit();
                return error.OutOfMemory;
            },
            else => {
                if (!@import("builtin").is_test) log.warn("trigram index damaged ({t}); rebuilding", .{err});
                ix.dropAll();
                ix.rebuilt = true;
            },
        };
        return ix;
    }

    /// Frees the index (readers still held stay valid until released).
    pub fn deinit(ix: *TrigramIndex) void {
        const gpa = ix.gpa;
        if (ix.current) |r| r.release();
        for (ix.segs.items) |s| s.unref(gpa, ix.io);
        ix.segs.deinit(gpa);
        ix.pending.deinit();
        ix.pending_deleted.deinit(gpa);
        ix.pending_files.deinit(gpa);
        ix.locs.deinit(gpa);
        ix.files.deinit(gpa);
        for (ix.extractors.items) |e| {
            e.deinit(gpa);
            gpa.destroy(e);
        }
        ix.extractors.deinit(gpa);
        gpa.destroy(ix);
    }

    /// The scheduler plugin for this index.
    pub fn plugin(ix: *TrigramIndex) IndexPlugin {
        return .{
            .name = "trigram",
            .version = segment.version,
            .ctx = ix,
            .wants = pWants,
            .index = pIndex,
            .remove = pRemove,
            .commit = pCommit,
            .has = pHas,
        };
    }

    fn pWants(_: *anyopaque, _: *const FileRef, class: ContentClass) bool {
        return class.isText();
    }

    fn pIndex(ctx: *anyopaque, f: *const FileRef, bytes: []const u8, _: ContentClass, out: *PluginOutput) anyerror!void {
        const ix: *TrigramIndex = @ptrCast(@alignCast(ctx));
        try ix.add(f.path_hash, f.id, bytes);
        out.bytes_indexed += bytes.len;
    }

    fn pRemove(ctx: *anyopaque, f: *const FileRef) void {
        const ix: *TrigramIndex = @ptrCast(@alignCast(ctx));
        ix.remove(f.path_hash);
    }

    fn pCommit(ctx: *anyopaque) void {
        const ix: *TrigramIndex = @ptrCast(@alignCast(ctx));
        ix.commit() catch |err| log.err("trigram commit failed: {t}", .{err});
    }

    fn pHas(ctx: *anyopaque, f: *const FileRef) bool {
        const ix: *TrigramIndex = @ptrCast(@alignCast(ctx));
        return ix.bind(f.path_hash, f.id);
    }

    /// Indexes (or re-indexes) one document.
    pub fn add(ix: *TrigramIndex, path_hash: u64, id: FileId, bytes: []const u8) !void {
        const ex = try ix.takeExtractor();
        defer ix.giveExtractor(ex);
        const tris = try ex.extract(ix.gpa, bytes);
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        ix.tombstoneLocked(path_hash);
        const local = try ix.pending.add(.{ .path_hash = path_hash, .hint = id.index }, tris, bytes.len);
        try ix.pending_files.append(ix.gpa, id);
        try ix.pending_deleted.resize(ix.gpa, local + 1, false);
        try ix.locs.put(ix.gpa, path_hash, .{ .seg = pending_seg, .local = local });
        try ix.files.put(ix.gpa, path_hash, id);
        if (ix.pending_since == null) ix.pending_since = Io.Timestamp.now(ix.io, .awake);
    }

    /// Forgets a document.
    pub fn remove(ix: *TrigramIndex, path_hash: u64) void {
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        ix.tombstoneLocked(path_hash);
        _ = ix.locs.remove(path_hash);
        _ = ix.files.remove(path_hash);
    }

    /// Records that `path_hash` is file `id` this session; returns whether
    /// the index holds a live doc for it (warm start: no re-index needed).
    pub fn bind(ix: *TrigramIndex, path_hash: u64, id: FileId) bool {
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        if (!ix.locs.contains(path_hash)) return false;
        ix.files.put(ix.gpa, path_hash, id) catch return false;
        ix.invalidateLocked();
        return true;
    }

    fn tombstoneLocked(ix: *TrigramIndex, path_hash: u64) void {
        const loc = ix.locs.get(path_hash) orelse return;
        if (loc.seg == pending_seg) {
            ix.pending_deleted.set(loc.local);
            return;
        }
        for (ix.segs.items) |s| if (s.no == loc.seg) {
            if (!s.deleted.isSet(loc.local)) {
                s.deleted.set(loc.local);
                s.deleted_count += 1;
            }
            break;
        };
        ix.invalidateLocked();
    }

    fn invalidateLocked(ix: *TrigramIndex) void {
        if (ix.current) |r| r.release();
        ix.current = null;
    }

    /// Writes the pending batch as a segment when it is big or old enough,
    /// then merges if the policy says so.
    pub fn commit(ix: *TrigramIndex) !void {
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        const old = if (ix.pending_since) |s| s.durationTo(Io.Timestamp.now(ix.io, .awake)).nanoseconds >= ix.opts.commit_ns else false;
        if (ix.pending.text_bytes < ix.opts.commit_bytes and !old) return;
        try ix.flushLocked();
        try ix.mergeLocked(false);
    }

    /// Writes the pending batch as a segment now.
    pub fn flush(ix: *TrigramIndex) !void {
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        try ix.flushLocked();
    }

    fn flushLocked(ix: *TrigramIndex) !void {
        var nb: [32]u8 = undefined;
        if (ix.pending.docCount() == 0) return;
        const gpa = ix.gpa;
        const bytes = try ix.pending.finish(gpa);
        var seg_owned = true;
        defer if (seg_owned) gpa.free(bytes);
        const no = ix.next_no;
        const s = try ix.newSeg(no, bytes);
        seg_owned = false;
        errdefer s.unref(gpa, ix.io);
        // Carry over tombstones set while the batch was pending.
        var it = ix.pending_deleted.iterator(.{});
        while (it.next()) |i| {
            s.deleted.set(i);
            s.deleted_count += 1;
        }
        try ix.segs.append(gpa, s);
        ix.next_no += 1;
        // Docs move from the batch to the segment.
        var lit = ix.locs.valueIterator();
        while (lit.next()) |l| if (l.seg == pending_seg) {
            l.seg = no;
        };
        ix.pending.deinit();
        ix.pending = .init(gpa);
        ix.pending_deleted.deinit(gpa);
        ix.pending_deleted = .{};
        ix.pending_files.clearRetainingCapacity();
        ix.pending_since = null;
        ix.invalidateLocked();
        if (ix.dir) |d| {
            try writeAtomic(ix.io, d, segName(&nb, no), bytes_of(s));
            try ix.saveMetaLocked();
        }
    }

    fn newSeg(ix: *TrigramIndex, no: u32, bytes: []u8) !*Seg {
        const gpa = ix.gpa;
        const parsed = Segment.parse(bytes) catch unreachable; // we just built it
        const s = try gpa.create(Seg);
        errdefer gpa.destroy(s);
        s.* = .{ .no = no, .owned = bytes, .seg = parsed, .deleted = try .initEmpty(gpa, parsed.doc_count) };
        return s;
    }

    /// Merges segments per the policy; `all` merges everything into one.
    pub fn merge(ix: *TrigramIndex, all: bool) !void {
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        try ix.mergeLocked(all);
    }

    fn mergeLocked(ix: *TrigramIndex, all: bool) !void {
        var nb: [32]u8 = undefined;
        const gpa = ix.gpa;
        var pick: std.ArrayList(*Seg) = .empty;
        defer pick.deinit(gpa);
        if (all) {
            if (ix.segs.items.len == 0) return;
            if (ix.segs.items.len == 1 and ix.segs.items[0].deleted_count == 0) return;
            try pick.appendSlice(gpa, ix.segs.items);
        } else {
            // Heavily deleted segments are rewritten; then the smallest
            // `merge_factor` segments merge once there are that many.
            for (ix.segs.items) |s| {
                const frac = @as(f32, @floatFromInt(s.deleted_count)) / @as(f32, @floatFromInt(@max(1, s.seg.doc_count)));
                if (frac > ix.opts.max_deleted) try pick.append(gpa, s);
            }
            if (pick.items.len == 0 and ix.segs.items.len >= ix.opts.merge_factor) {
                const sorted = try gpa.dupe(*Seg, ix.segs.items);
                defer gpa.free(sorted);
                std.mem.sort(*Seg, sorted, {}, struct {
                    fn lt(_: void, a: *Seg, b: *Seg) bool {
                        return a.seg.doc_count < b.seg.doc_count;
                    }
                }.lt);
                try pick.appendSlice(gpa, sorted[0..ix.opts.merge_factor]);
            }
            if (pick.items.len == 0) return;
        }
        // Keep the original order so doc ids stay ascending.
        std.mem.sort(*Seg, pick.items, {}, struct {
            fn lt(_: void, a: *Seg, b: *Seg) bool {
                return a.no < b.no;
            }
        }.lt);

        var b: Builder = .init(gpa);
        defer b.deinit();
        var remaps = try gpa.alloc([]u32, pick.items.len);
        var made: usize = 0;
        defer {
            for (remaps[0..made]) |m| gpa.free(m);
            gpa.free(remaps);
        }
        for (pick.items, 0..) |s, si| {
            const m = try gpa.alloc(u32, s.seg.doc_count);
            remaps[si] = m;
            made += 1;
            for (0..s.seg.doc_count) |i| {
                m[i] = if (s.deleted.isSet(i)) pending_seg else try b.addDoc(s.seg.doc(@intCast(i)));
            }
        }
        // Postings: walk each trigram table in order; new ids ascend
        // because segments are visited in order and remaps are monotonic.
        var tmp: std.ArrayList(u32) = .empty;
        defer tmp.deinit(gpa);
        for (pick.items, 0..) |s, si| {
            for (0..s.seg.trigram_count) |ti| {
                tmp.clearRetainingCapacity();
                try s.seg.postingsAt(@intCast(ti), 0, &tmp, gpa);
                const t = s.seg.entry(@intCast(ti)).trigram;
                for (tmp.items) |local| {
                    const nd = remaps[si][local];
                    if (nd != pending_seg) try b.addPosting(t, nd);
                }
            }
        }
        const no = ix.next_no;
        var ns: ?*Seg = null;
        if (b.docCount() > 0) {
            const bytes = try b.finish(gpa);
            ns = ix.newSeg(no, bytes) catch |err| {
                gpa.free(bytes);
                return err;
            };
            ix.next_no += 1;
        }
        errdefer if (ns) |s| s.unref(gpa, ix.io);
        // Swap: the merged segment replaces the picked ones in place of the first.
        var out: std.ArrayList(*Seg) = .empty;
        errdefer out.deinit(gpa);
        var placed = false;
        for (ix.segs.items) |s| {
            if (std.mem.indexOfScalar(*Seg, pick.items, s) == null) {
                try out.append(gpa, s);
            } else if (!placed) {
                placed = true;
                if (ns) |n| try out.append(gpa, n);
            }
        }
        // Relocate live docs.
        var lit = ix.locs.valueIterator();
        while (lit.next()) |l| {
            for (pick.items, 0..) |s, si| if (s.no == l.seg) {
                l.* = .{ .seg = no, .local = remaps[si][l.local] };
                break;
            };
        }
        ix.segs.deinit(gpa);
        ix.segs = out;
        ix.invalidateLocked();
        if (ix.dir) |d| {
            if (ns) |n| try writeAtomic(ix.io, d, segName(&nb, n.no), bytes_of(n));
            try ix.saveMetaLocked();
            for (pick.items) |s| {
                d.deleteFile(ix.io, segName(&nb, s.no)) catch {};
                d.deleteFile(ix.io, delName(&nb, s.no)) catch {};
            }
        }
        for (pick.items) |s| s.unref(gpa, ix.io);
    }

    /// The current view; release it when done.
    pub fn reader(ix: *TrigramIndex) !*const Reader {
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        if (ix.current == null) ix.current = try ix.buildReaderLocked();
        return ix.current.?.acquire();
    }

    fn buildReaderLocked(ix: *TrigramIndex) !*Reader {
        const gpa = ix.gpa;
        const n = ix.segs.items.len;
        const r = try gpa.create(Reader);
        errdefer gpa.destroy(r);
        const segs = try gpa.dupe(*Seg, ix.segs.items);
        errdefer gpa.free(segs);
        const deleted = try gpa.alloc(std.DynamicBitSetUnmanaged, n);
        errdefer gpa.free(deleted);
        var copied: usize = 0;
        errdefer for (deleted[0..copied]) |*d| d.deinit(gpa);
        for (segs, deleted) |s, *d| {
            d.* = try s.deleted.clone(gpa);
            copied += 1;
        }
        const bases = try gpa.alloc(u32, n);
        errdefer gpa.free(bases);
        var total: u32 = 0;
        for (segs, bases) |s, *b| {
            b.* = total;
            total += s.seg.doc_count;
        }
        const files = try gpa.alloc(FileId, total);
        errdefer gpa.free(files);
        for (segs, bases, deleted) |s, base, d| {
            for (0..s.seg.doc_count) |i| {
                files[base + i] = if (d.isSet(i)) .none else ix.files.get(s.seg.doc(@intCast(i)).path_hash) orelse .none;
            }
        }
        for (segs) |s| _ = s.refs.fetchAdd(1, .monotonic);
        r.* = .{ .gpa = gpa, .io = ix.io, .segs = segs, .deleted = deleted, .bases = bases, .doc_total = total, .files = files };
        return r;
    }

    /// Segment count (tests, stats).
    pub fn segmentCount(ix: *TrigramIndex) usize {
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        return ix.segs.items.len;
    }

    /// Writes tombstones and the manifest (on idle and close).
    pub fn save(ix: *TrigramIndex) !void {
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        if (ix.dir != null) try ix.saveMetaLocked();
    }

    // Manifest: "ZGTM" version u32, next_no u32, count u32, then count u32
    // segment numbers, then xxhash3. Tombstones: seg-<no>.del, the raw bit
    // set words.
    fn saveMetaLocked(ix: *TrigramIndex) !void {
        var nb: [32]u8 = undefined;
        const d = ix.dir.?;
        const gpa = ix.gpa;
        for (ix.segs.items) |s| {
            const words = s.deleted.masks[0 .. (s.deleted.bit_length + 63) / 64];
            try writeAtomic(ix.io, d, delName(&nb, s.no), std.mem.sliceAsBytes(words));
        }
        var m: std.ArrayList(u8) = .empty;
        defer m.deinit(gpa);
        try m.appendSlice(gpa, "ZGTM");
        try appendU32(&m, gpa, 1);
        try appendU32(&m, gpa, ix.next_no);
        try appendU32(&m, gpa, @intCast(ix.segs.items.len));
        for (ix.segs.items) |s| try appendU32(&m, gpa, s.no);
        var h: [8]u8 = undefined;
        std.mem.writeInt(u64, &h, std.hash.XxHash3.hash(0, m.items), .little);
        try m.appendSlice(gpa, &h);
        try writeAtomic(ix.io, d, "manifest", m.items);
    }

    fn load(ix: *TrigramIndex) !void {
        const d = ix.dir.?;
        const gpa = ix.gpa;
        const m = d.readFileAlloc(ix.io, "manifest", gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer gpa.free(m);
        if (m.len < 24 or !std.mem.eql(u8, m[0..4], "ZGTM")) return error.BadManifest;
        if (std.hash.XxHash3.hash(0, m[0 .. m.len - 8]) != std.mem.readInt(u64, m[m.len - 8 ..][0..8], .little)) return error.ChecksumMismatch;
        if (std.mem.readInt(u32, m[4..8], .little) != 1) return error.BadManifest;
        ix.next_no = std.mem.readInt(u32, m[8..12], .little);
        const count = std.mem.readInt(u32, m[12..16], .little);
        if (m.len != 16 + count * 4 + 8) return error.BadManifest;
        for (0..count) |i| {
            const no = std.mem.readInt(u32, m[16 + i * 4 ..][0..4], .little);
            const s = try ix.openSeg(no);
            ix.segs.append(gpa, s) catch |err| {
                s.unref(gpa, ix.io);
                return err;
            };
            for (0..s.seg.doc_count) |li| if (!s.deleted.isSet(li)) {
                try ix.locs.put(gpa, s.seg.doc(@intCast(li)).path_hash, .{ .seg = no, .local = @intCast(li) });
            };
        }
    }

    fn openSeg(ix: *TrigramIndex, no: u32) !*Seg {
        var nb: [32]u8 = undefined;
        const gpa = ix.gpa;
        const d = ix.dir.?;
        var f = try d.openFile(ix.io, segName(&nb, no), .{});
        defer f.close(ix.io);
        const len = (try f.stat(ix.io)).size;
        if (len == 0) return error.Truncated;
        var mm = try f.createMemoryMap(ix.io, .{ .len = @intCast(len), .protection = .{ .read = true, .write = false }, .populate = false });
        errdefer mm.destroy(ix.io);
        // Segments are immutable: one sync point at open suffices.
        try mm.read(ix.io);
        const parsed = try Segment.parse(mm.memory);
        const s = try gpa.create(Seg);
        errdefer gpa.destroy(s);
        s.* = .{ .no = no, .mm = mm, .seg = parsed, .deleted = try .initEmpty(gpa, parsed.doc_count) };
        if (d.readFileAlloc(ix.io, delName(&nb, no), gpa, .limited(1 << 28))) |bits| {
            defer gpa.free(bits);
            const words = s.deleted.masks[0 .. (s.deleted.bit_length + 63) / 64];
            if (bits.len == words.len * 8) {
                @memcpy(std.mem.sliceAsBytes(words), bits);
                s.deleted_count = @intCast(s.deleted.count());
            }
        } else |_| {}
        return s;
    }

    fn dropAll(ix: *TrigramIndex) void {
        for (ix.segs.items) |s| s.unref(ix.gpa, ix.io);
        ix.segs.clearRetainingCapacity();
        ix.locs.clearRetainingCapacity();
        ix.next_no = 0;
        const d = ix.dir orelse return;
        var it = d.iterate();
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| ix.gpa.free(n);
            names.deinit(ix.gpa);
        }
        while (it.next(ix.io) catch null) |e| {
            const n = ix.gpa.dupe(u8, e.name) catch break;
            names.append(ix.gpa, n) catch {
                ix.gpa.free(n);
                break;
            };
        }
        for (names.items) |n| d.deleteFile(ix.io, n) catch {};
    }

    fn takeExtractor(ix: *TrigramIndex) !*segment.Extractor {
        ix.lock.lockUncancelable(ix.io);
        const e = ix.extractors.pop();
        ix.lock.unlock(ix.io);
        if (e) |x| return x;
        const x = try ix.gpa.create(segment.Extractor);
        errdefer ix.gpa.destroy(x);
        x.* = try .init(ix.gpa);
        return x;
    }

    fn giveExtractor(ix: *TrigramIndex, e: *segment.Extractor) void {
        ix.lock.lockUncancelable(ix.io);
        defer ix.lock.unlock(ix.io);
        ix.extractors.append(ix.gpa, e) catch {
            e.deinit(ix.gpa);
            ix.gpa.destroy(e);
        };
    }
};

fn bytes_of(s: *const Seg) []const u8 {
    return s.seg.bytes;
}

fn appendU32(m: *std.ArrayList(u8), gpa: Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try m.appendSlice(gpa, &b);
}

fn segName(buf: *[32]u8, no: u32) []const u8 {
    return std.fmt.bufPrint(buf, "seg-{d}.zgt", .{no}) catch unreachable;
}

fn delName(buf: *[32]u8, no: u32) []const u8 {
    return std.fmt.bufPrint(buf, "seg-{d}.del", .{no}) catch unreachable;
}
