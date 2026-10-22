//! Graph lane layout tests: golden ASCII renders of the fixture DAGs in
//! `testdata/graph_layout/`, incremental against full layouts, column
//! counts, overflow, and a property test over random DAGs.
//!
//! Fixture format: `#` comments, optional `!max_columns=N`, `!straight=0`
//! and `!collapse=0` option lines, then one commit per line, children
//! first: `name [kind]: parent ~elided-parent ...`. The expected render
//! follows a `====` line. A fixture without one gets its render written
//! and the test fails, so new goldens are reviewed before they pass.

const std = @import("std");
const options = @import("zg_options");
const layout = @import("layout.zig");
const GraphNodeIn = layout.GraphNodeIn;
const Layout = layout.Layout;
const Pos = layout.Pos;
const Allocator = std.mem.Allocator;
const t = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    nodes: []GraphNodeIn,
    names: []const []const u8,
    opts: layout.LayoutOptions,
    expected: ?[]const u8,

    fn deinit(f: *Fixture) void {
        f.arena_state.deinit();
    }
};

fn parseFixture(gpa: Allocator, text: []const u8) !Fixture {
    var f: Fixture = .{ .arena_state = .init(gpa), .nodes = &.{}, .names = &.{}, .opts = .{}, .expected = null };
    errdefer f.deinit();
    const a = f.arena_state.allocator();
    var body = text;
    if (std.mem.indexOf(u8, text, "====\n")) |sep| {
        body = text[0..sep];
        f.expected = text[sep + 5 ..];
    }
    var names: std.ArrayList([]const u8) = .empty;
    const Line = struct { kind: layout.NodeKind, parents: []const []const u8 };
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " ");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '!') {
            const eq = std.mem.indexOfScalar(u8, line, '=').?;
            const v = try std.fmt.parseInt(u16, line[eq + 1 ..], 10);
            const key = line[1..eq];
            if (std.mem.eql(u8, key, "max_columns")) f.opts.max_columns = v else if (std.mem.eql(u8, key, "straight")) f.opts.prefer_first_parent_straight = v != 0 else if (std.mem.eql(u8, key, "collapse")) f.opts.collapse_elided = v != 0 else return error.BadFixture;
            continue;
        }
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadFixture;
        var head = std.mem.tokenizeScalar(u8, line[0..colon], ' ');
        var name = head.next() orelse return error.BadFixture;
        var kind: layout.NodeKind = .normal;
        if (std.mem.endsWith(u8, name, "@")) {
            name = name[0 .. name.len - 1];
            kind = .wc;
        } else if (std.mem.endsWith(u8, name, "#")) {
            name = name[0 .. name.len - 1];
            kind = .immutable;
        }
        if (head.next()) |k| kind = if (std.mem.eql(u8, k, "elided")) .elided_marker else std.meta.stringToEnum(layout.NodeKind, k) orelse return error.BadFixture;
        var ps: std.ArrayList([]const u8) = .empty;
        var pt = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
        while (pt.next()) |p| try ps.append(a, p);
        try names.append(a, name);
        try lines.append(a, .{ .kind = kind, .parents = ps.items });
    }
    // Names map to positions; undisplayed parents get positions past the
    // displayed ones.
    var ids: std.StringArrayHashMapUnmanaged(u32) = .empty;
    for (names.items, 0..) |n, i| try ids.put(a, n, @intCast(i));
    const nodes = try a.alloc(GraphNodeIn, names.items.len);
    for (nodes, names.items, lines.items) |*node, n, l| {
        var vis: std.ArrayList(Pos) = .empty;
        var eli: std.ArrayList(Pos) = .empty;
        for (l.parents) |p| {
            const elided = p[0] == '~';
            const pn = if (elided) p[1..] else p;
            const gop = try ids.getOrPut(a, pn);
            if (!gop.found_existing) gop.value_ptr.* = @intCast(ids.count() - 1);
            try (if (elided) &eli else &vis).append(a, @enumFromInt(gop.value_ptr.*));
        }
        node.* = .{ .id = @enumFromInt(ids.get(n).?), .parents = vis.items, .elided_parents = eli.items, .kind = l.kind };
    }
    f.nodes = nodes;
    f.names = names.items;
    return f;
}

fn render(gpa: Allocator, l: *const Layout, f: *const Fixture) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try layout.renderLabeled(l, f.nodes, &out.writer, .ascii, f.names);
    return out.toOwnedSlice();
}

fn expectSameLayout(a: *const Layout, b: *const Layout) !void {
    try t.expectEqual(a.rows.len, b.rows.len);
    try t.expectEqual(a.width, b.width);
    for (a.rows, b.rows) |x, y| {
        try t.expectEqual(x.node_col, y.node_col);
        try t.expectEqualSlices(layout.Edge, x.edges_out, y.edges_out);
        try t.expectEqualSlices(layout.Lane, x.edges_through, y.edges_through);
    }
}

/// Follows every edge of every commit down the rows to the commit it
/// reaches, which must be one of its parents, and checks each displayed
/// parent is reached exactly once. Overflow lanes are not followed.
fn checkEdges(gpa: Allocator, l: *const Layout, nodes: []const GraphNodeIn, max_columns: u16) !void {
    var row_of: std.AutoHashMapUnmanaged(Pos, usize) = .empty;
    defer row_of.deinit(gpa);
    for (nodes, 0..) |n, i| try row_of.put(gpa, n.id, i);
    const ovf = max_columns - 1;
    for (l.rows, nodes, 0..) |row, n, i| {
        var reached: std.ArrayList(Pos) = .empty;
        defer reached.deinit(gpa);
        for (row.edges_out) |e| {
            if (e.from_col != row.node_col) continue;
            if (e.to_col == ovf) continue;
            var col = e.to_col;
            var r = i + 1;
            const target: Pos = while (r < l.rows.len) : (r += 1) {
                if (l.rows[r].node_col == col) break nodes[r].id;
                var next: ?u16 = null;
                for (l.rows[r].edges_out) |f| if (f.from_col == col) {
                    try t.expect(next == null);
                    next = f.to_col;
                };
                col = next orelse return error.LaneEndsWithoutCommit;
                if (col == ovf) break @enumFromInt(std.math.maxInt(u32));
            } else @enumFromInt(std.math.maxInt(u32));
            if (@intFromEnum(target) == std.math.maxInt(u32)) continue;
            const is_parent = std.mem.indexOfScalar(Pos, n.parents, target) != null or
                std.mem.indexOfScalar(Pos, n.elided_parents, target) != null;
            try t.expect(is_parent);
            try reached.append(gpa, target);
        }
        // No two edges reach the same parent, and every displayed parent
        // below is reached (unless it went to the overflow column).
        for (reached.items, 0..) |x, k| try t.expect(std.mem.indexOfScalar(Pos, reached.items[k + 1 ..], x) == null);
        var overflowed = false;
        for (row.edges_out) |e| {
            if (e.from_col == row.node_col and e.to_col == ovf) overflowed = true;
        }
        if (!overflowed) {
            for ([2][]const Pos{ n.parents, n.elided_parents }) |list| for (list) |p| {
                const pr = row_of.get(p) orelse continue;
                if (pr <= i) continue;
                try t.expect(std.mem.indexOfScalar(Pos, reached.items, p) != null);
            };
        }
    }
}

test "graph_layout: golden ASCII for fixture DAGs" {
    const gpa = t.allocator;
    var root = try std.Io.Dir.openDirAbsolute(t.io, options.package_root, .{});
    defer root.close(t.io);
    var dir = try root.openDir(t.io, "testdata/graph_layout", .{ .iterate = true });
    defer dir.close(t.io);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(t.io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".txt")) try names.append(gpa, try gpa.dupe(u8, e.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    try t.expect(names.items.len >= 30);
    var written: usize = 0;
    for (names.items) |name| {
        const text = try dir.readFileAlloc(t.io, name, gpa, .limited(1 << 20));
        defer gpa.free(text);
        var f = try parseFixture(gpa, text);
        defer f.deinit();
        var l = try layout.compute(gpa, f.nodes, f.opts);
        defer l.deinit();
        const got = try render(gpa, &l, &f);
        defer gpa.free(got);
        if (f.expected) |want| {
            if (!std.mem.eql(u8, want, got)) {
                std.debug.print("graph_layout fixture {s}:\n{s}", .{ name, got });
                return error.GoldenMismatch;
            }
        } else {
            const updated = try std.mem.concat(gpa, u8, &.{ text, "====\n", got });
            defer gpa.free(updated);
            try dir.writeFile(t.io, .{ .sub_path = name, .data = updated });
            written += 1;
        }
        try checkEdges(gpa, &l, f.nodes, f.opts.max_columns);

        // Incremental from a few edits equals the full layout.
        if (f.nodes.len >= 2) {
            var without_first = try layout.compute(gpa, f.nodes[1..], f.opts);
            defer without_first.deinit();
            var inc = try layout.computeIncremental(&without_first, f.nodes[1..], f.nodes, f.opts, gpa);
            defer inc.deinit();
            try expectSameLayout(&l, &inc);
            var back = try layout.computeIncremental(&l, f.nodes, f.nodes[1..], f.opts, gpa);
            defer back.deinit();
            try expectSameLayout(&without_first, &back);
            var same = try layout.computeIncremental(&l, f.nodes, f.nodes, f.opts, gpa);
            defer same.deinit();
            try expectSameLayout(&l, &same);
        }
    }
    if (written > 0) {
        std.debug.print("graph_layout: wrote {d} new goldens; review them and rerun\n", .{written});
        return error.GoldenWritten;
    }
}

test "graph_layout: column count minimal on linear stacks" {
    const gpa = t.allocator;
    var nodes: [1000]GraphNodeIn = undefined;
    var parents: [1000]Pos = undefined;
    for (&nodes, 0..) |*n, i| {
        parents[i] = @enumFromInt(i + 1);
        n.* = .{ .id = @enumFromInt(i), .parents = if (i + 1 < nodes.len) parents[i .. i + 1] else &.{} };
    }
    var l = try layout.compute(gpa, &nodes, .{});
    defer l.deinit();
    try t.expectEqual(@as(u16, 1), l.width);
    for (l.rows) |r| {
        try t.expectEqual(@as(u16, 0), r.node_col);
        try t.expectEqual(@as(usize, 0), r.edges_through.len);
    }
}

test "graph_layout: max_columns overflow lane" {
    const gpa = t.allocator;
    // Ten heads on one root, three columns: two regular and the overflow.
    const root_id: Pos = @enumFromInt(10);
    const parent = [_]Pos{root_id};
    var nodes: [11]GraphNodeIn = undefined;
    for (nodes[0..10], 0..) |*n, i| n.* = .{ .id = @enumFromInt(i), .parents = &parent };
    nodes[10] = .{ .id = root_id };
    var l = try layout.compute(gpa, &nodes, .{ .max_columns = 3 });
    defer l.deinit();
    try t.expect(l.width <= 3);
    for (l.rows) |r| try t.expect(r.node_col < 3);
    // The root is waited for in column 0 throughout; no lane overflows
    // because every head joins it.
    try t.expectEqual(@as(u16, 0), l.rows[10].node_col);

    // An octopus wider than the columns sends parents to the overflow.
    const ps = [_]Pos{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(3), @enumFromInt(4), @enumFromInt(5) };
    var oct: [6]GraphNodeIn = undefined;
    oct[0] = .{ .id = @enumFromInt(0), .parents = &ps };
    for (oct[1..], 1..) |*n, i| n.* = .{ .id = @enumFromInt(i) };
    var lo = try layout.compute(gpa, &oct, .{ .max_columns = 3 });
    defer lo.deinit();
    var to_overflow: usize = 0;
    for (lo.rows[0].edges_out) |e| if (e.to_col == 2) {
        to_overflow += 1;
    };
    try t.expectEqual(@as(usize, 3), to_overflow);
    var drawn: std.Io.Writer.Allocating = .init(gpa);
    defer drawn.deinit();
    try layout.renderAscii(&lo, &oct, &drawn.writer, .ascii);
    try t.expect(std.mem.indexOfScalar(u8, drawn.written(), '.') != null);
    // Overflowed commits still get a column of their own.
    for (lo.rows) |r| try t.expect(r.node_col < 3);
}

/// A random DAG of `n` commits in topological order (children first):
/// each commit has up to three parents among the next few commits, some
/// elided.
fn randomDag(a: Allocator, r: std.Random, n: usize) ![]GraphNodeIn {
    const nodes = try a.alloc(GraphNodeIn, n);
    for (nodes, 0..) |*node, i| {
        var vis: std.ArrayList(Pos) = .empty;
        var eli: std.ArrayList(Pos) = .empty;
        const np = if (i + 1 == n) 0 else r.weightedIndex(u8, &.{ 2, 12, 4, 1 });
        for (0..np) |_| {
            const span = @min(n - i - 1, 6);
            const p: Pos = @enumFromInt(i + 1 + r.uintLessThan(usize, span));
            if (std.mem.indexOfScalar(Pos, vis.items, p) != null or std.mem.indexOfScalar(Pos, eli.items, p) != null) continue;
            try (if (r.uintLessThan(u8, 8) == 0) &eli else &vis).append(a, p);
        }
        node.* = .{
            .id = @enumFromInt(i),
            .parents = vis.items,
            .elided_parents = eli.items,
            .kind = @enumFromInt(r.uintLessThan(u8, 6)),
        };
    }
    return nodes;
}

test "graph_layout: property: edges reach parents, incremental equals full" {
    const gpa = t.allocator;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    for (0..200) |_| {
        const n = 1 + r.uintLessThan(usize, 60);
        const nodes = try randomDag(a, r, n);
        const opts: layout.LayoutOptions = .{ .prefer_first_parent_straight = r.boolean(), .collapse_elided = r.boolean() };
        var l = try layout.compute(gpa, nodes, opts);
        defer l.deinit();
        try checkEdges(gpa, &l, nodes, opts.max_columns);
        // No two commits share a row and column: one commit per row by
        // construction; lanes crossing a row never use its commit's column.
        for (l.rows) |row| for (row.edges_through) |th| try t.expect(th.col != row.node_col);

        // Edit: change one commit's kind, drop one, or prepend one.
        const edited = try a.dupe(GraphNodeIn, nodes);
        const at = r.uintLessThan(usize, n);
        edited[at].kind = if (edited[at].kind == .wc) .normal else .wc;
        var inc = try layout.computeIncremental(&l, nodes, edited, opts, gpa);
        defer inc.deinit();
        var full = try layout.compute(gpa, edited, opts);
        defer full.deinit();
        try expectSameLayout(&full, &inc);

        if (n >= 2) {
            var inc2 = try layout.computeIncremental(&l, nodes, nodes[1..], opts, gpa);
            defer inc2.deinit();
            var full2 = try layout.compute(gpa, nodes[1..], opts);
            defer full2.deinit();
            try expectSameLayout(&full2, &inc2);
        }
    }
}

test "graph_layout: deterministic" {
    const gpa = t.allocator;
    var prng: std.Random.DefaultPrng = .init(7);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const nodes = try randomDag(arena_state.allocator(), prng.random(), 500);
    var a = try layout.compute(gpa, nodes, .{});
    defer a.deinit();
    var b = try layout.compute(gpa, nodes, .{});
    defer b.deinit();
    try expectSameLayout(&a, &b);
}
