//! The default shaper (scripts without reordering or joining) and the
//! choice of complex shaper for a script.

const plan = @import("../plan.zig");
const ComplexShaper = plan.ComplexShaper;
const Script = @import("../../unicode/root.zig").Script;

/// No script-specific features; marks are zeroed by GDEF after GPOS.
pub const shaper: ComplexShaper = .{ .name = "default" };

/// The complex shaper for `script`.
pub fn select(script: Script) *const ComplexShaper {
    _ = script;
    return &shaper;
}
