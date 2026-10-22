//! Glyph outlines: the flat `Path` that every outline decoder emits.

const std = @import("std");

pub const path = @import("path.zig");

/// A flat outline in font units.
pub const Path = path.Path;
/// One path command.
pub const Verb = path.Verb;
/// A 2x3 affine map.
pub const Affine = path.Affine;
/// An axis-aligned rectangle.
pub const Rect = path.Rect;

test {
    std.testing.refAllDecls(@This());
}
