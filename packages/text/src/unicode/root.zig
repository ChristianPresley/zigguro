//! Unicode properties and algorithms over tables generated at build time
//! from the vendored UCD (tools/ucdgen).

const std = @import("std");
const p = @import("props.zig");

pub const props_mod = p;
pub const Props = p.Props;
pub const Aux = p.Aux;
pub const GeneralCategory = p.GeneralCategory;
pub const GraphemeBreak = p.GraphemeBreak;
pub const IndicConjunctBreak = p.IndicConjunctBreak;
pub const WordBreak = p.WordBreak;
pub const LineBreak = p.LineBreak;
pub const BidiClass = p.BidiClass;
pub const BracketType = p.BracketType;
pub const EastAsianWidth = p.EastAsianWidth;
pub const Script = p.Script;
pub const JoiningType = p.JoiningType;
pub const QuickCheck = p.QuickCheck;
pub const IndicSyllabic = p.IndicSyllabic;
pub const IndicPositional = p.IndicPositional;
pub const CaseKind = p.CaseKind;
pub const Mapping = p.Mapping;
pub const Decomposition = p.Decomposition;
pub const IndicCategories = p.IndicCategories;
pub const unicode_version = p.unicode_version;
pub const props = p.props;
pub const aux = p.aux;
pub const scriptExtensions = p.scriptExtensions;
pub const mirror = p.mirror;
pub const pairedBracket = p.pairedBracket;
pub const indicCategories = p.indicCategories;
pub const isEmojiVariationBase = p.isEmojiVariationBase;
pub const decomposition = p.decomposition;
pub const decomposeCanonical = p.decomposeCanonical;
pub const decomposeCompat = p.decomposeCompat;
pub const compose = p.compose;
pub const caseFoldFull = p.caseFoldFull;
pub const caseFoldSimple = p.caseFoldSimple;
pub const caseMapSimple = p.caseMapSimple;
pub const caseMapFull = p.caseMapFull;
pub const isCased = p.isCased;
pub const isCaseIgnorable = p.isCaseIgnorable;

/// UAX #29 extended grapheme clusters.
pub const grapheme = @import("grapheme.zig");
/// UAX #29 word boundaries.
pub const word = @import("word.zig");
/// UAX #14 line-break opportunities.
pub const line_break = @import("line_break.zig");
/// Script runs (Script_Extensions, brackets) for shaping.
pub const script = @import("script.zig");
/// UAX #9 bidirectional algorithm.
pub const bidi = @import("bidi.zig");
/// Display width in terminal cells.
pub const width = @import("width.zig");
/// Case folding.
pub const casefold = @import("casefold.zig");
/// Case mapping and case shapes.
pub const casemap = @import("casemap.zig");
/// Normalization forms (UAX #15).
pub const normalize = @import("normalize.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("decode.zig");
    _ = @import("case_test.zig");
}
