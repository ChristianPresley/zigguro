//! Twenty reference diagrams rendered to SVG goldens (every shape, edge
//! style and end, clusters, class and style directives, all four
//! directions), determinism, and the two ways a fence can't be drawn.

const std = @import("std");
const dr = @import("root.zig");
const vector = @import("../vector/root.zig");

const testing = std.testing;
const gpa = testing.allocator;

const Ref = struct { name: []const u8, src: []const u8 };

const refs = [_]Ref{
    .{ .name = "basic", .src =
    \\flowchart TD
    \\  A[Start] --> B{Is it?}
    \\  B -->|Yes| C[OK]
    \\  C --> D[Rethink]
    \\  D --> B
    \\  B ---->|No| E[End]
    },
    .{ .name = "shapes_a", .src =
    \\flowchart LR
    \\  a[rect] --> b(round) --> c([stadium]) --> d[[subroutine]]
    \\  d --> e[(cylinder)] --> f((circle)) --> g(((double)))
    },
    .{ .name = "shapes_b", .src =
    \\flowchart LR
    \\  a>flag] --> b{rhombus} --> c{{hexagon}}
    \\  c --> d[/lean right/] --> e[\lean left\]
    \\  e --> f[/trapezoid\] --> g[\trapezoid alt/]
    },
    .{ .name = "edge_styles", .src =
    \\flowchart TB
    \\  a --> b
    \\  a --- c
    \\  a -.-> d
    \\  a ==> e
    \\  a ~~~ f
    \\  b -.- g
    \\  c === h
    },
    .{ .name = "edge_ends", .src =
    \\flowchart LR
    \\  a --o b
    \\  a --x c
    \\  a <--> d
    \\  a o--o e
    \\  a x--x f
    },
    .{ .name = "edge_labels", .src =
    \\flowchart TB
    \\  a -- text on the edge --> b
    \\  a -->|pipe label| c
    \\  b -. dotted label .-> d
    \\  c == thick label ==> d
    },
    .{ .name = "cluster", .src =
    \\flowchart TB
    \\  c1 --> a2
    \\  subgraph one
    \\    a1 --> a2
    \\  end
    \\  subgraph two
    \\    b1 --> b2
    \\  end
    \\  subgraph three
    \\    c1 --> c2
    \\  end
    },
    .{ .name = "nested_clusters", .src =
    \\flowchart LR
    \\  subgraph outer [Outer box]
    \\    subgraph inner [Inner box]
    \\      x --> y
    \\    end
    \\    y --> z
    \\  end
    \\  start --> x
    \\  z --> stop
    },
    .{ .name = "cluster_edges", .src =
    \\flowchart TB
    \\  subgraph s1 [First]
    \\    a --> b
    \\  end
    \\  subgraph s2 [Second]
    \\    c --> d
    \\  end
    \\  s1 --> s2
    \\  b --> c
    },
    .{ .name = "classdef", .src =
    \\flowchart LR
    \\  a:::hot --> b --> c
    \\  classDef hot fill:#f96,stroke:#333,stroke-width:3px,color:#fff
    \\  classDef cool fill:#9cf,stroke-dasharray: 4 2
    \\  class b,c cool
    },
    .{ .name = "style", .src =
    \\flowchart TB
    \\  a --> b
    \\  style a fill:#bbf,stroke:#f66,stroke-width:2px,color:#000
    \\  style b fill:none,stroke:#0a0
    },
    .{ .name = "linkstyle", .src =
    \\flowchart LR
    \\  a --> b --> c
    \\  a --> c
    \\  linkStyle default stroke:#888
    \\  linkStyle 1 stroke:#e33,stroke-width:3px
    \\  linkStyle 2 stroke-dasharray: 5 5
    },
    .{ .name = "default_class", .src =
    \\flowchart TB
    \\  a --> b
    \\  classDef default fill:#fff4dd,stroke:#c90
    },
    .{ .name = "dir_bt", .src =
    \\flowchart BT
    \\  a --> b --> c
    \\  a --> c
    },
    .{ .name = "dir_rl", .src =
    \\flowchart RL
    \\  a[Input] --> b(Process) --> c[Output]
    \\  b --> d[(Log)]
    },
    .{ .name = "cycle", .src =
    \\flowchart TB
    \\  a --> b --> c --> a
    \\  c --> d
    },
    .{ .name = "self_loop", .src =
    \\flowchart LR
    \\  a --> a
    \\  a -->|again| b
    \\  b -->|retry| b
    },
    .{ .name = "multiline", .src =
    \\flowchart TB
    \\  a["A label that is long enough to wrap onto more than one line in the box"] --> b["two<br>lines"]
    \\  b --> c["Escapes & <tags>"]
    },
    .{ .name = "fan", .src =
    \\graph TD
    \\  root --> a & b & c & d
    \\  a & b --> m
    \\  c & d --> n
    \\  m & n --> sink
    },
    .{ .name = "title", .src =
    \\---
    \\title: Release flow
    \\---
    \\flowchart LR
    \\  dev[Develop] --> review{Review}
    \\  review -->|approved| ship([Ship])
    \\  review -->|changes| dev
    },
};

fn svgOf(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    var e: dr.Estimate = .{};
    var w: std.Io.Writer.Allocating = .init(a);
    try testing.expect(try dr.writeDiagramSvg(&w.writer, src, .light, e.measure()));
    return w.written();
}

test "svg_goldens" {
    try testing.expectEqual(20, refs.len);
    inline for (refs) |ref| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const svg = try svgOf(arena.allocator(), ref.src);
        try @import("zg_core").testkit.golden.expectGoldenOpts(testing.io, @src(), ref.name ++ ".svg", svg, .{ .root = @import("zg_options").package_root, .dir = "testdata/diagram_render", .normalize = .exact });
    }
}

test "display_list_deterministic" {
    for (refs) |ref| {
        var a1: std.heap.ArenaAllocator = .init(gpa);
        defer a1.deinit();
        var a2: std.heap.ArenaAllocator = .init(gpa);
        defer a2.deinit();
        var e: dr.Estimate = .{};
        const b1 = try dr.build(a1.allocator(), ref.src, .dark, e.measure());
        const b2 = try dr.build(a2.allocator(), ref.src, .dark, e.measure());
        try testing.expectEqual(b1.ok.list.hash, b2.ok.list.hash);
        try testing.expectEqual(b1.ok.list.items.len, b2.ok.list.items.len);
        // Another theme draws the same geometry in other colours.
        var a3: std.heap.ArenaAllocator = .init(gpa);
        defer a3.deinit();
        const b3 = try dr.build(a3.allocator(), ref.src, .light, e.measure());
        try testing.expect(b3.ok.list.hash != b1.ok.list.hash);
        try testing.expectEqual(b1.ok.list.items.len, b3.ok.list.items.len);
    }
}

test "every node, edge and cluster is drawn" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var e: dr.Estimate = .{};
    const b = try dr.build(arena.allocator(), refs[8].src, .light, e.measure());
    const ok = b.ok;
    var texts: usize = 0;
    var fills: usize = 0;
    for (ok.list.items) |it| switch (it) {
        .text => texts += 1,
        .fill => fills += 1,
        else => {},
    };
    // Four node labels and two cluster titles; four node and two
    // cluster fills, plus arrowheads.
    try testing.expectEqual(6, texts);
    try testing.expect(fills >= 6 + ok.diagram.edges.len);
}

test "unsupported_type_shows_source_notice" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var e: dr.Estimate = .{};
    const src = "sequenceDiagram\n  Alice->>Bob: Hi\n";
    try testing.expect(try dr.build(arena.allocator(), src, .light, e.measure()) == .unsupported);
    var w: std.Io.Writer.Allocating = .init(arena.allocator());
    try testing.expect(!try dr.writeDiagramSvg(&w.writer, src, .light, e.measure()));
    try testing.expectEqual(0, w.written().len);
}

test "parse_error_shows_line_col" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var e: dr.Estimate = .{};
    const b = try dr.build(arena.allocator(), "flowchart TB\n  a --> b\n  c -->\n", .light, e.measure());
    const errs = b.errors;
    try testing.expect(errs.len >= 1);
    try testing.expectEqual(3, errs[0].line);
    try testing.expect(errs[0].col >= 3);
    try testing.expect(errs[0].message.len > 0);
}

test "svg escapes label text" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const svg = try svgOf(arena.allocator(), refs[17].src);
    try testing.expect(std.mem.indexOf(u8, svg, "Escapes &amp; &lt;tags&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, svg, ">two</text>") != null);
    try testing.expect(std.mem.indexOf(u8, svg, ">lines</text>") != null);
}
