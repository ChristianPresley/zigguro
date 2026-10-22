//! zg_update benchmarks (`zig build bench`). Budget: `decide` on a 64 KiB
//! manifest plus signature < 1 ms (E17 update budget).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_update = @import("zg_update");
const bench = zg_core.bench;
const verify = zg_update.verify;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const Fixture = struct {
    manifest: []u8,
    sig: []u8,
};

fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    // The golden manifest with its summary padded to just under 64 KiB.
    const golden = zg_update.manifest.golden;
    const marker = "\"Faster search\"";
    const at = std.mem.indexOf(u8, golden, marker).?;
    const pad = zg_update.manifest.max_manifest_bytes - golden.len;
    const m = try gpa.alloc(u8, golden.len + pad);
    defer gpa.free(m);
    @memcpy(m[0 .. at + 1], golden[0 .. at + 1]);
    @memset(m[at + 1 ..][0..pad], 'x');
    @memcpy(m[at + 1 + pad ..], golden[at + 1 ..]);
    const sig = try verify.testing_support.signManifest(gpa, m, "update-stable.json", "stable", 1761016620);
    defer gpa.free(sig);
    var fx: Fixture = .{ .manifest = m, .sig = sig };
    try b.run("update: decide 64KiB", &fx, decide);
}

fn decide(fx: *Fixture, s: *bench.State) void {
    s.setBytes(fx.manifest.len);
    const ctx: verify.Context = .{
        .now_unix = 1792600000,
        .build_epoch = 1792500000,
        .current = .{ .major = 0, .minor = 3, .patch = 9 },
        .target = "x86_64-linux",
        .channel = "stable",
        .expected_file = "update-stable.json",
        .last_serial = 0,
        .install_id = @splat(0),
        .manual = true,
    };
    const keys = [_]zg_update.verify.PublicKey{verify.testing_support.key().pk};
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var arena: std.heap.ArenaAllocator = .init(s.allocator());
        defer arena.deinit();
        const r = verify.decide(arena.allocator(), ctx, &keys, fx.manifest, fx.sig) catch unreachable;
        bench.doNotOptimizeAway(r.serial);
    }
}
