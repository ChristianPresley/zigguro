//! Syllable-based names (E14.F06.S01.T01): identifiers such as
//! `kmem_cache_pool` or `vrtx_q2_ctrl`, drawn from a fixed syllable table
//! so output never depends on anything but the PRNG.

const std = @import("std");

pub const syllables = [_][]const u8{
    "k",     "mem",   "cache", "pool", "vr",   "tx",    "q",     "ctrl", "dev",   "net",
    "fs",    "io",    "irq",   "dma",  "pci",  "usb",   "blk",   "sch",  "lock",  "map",
    "page",  "buf",   "rx",    "phy",  "reg",  "clk",   "pwr",   "gpio", "spi",   "i2c",
    "drv",   "core",  "util",  "init", "conf", "hw",    "sw",    "acpi", "efi",   "mmu",
    "tlb",   "vfs",   "inode", "sock", "tcp",  "udp",   "ip",    "eth",  "wl",    "bt",
    "snd",   "pcm",   "gpu",   "drm",  "fb",   "kbd",   "hid",   "tty",  "ser",   "log",
    "trace", "perf",  "bpf",   "sec",  "key",  "crypt", "hash",  "zip",  "bench", "mock",
    "xen",   "kvm",   "virt",  "aud",  "vid",  "cam",   "disp",  "ren",  "blink", "layout",
    "frame", "paint", "view",  "list", "tree", "node",  "graph", "task", "work",  "queue",
    "sync",  "async", "batch", "pipe", "port", "host",  "link",  "path", "file",  "dir",
};

/// A uniform index below `n`, drawn as a u64 so the stream is the same
/// on 32- and 64-bit targets.
pub fn pick(r: std.Random, n: usize) usize {
    return @intCast(r.uintLessThan(u64, n));
}

/// Appends an identifier of `min_parts`..`max_parts` syllables to `out`,
/// joined by `sep`, sometimes with a digit.
pub fn identifier(r: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator, min_parts: u8, max_parts: u8, sep: u8) !void {
    const n = min_parts + r.uintLessThan(u8, max_parts - min_parts + 1);
    for (0..n) |i| {
        if (i > 0) try out.append(gpa, sep);
        try out.appendSlice(gpa, syllables[pick(r, syllables.len)]);
        if (r.uintLessThan(u8, 16) == 0) try out.append(gpa, '0' + r.uintLessThan(u8, 10));
    }
}

/// A long name: syllables joined by `_` up to `max_len` bytes (at least
/// `min_len`).
pub fn longName(r: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator, min_len: usize, max_len: usize) !void {
    const target = min_len + pick(r, max_len - min_len + 1);
    const start = out.items.len;
    while (out.items.len - start < target) {
        if (out.items.len > start) try out.append(gpa, '_');
        try out.appendSlice(gpa, syllables[pick(r, syllables.len)]);
    }
    out.shrinkRetainingCapacity(start + @min(out.items.len - start, max_len));
    while (out.items.len > start + 1 and out.items[out.items.len - 1] == '_') out.items.len -= 1;
}

test "corpusgen names: deterministic identifiers" {
    const gpa = std.testing.allocator;
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    var p1: std.Random.DefaultPrng = .init(7);
    var p2: std.Random.DefaultPrng = .init(7);
    for (0..50) |_| {
        try identifier(p1.random(), &a, gpa, 1, 3, '_');
        try identifier(p2.random(), &b, gpa, 1, 3, '_');
    }
    try std.testing.expectEqualStrings(a.items, b.items);
    a.clearRetainingCapacity();
    try longName(p1.random(), &a, gpa, 60, 120);
    try std.testing.expect(a.items.len >= 50 and a.items.len <= 120);
}
