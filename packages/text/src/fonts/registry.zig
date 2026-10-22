//! Instance ids for the faces text is laid out with.
//!
//! Layout, shape caches and glyph keys name a face instance by a u18 id.
//! This registry hands out those ids for instances the caller already
//! owns. E03.F07 extends it with database-backed registration
//! (`FaceRef` + coordinates + synthesis) and thread-safe growth; the id
//! space and `get` stay as they are.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ot = @import("../ot/root.zig");
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;

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
    entries: std.ArrayList(Registered) = .empty,

    /// An empty registry.
    pub fn init(gpa: Allocator) FontRegistry {
        return .{ .gpa = gpa };
    }

    /// Frees the table (the instances belong to the caller).
    pub fn deinit(r: *FontRegistry) void {
        r.entries.deinit(r.gpa);
        r.* = undefined;
    }

    /// Registers `inst`, which must outlive the registry; returns its id.
    /// The same pointer registered twice gets the same id.
    pub fn register(r: *FontRegistry, inst: *const FaceInstance) Allocator.Error!InstanceId {
        for (r.entries.items, 0..) |e, i| if (e.inst == inst) return @intCast(first_id + i);
        if (r.entries.items.len >= std.math.maxInt(InstanceId) - first_id) return error.OutOfMemory;
        const face = inst.face;
        try r.entries.append(r.gpa, .{
            .inst = inst,
            .upem = @floatFromInt(@max(face.metrics().units_per_em, 1)),
            .color = face.knownTable(.colr) != null or face.knownTable(.cbdt) != null or face.knownTable(.sbix) != null,
            .monospace = face.style().monospace,
            .ascii = asciiCoverage(face),
        });
        return @intCast(first_id + r.entries.items.len - 1);
    }

    /// The instance registered as `id` (which must be a registered id).
    pub fn get(r: *const FontRegistry, id: InstanceId) *const Registered {
        return &r.entries.items[id - first_id];
    }

    /// True when `id` names a registered instance.
    pub fn has(r: *const FontRegistry, id: InstanceId) bool {
        return id >= first_id and id - first_id < r.entries.items.len;
    }
};
