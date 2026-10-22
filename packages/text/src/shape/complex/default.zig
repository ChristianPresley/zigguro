//! The default shaper (scripts without reordering or joining) and the
//! choice of complex shaper for a script.

const plan = @import("../plan.zig");
const ComplexShaper = plan.ComplexShaper;
const Script = @import("../../unicode/root.zig").Script;
const ot = @import("../../ot/root.zig");
const arabic = @import("arabic.zig");
const use = @import("use.zig");
const khmer = @import("khmer.zig");
const myanmar = @import("myanmar.zig");

/// No script-specific features; marks are zeroed by GDEF after GPOS.
pub const shaper: ComplexShaper = .{ .name = "default" };

/// The complex shaper for `script`, given the GSUB script tag the plan
/// chose (null when the font has none), as HarfBuzz picks it. Arabic always
/// uses the Arabic shaper; Syriac only when the font has a script record
/// other than `DFLT`. The USE scripts use USE unless the font only has
/// `DFLT` or `latn` for them; the Indic scripts use USE with their `xxx3`
/// tags and the default shaper otherwise until the Indic shaper lands.
/// Khmer always uses its shaper; Myanmar uses its shaper unless the font
/// only has `DFLT`, `latn` or the old `mymr` tag.
pub fn select(script: Script, chosen_gsub: ?ot.Tag) *const ComplexShaper {
    const generic = if (chosen_gsub) |t| t == ot.tag("DFLT") or t == ot.tag("latn") else false;
    return switch (script) {
        .Arab => &arabic.shaper,
        .Syrc => if (chosen_gsub) |t| (if (t != ot.tag("DFLT")) &arabic.shaper else &shaper) else &shaper,
        .Khmr => &khmer.shaper,
        .Mymr => if (chosen_gsub) |t| (if (generic or t == ot.tag("mymr")) &shaper else &myanmar.shaper) else &myanmar.shaper,
        .Beng, .Deva, .Gujr, .Guru, .Knda, .Mlym, .Orya, .Taml, .Telu => if (chosen_gsub) |t| (if (!generic and t & 0xFF == '3') &use.shaper else &shaper) else &shaper,
        else => if (isUseScript(script) and !generic) &use.shaper else &shaper,
    };
}

/// HarfBuzz's USE scripts.
pub fn isUseScript(s: Script) bool {
    return switch (s) {
        .Tibt, .Mong, .Sinh, .Buhd, .Hano, .Tglg, .Tagb, .Limb, .Tale, .Bugi, .Khar, .Sylo, .Tfng, .Bali, .Nkoo, .Phag => true,
        .Cham, .Kali, .Lepc, .Rjng, .Saur, .Sund, .Egyp, .Java, .Kthi, .Mtei, .Lana, .Tavt, .Batk, .Brah, .Mand => true,
        .Cakm, .Plrd, .Shrd, .Takr, .Dupl, .Gran, .Khoj, .Sind, .Mahj, .Mani, .Modi, .Hmng, .Phlp, .Sidd, .Tirh => true,
        .Ahom, .Mult, .Adlm, .Bhks, .Marc, .Newa, .Gonm, .Soyo, .Zanb, .Dogr, .Gong, .Rohg, .Maka, .Medf, .Sogo, .Sogd => true,
        .Elym, .Nand, .Hmnp, .Wcho, .Chrs, .Diak, .Kits, .Yezi, .Cpmn, .Ougr, .Tnsa, .Toto, .Vith, .Kawi, .Nagm => true,
        .Gara, .Gukh, .Krai, .Onao, .Sunu, .Todr, .Tutg, .Berf, .Sidt, .Tayo, .Tols, .Jurc, .Pcun, .Seal => true,
        else => false,
    };
}
