//! Font variations: fvar/avar normalization, the shared delta stores,
//! HVAR/MVAR, and `FaceInstance`.

const std = @import("std");

pub const ivs = @import("ivs.zig");
pub const fvar = @import("fvar.zig");
pub const avar = @import("avar.zig");
pub const hvar = @import("hvar.zig");
pub const mvar = @import("mvar.zig");
pub const instance = @import("instance.zig");

/// Normalized F2Dot14 coordinates, one per axis.
pub const VarCoords = ivs.VarCoords;
/// A variation axis in user units.
pub const Axis = fvar.Axis;
/// A user-space axis setting.
pub const AxisValue = fvar.AxisValue;
/// One face at one variation position.
pub const FaceInstance = instance.FaceInstance;
/// Font-wide metrics at an instance.
pub const FontMetricsF = instance.FontMetricsF;
/// Named instances of a face.
pub const namedInstances = instance.namedInstances;

test {
    std.testing.refAllDecls(@This());
    _ = @import("var_test.zig");
}
