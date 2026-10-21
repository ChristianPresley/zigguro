//! Package-graph layering checker (`zig build check-layers`).
//!
//! Reads every package's `build.zig.zon`, collects dependency edges and checks
//! them against `tools/pkgtool/layers.zon`: a package may only depend on a
//! lower layer, or on a same-layer package explicitly whitelisted. Cycles,
//! unknown packages, `.url` dependencies and paths leaving the repository are
//! always rejected. `zg_build` is build-time only and ignored.

const std = @import("std");
const zon = @import("zon.zig");

/// A dependency edge `from -> to`.
pub const Edge = struct { from: []const u8, to: []const u8 };

/// One problem found by `check`.
pub const Violation = union(enum) {
    /// `from` depends on a higher layer.
    upward: Edge,
    /// Same-layer edge that is not whitelisted.
    same_layer: Edge,
    /// A dependency cycle; first and last names are equal.
    cycle: []const []const u8,
    /// A package missing from `layers.zon`.
    unknown_pkg: []const u8,
    /// A `.url` dependency (third-party code is forbidden).
    url_dependency: Edge,
    /// A `.path` dependency resolving outside the repository.
    path_outside_repo: Edge,
    /// A dependency key that differs from the target package's `.name`.
    name_mismatch: Edge,
};

/// A package and its declared dependencies, as read from its zon.
pub const Package = struct {
    name: []const u8,
    deps: []const Dep,

    /// One `.dependencies` entry.
    pub const Dep = struct {
        name: []const u8,
        path: ?[]const u8 = null,
        url: ?[]const u8 = null,
    };
};

/// The parsed `layers.zon`.
pub const Layers = struct {
    layer: std.StringHashMapUnmanaged(i64) = .empty,
    allow: std.ArrayList(Edge) = .empty,

    /// Parses `layers.zon` source. Strings are copied into `arena`.
    pub fn parse(arena: std.mem.Allocator, source: [:0]const u8) !Layers {
        var doc = try zon.Doc.parse(arena, source);
        const r = doc.root();
        var l: Layers = .{};
        const layers = r.field("layers") orelse return error.MissingLayers;
        for (0..layers.len()) |i| {
            const n = layers.at(i).int() orelse return error.BadLayer;
            try l.layer.put(arena, try arena.dupe(u8, layers.fieldName(i)), n);
        }
        if (r.field("allow_same_layer")) |allow| {
            for (0..allow.len()) |i| {
                const pair = allow.at(i);
                if (pair.len() != 2) return error.BadWhitelist;
                try l.allow.append(arena, .{
                    .from = try arena.dupe(u8, pair.at(0).string() orelse return error.BadWhitelist),
                    .to = try arena.dupe(u8, pair.at(1).string() orelse return error.BadWhitelist),
                });
            }
        }
        return l;
    }

    fn allowed(l: *const Layers, e: Edge) bool {
        for (l.allow.items) |a| {
            if (std.mem.eql(u8, a.from, e.from) and std.mem.eql(u8, a.to, e.to)) return true;
        }
        return false;
    }
};

/// Name of the build-time-only helper package, which is exempt.
pub const build_pkg = "zg_build";

/// Checks an in-memory package graph. Results are allocated in `arena`.
pub fn checkGraph(arena: std.mem.Allocator, pkgs: []const Package, layers: *const Layers) ![]Violation {
    var out: std.ArrayList(Violation) = .empty;
    for (pkgs) |p| {
        if (std.mem.eql(u8, p.name, build_pkg)) continue;
        const from_layer = layers.layer.get(p.name) orelse {
            try out.append(arena, .{ .unknown_pkg = p.name });
            continue;
        };
        for (p.deps) |d| {
            const e: Edge = .{ .from = p.name, .to = d.name };
            if (d.url != null) {
                try out.append(arena, .{ .url_dependency = e });
                continue;
            }
            if (std.mem.eql(u8, d.name, build_pkg)) continue;
            const to_layer = layers.layer.get(d.name) orelse {
                try out.append(arena, .{ .unknown_pkg = d.name });
                continue;
            };
            if (to_layer > from_layer) {
                try out.append(arena, .{ .upward = e });
            } else if (to_layer == from_layer and !layers.allowed(e)) {
                try out.append(arena, .{ .same_layer = e });
            }
        }
    }
    if (try findCycle(arena, pkgs)) |c| try out.append(arena, .{ .cycle = c });
    return out.items;
}

const Color = enum { white, grey, black };

fn findCycle(arena: std.mem.Allocator, pkgs: []const Package) !?[]const []const u8 {
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (pkgs, 0..) |p, i| try index.put(arena, p.name, i);
    const color = try arena.alloc(Color, pkgs.len);
    @memset(color, .white);
    var stack: std.ArrayList(usize) = .empty;
    for (0..pkgs.len) |i| {
        if (color[i] == .white) {
            if (try dfs(arena, pkgs, &index, color, &stack, i)) |c| return c;
        }
    }
    return null;
}

fn dfs(
    arena: std.mem.Allocator,
    pkgs: []const Package,
    index: *const std.StringHashMapUnmanaged(usize),
    color: []Color,
    stack: *std.ArrayList(usize),
    i: usize,
) !?[]const []const u8 {
    color[i] = .grey;
    try stack.append(arena, i);
    for (pkgs[i].deps) |d| {
        const j = index.get(d.name) orelse continue;
        switch (color[j]) {
            .grey => {
                const start = std.mem.findScalar(usize, stack.items, j).?;
                var path: std.ArrayList([]const u8) = .empty;
                for (stack.items[start..]) |k| try path.append(arena, pkgs[k].name);
                try path.append(arena, pkgs[j].name);
                return path.items;
            },
            .white => if (try dfs(arena, pkgs, index, color, stack, j)) |c| return c,
            .black => {},
        }
    }
    _ = stack.pop();
    color[i] = .black;
    return null;
}

/// Reads one `build.zig.zon` into a `Package` (strings live in `arena`).
pub fn readPackage(arena: std.mem.Allocator, source: [:0]const u8) !Package {
    var doc = try zon.Doc.parse(arena, source);
    const r = doc.root();
    const name = (r.field("name") orelse return error.MissingName).enumLiteral() orelse return error.MissingName;
    var deps: std.ArrayList(Package.Dep) = .empty;
    if (r.field("dependencies")) |ds| {
        for (0..ds.len()) |i| {
            const d = ds.at(i);
            try deps.append(arena, .{
                .name = try arena.dupe(u8, ds.fieldName(i)),
                .path = if (d.field("path")) |p| try arena.dupe(u8, p.string() orelse "") else null,
                .url = if (d.field("url")) |u| try arena.dupe(u8, u.string() orelse "") else null,
            });
        }
    }
    return .{ .name = try arena.dupe(u8, name), .deps = deps.items };
}

/// Checks the repository at `repo_root`: the root `build.zig.zon` and every
/// package reachable from it through `.path` dependencies.
pub fn check(arena: std.mem.Allocator, io: std.Io, repo_root: std.Io.Dir) ![]Violation {
    const layers_src = try repo_root.readFileAllocOptions(io, "tools/pkgtool/layers.zon", arena, .limited(1 << 20), .of(u8), 0);
    var layers = try Layers.parse(arena, layers_src);

    var out: std.ArrayList(Violation) = .empty;
    var pkgs: std.ArrayList(Package) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var queue: std.ArrayList([]const u8) = .empty; // repo-relative package dirs

    const root_src = try repo_root.readFileAllocOptions(io, "build.zig.zon", arena, .limited(1 << 20), .of(u8), 0);
    const root_pkg = try readPackage(arena, root_src);
    for (root_pkg.deps) |d| {
        const e: Edge = .{ .from = root_pkg.name, .to = d.name };
        if (d.url != null) {
            try out.append(arena, .{ .url_dependency = e });
            continue;
        }
        const rel = try normalize(arena, ".", d.path orelse "") orelse {
            try out.append(arena, .{ .path_outside_repo = e });
            continue;
        };
        try queue.append(arena, rel);
    }

    while (queue.pop()) |dir| {
        if ((try seen.getOrPut(arena, dir)).found_existing) continue;
        const zon_path = try std.fs.path.join(arena, &.{ dir, "build.zig.zon" });
        const src = try repo_root.readFileAllocOptions(io, zon_path, arena, .limited(1 << 20), .of(u8), 0);
        const p = try readPackage(arena, src);
        try pkgs.append(arena, p);
        for (p.deps) |d| {
            const e: Edge = .{ .from = p.name, .to = d.name };
            if (d.url != null) continue; // reported by checkGraph
            const rel = try normalize(arena, dir, d.path orelse "") orelse {
                try out.append(arena, .{ .path_outside_repo = e });
                continue;
            };
            try queue.append(arena, rel);
        }
    }

    // Dependency keys must equal the target's zon `.name`.
    var names: std.StringHashMapUnmanaged(void) = .empty;
    for (pkgs.items) |p| try names.put(arena, p.name, {});
    for (pkgs.items) |p| for (p.deps) |d| {
        if (d.url == null and !names.contains(d.name)) try out.append(arena, .{ .name_mismatch = .{ .from = p.name, .to = d.name } });
    };

    try out.appendSlice(arena, try checkGraph(arena, pkgs.items, &layers));
    return out.items;
}

/// Joins `base/rel` and normalises it; null when it escapes the repo root.
fn normalize(arena: std.mem.Allocator, base: []const u8, rel: []const u8) !?[]const u8 {
    if (rel.len == 0 or std.fs.path.isAbsolute(rel)) return null;
    const joined = try std.fs.path.resolvePosix(arena, &.{ "/repo", base, rel });
    if (!std.mem.startsWith(u8, joined, "/repo/")) return null;
    return joined["/repo/".len..];
}

/// Prints one violation per line in the documented format.
pub fn format(v: Violation, layers: ?*const Layers, w: *std.Io.Writer) !void {
    const lay = struct {
        fn of(l: ?*const Layers, n: []const u8) i64 {
            return if (l) |x| x.layer.get(n) orelse -1 else -1;
        }
    }.of;
    switch (v) {
        .upward => |e| try w.print("layer violation: {s}({d}) -> {s}({d})\n", .{ e.from, lay(layers, e.from), e.to, lay(layers, e.to) }),
        .same_layer => |e| try w.print("layer violation: {s}({d}) -> {s}({d}) is a same-layer edge not listed in allow_same_layer\n", .{ e.from, lay(layers, e.from), e.to, lay(layers, e.to) }),
        .cycle => |c| {
            try w.writeAll("cycle: ");
            for (c, 0..) |n, i| {
                if (i != 0) try w.writeAll(" -> ");
                try w.writeAll(n);
            }
            try w.writeAll("\n");
        },
        .unknown_pkg => |n| try w.print("unknown package: {s} is not listed in tools/pkgtool/layers.zon\n", .{n}),
        .url_dependency => |e| try w.print("url dependency: {s} -> {s} (only .path dependencies are allowed)\n", .{ e.from, e.to }),
        .path_outside_repo => |e| try w.print("path outside repo: {s} -> {s}\n", .{ e.from, e.to }),
        .name_mismatch => |e| try w.print("name mismatch: {s} depends on key {s}, which is not the .name of any package\n", .{ e.from, e.to }),
    }
}

const test_layers =
    \\.{ .layers = .{ .zg_core = 0, .zg_jsonrpc = 1, .zg_net = 1, .zg_gui = 3, .zg_review = 4, .zg_scm = 4 },
    \\   .allow_same_layer = .{ .{ "zg_review", "zg_scm" } } }
;

fn testCheck(arena: std.mem.Allocator, pkgs: []const Package) ![]Violation {
    var layers = try Layers.parse(arena, test_layers);
    return checkGraph(arena, pkgs, &layers);
}

test "layers: clean graph" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const v = try testCheck(a.allocator(), &.{
        .{ .name = "zg_core", .deps = &.{.{ .name = "zg_build", .path = "../build" }} },
        .{ .name = "zg_net", .deps = &.{.{ .name = "zg_core", .path = "../core" }} },
        .{ .name = "zg_review", .deps = &.{ .{ .name = "zg_scm", .path = "../scm" }, .{ .name = "zg_gui", .path = "../gui" } } },
        .{ .name = "zg_scm", .deps = &.{} },
    });
    try std.testing.expectEqual(@as(usize, 0), v.len);
}

test "layers: upward edge" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const v = try testCheck(a.allocator(), &.{
        .{ .name = "zg_core", .deps = &.{.{ .name = "zg_net", .path = "../net" }} },
        .{ .name = "zg_net", .deps = &.{} },
    });
    try std.testing.expectEqual(@as(usize, 1), v.len);
    try std.testing.expectEqualStrings("zg_net", v[0].upward.to);
}

test "layers: same-layer edge not whitelisted" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const v = try testCheck(a.allocator(), &.{
        .{ .name = "zg_net", .deps = &.{.{ .name = "zg_jsonrpc", .path = "../jsonrpc" }} },
        .{ .name = "zg_jsonrpc", .deps = &.{} },
    });
    try std.testing.expectEqual(@as(usize, 1), v.len);
    try std.testing.expect(v[0] == .same_layer);
}

test "layers: 3-node cycle" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var layers = try Layers.parse(a.allocator(),
        \\.{ .layers = .{ .a = 1, .b = 1, .c = 1 }, .allow_same_layer = .{ .{ "a", "b" }, .{ "b", "c" }, .{ "c", "a" } } }
    );
    const v = try checkGraph(a.allocator(), &.{
        .{ .name = "a", .deps = &.{.{ .name = "b" }} },
        .{ .name = "b", .deps = &.{.{ .name = "c" }} },
        .{ .name = "c", .deps = &.{.{ .name = "a" }} },
    }, &layers);
    try std.testing.expectEqual(@as(usize, 1), v.len);
    const c = v[0].cycle;
    try std.testing.expectEqual(@as(usize, 4), c.len);
    try std.testing.expectEqualStrings(c[0], c[3]);
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format(v[0], &layers, &w);
    try std.testing.expectEqualStrings("cycle: a -> b -> c -> a\n", w.buffered());
}

test "layers: url dependency rejected" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const v = try testCheck(a.allocator(), &.{
        .{ .name = "zg_net", .deps = &.{.{ .name = "zg_evil", .url = "https://example.com/x.tar.gz" }} },
    });
    try std.testing.expectEqual(@as(usize, 1), v.len);
    try std.testing.expect(v[0] == .url_dependency);
}

test "layers: unknown package" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const v = try testCheck(a.allocator(), &.{.{ .name = "zg_mystery", .deps = &.{} }});
    try std.testing.expectEqual(@as(usize, 1), v.len);
    try std.testing.expect(v[0] == .unknown_pkg);
}

test "layers: readPackage parses a build.zig.zon" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    const p = try readPackage(a.allocator(),
        \\.{ .name = .zg_net, .version = "0.0.0", .fingerprint = 0xaeacf74069173310,
        \\   .dependencies = .{ .zg_build = .{ .path = "../build" }, .zg_core = .{ .path = "../core" } },
        \\   .paths = .{""} }
    );
    try std.testing.expectEqualStrings("zg_net", p.name);
    try std.testing.expectEqual(@as(usize, 2), p.deps.len);
    try std.testing.expectEqualStrings("../core", p.deps[1].path.?);
}

test "layers: normalize rejects escaping paths" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("packages/core", (try normalize(a.allocator(), "packages/net", "../core")).?);
    try std.testing.expect((try normalize(a.allocator(), "packages/net", "../../../x")) == null);
    try std.testing.expect((try normalize(a.allocator(), ".", "/abs")) == null);
}
