//! The screen model (E06.F03): cells, pages, the page list, screens and the
//! print path.

pub const cell = @import("screen/cell.zig");
pub const Cell = cell.Cell;
pub const Row = cell.Row;
pub const style = @import("screen/style.zig");
pub const Style = style.Style;
pub const Color = style.Color;
pub const Page = @import("screen/Page.zig");
pub const hyperlink = @import("screen/hyperlink.zig");
pub const grapheme = @import("screen/grapheme.zig");
pub const PageList = @import("screen/PageList.zig");
pub const Pin = PageList.Pin;
pub const Screen = @import("screen/Screen.zig");
pub const print = @import("screen/print.zig");
pub const reflow = @import("screen/reflow.zig");
pub const cold = @import("screen/cold.zig");
pub const unicode = @import("screen/unicode.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("screen/cellmap.zig");
    _ = @import("screen/fill.zig");
}
