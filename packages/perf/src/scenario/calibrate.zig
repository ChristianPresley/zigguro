//! Runner calibration (E14.F06.S01.T02): four fixed kernels give a
//! machine scale factor against the reference laptop, so absolute
//! budgets can be checked (advisory) on other machines.
//!
//! - `int_alu`: an integer hash round per op.
//! - `mem_bw`: one streaming copy of 64 MiB per op.
//! - `branchy`: one lookup in a 4 095-node binary search tree laid out in
//!   an array, with pseudo-random keys (half of them miss).
//! - `alloc`: one allocation and free of 16 to 4 096 bytes per op.
//!
//! Each kernel runs for `kernel_ns` (0.5 s by default). `scale` is the
//! geometric mean of ns/op over the reference ns/op: above 1 means slower
//! than the reference. The reference numbers live in
//! `perf/baselines/ref_laptop_2024/calibration.json`. Every kernel folds
//! its work into a checksum so the optimizer cannot remove it, and the
//! checksum for a given op count is the same on every machine.

const std = @import("std");
const zg_core = @import("zg_core");

pub const Kernel = enum { int_alu, mem_bw, branchy, alloc };

pub const Components = struct {
    int_alu: f64 = 0,
    mem_bw: f64 = 0,
    branchy: f64 = 0,
    alloc: f64 = 0,

    pub fn get(c: Components, k: Kernel) f64 {
        return switch (k) {
            inline else => |t| @field(c, @tagName(t)),
        };
    }

    pub fn set(c: *Components, k: Kernel, v: f64) void {
        switch (k) {
            inline else => |t| @field(c, @tagName(t)) = v,
        }
    }
};

pub const Calibration = struct {
    /// Geometric mean of `components` (1 when there is no reference).
    scale: f64,
    /// ns/op over the reference ns/op, per kernel.
    components: Components,
    /// Measured ns/op.
    ns_per_op: Components,
    checksum: u64,
};

pub const Options = struct {
    kernel_ns: u64 = 500 * std.time.ns_per_ms,
    /// Reference ns/op (zero fields are skipped in the mean).
    reference: Components = .{},
};

pub const copy_bytes = 64 << 20;
const tree_nodes = 4095;

/// The kernels' buffers.
pub const Workspace = struct {
    gpa: std.mem.Allocator,
    src: []u8,
    dst: []u8,
    tree: []u32,

    pub fn init(gpa: std.mem.Allocator) !Workspace {
        const src = try gpa.alloc(u8, copy_bytes);
        errdefer gpa.free(src);
        const dst = try gpa.alloc(u8, copy_bytes);
        errdefer gpa.free(dst);
        for (src, 0..) |*b, i| b.* = @truncate(i *% 131);
        const tree = try gpa.alloc(u32, tree_nodes);
        // Implicit BST (Eytzinger order) over the even keys 0, 2, 4, ...
        var next: u32 = 0;
        fill(tree, 0, &next);
        return .{ .gpa = gpa, .src = src, .dst = dst, .tree = tree };
    }

    fn fill(tree: []u32, i: usize, next: *u32) void {
        if (i >= tree.len) return;
        fill(tree, 2 * i + 1, next);
        tree[i] = next.* * 2;
        next.* += 1;
        fill(tree, 2 * i + 2, next);
    }

    pub fn deinit(w: *Workspace) void {
        w.gpa.free(w.src);
        w.gpa.free(w.dst);
        w.gpa.free(w.tree);
    }
};

/// Runs `ops` ops of `k` and returns their checksum.
pub fn runKernel(w: *Workspace, k: Kernel, ops: u64, seed: u64) !u64 {
    var acc: u64 = seed;
    switch (k) {
        .int_alu => for (0..ops) |i| {
            acc = (acc ^ i) *% 0x9e37_79b9_7f4a_7c15;
            acc ^= acc >> 29;
            acc = acc *% 0xbf58_476d_1ce4_e5b9 +% 7;
        },
        .mem_bw => for (0..ops) |i| {
            @memcpy(w.dst, w.src);
            const at = (acc +% i) % copy_bytes;
            acc = acc *% 31 +% w.dst[at];
            w.src[at] +%= 1;
        },
        .branchy => {
            var x = seed | 1;
            for (0..ops) |_| {
                x ^= x << 13;
                x ^= x >> 7;
                x ^= x << 17;
                const key: u32 = @intCast(x % (tree_nodes * 2));
                var i: usize = 0;
                var found: u64 = 0;
                while (i < w.tree.len) {
                    const v = w.tree[i];
                    if (key == v) {
                        found = i + 1;
                        break;
                    }
                    i = if (key < v) 2 * i + 1 else 2 * i + 2;
                }
                acc = acc *% 33 +% found;
            }
        },
        .alloc => {
            var x = seed | 1;
            for (0..ops) |_| {
                x = x *% 6364136223846793005 +% 1442695040888963407;
                const size: usize = 16 + @as(usize, @intCast((x >> 33) % 4081));
                const m = try w.gpa.alloc(u8, size);
                m[0] = @truncate(x);
                m[size - 1] = @truncate(x >> 8);
                acc = acc *% 31 +% m[0] +% m[size - 1] +% size;
                w.gpa.free(m);
            }
        },
    }
    return acc;
}

fn batchOps(k: Kernel) u64 {
    return switch (k) {
        .int_alu => 1 << 20,
        .mem_bw => 1,
        .branchy => 1 << 14,
        .alloc => 1 << 12,
    };
}

/// Measures every kernel for `opts.kernel_ns` and computes the scale.
pub fn calibrateWith(io: std.Io, gpa: std.mem.Allocator, opts: Options) !Calibration {
    var w = try Workspace.init(gpa);
    defer w.deinit();
    var c: Calibration = .{ .scale = 1, .components = .{}, .ns_per_op = .{}, .checksum = 0 };
    for (std.enums.values(Kernel)) |k| {
        // One untimed batch to warm caches and the allocator.
        c.checksum +%= try runKernel(&w, k, batchOps(k), 1);
        var ops: u64 = 0;
        const t0 = zg_core.time.nowNs(io);
        var elapsed: u64 = 0;
        while (elapsed < opts.kernel_ns) {
            c.checksum +%= try runKernel(&w, k, batchOps(k), ops);
            ops += batchOps(k);
            elapsed = zg_core.time.nowNs(io) - t0;
        }
        c.ns_per_op.set(k, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ops)));
    }
    const s = scaleOf(c.ns_per_op, opts.reference);
    c.scale = s.scale;
    c.components = s.components;
    return c;
}

/// The per-kernel ratios of `measured` over `reference` and their
/// geometric mean; kernels without a reference are skipped (scale 1 when
/// none has one).
pub fn scaleOf(measured: Components, reference: Components) struct { scale: f64, components: Components } {
    var comps: Components = .{};
    var log_sum: f64 = 0;
    var n: u32 = 0;
    for (std.enums.values(Kernel)) |k| {
        const ref = reference.get(k);
        if (ref <= 0 or measured.get(k) <= 0) continue;
        const ratio = measured.get(k) / ref;
        comps.set(k, ratio);
        log_sum += @log(ratio);
        n += 1;
    }
    return .{ .scale = if (n > 0) @exp(log_sum / @as(f64, @floatFromInt(n))) else 1, .components = comps };
}

/// Reads the reference file (`{"ns_per_op": {...}}`).
pub fn parseReference(arena: std.mem.Allocator, bytes: []const u8) !Components {
    const R = struct { ns_per_op: Components };
    return (try std.json.parseFromSliceLeaky(R, arena, bytes, .{ .ignore_unknown_fields = true })).ns_per_op;
}

/// Writes `{"scale": .., "components": .., "ns_per_op": .., "checksum": ..}`;
/// perfgate reads `scale`, and the same file serves as a reference.
pub fn writeJson(c: Calibration, w: *std.Io.Writer) !void {
    try std.json.Stringify.value(c, .{ .whitespace = .indent_2 }, w);
    try w.writeAll("\n");
}

test "calibrate: deterministic workload checksum" {
    var w = try Workspace.init(std.testing.allocator);
    defer w.deinit();
    const a = try runKernel(&w, .int_alu, 1000, 5);
    try std.testing.expectEqual(a, try runKernel(&w, .int_alu, 1000, 5));
    try std.testing.expectEqual(@as(u64, 0xeacd_ab62_2f2b_6dc4), a);
    const b = try runKernel(&w, .branchy, 1000, 5);
    try std.testing.expectEqual(b, try runKernel(&w, .branchy, 1000, 5));
    try std.testing.expect(b != 5);
    const c = try runKernel(&w, .alloc, 100, 5);
    try std.testing.expectEqual(c, try runKernel(&w, .alloc, 100, 5));
    // The tree holds the even keys in order.
    try std.testing.expectEqual(@as(u32, 2 * (tree_nodes / 2)), w.tree[0]);
}

test "calibrate: scale is the geometric mean against the reference" {
    const c = try calibrateWith(std.testing.io, std.testing.allocator, .{ .kernel_ns = 2 * std.time.ns_per_ms });
    try std.testing.expectEqual(@as(f64, 1), c.scale);
    try std.testing.expect(c.ns_per_op.int_alu > 0 and c.ns_per_op.mem_bw > 0);
    // Against a reference twice as fast everywhere, the scale is 2.
    const twice = scaleOf(.{ .int_alu = 2, .mem_bw = 4, .branchy = 6, .alloc = 8 }, .{ .int_alu = 1, .mem_bw = 2, .branchy = 3, .alloc = 4 });
    try std.testing.expectApproxEqAbs(@as(f64, 2), twice.scale, 1e-12);
    // 4x on one kernel and 1x on another: geometric mean 2.
    const mixed = scaleOf(.{ .int_alu = 4, .mem_bw = 1 }, .{ .int_alu = 1, .mem_bw = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 2), mixed.scale, 1e-12);
    try std.testing.expectEqual(@as(f64, 0), mixed.components.alloc);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeJson(c, &aw.writer);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const back = try parseReference(arena.allocator(), aw.written());
    try std.testing.expectEqual(c.ns_per_op.alloc, back.alloc);
}
