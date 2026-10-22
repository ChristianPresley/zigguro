//! PE CodeView ids (E17.F05.S01.T03): the RSDS record's GUID and age, the
//! key a symbol server files a module's PDB under. Reads either a loaded
//! image (sections at their RVAs) or the file on disk (sections at their
//! raw offsets). Pure and allocation-free: the Windows crash path calls
//! `cp_codeViewId` on loaded modules, and tests run on every OS.

const std = @import("std");

/// GUID (16 bytes, as stored) followed by the age (u32 little-endian).
pub const id_len = 20;

/// Where the image's sections live in `bytes`.
pub const Layout = enum { memory, file };

const debug_dir_index = 6;
const debug_type_codeview = 2;
const debug_entry_size = 28;

/// The CodeView id of the PE image in `bytes`, or null when it has none
/// or the headers do not fit. `bytes` must cover the image (`SizeOfImage`
/// for `.memory`, the whole file for `.file`).
pub fn cp_codeViewId(bytes: []const u8, layout: Layout) ?*const [id_len]u8 {
    if (bytes.len < 0x40 or bytes[0] != 'M' or bytes[1] != 'Z') return null;
    const pe = cp_u32(bytes, 0x3c) orelse return null;
    if (pe > bytes.len or bytes.len - pe < 24) return null;
    if (!std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return null;
    const coff = pe + 4;
    const n_sections = cp_u16(bytes, coff + 2) orelse return null;
    const opt_size = cp_u16(bytes, coff + 16) orelse return null;
    const opt = coff + 20;
    const magic = cp_u16(bytes, opt) orelse return null;
    // NumberOfRvaAndSizes and the data directories, PE32+ or PE32.
    const dirs_at: usize, const n_dirs_at: usize = switch (magic) {
        0x20b => .{ opt + 112, opt + 108 },
        0x10b => .{ opt + 96, opt + 92 },
        else => return null,
    };
    const n_dirs = cp_u32(bytes, n_dirs_at) orelse return null;
    if (n_dirs <= debug_dir_index) return null;
    const dir = dirs_at + debug_dir_index * 8;
    if (dir + 8 > opt + opt_size) return null;
    const dir_rva = cp_u32(bytes, dir) orelse return null;
    const dir_size = cp_u32(bytes, dir + 4) orelse return null;
    if (dir_rva == 0 or dir_size == 0) return null;
    const sections = opt + opt_size;
    const dir_off = cp_offset(bytes, layout, sections, n_sections, dir_rva) orelse return null;
    var i: usize = 0;
    while (i + debug_entry_size <= dir_size) : (i += debug_entry_size) {
        const e = dir_off + i;
        const kind = cp_u32(bytes, e + 12) orelse return null;
        if (kind != debug_type_codeview) continue;
        const size = cp_u32(bytes, e + 16) orelse return null;
        const rva = cp_u32(bytes, e + 20) orelse return null;
        const raw = cp_u32(bytes, e + 24) orelse return null;
        // The raw pointer is a file offset; loaded images use the RVA.
        const at: usize = switch (layout) {
            .memory => rva,
            .file => raw,
        };
        if (size < 4 + id_len or at > bytes.len or bytes.len - at < 4 + id_len) return null;
        if (!std.mem.eql(u8, bytes[at..][0..4], "RSDS")) return null;
        return bytes[at + 4 ..][0..id_len];
    }
    return null;
}

/// File offset (or RVA for `.memory`) of `rva`.
fn cp_offset(bytes: []const u8, layout: Layout, sections: usize, n: u16, rva: u32) ?usize {
    if (layout == .memory) return if (rva < bytes.len) rva else null;
    var s: usize = 0;
    while (s < n) : (s += 1) {
        const h = sections + s * 40;
        const vsize = cp_u32(bytes, h + 8) orelse return null;
        const vaddr = cp_u32(bytes, h + 12) orelse return null;
        const raw_size = cp_u32(bytes, h + 16) orelse return null;
        const raw_ptr = cp_u32(bytes, h + 20) orelse return null;
        const span = @max(vsize, raw_size);
        if (rva >= vaddr and rva - vaddr < span) {
            const off = @as(usize, raw_ptr) + (rva - vaddr);
            return if (off < bytes.len) off else null;
        }
    }
    return null;
}

fn cp_u16(bytes: []const u8, at: usize) ?u16 {
    if (at > bytes.len or bytes.len - at < 2) return null;
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn cp_u32(bytes: []const u8, at: usize) ?u32 {
    if (at > bytes.len or bytes.len - at < 4) return null;
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

const testing = std.testing;

/// A minimal PE32+ image with one section holding the debug directory
/// and an RSDS record, in memory or file layout.
fn fixture(buf: []u8, layout: Layout) []u8 {
    @memset(buf, 0);
    buf[0] = 'M';
    buf[1] = 'Z';
    const pe = 0x80;
    std.mem.writeInt(u32, buf[0x3c..][0..4], pe, .little);
    @memcpy(buf[pe..][0..4], "PE\x00\x00");
    const coff = pe + 4;
    std.mem.writeInt(u16, buf[coff + 2 ..][0..2], 1, .little);
    const opt_size = 240;
    std.mem.writeInt(u16, buf[coff + 16 ..][0..2], opt_size, .little);
    const opt = coff + 20;
    std.mem.writeInt(u16, buf[opt..][0..2], 0x20b, .little);
    std.mem.writeInt(u32, buf[opt + 108 ..][0..4], 16, .little);
    // .rdata: RVA 0x1000, raw 0x200.
    const rva: u32 = 0x1000;
    const raw: u32 = 0x200;
    const sec = opt + opt_size;
    std.mem.writeInt(u32, buf[sec + 8 ..][0..4], 0x100, .little);
    std.mem.writeInt(u32, buf[sec + 12 ..][0..4], rva, .little);
    std.mem.writeInt(u32, buf[sec + 16 ..][0..4], 0x100, .little);
    std.mem.writeInt(u32, buf[sec + 20 ..][0..4], raw, .little);
    const dir = opt + 112 + debug_dir_index * 8;
    std.mem.writeInt(u32, buf[dir..][0..4], rva, .little);
    std.mem.writeInt(u32, buf[dir + 4 ..][0..4], debug_entry_size * 2, .little);
    const base: u32 = if (layout == .memory) rva else raw;
    // A non-CodeView entry first, then CodeView pointing 0x40 further.
    const e = base + debug_entry_size;
    std.mem.writeInt(u32, buf[base + 12 ..][0..4], 13, .little);
    std.mem.writeInt(u32, buf[e + 12 ..][0..4], debug_type_codeview, .little);
    std.mem.writeInt(u32, buf[e + 16 ..][0..4], 4 + id_len + 8, .little);
    std.mem.writeInt(u32, buf[e + 20 ..][0..4], rva + 0x40, .little);
    std.mem.writeInt(u32, buf[e + 24 ..][0..4], raw + 0x40, .little);
    const cv = base + 0x40;
    @memcpy(buf[cv..][0..4], "RSDS");
    for (buf[cv + 4 ..][0..id_len], 0..) |*b, i| b.* = @intCast(i + 1);
    return buf[0 .. base + 0x100];
}

test "pe: CodeView id from memory and file layouts" {
    var buf: [0x1200]u8 = undefined;
    var want: [id_len]u8 = undefined;
    for (&want, 0..) |*b, i| b.* = @intCast(i + 1);
    for ([_]Layout{ .memory, .file }) |layout| {
        const img = fixture(&buf, layout);
        try testing.expectEqualSlices(u8, &want, cp_codeViewId(img, layout).?);
        // Truncated anywhere before the record: no id, no out-of-bounds read.
        var n: usize = 0;
        while (n < img.len - 0x100 + 0x40 + 4 + id_len) : (n += 7) {
            try testing.expect(cp_codeViewId(img[0..n], layout) == null);
        }
    }
    // Not a PE, or no RSDS signature.
    const img = fixture(&buf, .file);
    try testing.expect(cp_codeViewId("not a pe file at all, just some bytes padding padding padding padding", .file) == null);
    img[0x240] = 'X';
    try testing.expect(cp_codeViewId(img, .file) == null);
}
