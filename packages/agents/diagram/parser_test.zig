//! The flowchart parser: the corpus against its AST goldens (run with
//! -Dupdate-golden to rewrite them), error recovery, type detection and
//! a fuzz target.

const std = @import("std");
const options = @import("zg_options");
const ast = @import("ast.zig");
const diag = @import("diag.zig");
const parser = @import("parser.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const corpus_dir = "diagram/testdata/flowchart";

/// The golden text for `src`: the AST as ZON, then each diagnostic as a
/// comment.
fn render(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    const d = try parser.parse(a, src, &diags);
    var w: std.Io.Writer.Allocating = .init(a);
    if (d) |x| try ast.dump(&w.writer, x) else try w.writer.writeAll("null\n");
    for (diags.items) |x| {
        try w.writer.writeAll("// ");
        try diag.format(&w.writer, &.{x});
    }
    // In `zig fmt` form, as the repository's format check wants.
    if (d == null) return w.written();
    const tree = try std.zig.Ast.parse(a, try a.dupeZ(u8, w.written()), .zon);
    try testing.expectEqual(0, tree.errors.len);
    return tree.renderAlloc(a);
}

test "corpus_goldens" {
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, corpus_dir, .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var it = dir.iterate();
    while (try it.next(io)) |e| if (std.mem.endsWith(u8, e.name, ".mmd")) try names.append(a, try a.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    try testing.expect(names.items.len >= 60);
    var failed: usize = 0;
    for (names.items) |name| {
        const src = try dir.readFileAlloc(io, name, a, .limited(1 << 20));
        const got = try render(a, src);
        const golden = try std.fmt.allocPrint(a, "{s}.ast.zon", .{name[0 .. name.len - 4]});
        if (options.update_golden) {
            try dir.writeFile(io, .{ .sub_path = golden, .data = got });
            continue;
        }
        const want = dir.readFileAlloc(io, golden, a, .limited(1 << 20)) catch |e| {
            std.debug.print("{s}: {s} (run with -Dupdate-golden)\n", .{ golden, @errorName(e) });
            failed += 1;
            continue;
        };
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("{s} differs; got:\n{s}\n", .{ golden, got });
            failed += 1;
        }
    }
    try testing.expectEqual(0, failed);
}

const Case = struct { src: []const u8, line: u32, col: u32, msg: []const u8 };

test "error_recovery_table" {
    const cases = [_]Case{
        .{ .src = "flowchart LR\n  A --> \n  B --> C\n", .line = 2, .col = 5, .msg = "a link needs a node after it" },
        .{ .src = "flowchart LR\n  A[unclosed --> B\n  C --> D\n", .line = 2, .col = 4, .msg = "unclosed shape bracket" },
        .{ .src = "flowchart LR\n  A[\"unterminated] --> B\n  C\n", .line = 2, .col = 5, .msg = "unterminated quoted label" },
        .{ .src = "flowchart LR\n  A -- text B\n  C --> D\n", .line = 2, .col = 5, .msg = "link text needs a closing '-->' or '---'" },
        .{ .src = "flowchart LR\n  A -. text B\n", .line = 2, .col = 5, .msg = "link text needs a closing '.->' or '.-'" },
        .{ .src = "flowchart LR\n  A == text B\n", .line = 2, .col = 5, .msg = "link text needs a closing '==>' or '==='" },
        .{ .src = "flowchart LR\n  A -->|label B\n", .line = 2, .col = 8, .msg = "unclosed '|' link label" },
        .{ .src = "flowchart LR\n  A --> end\n", .line = 2, .col = 9, .msg = "'end' cannot be a node id; capitalize a letter (End or END)" },
        .{ .src = "flowchart LR\n  A\n  end\n", .line = 3, .col = 3, .msg = "'end' without an open subgraph" },
        .{ .src = "flowchart LR\n  subgraph s\n    A\n", .line = 2, .col = 3, .msg = "subgraph 's' has no 'end'" },
        .{ .src = "flowchart XY\n  A\n", .line = 1, .col = 11, .msg = "unknown direction 'XY' (use TB, TD, BT, LR or RL)" },
        .{ .src = "flowchart LR\n  A B\n", .line = 2, .col = 5, .msg = "unexpected 'B'; expected a link such as '-->'" },
        .{ .src = "flowchart LR\n  --> B\n", .line = 2, .col = 3, .msg = "expected a node id, found '-'" },
        .{ .src = "flowchart LR\n  style A fill:#12\n", .line = 2, .col = 16, .msg = "invalid colour '#12'" },
        .{ .src = "flowchart LR\n  style A stroke-width:wide\n", .line = 2, .col = 24, .msg = "invalid width 'wide'" },
        .{ .src = "flowchart LR\n  A --> B\n  linkStyle 3 stroke:red\n", .line = 3, .col = 3, .msg = "linkStyle 3: there are only 1 links" },
        .{ .src = "flowchart LR\n  linkStyle x stroke:red\n", .line = 2, .col = 3, .msg = "linkStyle takes edge numbers or 'default', not 'x'" },
        .{ .src = "flowchart LR\n  subgraph a\n  end\n  subgraph a\n  end\n", .line = 4, .col = 3, .msg = "duplicate subgraph id 'a'" },
        .{ .src = "flowchart LR\n  A@{ shape: rect\n", .line = 2, .col = 4, .msg = "unclosed '@{'" },
        .{ .src = "flowchart LR\n  A <--- B\n", .line = 2, .col = 5, .msg = "a link with an end at its start needs one at its end too" },
    };
    for (cases) |cs| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var diags: std.ArrayList(diag.Diagnostic) = .empty;
        const d = try parser.parse(arena.allocator(), cs.src, &diags);
        var found = false;
        for (diags.items) |x| found = found or (x.severity == .err and x.line == cs.line and x.col == cs.col and std.mem.eql(u8, x.message, cs.msg));
        if (!found) {
            std.debug.print("case {s}\nwanted {d}:{d}: {s}\ngot:\n", .{ cs.src, cs.line, cs.col, cs.msg });
            for (diags.items) |x| std.debug.print("  {d}:{d}: {s}\n", .{ x.line, x.col, x.message });
            return error.TestUnexpectedResult;
        }
        // Parsing goes on: a diagram comes back.
        try testing.expect(d != null);
    }

    // Recovery keeps the statements after a bad line.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    const d = (try parser.parse(arena.allocator(), "flowchart LR\n  A --> \n  B[x --> C\n  D --> E\n", &diags)).?;
    try testing.expectEqual(2, diags.items.len);
    try testing.expectEqual(1, d.edges.len);
    try testing.expectEqualStrings("D", d.nodes[d.edges[0].from].id);

    // No header, no diagram.
    diags.clearRetainingCapacity();
    try testing.expectEqual(null, try parser.parse(arena.allocator(), "A --> B\n", &diags));
    try testing.expectEqualStrings("expected 'flowchart' or 'graph', found 'A'", diags.items[0].message);
    diags.clearRetainingCapacity();
    try testing.expectEqual(null, try parser.parse(arena.allocator(), "sequenceDiagram\n  A->>B: hi\n", &diags));
    try testing.expectEqualStrings("'sequenceDiagram' diagrams are not supported; only flowcharts are", diags.items[0].message);
    diags.clearRetainingCapacity();
    try testing.expectEqual(null, try parser.parse(arena.allocator(), "---\ntitle: x\n", &diags));
    try testing.expectEqualStrings("unclosed frontmatter: no closing '---'", diags.items[0].message);
}

test "detect_type_table" {
    const cases = [_]struct { []const u8, parser.DiagramType }{
        .{ "flowchart LR\nA-->B", .flowchart },
        .{ "graph TD;A-->B", .flowchart },
        .{ "\n\n  %% comment\nflowchart", .flowchart },
        .{ "---\ntitle: t\n---\ngraph", .flowchart },
        .{ "%%{init: {}}%%\nflowchart TB", .flowchart },
        .{ "sequenceDiagram\nA->>B: x", .unsupported },
        .{ "classDiagram\n", .unsupported },
        .{ "stateDiagram-v2\n", .unsupported },
        .{ "erDiagram\n", .unsupported },
        .{ "gantt\n", .unsupported },
        .{ "pie title Pets\n", .unsupported },
        .{ "mindmap\n", .unsupported },
        .{ "gitGraph\n", .unsupported },
        .{ "hello world", .unknown },
        .{ "", .unknown },
        .{ "---\ntitle: x\n", .unknown },
    };
    for (cases) |c| try testing.expectEqual(c[1], parser.detectType(c[0]));
}

test "labels" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("plain", try parser.labelText(a, " plain "));
    try testing.expectEqualStrings("a (b)", try parser.labelText(a, "\"a (b)\""));
    try testing.expectEqualStrings("one\ntwo", try parser.labelText(a, "one<br/>two"));
    try testing.expectEqualStrings("say \"hi\" #1", try parser.labelText(a, "say #quot;hi#quot; #35;1"));
    try testing.expectEqualStrings("♥", try parser.labelText(a, "#9829;"));
    try testing.expectEqualStrings("#notanentity", try parser.labelText(a, "#notanentity"));
    try testing.expectEqualStrings("Bold text\nnext", try parser.labelText(a, "\"`**Bold** text\n   next`\""));
    try testing.expectEqual(@as(?u32, 0xffff99ff), parser.parseColor("#f9f"));
    try testing.expectEqual(@as(?u32, 0x44112233), parser.parseColor("#11223344"));
    try testing.expectEqual(@as(?u32, 0xffff0000), parser.parseColor("Red"));
    try testing.expectEqual(@as(?u32, 0), parser.parseColor("none"));
    try testing.expectEqual(null, parser.parseColor("#12"));
}

test "limits" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("flowchart LR\n");
    for (0..parser.max_nodes + 10) |i| try w.writer.print("n{d}\n", .{i});
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    const d = (try parser.parse(a, w.written(), &diags)).?;
    try testing.expectEqual(parser.max_nodes, d.nodes.len);
    try testing.expectEqualStrings("too many nodes (the limit is 5000)", diags.items[0].message);
}

/// `n` nodes in rows with two edges each (300 nodes, 600 edges: the
/// 1 ms budget's size).
pub fn sample(a: std.mem.Allocator, n: usize) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("flowchart TB\n");
    for (0..n) |i| try w.writer.print("  n{d}[\"Step {d}\"] --> n{d}\n  n{d} -.->|retry| n{d}\n", .{ i, i, (i + 1) % n, i, (i * 7 + 3) % n });
    return w.written();
}

test "300 nodes and 600 edges" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src = try sample(arena.allocator(), 300);
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    const d = (try parser.parse(arena.allocator(), src, &diags)).?;
    try testing.expectEqual(0, diags.items.len);
    try testing.expectEqual(300, d.nodes.len);
    try testing.expectEqual(600, d.edges.len);
}

test "fuzz_flowchart_parse" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const n = s.slice(&buf);
            // Half the inputs start with a header so the parser gets past it.
            var src_buf: [600]u8 = undefined;
            const hdr = "flowchart LR\n";
            const src = if (n > 0 and buf[0] & 1 == 0) blk: {
                @memcpy(src_buf[0..hdr.len], hdr);
                @memcpy(src_buf[hdr.len..][0..n], buf[0..n]);
                break :blk src_buf[0 .. hdr.len + n];
            } else buf[0..n];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var diags: std.ArrayList(diag.Diagnostic) = .empty;
            _ = parser.detectType(src);
            const d = try parser.parse(arena.allocator(), src, &diags) orelse return;
            // Every index is in range.
            for (d.edges) |e| {
                try testing.expect(e.from < if (e.from_kind == .node) d.nodes.len else d.subgraphs.len);
                try testing.expect(e.to < if (e.to_kind == .node) d.nodes.len else d.subgraphs.len);
            }
            for (d.subgraphs) |sg| {
                for (sg.members) |m| try testing.expect(m < d.nodes.len);
                for (sg.children) |c| try testing.expect(c < d.subgraphs.len);
            }
            for (diags.items) |x| try testing.expect(x.span.start <= x.span.end and x.span.end <= src.len);
        }
    }.one, .{ .corpus = &.{ "A --> B", "subgraph s\nA -->|x| B\nend", "A[\"`**b**`\"] -.-> B{{h}}", "style A fill:#fff", "A -- t --> B & C" } });
}
