//! zg_diagram (E13.F07.S02): diagrams from text — the Mermaid flowchart
//! subset's parser (T01) and layered layout (T02). It imports only std.

const std = @import("std");

pub const ast = @import("ast.zig");
pub const diag = @import("diag.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const layout_mod = @import("layout/root.zig");

pub const Span = ast.Span;
pub const Dir = ast.Dir;
pub const Shape = ast.Shape;
pub const Style = ast.Style;
pub const Node = ast.Node;
pub const EdgeStyle = ast.EdgeStyle;
pub const EdgeEnd = ast.EdgeEnd;
pub const Edge = ast.Edge;
pub const Subgraph = ast.Subgraph;
pub const ClassDef = ast.ClassDef;
pub const LinkStyle = ast.LinkStyle;
pub const Diagram = ast.Diagram;
pub const Diagnostic = diag.Diagnostic;

pub const detectType = parser.detectType;
pub const parse = parser.parse;

pub const Measure = layout_mod.Measure;
pub const LayoutOpts = layout_mod.LayoutOpts;
pub const NodeBox = layout_mod.NodeBox;
pub const EdgePath = layout_mod.EdgePath;
pub const ClusterBox = layout_mod.ClusterBox;
pub const Layout = layout_mod.Layout;
pub const layout = layout_mod.layout;
pub const shapeBoundary = layout_mod.shapeBoundary;

test {
    std.testing.refAllDecls(@This());
    _ = @import("parser_test.zig");
    _ = @import("layout_test.zig");
}
