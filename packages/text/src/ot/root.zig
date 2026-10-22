//! OpenType binary parsing. Every table view borrows the font bytes.

const std = @import("std");

pub const reader = @import("reader.zig");
pub const sfnt = @import("sfnt.zig");
pub const face = @import("face.zig");
pub const cmap = @import("cmap.zig");
pub const head = @import("head.zig");
pub const hhea = @import("hhea.zig");
pub const hmtx = @import("hmtx.zig");
pub const maxp = @import("maxp.zig");
pub const os2 = @import("os2.zig");
pub const post = @import("post.zig");
pub const name = @import("name.zig");
pub const glyf = @import("glyf.zig");
pub const cff = @import("cff.zig");
pub const cff_charstring = @import("cff_charstring.zig");
pub const variation = @import("var/root.zig");
/// CBLC/CBDT colour bitmap strikes.
pub const cbdt = @import("cbdt.zig");
/// sbix bitmap strikes.
pub const sbix = @import("sbix.zig");
/// COLR v0/v1 colour glyphs.
pub const colr = @import("colr.zig");
/// CPAL colour palettes.
pub const cpal = @import("cpal.zig");
/// Shared GSUB/GPOS structures: coverage, class defs, scripts, features, lookups.
pub const layout_common = @import("layout_common.zig");
/// Glyph definition table.
pub const gdef = @import("gdef.zig");

/// A glyph index; 0 is `.notdef`.
pub const GlyphId = reader.GlyphId;
/// A big-endian four-character code.
pub const Tag = reader.Tag;
/// The `Tag` of a four-character string.
pub const tag = reader.tag;
/// Bounds-checked big-endian reader.
pub const Reader = reader.Reader;
/// One face over borrowed bytes.
pub const Face = face.Face;
/// Font-wide metrics in design units.
pub const FontMetrics = face.FontMetrics;
/// Style attributes for matching.
pub const Style = face.Style;
/// A read-only memory-mapped font file.
pub const MappedFont = face.MappedFont;
/// Located tables of one face.
pub const TableDir = sfnt.TableDir;
/// The naming table.
pub const NameTable = name.NameTable;
/// Well-known name IDs.
pub const NameId = name.NameId;

test {
    std.testing.refAllDecls(@This());
}
