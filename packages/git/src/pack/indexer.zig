//! index-pack: turn a received pack into a stored `.pack` + `.idx` + `.rev`.
//!
//! Pass 1 walks the entries in order, inflating each to find its end, CRC32
//! and (for non-deltas) its Oid. Pass 2 resolves deltas: every resolved
//! object is a root whose OFS/REF children are applied depth-first, with
//! roots spread over worker tasks in an `std.Io.Group`. REF_DELTA bases
//! missing from a thin pack are read from the local odb and appended as full
//! objects, and the header count and trailer are rewritten.
//!
//! The pack bytes are written to `objects/pack/tmp_pack_*` as they arrive and
//! memory-mapped for indexing; the delta resolution keeps only the current
//! chain's bases in memory.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const object = @import("../object.zig");
const zlib = @import("../zlib.zig");
const delta = @import("delta.zig");
const pack_mod = @import("pack.zig");
const idx_mod = @import("idx.zig");
const rev_mod = @import("rev.zig");
const writer_mod = @import("writer.zig");
const MappedFile = @import("../mapped.zig").MappedFile;
const Odb = @import("../odb.zig").Odb;
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const ObjectType = object.ObjectType;
const EntryKind = pack_mod.EntryKind;
const Allocator = std.mem.Allocator;

/// Indexer options.
pub const IndexerOptions = struct {
    /// Complete thin packs from the local odb.
    fix_thin: bool = true,
    /// Worker tasks for delta resolution; 0 = CPU count.
    threads: u8 = 0,
    /// Reserved: walk reachability after indexing (E09.F08 fetch).
    verify_connectivity: bool = false,
    /// Leave a `.keep` file next to the pack (fetch holds it against GC).
    keep: bool = false,
};

/// Indexing progress, readable from another thread.
pub const Progress = struct {
    /// Entries in the pack.
    total: std.atomic.Value(u32) = .init(0),
    /// Entries resolved so far.
    done: std.atomic.Value(u32) = .init(0),
};

/// Errors from indexing.
pub const Error = error{ CorruptPack, ThinPackMissingBase } || Allocator.Error;

/// The index of a pack held in memory.
pub const Indexed = struct {
    /// Objects sorted by Oid, ready for `idx.writeIndex`.
    entries: []idx_mod.Entry,
    /// Bytes replacing the old trailer when thin bases were appended (the
    /// new entries); empty otherwise.
    appended: []u8,
    /// Number of appended thin bases.
    thin_fixed: u32,
    /// Object count of the final pack.
    count: u32,

    /// Frees the tables.
    pub fn deinit(ix: *Indexed, gpa: Allocator) void {
        gpa.free(ix.entries);
        gpa.free(ix.appended);
        ix.* = undefined;
    }

    /// idx positions in pack order (for `.rev`); caller frees.
    pub fn revPositions(ix: *const Indexed, gpa: Allocator) Allocator.Error![]u32 {
        const pos = try gpa.alloc(u32, ix.entries.len);
        for (pos, 0..) |*p, i| p.* = @intCast(i);
        std.mem.sort(u32, pos, ix.entries, struct {
            fn lt(es: []idx_mod.Entry, a: u32, b: u32) bool {
                return es[a].offset < es[b].offset;
            }
        }.lt);
        return pos;
    }
};

const Entry = struct {
    offset: u64,
    kind: EntryKind,
    size: u64,
    data_offset: u64,
    base_offset: u64 = 0,
    base_oid: Oid = undefined,
    crc: u32,
    // Set once resolved.
    oid: Oid = undefined,
    type: ObjectType = .blob,
    resolved: bool = false,
};

const OfsChild = struct { base: u64, idx: u32 };
const RefChild = struct { base: Oid, idx: u32 };

const Ctx = struct {
    gpa: Allocator,
    format: ObjectFormat,
    body: []const u8,
    entries: []Entry,
    ofs: []OfsChild,
    ref: []RefChild,
    progress: ?*Progress,
    next_root: std.atomic.Value(u32) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),
    err: ?Error = null,
    err_mutex: std.Io.Mutex = .init,

    fn ofsRange(c: *const Ctx, base: u64) []const OfsChild {
        const lo = std.sort.lowerBound(OfsChild, c.ofs, base, struct {
            fn f(b: u64, x: OfsChild) std.math.Order {
                return std.math.order(b, x.base);
            }
        }.f);
        var hi = lo;
        while (hi < c.ofs.len and c.ofs[hi].base == base) hi += 1;
        return c.ofs[lo..hi];
    }

    fn refRange(c: *const Ctx, base: Oid) []const RefChild {
        const lo = std.sort.lowerBound(RefChild, c.ref, base, struct {
            fn f(b: Oid, x: RefChild) std.math.Order {
                return b.order(x.base);
            }
        }.f);
        var hi = lo;
        while (hi < c.ref.len and c.ref[hi].base.eql(base)) hi += 1;
        return c.ref[lo..hi];
    }

    fn inflate(c: *const Ctx, gpa: Allocator, e: *const Entry) Error![]u8 {
        if (e.size > (c.body.len - e.data_offset) * 1032 + 1024) return error.CorruptPack;
        const out = try gpa.alloc(u8, @intCast(e.size));
        errdefer gpa.free(out);
        var r: std.Io.Reader = .fixed(c.body[@intCast(e.data_offset)..]);
        zlib.inflateExact(&r, out) catch return error.CorruptPack;
        return out;
    }

    /// Resolves every delta reachable from the resolved entry `root` (whose
    /// data is `root_data`, owned and freed here).
    fn resolveTree(c: *Ctx, gpa: Allocator, root_offset: u64, root_oid: Oid, root_type: ObjectType, root_data: []u8) Error!void {
        const Frame = struct { data: []u8, ofs: []const OfsChild, ref: []const RefChild, i: usize = 0 };
        var stack: std.ArrayList(Frame) = .empty;
        defer {
            for (stack.items) |f| gpa.free(f.data);
            stack.deinit(gpa);
        }
        try stack.append(gpa, .{ .data = root_data, .ofs = c.ofsRange(root_offset), .ref = c.refRange(root_oid) });
        while (stack.items.len > 0) {
            if (c.failed.load(.monotonic)) return;
            const top = &stack.items[stack.items.len - 1];
            const n = top.ofs.len + top.ref.len;
            if (top.i >= n) {
                gpa.free(top.data);
                _ = stack.pop();
                continue;
            }
            const child_idx = if (top.i < top.ofs.len) top.ofs[top.i].idx else top.ref[top.i - top.ofs.len].idx;
            top.i += 1;
            const e = &c.entries[child_idx];
            if (e.resolved) continue; // a REF child also listed by offset
            const d = try c.inflate(gpa, e);
            defer gpa.free(d);
            const dh = delta.parseHeader(d) catch return error.CorruptPack;
            if (dh.result_size > std.math.maxInt(u32) * 4) return error.CorruptPack;
            const out = try gpa.alloc(u8, @intCast(dh.result_size));
            errdefer gpa.free(out);
            delta.applyDelta(top.data, d, out) catch return error.CorruptPack;
            e.type = root_type;
            e.oid = object.hashObject(c.format, root_type, out);
            e.resolved = true;
            if (c.progress) |p| _ = p.done.fetchAdd(1, .monotonic);
            try stack.append(gpa, .{ .data = out, .ofs = c.ofsRange(e.offset), .ref = c.refRange(e.oid) });
        }
    }

    fn fail(c: *Ctx, io: std.Io, e: Error) void {
        c.err_mutex.lockUncancelable(io);
        defer c.err_mutex.unlock(io);
        if (c.err == null) c.err = e;
        c.failed.store(true, .monotonic);
    }

    fn worker(c: *Ctx, io: std.Io, roots: []const u32) void {
        while (!c.failed.load(.monotonic)) {
            const i = c.next_root.fetchAdd(1, .monotonic);
            if (i >= roots.len) return;
            const e = &c.entries[roots[i]];
            // Most objects are nobody's base: skip inflating them again.
            if (c.ofsRange(e.offset).len == 0 and c.refRange(e.oid).len == 0) continue;
            const data = c.inflate(c.gpa, e) catch |err| return c.fail(io, err);
            c.resolveTree(c.gpa, e.offset, e.oid, e.type, data) catch |err| return c.fail(io, err);
        }
    }
};

/// Indexes complete pack bytes (header, entries, trailer). With `odb` and
/// `opts.fix_thin`, missing REF_DELTA bases are read from it and returned
/// as `appended` entries.
pub fn indexBytes(gpa: Allocator, io: std.Io, data: []const u8, fmt: ObjectFormat, odb: ?*Odb, opts: IndexerOptions, progress: ?*Progress) Error!Indexed {
    const hl = fmt.len();
    if (data.len < 12 + hl) return error.CorruptPack;
    if (!std.mem.eql(u8, data[0..4], "PACK")) return error.CorruptPack;
    const version = std.mem.readInt(u32, data[4..8], .big);
    if (version != 2 and version != 3) return error.CorruptPack;
    const count = std.mem.readInt(u32, data[8..12], .big);
    const body = data[0 .. data.len - hl];
    if (!oid_mod.hashBytes(fmt, body).eql(Oid.fromBytes(fmt, data[body.len..]))) return error.CorruptPack;
    // Every entry takes at least 2 bytes (1 header + a 0-byte zlib stream
    // needs more), which bounds `count` before allocating.
    if (count > body.len / 2) return error.CorruptPack;
    if (progress) |p| p.total.store(count, .monotonic);

    // Pass 1.
    var entries: std.ArrayList(Entry) = try .initCapacity(gpa, count);
    defer entries.deinit(gpa);
    var ofs: std.ArrayList(OfsChild) = .empty;
    defer ofs.deinit(gpa);
    var ref: std.ArrayList(RefChild) = .empty;
    defer ref.deinit(gpa);
    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(gpa);
    var off: u64 = 12;
    for (0..count) |i| {
        const h = pack_mod.parseEntryHeader(body, off, fmt) catch return error.CorruptPack;
        var e: Entry = .{ .offset = off, .kind = h.kind, .size = h.size, .data_offset = h.data_offset, .crc = 0 };
        var r: std.Io.Reader = .fixed(body[@intCast(h.data_offset)..]);
        if (h.size > (body.len - h.data_offset) * 1032 + 1024) return error.CorruptPack;
        const buf = try gpa.alloc(u8, @intCast(h.size));
        defer gpa.free(buf);
        zlib.inflateExact(&r, buf) catch return error.CorruptPack;
        const end = h.data_offset + r.seek;
        e.crc = std.hash.Crc32.hash(body[@intCast(off)..@intCast(end)]);
        switch (h.base) {
            .none => {
                e.type = h.kind.objectType().?;
                e.oid = object.hashObject(fmt, e.type, buf);
                e.resolved = true;
                try roots.append(gpa, @intCast(i));
                if (progress) |p| _ = p.done.fetchAdd(1, .monotonic);
            },
            .offset => |b| {
                e.base_offset = b;
                try ofs.append(gpa, .{ .base = b, .idx = @intCast(i) });
            },
            .oid => |b| {
                e.base_oid = b;
                try ref.append(gpa, .{ .base = b, .idx = @intCast(i) });
            },
        }
        entries.appendAssumeCapacity(e);
        off = end;
    }
    if (off != body.len) return error.CorruptPack;
    // OFS bases must be entry starts.
    for (ofs.items) |o| {
        _ = findEntry(entries.items, o.base) orelse return error.CorruptPack;
    }
    std.mem.sort(OfsChild, ofs.items, {}, struct {
        fn lt(_: void, a: OfsChild, b: OfsChild) bool {
            return a.base < b.base;
        }
    }.lt);
    std.mem.sort(RefChild, ref.items, {}, struct {
        fn lt(_: void, a: RefChild, b: RefChild) bool {
            return a.base.order(b.base) == .lt;
        }
    }.lt);

    // Pass 2.
    var ctx: Ctx = .{
        .gpa = gpa,
        .format = fmt,
        .body = body,
        .entries = entries.items,
        .ofs = ofs.items,
        .ref = ref.items,
        .progress = progress,
    };
    const threads: usize = if (opts.threads != 0) opts.threads else @min(std.Thread.getCpuCount() catch 1, 64);
    if (threads <= 1 or roots.items.len < 2) {
        ctx.worker(io, roots.items);
    } else {
        var group: std.Io.Group = .init;
        for (0..@min(threads, roots.items.len)) |_| group.async(io, Ctx.worker, .{ &ctx, io, roots.items });
        group.await(io) catch {};
    }
    if (ctx.err) |e| return e;

    // Thin bases.
    var appended: std.Io.Writer.Allocating = .init(gpa);
    defer appended.deinit();
    var extra: std.ArrayList(idx_mod.Entry) = .empty;
    defer extra.deinit(gpa);
    while (true) {
        var missing: ?Oid = null;
        for (entries.items) |e| {
            if (e.resolved) continue;
            if (e.kind != .ref_delta) return error.CorruptPack;
            missing = e.base_oid;
            break;
        }
        const base_id = missing orelse break;
        const o = (if (opts.fix_thin) odb else null) orelse return error.ThinPackMissingBase;
        const obj = o.read(gpa, base_id) catch return error.ThinPackMissingBase;
        defer gpa.free(obj.data);
        // An unresolved REF_DELTA whose base is in the pack means a cycle.
        for (entries.items) |e| if (e.resolved and e.oid.eql(base_id)) return error.CorruptPack;
        for (extra.items) |x| if (x.oid.eql(base_id)) return error.CorruptPack;
        // Append the base as a full entry in place of the old trailer.
        const start = appended.written().len;
        writer_mod.writeEntryHeader(&appended.writer, @intFromEnum(obj.type), obj.data.len) catch return error.OutOfMemory;
        zlibPlain(gpa, &appended.writer, obj.data) catch return error.OutOfMemory;
        try extra.append(gpa, .{
            .oid = base_id,
            .crc32 = std.hash.Crc32.hash(appended.written()[start..]),
            .offset = body.len + start,
        });
        const copy = try gpa.dupe(u8, obj.data);
        try ctx.resolveTree(gpa, std.math.maxInt(u64), base_id, obj.type, copy);
        if (ctx.err) |e| return e;
    }
    const out = try gpa.alloc(idx_mod.Entry, entries.items.len + extra.items.len);
    errdefer gpa.free(out);
    for (entries.items, 0..) |e, i| out[i] = .{ .oid = e.oid, .crc32 = e.crc, .offset = e.offset };
    @memcpy(out[entries.items.len..], extra.items);
    std.mem.sort(idx_mod.Entry, out, {}, idx_mod.Entry.lessThan);
    for (out[1..], 0..) |e, i| if (e.oid.eql(out[i].oid)) return error.CorruptPack;
    return .{
        .entries = out,
        .appended = try appended.toOwnedSlice(),
        .thin_fixed = @intCast(extra.items.len),
        .count = @intCast(out.len),
    };
}

fn zlibPlain(gpa: Allocator, w: *std.Io.Writer, data: []const u8) !void {
    const flate = std.compress.flate;
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const comp = try gpa.create(flate.Compress);
    defer gpa.destroy(comp);
    _ = try w.writableSliceGreedy(16);
    comp.* = try .init(w, window, .zlib, .default);
    try comp.writer.writeAll(data);
    try comp.finish();
}

fn findEntry(entries: []const Entry, off: u64) ?usize {
    var lo: usize = 0;
    var hi = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].offset < off) lo = mid + 1 else if (entries[mid].offset > off) hi = mid else return mid;
    }
    return null;
}

/// A stored pack.
pub const IndexedPack = struct {
    /// Pack checksum; the files are `pack-<hex>.{pack,idx,rev}`.
    checksum: Oid,
    /// Objects in the pack.
    count: u32,
    /// Thin bases appended.
    thin_fixed: u32,
};

/// Streams a pack into `objects/pack/` and indexes it on `finish`.
pub const Indexer = struct {
    gpa: Allocator,
    io: std.Io,
    odb: *Odb,
    format: ObjectFormat,
    opts: IndexerOptions,
    pack_dir: std.Io.Dir,
    tmp_name: [32]u8,
    file: std.Io.File,
    file_writer: std.Io.File.Writer,
    buf: [64 * 1024]u8 = undefined,
    open: bool = true,

    /// Creates `objects/pack/tmp_pack_<random>` for the incoming bytes.
    pub fn init(gpa: Allocator, io: std.Io, odb: *Odb, fmt: ObjectFormat, opts: IndexerOptions) !*Indexer {
        const ix = try gpa.create(Indexer);
        errdefer gpa.destroy(ix);
        const pd = try odb.dir.createDirPathOpen(io, "pack", .{});
        errdefer pd.close(io);
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        ix.* = .{
            .gpa = gpa,
            .io = io,
            .odb = odb,
            .format = fmt,
            .opts = opts,
            .pack_dir = pd,
            .tmp_name = undefined,
            .file = undefined,
            .file_writer = undefined,
        };
        _ = std.fmt.bufPrint(&ix.tmp_name, "tmp_pack_{x}", .{rnd}) catch unreachable;
        ix.file = try pd.createFile(io, ix.tmpName(), .{ .exclusive = true });
        ix.file_writer = ix.file.writer(io, &ix.buf);
        return ix;
    }

    fn tmpName(ix: *const Indexer) []const u8 {
        return ix.tmp_name[0 .. "tmp_pack_".len + 16];
    }

    /// Where to write the pack bytes as they arrive.
    pub fn writer(ix: *Indexer) *std.Io.Writer {
        return &ix.file_writer.interface;
    }

    /// Removes the temp file and frees the indexer.
    pub fn deinit(ix: *Indexer) void {
        if (ix.open) ix.file.close(ix.io);
        ix.pack_dir.deleteFile(ix.io, ix.tmpName()) catch {};
        ix.pack_dir.close(ix.io);
        ix.gpa.destroy(ix);
    }

    /// Indexes the received pack and atomically installs
    /// `pack-<checksum>.{pack,rev,idx}` (idx last, since readers find packs
    /// by their idx).
    pub fn finish(ix: *Indexer, progress: ?*Progress) !IndexedPack {
        const gpa = ix.gpa;
        const io = ix.io;
        try ix.file_writer.interface.flush();
        ix.file.close(io);
        ix.open = false;
        var mf = try MappedFile.open(gpa, io, ix.pack_dir, ix.tmpName());
        var mapped = true;
        defer if (mapped) mf.close(gpa, io);
        var res = try indexBytes(gpa, io, mf.bytes, ix.format, ix.odb, ix.opts, progress);
        defer res.deinit(gpa);
        const hl = ix.format.len();
        var checksum = Oid.fromBytes(ix.format, mf.bytes[mf.bytes.len - hl ..]);
        // The file renamed into place; a fixed thin pack is a second file.
        var fixed_buf: [40]u8 = undefined;
        const fixed_name = std.fmt.bufPrint(&fixed_buf, "{s}_fixed", .{ix.tmpName()}) catch unreachable;
        var src = ix.tmpName();
        if (res.thin_fixed > 0) {
            // Rewrite: new count, old entries, appended bases, new trailer.
            const f = try ix.pack_dir.createFile(io, fixed_name, .{});
            errdefer ix.pack_dir.deleteFile(io, fixed_name) catch {};
            defer f.close(io);
            var wbuf: [64 * 1024]u8 = undefined;
            var fw = f.writer(io, &wbuf);
            var hasher = oid_mod.Hasher.init(ix.format);
            var hbuf: [256]u8 = undefined;
            var hw = fw.interface.hashed(&hasher, &hbuf);
            try hw.writer.writeAll(mf.bytes[0..8]);
            try hw.writer.writeInt(u32, res.count, .big);
            try hw.writer.writeAll(mf.bytes[12 .. mf.bytes.len - hl]);
            try hw.writer.writeAll(res.appended);
            try hw.writer.flush();
            checksum = hasher.final();
            try fw.interface.writeAll(checksum.slice());
            try fw.interface.flush();
            src = fixed_name;
        }
        // Windows cannot rename a mapped file.
        mf.close(gpa, io);
        mapped = false;
        var hex_buf: [64]u8 = undefined;
        const hex = checksum.hex(&hex_buf);
        var name_buf: [96]u8 = undefined;
        if (ix.opts.keep) {
            try ix.pack_dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name_buf, "pack-{s}.keep", .{hex}), .data = "zigguro index-pack\n" });
        }
        try ix.pack_dir.rename(src, ix.pack_dir, try std.fmt.bufPrint(&name_buf, "pack-{s}.pack", .{hex}), io);
        try writeAtomic(gpa, io, ix.pack_dir, try std.fmt.bufPrint(&name_buf, "pack-{s}.rev", .{hex}), .rev, &res, checksum);
        try writeAtomic(gpa, io, ix.pack_dir, try std.fmt.bufPrint(&name_buf, "pack-{s}.idx", .{hex}), .idx, &res, checksum);
        return .{ .checksum = checksum, .count = res.count, .thin_fixed = res.thin_fixed };
    }
};

fn writeAtomic(gpa: Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, kind: enum { idx, rev }, res: *const Indexed, checksum: Oid) !void {
    var af = try dir.createFileAtomic(io, name, .{ .replace = true, .permissions = @import("../loose.zig").readOnlyPermissions() });
    defer af.deinit(io);
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = af.file.writer(io, &wbuf);
    switch (kind) {
        .idx => _ = try idx_mod.writeIndex(&fw.interface, checksum.format, res.entries, checksum.slice()),
        .rev => {
            const pos = try res.revPositions(gpa);
            defer gpa.free(pos);
            try rev_mod.writeRev(&fw.interface, checksum.format, pos, checksum.slice());
        },
    }
    try fw.interface.flush();
    try af.replace(io);
}

const testdata = @import("../testdata.zig");

test "indexer: fixture packs -> idx equals git's idx bytes" {
    const t = std.testing;
    const gpa = t.allocator;
    for ([_]ObjectFormat{ .sha1, .sha256 }) |fmt| {
        var fx = try testdata.Fixture.open(gpa, t.io, fmt);
        defer fx.close();
        for (fx.packs.items) |p| {
            for ([_]u8{ 1, 4 }) |threads| {
                var progress: Progress = .{};
                var res = try indexBytes(gpa, t.io, p.bytes, fmt, null, .{ .threads = threads }, &progress);
                defer res.deinit(gpa);
                try t.expectEqual(p.count, progress.done.load(.monotonic));
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                _ = try idx_mod.writeIndex(&aw.writer, fmt, res.entries, p.index.packChecksum());
                try t.expectEqualSlices(u8, p.idx_file.bytes, aw.written());
            }
        }
    }
}

test "indexer: corrupt stream errors cleanly" {
    const t = std.testing;
    const gpa = t.allocator;
    var fx = try testdata.Fixture.open(gpa, t.io, .sha1);
    defer fx.close();
    const p = fx.packs.items[0];
    const copy = try gpa.dupe(u8, p.bytes);
    defer gpa.free(copy);
    // Flip a byte in the middle: the trailer no longer matches.
    copy[copy.len / 2] ^= 0x55;
    try t.expectError(error.CorruptPack, indexBytes(gpa, t.io, copy, .sha1, null, .{}, null));
    // Same damage with a recomputed trailer: inflate or delta checks fail.
    const body = copy[0 .. copy.len - 20];
    @memcpy(copy[copy.len - 20 ..], oid_mod.hashBytes(.sha1, body).slice());
    try t.expectError(error.CorruptPack, indexBytes(gpa, t.io, copy, .sha1, null, .{}, null));
    try t.expectError(error.CorruptPack, indexBytes(gpa, t.io, p.bytes[0..30], .sha1, null, .{}, null));
}

test "indexer: thin pack fixed and installed" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const odb = try Odb.open(gpa, t.io, tmp.dir, .sha1, .{});
    defer odb.close();
    var big: std.Io.Writer.Allocating = .init(gpa);
    defer big.deinit();
    for (0..400) |i| try big.writer.print("shared line {d}\n", .{i});
    const base_id = try odb.writeLoose(.blob, big.written());
    try big.writer.writeAll("one more line\n");
    var pw = writer_mod.PackWriter.init(gpa, odb, .sha1);
    defer pw.deinit();
    const new_id = try pw.addData(.blob, big.written(), .{ .path = "f" });
    const ix = try Indexer.init(gpa, t.io, odb, .sha1, .{ .keep = true });
    defer ix.deinit();
    _ = try pw.finish(ix.writer(), .{ .thin_bases = &.{base_id} });
    const res = try ix.finish(null);
    try t.expectEqual(@as(u32, 2), res.count);
    try t.expectEqual(@as(u32, 1), res.thin_fixed);

    // Without the odb the thin pack is rejected.
    var raw: std.Io.Writer.Allocating = .init(gpa);
    defer raw.deinit();
    var pw2 = writer_mod.PackWriter.init(gpa, odb, .sha1);
    defer pw2.deinit();
    _ = try pw2.addData(.blob, big.written(), .{ .path = "f" });
    _ = try pw2.finish(&raw.writer, .{ .thin_bases = &.{base_id} });
    try t.expectError(error.ThinPackMissingBase, indexBytes(gpa, t.io, raw.written(), .sha1, null, .{}, null));

    // The installed pack is readable through a fresh odb.
    try odb.rescan();
    try t.expectEqual(@as(usize, 1), odb.packs.items.len);
    var o = try odb.readVerified(gpa, new_id);
    defer o.deinit(gpa);
    try t.expectEqualStrings(big.written(), o.data);
    var b = try odb.readVerified(gpa, base_id);
    b.deinit(gpa);
    var hex_buf: [64]u8 = undefined;
    var name_buf: [96]u8 = undefined;
    var pd = try tmp.dir.openDir(t.io, "pack", .{});
    defer pd.close(t.io);
    try pd.access(t.io, try std.fmt.bufPrint(&name_buf, "pack-{s}.keep", .{res.checksum.hex(&hex_buf)}), .{});
    try pd.access(t.io, try std.fmt.bufPrint(&name_buf, "pack-{s}.rev", .{res.checksum.hex(&hex_buf)}), .{});
}

test "fuzz: git-pack" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            // Give the input a valid trailer so parsing gets past it.
            var full: [4096 + 20]u8 = undefined;
            @memcpy(full[0..input.len], input);
            @memcpy(full[input.len..][0..20], oid_mod.hashBytes(.sha1, input).slice());
            var res = indexBytes(std.testing.allocator, std.testing.io, full[0 .. input.len + 20], .sha1, null, .{ .threads = 1 }, null) catch return;
            res.deinit(std.testing.allocator);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "git-pack") });
}
