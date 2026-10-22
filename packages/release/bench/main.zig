//! zg_release benchmarks (`zig build bench`).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_release = @import("zg_release");
const bench = zg_core.bench;
const minisign = zg_release.minisign;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const Fixture = struct {
    key: minisign.PublicKey,
    sig: minisign.Signature,
    sig_text: []u8,
    message: []u8,
};

fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    const kp = try minisign.keyPairFromSeed(@splat(1), @splat(2));
    const message = try gpa.alloc(u8, 64 << 10);
    defer gpa.free(message);
    @memset(message, 'm');
    const text = try minisign.sign(gpa, kp.kp, kp.pk.key_id, message, "u", "timestamp:1\tfile:x");
    defer gpa.free(text);
    var fx: Fixture = .{ .key = kp.pk, .sig = try minisign.Signature.parse(text), .sig_text = text, .message = message };
    try b.run("minisign: verify 64 KiB", &fx, verifyOne);
    try b.run("version: parse + order", {}, parseOrder);
}

fn verifyOne(fx: *Fixture, s: *bench.State) void {
    s.setBytes(fx.message.len);
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const sig = minisign.Signature.parse(fx.sig_text) catch unreachable;
        const k = minisign.verify(&sig, &.{fx.key}, fx.message) catch unreachable;
        bench.doNotOptimizeAway(k);
    }
}

fn parseOrder(_: void, s: *bench.State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        const a = zg_release.Version.parse("0.5.0-insiders.20261021.1+g1a2b3c4d5e6f") catch unreachable;
        const b = zg_release.Version.parse("0.5.0-insiders.20261021.2") catch unreachable;
        bench.doNotOptimizeAway(a.order(b));
    }
}
