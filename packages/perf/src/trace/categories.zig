//! Trace categories: the first dotted segment of a zone or span name
//! (`gui.layout` is in `gui`). Sessions filter on them and exporters use
//! them as Perfetto/Chrome categories.

const std = @import("std");

/// A trace category.
pub const Category = enum(u6) {
    gui,
    render,
    gpu,
    platform,
    text,
    editor,
    syntax,
    terminal,
    lsp,
    dap,
    workspace,
    notes,
    scm,
    git,
    ai,
    mcp,
    review,
    agents,
    perf,
    startup,
    mem,
    io,
    net,
    other,

    /// The category of a dotted name (`other` when the prefix is unknown).
    pub fn ofName(name: []const u8) Category {
        const end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
        return std.meta.stringToEnum(Category, name[0..end]) orelse .other;
    }
};

/// A set of categories.
pub const Set = std.EnumSet(Category);

test "categories: ofName" {
    try std.testing.expectEqual(Category.gui, Category.ofName("gui.layout"));
    try std.testing.expectEqual(Category.ai, Category.ofName("ai.request"));
    try std.testing.expectEqual(Category.other, Category.ofName("frame"));
    try std.testing.expectEqual(Category.other, Category.ofName("weird.x"));
}
