//! check-frame-pointers: verifies that a built executable keeps frame
//! pointers (E14.F02.S03.T02), so `perf record --call-graph fp` and WPA
//! stack walks work on profile builds:
//!
//!   check-frame-pointers <exe>
//!
//! Finds `zg_perf_fp_probe` (a `noinline export fn` in zg_perf) through the
//! ELF symbol table or the PE export table and checks that its code starts
//! with the x86_64 frame setup `push rbp; mov rbp, rsp` (55 48 89 e5).
//! Other architectures are reported and pass. Std only.

const std = @import("std");

/// The probe's exported name.
pub const probe = "zg_perf_fp_probe";
/// `push rbp; mov rbp, rsp`.
pub const x86_64_prologue = [_]u8{ 0x55, 0x48, 0x89, 0xe5 };

/// What the probe lookup found.
pub const Found = struct {
    /// File offset of the probe's first byte.
    offset: usize,
    x86_64: bool,
};

pub const Error = error{ NotAnExecutable, ProbeNotFound, Truncated };

fn int(comptime T: type, bytes: []const u8, at: usize) Error!T {
    if (at + @sizeOf(T) > bytes.len) return error.Truncated;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

/// Finds the probe in a little-endian ELF64 image (symbol tables).
pub fn findElf(bytes: []const u8) Error!Found {
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..4], "\x7fELF") or bytes[4] != 2 or bytes[5] != 1) return error.NotAnExecutable;
    const machine = try int(u16, bytes, 18);
    const shoff = try int(u64, bytes, 40);
    const shentsize = try int(u16, bytes, 58);
    const shnum = try int(u16, bytes, 60);
    const Section = struct { type: u32, addr: u64, offset: u64, size: u64, link: u32, entsize: u64 };
    const section = struct {
        fn at(b: []const u8, off: u64, size: u16, i: usize) Error!Section {
            const base: usize = @intCast(off + i * size);
            return .{
                .type = try int(u32, b, base + 4),
                .addr = try int(u64, b, base + 16),
                .offset = try int(u64, b, base + 24),
                .size = try int(u64, b, base + 32),
                .link = try int(u32, b, base + 40),
                .entsize = try int(u64, b, base + 56),
            };
        }
    }.at;
    for (0..shnum) |i| {
        const s = try section(bytes, shoff, shentsize, i);
        // SHT_SYMTAB = 2, SHT_DYNSYM = 11.
        if (s.type != 2 and s.type != 11) continue;
        const strtab = try section(bytes, shoff, shentsize, s.link);
        const n = s.size / @max(s.entsize, 24);
        for (0..n) |k| {
            const sym: usize = @intCast(s.offset + k * 24);
            const name_off = try int(u32, bytes, sym);
            const shndx = try int(u16, bytes, sym + 6);
            const value = try int(u64, bytes, sym + 8);
            const start: usize = @intCast(strtab.offset + name_off);
            if (start >= bytes.len) return error.Truncated;
            const name = std.mem.sliceTo(bytes[start..], 0);
            if (!std.mem.eql(u8, name, probe) or shndx == 0 or shndx >= shnum) continue;
            const text = try section(bytes, shoff, shentsize, shndx);
            return .{ .offset = @intCast(text.offset + (value - text.addr)), .x86_64 = machine == 62 };
        }
    }
    return error.ProbeNotFound;
}

/// Finds the probe in a PE32+ image (export table).
pub fn findPe(bytes: []const u8) Error!Found {
    if (bytes.len < 64 or !std.mem.eql(u8, bytes[0..2], "MZ")) return error.NotAnExecutable;
    const pe: usize = try int(u32, bytes, 0x3c);
    if (pe + 24 > bytes.len or !std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return error.NotAnExecutable;
    const coff = pe + 4;
    const machine = try int(u16, bytes, coff);
    const nsections = try int(u16, bytes, coff + 2);
    const opt_size = try int(u16, bytes, coff + 16);
    const opt = coff + 20;
    if (try int(u16, bytes, opt) != 0x20b) return error.NotAnExecutable; // PE32+
    const export_rva = try int(u32, bytes, opt + 112);
    if (export_rva == 0) return error.ProbeNotFound;
    const sections = opt + opt_size;
    const toOffset = struct {
        fn f(b: []const u8, first: usize, count: u16, rva: u32) Error!usize {
            for (0..count) |i| {
                const s = first + i * 40;
                const vsize = try int(u32, b, s + 8);
                const vaddr = try int(u32, b, s + 12);
                const raw = try int(u32, b, s + 20);
                if (rva >= vaddr and rva < vaddr + @max(vsize, try int(u32, b, s + 16))) return raw + (rva - vaddr);
            }
            return error.Truncated;
        }
    }.f;
    const dir = try toOffset(bytes, sections, nsections, export_rva);
    const n_names = try int(u32, bytes, dir + 24);
    const funcs = try toOffset(bytes, sections, nsections, try int(u32, bytes, dir + 28));
    const names = try toOffset(bytes, sections, nsections, try int(u32, bytes, dir + 32));
    const ords = try toOffset(bytes, sections, nsections, try int(u32, bytes, dir + 36));
    for (0..n_names) |i| {
        const name_at = try toOffset(bytes, sections, nsections, try int(u32, bytes, names + i * 4));
        if (name_at >= bytes.len) return error.Truncated;
        if (!std.mem.eql(u8, std.mem.sliceTo(bytes[name_at..], 0), probe)) continue;
        const ord = try int(u16, bytes, ords + i * 2);
        const rva = try int(u32, bytes, funcs + @as(usize, ord) * 4);
        return .{ .offset = try toOffset(bytes, sections, nsections, rva), .x86_64 = machine == 0x8664 };
    }
    return error.ProbeNotFound;
}

/// Finds the probe in an ELF or PE image.
pub fn find(bytes: []const u8) Error!Found {
    return findElf(bytes) catch |e| switch (e) {
        error.NotAnExecutable => findPe(bytes),
        else => e,
    };
}

/// Whether the probe at `f` has the frame setup (true off x86_64).
pub fn hasFramePointer(bytes: []const u8, f: Found) bool {
    if (!f.x86_64) return true;
    if (f.offset + 4 > bytes.len) return false;
    return std.mem.eql(u8, bytes[f.offset..][0..4], &x86_64_prologue);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    _ = args.next();
    const path = args.next() orelse {
        std.debug.print("usage: check-frame-pointers <exe>\n", .{});
        return 2;
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 31));
    const f = find(bytes) catch |e| {
        std.debug.print("check-frame-pointers: {s}: {t}\n", .{ path, e });
        return 1;
    };
    if (!f.x86_64) {
        std.debug.print("check-frame-pointers: {s}: not x86_64, prologue check skipped\n", .{path});
        return 0;
    }
    if (!hasFramePointer(bytes, f)) {
        std.debug.print("check-frame-pointers: {s}: {s} does not start with push rbp; mov rbp, rsp: {x}\n", .{ path, probe, bytes[f.offset..][0..@min(8, bytes.len - f.offset)] });
        return 1;
    }
    std.debug.print("check-frame-pointers: {s}: frame pointers present\n", .{path});
    return 0;
}

test "check-frame-pointers: rejects non-executables" {
    try std.testing.expectError(error.NotAnExecutable, find("hello, this is not an executable at all, just some text......"));
}

test "check-frame-pointers: finds a probe in a minimal ELF" {
    // ELF64 header + 3 section headers (null, .text, .symtab, .strtab).
    var img: [1024]u8 = @splat(0);
    @memcpy(img[0..4], "\x7fELF");
    img[4] = 2;
    img[5] = 1;
    std.mem.writeInt(u16, img[18..20], 62, .little);
    std.mem.writeInt(u64, img[40..48], 512, .little); // shoff
    std.mem.writeInt(u16, img[58..60], 64, .little);
    std.mem.writeInt(u16, img[60..62], 4, .little);
    // .text at file 256, addr 0x1000.
    const text = 512 + 64;
    std.mem.writeInt(u32, img[text + 4 ..][0..4], 1, .little);
    std.mem.writeInt(u64, img[text + 16 ..][0..8], 0x1000, .little);
    std.mem.writeInt(u64, img[text + 24 ..][0..8], 256, .little);
    @memcpy(img[260..264], &x86_64_prologue);
    // .symtab at 64: entry 1 names offset 1 in .strtab, shndx 1, value 0x1004.
    const symtab = 512 + 128;
    std.mem.writeInt(u32, img[symtab + 4 ..][0..4], 2, .little);
    std.mem.writeInt(u64, img[symtab + 24 ..][0..8], 64, .little);
    std.mem.writeInt(u64, img[symtab + 32 ..][0..8], 48, .little);
    std.mem.writeInt(u32, img[symtab + 40 ..][0..4], 3, .little);
    std.mem.writeInt(u64, img[symtab + 56 ..][0..8], 24, .little);
    std.mem.writeInt(u32, img[88..92], 1, .little);
    std.mem.writeInt(u16, img[94..96], 1, .little);
    std.mem.writeInt(u64, img[96..104], 0x1004, .little);
    // .strtab at 128.
    const strtab = 512 + 192;
    std.mem.writeInt(u32, img[strtab + 4 ..][0..4], 3, .little);
    std.mem.writeInt(u64, img[strtab + 24 ..][0..8], 128, .little);
    @memcpy(img[129..][0..probe.len], probe);
    const f = try find(&img);
    try std.testing.expectEqual(@as(usize, 260), f.offset);
    try std.testing.expect(f.x86_64);
    try std.testing.expect(hasFramePointer(&img, f));
    img[260] = 0x90;
    try std.testing.expect(!hasFramePointer(&img, f));
}
