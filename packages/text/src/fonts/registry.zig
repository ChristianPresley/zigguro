//! Instance ids for the faces text is laid out with.
//!
//! Layout, shape caches and glyph keys name a face instance by a u18 id.
//! Ids come from two sources: `register` for instances the caller owns,
//! and `instance` for a face of the font database at some variation
//! position and synthesis, which the registry opens itself (each file
//! mapped once and shared by its faces and instances).
//!
//! Ids are append-only and never reused. Entries live in a segmented
//! array (segments never move), so `get` is a lock-free read that any
//! thread can do for an id it was handed; inserts take a short lock.
//! Mapped files stay mapped until `deinit` (releasing idle maps is a
//! follow-up).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;
const AxisValue = @import("../ot/var/fvar.zig").AxisValue;
const db_mod = @import("db.zig");
const LastResortTable = @import("last_resort.zig").LastResortTable;
const matcher = @import("matcher.zig");

pub const Synth = matcher.Synth;

/// A face instance id. Ids below `first_id` are reserved.
pub const InstanceId = u18;

/// The virtual last-resort instance (E03.F07.S02.T04).
pub const last_resort_instance: InstanceId = 0;
/// The virtual instance of procedural terminal glyphs (E03.F08.S02.T04).
pub const procedural_instance: InstanceId = 1;
/// The first id `register` hands out.
pub const first_id: InstanceId = 2;

/// What layout keeps about a registered instance.
pub const Registered = struct {
    inst: *const FaceInstance,
    /// Design units per em.
    upem: f32,
    /// The face carries color glyphs (COLR, CBDT or sbix).
    color: bool,
    /// OS/2 or `post` says the face is monospaced.
    monospace: bool,
    /// Bit `c` is set when the face maps ASCII printable `c` (controls
    /// count as mapped: they are never drawn).
    ascii: u128,
    /// Synthetic bold/oblique the renderer applies.
    synth: Synth = .{},

    /// True when the face maps every printable ASCII character.
    pub fn coversAscii(r: *const Registered) bool {
        return r.ascii == ~@as(u128, 0) >> 1;
    }
};

fn asciiCoverage(face: *const ot.Face) u128 {
    var bits: u128 = 0;
    for (0..128) |c| {
        if (c >= 0x20 and c < 0x7F and face.glyphIndex(@intCast(c)) == 0) continue;
        bits |= @as(u128, 1) << @intCast(c);
    }
    return bits & (~@as(u128, 0) >> 1);
}

/// Maps instance ids to instances.
pub const FontRegistry = struct {
    gpa: Allocator,
    /// Segment `k` holds `seg0 << k` entries.
    segments: [segment_count]?[*]Registered = @splat(null),
    /// Published entry count (release on insert, acquire in `has`).
    len: std.atomic.Value(u32) = .init(0),
    lock: std.atomic.Mutex = .unlocked,
    /// Database-backed instances by key, and what they own.
    keyed: std.ArrayList(Owned) = .empty,
    files: std.StringHashMapUnmanaged(*FileNode) = .empty,
    /// The Io the files were opened with (closing needs it).
    io: ?std.Io = null,
    /// Glyph ids of last-resort code points (instance 0).
    last_resort: LastResortTable = .{},

    const seg0_log2 = 6;
    const seg0 = 1 << seg0_log2;
    const segment_count = 13; // 64 * (2^13 - 1) > 2^18 ids

    const FileNode = struct { mf: ot.MappedFont };
    const Owned = struct {
        path: []const u8,
        index: u16,
        coords: []const AxisValue,
        synth: Synth,
        node: *Node,
        id: InstanceId,
    };
    const Node = struct { face: ot.Face, inst: FaceInstance };

    /// An empty registry.
    pub fn init(gpa: Allocator) FontRegistry {
        return .{ .gpa = gpa };
    }

    /// Frees the table, the instances it opened and their files (the
    /// instances given to `register` belong to the caller).
    pub fn deinit(r: *FontRegistry) void {
        const gpa = r.gpa;
        for (r.keyed.items) |o| {
            o.node.inst.deinit(gpa);
            gpa.destroy(o.node);
            gpa.free(o.path);
            gpa.free(o.coords);
        }
        r.keyed.deinit(gpa);
        var it = r.files.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.mf.close(r.io.?);
            gpa.destroy(e.value_ptr.*);
            gpa.free(e.key_ptr.*);
        }
        r.files.deinit(gpa);
        r.last_resort.deinit(gpa);
        for (r.segments, 0..) |seg, k| if (seg) |p| gpa.free(p[0 .. @as(usize, seg0) << @intCast(k)]);
        r.* = undefined;
    }

    fn slot(idx: u32) struct { seg: usize, off: usize } {
        const i = idx + seg0;
        const k = 31 - @clz(i) - seg0_log2;
        return .{ .seg = k, .off = i - (@as(u32, seg0) << @intCast(k)) };
    }

    fn acquire(r: *FontRegistry) void {
        while (!r.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Appends `e` (lock held); returns its id.
    fn push(r: *FontRegistry, e: Registered) Allocator.Error!InstanceId {
        const n = r.len.load(.monotonic);
        if (n >= std.math.maxInt(InstanceId) - first_id) return error.OutOfMemory;
        const sl = slot(n);
        if (r.segments[sl.seg] == null) {
            const mem = try r.gpa.alloc(Registered, @as(usize, seg0) << @intCast(sl.seg));
            r.segments[sl.seg] = mem.ptr;
        }
        r.segments[sl.seg].?[sl.off] = e;
        r.len.store(n + 1, .release);
        return @intCast(first_id + n);
    }

    fn describe(inst: *const FaceInstance, synth: Synth) Registered {
        const face = inst.face;
        return .{
            .inst = inst,
            .upem = @floatFromInt(@max(face.metrics().units_per_em, 1)),
            .color = face.knownTable(.colr) != null or face.knownTable(.cbdt) != null or face.knownTable(.sbix) != null,
            .monospace = face.style().monospace,
            .ascii = asciiCoverage(face),
            .synth = synth,
        };
    }

    /// Registers `inst`, which must outlive the registry; returns its id.
    /// The same pointer registered twice gets the same id.
    pub fn register(r: *FontRegistry, inst: *const FaceInstance) Allocator.Error!InstanceId {
        r.acquire();
        defer r.lock.unlock();
        const n = r.len.load(.monotonic);
        for (0..n) |i| if (r.at(@intCast(i)).inst == inst) return @intCast(first_id + i);
        return r.push(describe(inst, .{}));
    }

    /// The id of face `f` of `db` at axis settings `coords` (user units)
    /// with `synth`, opening the file on first use. The same face file,
    /// index, coordinates and synthesis always get the same id, across
    /// database snapshots.
    pub fn instance(r: *FontRegistry, io: std.Io, db: *const db_mod.FontDb, f: db_mod.FaceRef, coords: []const AxisValue, synth: Synth) !InstanceId {
        const path = db.path(f);
        const index = db.face(f).index;
        r.acquire();
        defer r.lock.unlock();
        r.io = io;
        for (r.keyed.items) |o| {
            if (o.index == index and o.synth.eql(synth) and std.mem.eql(u8, o.path, path) and eqlCoords(o.coords, coords)) return o.id;
        }
        const gpa = r.gpa;
        const file = r.files.get(path) orelse blk: {
            const key = try gpa.dupe(u8, path);
            errdefer gpa.free(key);
            const node = try gpa.create(FileNode);
            errdefer gpa.destroy(node);
            node.mf = try ot.MappedFont.openAlloc(io, std.Io.Dir.cwd(), path, gpa);
            errdefer node.mf.close(io);
            try r.files.put(gpa, key, node);
            break :blk node;
        };
        const node = try gpa.create(Node);
        errdefer gpa.destroy(node);
        node.face = try ot.Face.init(file.mf.bytes(), index);
        node.inst = try FaceInstance.init(gpa, &node.face, coords);
        errdefer node.inst.deinit(gpa);
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        const owned_coords = try gpa.dupe(AxisValue, coords);
        errdefer gpa.free(owned_coords);
        try r.keyed.ensureUnusedCapacity(gpa, 1);
        const id = try r.push(describe(&node.inst, synth));
        r.keyed.appendAssumeCapacity(.{ .path = owned_path, .index = index, .coords = owned_coords, .synth = synth, .node = node, .id = id });
        return id;
    }

    fn eqlCoords(a: []const AxisValue, b: []const AxisValue) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (x.tag != y.tag or x.value != y.value) return false;
        return true;
    }

    fn at(r: *const FontRegistry, idx: u32) *const Registered {
        const sl = slot(idx);
        return &r.segments[sl.seg].?[sl.off];
    }

    /// The instance registered as `id` (which must be a registered id).
    /// Lock-free.
    pub fn get(r: *const FontRegistry, id: InstanceId) *const Registered {
        return r.at(id - first_id);
    }

    /// True when `id` names a registered instance.
    pub fn has(r: *const FontRegistry, id: InstanceId) bool {
        return id >= first_id and id - first_id < r.len.load(.acquire);
    }

    /// The last-resort glyph id of `cp` (see last_resort.zig). Callable
    /// through a const registry: the table locks itself.
    pub fn lastResortGlyph(r: *const FontRegistry, cp: u21) u16 {
        return @constCast(&r.last_resort).glyph(r.gpa, cp);
    }

    /// The code point of last-resort glyph `g`.
    pub fn lastResortCodepoint(r: *const FontRegistry, g: u16) u21 {
        return r.last_resort.codepoint(g);
    }

    /// The number of registered instances.
    pub fn count(r: *const FontRegistry) u32 {
        return r.len.load(.acquire);
    }
};
