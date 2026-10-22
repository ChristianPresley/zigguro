//! commit-graph reader (gitformat-commit-graph): parents, root trees,
//! generation numbers and commit times without inflating commits. Reads a
//! single `objects/info/commit-graph` or a split chain under
//! `objects/info/commit-graphs/`. Read-only.

const std = @import("std");
const oid_mod = @import("oid.zig");
const commit_mod = @import("commit.zig");
const MappedFile = @import("mapped.zig").MappedFile;
const Odb = @import("odb.zig").Odb;
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.zg_git);

/// Errors for malformed graph files.
pub const Error = error{CorruptCommitGraph};

/// A commit's global position in the graph (chain order, base layer first).
pub const GraphPos = enum(u32) { _ };

const parent_none: u32 = 0x7000_0000;
const edge_last: u32 = 0x8000_0000;

const Layer = struct {
    file: MappedFile,
    n: u32,
    /// Commits in all lower layers.
    base: u32,
    oidf: usize,
    oidl: usize,
    cdat: usize,
    gda2: ?usize,
    gdo2: ?[]const u8,
    edge: ?[]const u8,
    base_chunk: ?[]const u8,
    num_bases: u8,
};

fn parseLayer(file: MappedFile, fmt: ObjectFormat) Error!Layer {
    const b = file.bytes;
    const hl = fmt.len();
    if (b.len < 8 + 12 + hl) return error.CorruptCommitGraph;
    if (!std.mem.eql(u8, b[0..4], "CGPH") or b[4] != 1 or b[5] != fmt.hashVersion()) return error.CorruptCommitGraph;
    const chunks = b[6];
    const table_end = 8 + (@as(usize, chunks) + 1) * 12;
    const data_end = b.len - hl;
    if (table_end > data_end) return error.CorruptCommitGraph;
    var l: Layer = .{
        .file = file,
        .n = 0,
        .base = 0,
        .oidf = 0,
        .oidl = 0,
        .cdat = 0,
        .gda2 = null,
        .gdo2 = null,
        .edge = null,
        .base_chunk = null,
        .num_bases = b[7],
    };
    var oidf: ?[]const u8 = null;
    var oidl: ?[]const u8 = null;
    var cdat: ?[]const u8 = null;
    var gda2: ?[]const u8 = null;
    for (0..chunks) |i| {
        const e = b[8 + i * 12 ..];
        const start = std.mem.readInt(u64, e[4..12], .big);
        const end = std.mem.readInt(u64, b[8 + (i + 1) * 12 ..][4..12], .big);
        if (start < table_end or end < start or end > data_end) return error.CorruptCommitGraph;
        const c = b[@intCast(start)..@intCast(end)];
        const id = e[0..4];
        if (std.mem.eql(u8, id, "OIDF")) oidf = c else if (std.mem.eql(u8, id, "OIDL")) oidl = c else if (std.mem.eql(u8, id, "CDAT")) cdat = c else if (std.mem.eql(u8, id, "GDA2")) gda2 = c else if (std.mem.eql(u8, id, "GDO2")) l.gdo2 = c else if (std.mem.eql(u8, id, "EDGE")) l.edge = c else if (std.mem.eql(u8, id, "BASE")) l.base_chunk = c;
    }
    if (std.mem.readInt(u32, b[8 + @as(usize, chunks) * 12 ..][0..4], .big) != 0) return error.CorruptCommitGraph;
    const f = oidf orelse return error.CorruptCommitGraph;
    if (f.len != 1024) return error.CorruptCommitGraph;
    var prev: u32 = 0;
    for (0..256) |i| {
        const v = std.mem.readInt(u32, f[i * 4 ..][0..4], .big);
        if (v < prev) return error.CorruptCommitGraph;
        prev = v;
    }
    l.n = prev;
    const ol = oidl orelse return error.CorruptCommitGraph;
    const cd = cdat orelse return error.CorruptCommitGraph;
    if (ol.len != @as(usize, l.n) * hl or cd.len != @as(usize, l.n) * (hl + 16)) return error.CorruptCommitGraph;
    if (gda2) |g| {
        if (g.len != @as(usize, l.n) * 4) return error.CorruptCommitGraph;
        l.gda2 = g.ptr - b.ptr;
    }
    if (l.gdo2) |g| if (g.len % 8 != 0) return error.CorruptCommitGraph;
    if (l.edge) |g| if (g.len % 4 != 0) return error.CorruptCommitGraph;
    if (l.base_chunk) |g| if (g.len != @as(usize, l.num_bases) * hl) return error.CorruptCommitGraph;
    l.oidf = f.ptr - b.ptr;
    l.oidl = ol.ptr - b.ptr;
    l.cdat = cd.ptr - b.ptr;
    return l;
}

/// See the file comment. Lookups do not allocate.
pub const CommitGraph = struct {
    gpa: Allocator,
    format: ObjectFormat,
    /// Base layer first.
    layers: []Layer,
    total: u32,
    gen2: bool,

    /// Opens the graph in `objects_dir`; null when there is none. A broken
    /// chain keeps its consistent base prefix.
    pub fn open(gpa: Allocator, io: std.Io, objects_dir: std.Io.Dir, fmt: ObjectFormat) !?*CommitGraph {
        var layers: std.ArrayList(Layer) = .empty;
        errdefer {
            for (layers.items) |*l| l.file.close(gpa, io);
            layers.deinit(gpa);
        }
        if (MappedFile.open(gpa, io, objects_dir, "info/commit-graph")) |f| {
            var mf = f;
            const l = parseLayer(mf, fmt) catch |e| {
                mf.close(gpa, io);
                return e;
            };
            try layers.append(gpa, l);
        } else |e| switch (e) {
            error.FileNotFound => try openChain(gpa, io, objects_dir, fmt, &layers),
            else => |x| return x,
        }
        if (layers.items.len == 0) {
            layers.deinit(gpa);
            return null;
        }
        var total: u32 = 0;
        var gen2 = true;
        for (layers.items) |*l| {
            l.base = total;
            total = std.math.add(u32, total, l.n) catch return error.CorruptCommitGraph;
            gen2 = gen2 and l.gda2 != null;
        }
        const cg = try gpa.create(CommitGraph);
        cg.* = .{ .gpa = gpa, .format = fmt, .layers = try layers.toOwnedSlice(gpa), .total = total, .gen2 = gen2 };
        return cg;
    }

    fn openChain(gpa: Allocator, io: std.Io, objects_dir: std.Io.Dir, fmt: ObjectFormat, layers: *std.ArrayList(Layer)) !void {
        const text = objects_dir.readFileAlloc(io, "info/commit-graphs/commit-graph-chain", gpa, .limited(1 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => |x| return x,
        };
        defer gpa.free(text);
        var hashes: std.ArrayList(Oid) = .empty;
        defer hashes.deinit(gpa);
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            const h = Oid.parseHex(fmt, line) catch break;
            var hb: [64]u8 = undefined;
            var pb: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, "info/commit-graphs/graph-{s}.graph", .{h.hex(&hb)}) catch unreachable;
            var mf = MappedFile.open(gpa, io, objects_dir, path) catch |e| {
                log.warn("commit-graph chain: cannot open layer {s}: {t}; using {d} layers", .{ path, e, layers.items.len });
                return;
            };
            const l = parseLayer(mf, fmt) catch {
                mf.close(gpa, io);
                log.warn("commit-graph chain: corrupt layer {s}; using {d} layers", .{ path, layers.items.len });
                return;
            };
            // BASE must list exactly the layers below, in order.
            var ok = l.num_bases == hashes.items.len;
            if (ok) for (hashes.items, 0..) |prev, i| {
                const hl = fmt.len();
                if (!std.mem.eql(u8, l.base_chunk.?[i * hl ..][0..hl], prev.slice())) ok = false;
            };
            if (!ok) {
                mf.close(gpa, io);
                log.warn("commit-graph chain: BASE mismatch at {s}; using {d} layers", .{ path, layers.items.len });
                return;
            }
            layers.append(gpa, l) catch |e| {
                mf.close(gpa, io);
                return e;
            };
            try hashes.append(gpa, h);
        }
    }

    /// Unmaps every layer and frees `cg`.
    pub fn close(cg: *CommitGraph, io: std.Io) void {
        for (cg.layers) |*l| l.file.close(cg.gpa, io);
        cg.gpa.free(cg.layers);
        cg.gpa.destroy(cg);
    }

    /// Number of commits.
    pub fn count(cg: *const CommitGraph) u32 {
        return cg.total;
    }

    fn layerOf(cg: *const CommitGraph, p: GraphPos) struct { l: *const Layer, i: u32 } {
        const g = @intFromEnum(p);
        var k = cg.layers.len;
        while (k > 0) {
            k -= 1;
            if (g >= cg.layers[k].base) return .{ .l = &cg.layers[k], .i = g - cg.layers[k].base };
        }
        unreachable;
    }

    /// Position of `id`, or null.
    pub fn lookup(cg: *const CommitGraph, id: Oid) ?GraphPos {
        const key = id.slice();
        const hl = cg.format.len();
        var k = cg.layers.len;
        while (k > 0) {
            k -= 1;
            const l = &cg.layers[k];
            const b = l.file.bytes;
            const first = key[0];
            var lo: u32 = if (first == 0) 0 else std.mem.readInt(u32, b[l.oidf + (@as(usize, first) - 1) * 4 ..][0..4], .big);
            var hi: u32 = std.mem.readInt(u32, b[l.oidf + @as(usize, first) * 4 ..][0..4], .big);
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                switch (std.mem.order(u8, b[l.oidl + @as(usize, mid) * hl ..][0..hl], key)) {
                    .lt => lo = mid + 1,
                    .eq => return @enumFromInt(l.base + mid),
                    .gt => hi = mid,
                }
            }
        }
        return null;
    }

    /// Commit ID at `p`.
    pub fn oid(cg: *const CommitGraph, p: GraphPos) Oid {
        const x = cg.layerOf(p);
        const hl = cg.format.len();
        return .fromBytes(cg.format, x.l.file.bytes[x.l.oidl + @as(usize, x.i) * hl ..][0..hl]);
    }

    fn cdat(cg: *const CommitGraph, p: GraphPos) struct { e: []const u8, l: *const Layer, i: u32 } {
        const x = cg.layerOf(p);
        const hl = cg.format.len();
        return .{ .e = x.l.file.bytes[x.l.cdat + @as(usize, x.i) * (hl + 16) ..][0 .. hl + 16], .l = x.l, .i = x.i };
    }

    /// Root tree of the commit at `p`.
    pub fn tree(cg: *const CommitGraph, p: GraphPos) Oid {
        return .fromBytes(cg.format, cg.cdat(p).e[0..cg.format.len()]);
    }

    /// Parents of `p` in order, written into `buf` (octopus merges follow
    /// the EDGE list). Parents past `buf.len`, or invalid references, are
    /// dropped; size `buf` for the widest merge you care about.
    pub fn parents(cg: *const CommitGraph, p: GraphPos, buf: []GraphPos) []const GraphPos {
        const c = cg.cdat(p);
        const hl = cg.format.len();
        const p1 = std.mem.readInt(u32, c.e[hl..][0..4], .big);
        const p2 = std.mem.readInt(u32, c.e[hl + 4 ..][0..4], .big);
        var n: usize = 0;
        if (p1 == parent_none) return buf[0..0];
        if (p1 < cg.total and n < buf.len) {
            buf[n] = @enumFromInt(p1);
            n += 1;
        }
        if (p2 == parent_none) return buf[0..n];
        if (p2 & edge_last == 0) {
            if (p2 < cg.total and n < buf.len) {
                buf[n] = @enumFromInt(p2);
                n += 1;
            }
            return buf[0..n];
        }
        const edges = c.l.edge orelse return buf[0..n];
        var i: usize = p2 & ~edge_last;
        while (i * 4 + 4 <= edges.len) : (i += 1) {
            const v = std.mem.readInt(u32, edges[i * 4 ..][0..4], .big);
            const pos = v & ~edge_last;
            if (pos < cg.total and n < buf.len) {
                buf[n] = @enumFromInt(pos);
                n += 1;
            }
            if (v & edge_last != 0) break;
        }
        return buf[0..n];
    }

    /// Topological level (generation v1).
    pub fn topoLevel(cg: *const CommitGraph, p: GraphPos) u32 {
        const c = cg.cdat(p);
        return std.mem.readInt(u32, c.e[cg.format.len() + 8 ..][0..4], .big) >> 2;
    }

    /// Committer time in seconds (34 bits).
    pub fn commitTime(cg: *const CommitGraph, p: GraphPos) u64 {
        const c = cg.cdat(p);
        const hl = cg.format.len();
        const hi: u64 = std.mem.readInt(u32, c.e[hl + 8 ..][0..4], .big) & 3;
        const lo: u64 = std.mem.readInt(u32, c.e[hl + 12 ..][0..4], .big);
        return (hi << 32) | lo;
    }

    /// Corrected commit date (generation v2) when every layer has GDA2,
    /// else the topological level.
    pub fn generation(cg: *const CommitGraph, p: GraphPos) u64 {
        if (!cg.gen2) return cg.topoLevel(p);
        const c = cg.cdat(p);
        const off = std.mem.readInt(u32, c.l.file.bytes[c.l.gda2.? + @as(usize, c.i) * 4 ..][0..4], .big);
        if (off & 0x8000_0000 == 0) return cg.commitTime(p) + off;
        const g = c.l.gdo2 orelse return cg.commitTime(p);
        const k: usize = off & 0x7fff_ffff;
        if ((k + 1) * 8 > g.len) return cg.commitTime(p);
        return cg.commitTime(p) + std.mem.readInt(u64, g[k * 8 ..][0..8], .big);
    }

    /// Recomputes the trailing checksum of every layer (for fsck).
    pub fn verifyChecksums(cg: *const CommitGraph) bool {
        const hl = cg.format.len();
        for (cg.layers) |l| {
            const b = l.file.bytes;
            if (!oid_mod.hashBytes(cg.format, b[0 .. b.len - hl]).eql(Oid.fromBytes(cg.format, b[b.len - hl ..]))) return false;
        }
        return true;
    }
};

/// Whether `a` is an ancestor of (or equal to) `b`. Walks from `b` by
/// descending generation and prunes below `a`'s generation; commits missing
/// from the graph are parsed from `odb`.
pub fn isAncestor(gpa: Allocator, cg: ?*const CommitGraph, odb: *Odb, a: Oid, b: Oid) !bool {
    if (a.eql(b)) return true;
    const Node = struct { id: Oid, gen: u64 };
    const inf = std.math.maxInt(u64);
    const genOf = struct {
        fn f(g: ?*const CommitGraph, id: Oid) u64 {
            const graph = g orelse return inf;
            const p = graph.lookup(id) orelse return inf;
            return graph.generation(p);
        }
    }.f;
    const min_gen = genOf(cg, a);
    var queue: std.PriorityQueue(Node, void, struct {
        fn cmp(_: void, x: Node, y: Node) std.math.Order {
            return std.math.order(y.gen, x.gen);
        }
    }.cmp) = .empty;
    defer queue.deinit(gpa);
    var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer seen.deinit(gpa);
    try queue.push(gpa, .{ .id = b, .gen = genOf(cg, b) });
    try seen.put(gpa, b, {});
    var buf: [64]GraphPos = undefined;
    while (queue.pop()) |n| {
        if (n.id.eql(a)) return true;
        if (n.gen != inf and min_gen != inf and n.gen < min_gen) continue;
        if (cg) |g| if (g.lookup(n.id)) |p| {
            for (g.parents(p, &buf)) |pp| {
                const pid = g.oid(pp);
                if ((try seen.getOrPut(gpa, pid)).found_existing) continue;
                try queue.push(gpa, .{ .id = pid, .gen = g.generation(pp) });
            }
            continue;
        };
        var obj = try odb.read(gpa, n.id);
        defer obj.deinit(gpa);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const c = try commit_mod.parseCommit(arena_state.allocator(), odb.format, obj.data);
        for (c.parents) |pid| {
            if ((try seen.getOrPut(gpa, pid)).found_existing) continue;
            try queue.push(gpa, .{ .id = pid, .gen = genOf(cg, pid) });
        }
    }
    return false;
}

const testdata = @import("testdata.zig");

/// Checks parents, times and both generation definitions against the odb
/// for every commit listed in `commits.txt`.
fn checkAgainstOdb(gpa: Allocator, io: std.Io, root: std.Io.Dir, objects: std.Io.Dir, fmt: ObjectFormat) !*CommitGraph {
    const t = std.testing;
    const cg = (try CommitGraph.open(gpa, io, objects, fmt)).?;
    errdefer cg.close(io);
    const odb = try Odb.open(gpa, io, objects, fmt, .{});
    defer odb.close();
    const listing = try root.readFileAlloc(io, "commits.txt", gpa, .limited(1 << 20));
    defer gpa.free(listing);
    var level: std.AutoHashMapUnmanaged(Oid, u32) = .empty;
    defer level.deinit(gpa);
    var corrected: std.AutoHashMapUnmanaged(Oid, u64) = .empty;
    defer corrected.deinit(gpa);
    // Resolve in an order where parents come first (repeat until stable).
    var pending = true;
    var rounds: usize = 0;
    while (pending) : (rounds += 1) {
        try t.expect(rounds < 1000);
        pending = false;
        var lines = std.mem.tokenizeScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const id = try Oid.parseHex(fmt, f.next().?);
            if (level.contains(id)) continue;
            const p = cg.lookup(id) orelse continue; // newer than the graph
            var want_parents: [16]Oid = undefined;
            var np: usize = 0;
            var lvl: u32 = 1;
            var obj = try odb.read(gpa, id);
            defer obj.deinit(gpa);
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            const c = try commit_mod.parseCommit(arena_state.allocator(), fmt, obj.data);
            var corr: u64 = @intCast(c.committer.time);
            var ready = true;
            while (f.next()) |ph| : (np += 1) {
                want_parents[np] = try Oid.parseHex(fmt, ph);
                const pl = level.get(want_parents[np]) orelse {
                    ready = false;
                    continue;
                };
                lvl = @max(lvl, pl + 1);
                corr = @max(corr, corrected.get(want_parents[np]).? + 1);
            }
            if (!ready) {
                pending = true;
                continue;
            }
            var buf: [16]GraphPos = undefined;
            const got = cg.parents(p, &buf);
            try t.expectEqual(np, got.len);
            for (got, 0..) |gp, i| try t.expect(cg.oid(gp).eql(want_parents[i]));
            try t.expect(cg.tree(p).eql(c.tree));
            try t.expectEqual(@as(u64, @intCast(c.committer.time)), cg.commitTime(p));
            try t.expectEqual(lvl, cg.topoLevel(p));
            try t.expectEqual(corr, cg.generation(p));
            try level.put(gpa, id, lvl);
            try corrected.put(gpa, id, corr);
        }
    }
    try t.expect(level.count() > 0);
    try t.expect(cg.verifyChecksums());
    return cg;
}

test "commit_graph: single file fixtures (sha1, sha256)" {
    const t = std.testing;
    for ([_]ObjectFormat{ .sha1, .sha256 }) |fmt| {
        var fx = try testdata.Fixture.open(t.allocator, t.io, fmt);
        defer fx.close();
        const cg = try checkAgainstOdb(t.allocator, t.io, fx.root, fx.objects, fmt);
        defer cg.close(t.io);
        try t.expectEqual(@as(usize, 1), cg.layers.len);
        try t.expect(cg.gen2);
    }
}

test "commit_graph: split chain of 3 layers, octopus via EDGE, GDO2 overflow" {
    const t = std.testing;
    var root = try testdata.openDir(t.io, "graph-split");
    defer root.close(t.io);
    var objects = try root.openDir(t.io, "objects", .{});
    defer objects.close(t.io);
    const cg = try checkAgainstOdb(t.allocator, t.io, root, objects, .sha1);
    defer cg.close(t.io);
    try t.expectEqual(@as(usize, 3), cg.layers.len);
    var max_parents: usize = 0;
    var overflow = false;
    var i: u32 = 0;
    while (i < cg.count()) : (i += 1) {
        var buf: [8]GraphPos = undefined;
        max_parents = @max(max_parents, cg.parents(@enumFromInt(i), &buf).len);
        if (cg.generation(@enumFromInt(i)) - cg.commitTime(@enumFromInt(i)) > std.math.maxInt(u31)) overflow = true;
    }
    try t.expectEqual(@as(usize, 4), max_parents);
    try t.expect(overflow);
}

test "commit_graph: corrupt chunk table -> error, odb fallback" {
    const t = std.testing;
    const gpa = t.allocator;
    var fx = try testdata.Fixture.open(gpa, t.io, .sha1);
    defer fx.close();
    const good = try fx.objects.readFileAlloc(t.io, "info/commit-graph", gpa, .limited(1 << 20));
    defer gpa.free(good);
    const bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);
    bad[8 + 4 + 7] ^= 0x40; // first chunk offset
    try t.expectError(error.CorruptCommitGraph, parseLayer(.borrowed(bad), .sha1));
    try t.expectError(error.CorruptCommitGraph, parseLayer(.borrowed(good[0..40]), .sha1));
    // isAncestor works with no graph at all.
    const odb = try Odb.open(gpa, t.io, fx.objects, .sha1, .{});
    defer odb.close();
    const listing = try fx.root.readFileAlloc(t.io, "refs.txt", gpa, .limited(1 << 16));
    defer gpa.free(listing);
    const head = try Oid.parseHex(.sha1, listing[0..40]);
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    var side: ?Oid = null;
    while (lines.next()) |l| if (std.mem.endsWith(u8, l, "refs/heads/side")) {
        side = try Oid.parseHex(.sha1, l[0..40]);
    };
    try t.expect(try isAncestor(gpa, null, odb, side.?, head));
    try t.expect(!try isAncestor(gpa, null, odb, head, side.?));
}

test "commit_graph: isAncestor equals odb walk on fixture DAG" {
    const t = std.testing;
    const gpa = t.allocator;
    var root = try testdata.openDir(t.io, "graph-split");
    defer root.close(t.io);
    var objects = try root.openDir(t.io, "objects", .{});
    defer objects.close(t.io);
    const cg = (try CommitGraph.open(gpa, t.io, objects, .sha1)).?;
    defer cg.close(t.io);
    const odb = try Odb.open(gpa, t.io, objects, .sha1, .{});
    defer odb.close();
    var i: u32 = 0;
    while (i < cg.count()) : (i += 1) {
        var j: u32 = 0;
        while (j < cg.count()) : (j += 1) {
            const a = cg.oid(@enumFromInt(i));
            const b = cg.oid(@enumFromInt(j));
            try t.expectEqual(try isAncestor(gpa, null, odb, a, b), try isAncestor(gpa, cg, odb, a, b));
        }
    }
}

test "fuzz: git-commit-graph" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            const l = parseLayer(.borrowed(input), .sha1) catch return;
            var layers = [_]Layer{l};
            const cg: CommitGraph = .{ .gpa = std.testing.allocator, .format = .sha1, .layers = &layers, .total = l.n, .gen2 = l.gda2 != null };
            var i: u32 = 0;
            while (i < cg.total) : (i += 1) {
                var pbuf: [8]GraphPos = undefined;
                const p: GraphPos = @enumFromInt(i);
                _ = cg.parents(p, &pbuf);
                _ = cg.generation(p);
                _ = cg.lookup(cg.oid(p));
            }
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "git-commit-graph") });
}
