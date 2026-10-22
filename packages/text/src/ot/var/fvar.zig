//! `fvar` (axes and named instances) and the normalization of user
//! coordinates into F2Dot14 `VarCoords` (then remapped by `avar`).

const std = @import("std");
const reader = @import("../reader.zig");
const Tag = reader.Tag;

const Avar = @import("avar.zig").Avar;

/// The largest axis count an instance supports. The COLRv1 conformance
/// font has 44 axes, so this is above the 16 the design first assumed.
pub const max_axes = 64;

/// One variation axis, in user units.
pub const Axis = struct {
    tag: Tag,
    min: f32,
    default: f32,
    max: f32,
    /// `name` ID of the axis name.
    name_id: u16,
    /// HIDDEN_AXIS: not meant for user interfaces.
    hidden: bool,
};

/// A user-space axis setting, e.g. `.{ .tag = tag("wght"), .value = 700 }`.
pub const AxisValue = struct { tag: Tag, value: f32 };

fn fixed(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 65536.0;
}

/// A view of `fvar`.
pub const Fvar = struct {
    data: []const u8,
    axes_off: u16,
    axis_count: u16,
    axis_size: u16,
    instance_count: u16,
    instance_size: u16,

    /// Validates the header and that axes and instances fit.
    pub fn init(bytes: []const u8) error{Malformed}!Fvar {
        var r = try reader.Reader.at(bytes, 0);
        if (try r.u16_() != 1) return error.Malformed;
        _ = try r.u16_();
        const off = try r.u16_();
        _ = try r.u16_();
        const f: Fvar = .{
            .data = bytes,
            .axes_off = off,
            .axis_count = try r.u16_(),
            .axis_size = try r.u16_(),
            .instance_count = try r.u16_(),
            .instance_size = try r.u16_(),
        };
        if (f.axis_size < 20 or f.instance_size < 4 + 4 * @as(usize, f.axis_count)) return error.Malformed;
        if (f.axis_count > max_axes) return error.Malformed;
        const total = @as(usize, f.axis_count) * f.axis_size + @as(usize, f.instance_count) * f.instance_size;
        _ = try reader.subLen(bytes, off, total);
        return f;
    }

    /// Axis `i` (< `axis_count`).
    pub fn axis(f: *const Fvar, i: usize) Axis {
        const a = f.data[f.axes_off + i * f.axis_size ..][0..20];
        const lo = fixed(std.mem.readInt(i32, a[4..8], .big));
        const def = fixed(std.mem.readInt(i32, a[8..12], .big));
        const hi = fixed(std.mem.readInt(i32, a[12..16], .big));
        return .{
            .tag = std.mem.readInt(u32, a[0..4], .big),
            // Repair inverted ranges as the spec asks: treat min/max as the default.
            .min = @min(lo, def),
            .default = def,
            .max = @max(hi, def),
            .name_id = std.mem.readInt(u16, a[18..20], .big),
            .hidden = std.mem.readInt(u16, a[16..18], .big) & 1 != 0,
        };
    }

    /// Index of the axis with `t`, if any.
    pub fn axisIndex(f: *const Fvar, t: Tag) ?usize {
        for (0..f.axis_count) |i| if (f.axis(i).tag == t) return i;
        return null;
    }

    /// Iterates the named instances.
    pub fn namedInstances(f: Fvar) NamedInstanceIterator {
        return .{ .f = f };
    }
};

/// A named instance ("Bold", "Light Condensed", ...).
pub const NamedInstance = struct {
    subfamily_name_id: u16,
    /// `name` ID of the PostScript name, when the record has one.
    postscript_name_id: ?u16,
    /// Big-endian Fixed user coordinates, one per axis.
    coords_raw: []const u8,

    /// User coordinate of axis `i` (`i` < the face's axis count).
    pub fn coord(n: NamedInstance, i: usize) f32 {
        return fixed(std.mem.readInt(i32, n.coords_raw[i * 4 ..][0..4], .big));
    }
};

/// Iterator over `fvar` named instances.
pub const NamedInstanceIterator = struct {
    /// Null iterates nothing (a face without `fvar`).
    f: ?Fvar,
    i: u16 = 0,

    /// The next instance, or null.
    pub fn next(it: *NamedInstanceIterator) ?NamedInstance {
        const f = it.f orelse return null;
        if (it.i >= f.instance_count) return null;
        const base = f.axes_off + @as(usize, f.axis_count) * f.axis_size + @as(usize, it.i) * f.instance_size;
        it.i += 1;
        const rec = f.data[base..][0..f.instance_size];
        const coords_len = 4 * @as(usize, f.axis_count);
        return .{
            .subfamily_name_id = std.mem.readInt(u16, rec[0..2], .big),
            .postscript_name_id = if (f.instance_size >= coords_len + 6) std.mem.readInt(u16, rec[4 + coords_len ..][0..2], .big) else null,
            .coords_raw = rec[4..][0..coords_len],
        };
    }
};

/// Default normalization of a user value (clamped, then piecewise linear
/// around the default) to F2Dot14, rounding half away from zero.
pub fn normalizeAxis(a: Axis, value: f32) i16 {
    const v: f64 = std.math.clamp(value, a.min, a.max);
    const def: f64 = a.default;
    const n: f64 = if (v < def)
        -(def - v) / (def - a.min)
    else if (v > def)
        (v - def) / (a.max - def)
    else
        0;
    return @intFromFloat(@round(n * 16384.0));
}

/// Normalizes `user` settings against `fvar` (and `avar` when given) into
/// `out[0..axis_count]`. Axes without a setting stay at their default;
/// settings for unknown tags are ignored.
pub fn normalize(f: *const Fvar, av: ?*const Avar, user: []const AxisValue, out: []i16) void {
    for (0..f.axis_count) |i| {
        const a = f.axis(i);
        var c: i16 = 0;
        for (user) |u| if (u.tag == a.tag) {
            c = normalizeAxis(a, u.value);
        };
        out[i] = if (av) |m| m.map(i, c) else c;
    }
}
