//! Diagram rendering (E13.F07.S02.T03): Mermaid flowcharts parsed and
//! laid out by `zg_diagram`, drawn on the vector canvas with theme
//! colours and Mermaid style directives, and exported as SVG. The
//! interactive view and the Markdown fence renderer are in
//! `zg_agents_ui.diagram_view`.

const std = @import("std");

pub const theme = @import("theme.zig");
pub const shapes = @import("shapes.zig");
pub const render_mod = @import("render.zig");
pub const svg_export = @import("svg_export.zig");

pub const DiagramTheme = theme.DiagramTheme;
pub const Estimate = render_mod.Estimate;
pub const LineIter = render_mod.LineIter;
pub const Built = svg_export.Built;
pub const toDisplayList = render_mod.toDisplayList;
pub const render = render_mod.render;
pub const Prepared = svg_export.Prepared;
pub const prepare = svg_export.prepare;
pub const draw = svg_export.draw;
pub const build = svg_export.build;
pub const writeDiagramSvg = svg_export.writeDiagramSvg;
pub const writeSvg = svg_export.writeSvg;

test {
    std.testing.refAllDecls(@This());
    _ = @import("render_test.zig");
}
