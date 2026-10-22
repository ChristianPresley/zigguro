//! The default shaper (scripts without reordering or joining) and the
//! choice of complex shaper for a script.

const plan = @import("../plan.zig");
const ComplexShaper = plan.ComplexShaper;
const Script = @import("../../unicode/root.zig").Script;
const ot = @import("../../ot/root.zig");
const arabic = @import("arabic.zig");

/// No script-specific features; marks are zeroed by GDEF after GPOS.
pub const shaper: ComplexShaper = .{ .name = "default" };

/// The complex shaper for `script`, given the GSUB script tag the plan
/// chose (null when the font has none). Arabic always uses the Arabic
/// shaper; Syriac only when the font has a script record other than
/// `DFLT`, as in HarfBuzz. The other Arabic-joining scripts use it too
/// until the Universal Shaping Engine lands.
pub fn select(script: Script, chosen_gsub: ?ot.Tag) *const ComplexShaper {
    return switch (script) {
        .Arab => &arabic.shaper,
        .Syrc => if (chosen_gsub) |t| (if (t != ot.tag("DFLT")) &arabic.shaper else &shaper) else &shaper,
        .Nkoo, .Mong, .Mand, .Mani, .Phlp, .Rohg, .Adlm => &arabic.shaper,
        else => &shaper,
    };
}
