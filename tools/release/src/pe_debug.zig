//! The CodeView (RSDS) record of a PE image (E17.F01.S01.T02): the PDB
//! GUID and age the symbolizer and symbol stores match on. The id is the
//! symbol-store key, `<GUID as 32 uppercase hex><age in hex>`, with the
//! GUID's first three fields in their printed (big-endian) order.

const std = @import("std");

pub const Error = error{ NotPe, Malformed };

/// The RSDS record: id, and the PDB path the linker wrote.
pub const CodeView = struct { id: []const u8, pdb: []const u8 };

const debug_dir_index = 6;
const image_debug_type_codeview = 2;

/// The CodeView record, with the id formatted into `out` (≥ 40 bytes),
/// or null when the image has none.
pub fn codeView(bytes: []const u8, out: []u8) Error!?CodeView {
    if (bytes.len < 0x40 or !std.mem.eql(u8, bytes[0..2], "MZ")) return error.NotPe;
    const pe = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    if (@as(u64, pe) + 24 > bytes.len or !std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return error.NotPe;
    const coff = pe + 4;
    const nsec = std.mem.readInt(u16, bytes[coff + 2 ..][0..2], .little);
    const opt_size = std.mem.readInt(u16, bytes[coff + 16 ..][0..2], .little);
    const opt = coff + 20;
    if (opt + opt_size > bytes.len or opt_size < 2) return error.Malformed;
    const dirs: usize = switch (std.mem.readInt(u16, bytes[opt..][0..2], .little)) {
        0x10b => opt + 96,
        0x20b => opt + 112,
        else => return error.Malformed,
    };
    if (dirs + (debug_dir_index + 1) * 8 > opt + opt_size) return null;
    const rva = std.mem.readInt(u32, bytes[dirs + debug_dir_index * 8 ..][0..4], .little);
    const size = std.mem.readInt(u32, bytes[dirs + debug_dir_index * 8 + 4 ..][0..4], .little);
    if (rva == 0 or size == 0) return null;
    const sections = opt + opt_size;
    const dir_off = try fileOffset(bytes, sections, nsec, rva);
    var i: usize = 0;
    while (i + 28 <= size) : (i += 28) {
        const e = dir_off + i;
        if (e + 28 > bytes.len) return error.Malformed;
        if (std.mem.readInt(u32, bytes[e + 12 ..][0..4], .little) != image_debug_type_codeview) continue;
        const data_size = std.mem.readInt(u32, bytes[e + 16 ..][0..4], .little);
        const ptr = std.mem.readInt(u32, bytes[e + 24 ..][0..4], .little);
        if (data_size < 24 or @as(u64, ptr) + data_size > bytes.len) return error.Malformed;
        const rec = bytes[ptr..][0..data_size];
        if (!std.mem.eql(u8, rec[0..4], "RSDS")) continue;
        const g = rec[4..20];
        const age = std.mem.readInt(u32, rec[20..24], .little);
        if (out.len < 40) return error.Malformed;
        const tail = std.fmt.bytesToHex(g[8..16].*, .upper);
        const id = std.fmt.bufPrint(out, "{X:0>8}{X:0>4}{X:0>4}{s}{X}", .{
            std.mem.readInt(u32, g[0..4], .little),
            std.mem.readInt(u16, g[4..6], .little),
            std.mem.readInt(u16, g[6..8], .little),
            &tail,
            age,
        }) catch return error.Malformed;
        return .{ .id = id, .pdb = std.mem.sliceTo(rec[24..], 0) };
    }
    return null;
}

fn fileOffset(bytes: []const u8, sections: usize, n: u16, rva: u32) Error!usize {
    for (0..n) |k| {
        const s = sections + k * 40;
        if (s + 40 > bytes.len) return error.Malformed;
        const vsize = std.mem.readInt(u32, bytes[s + 8 ..][0..4], .little);
        const vaddr = std.mem.readInt(u32, bytes[s + 12 ..][0..4], .little);
        const raw = std.mem.readInt(u32, bytes[s + 20 ..][0..4], .little);
        if (rva >= vaddr and rva < vaddr + vsize) return raw + (rva - vaddr);
    }
    return error.Malformed;
}

const testing = std.testing;

test "pe_debug: reads the RSDS GUID and age" {
    // DOS header, PE header, PE32+ optional header with 16 directories,
    // one section mapping RVA 0x1000 to file 0x200, the debug directory
    // and the RSDS record.
    var img = [_]u8{0} ** 0x300;
    @memcpy(img[0..2], "MZ");
    std.mem.writeInt(u32, img[0x3c..0x40], 0x80, .little);
    @memcpy(img[0x80..0x84], "PE\x00\x00");
    const coff = 0x84;
    std.mem.writeInt(u16, img[coff + 2 ..][0..2], 1, .little);
    std.mem.writeInt(u16, img[coff + 16 ..][0..2], 240, .little);
    const opt = coff + 20;
    std.mem.writeInt(u16, img[opt..][0..2], 0x20b, .little);
    std.mem.writeInt(u32, img[opt + 112 + 6 * 8 ..][0..4], 0x1000, .little);
    std.mem.writeInt(u32, img[opt + 112 + 6 * 8 + 4 ..][0..4], 28, .little);
    const sec = opt + 240;
    std.mem.writeInt(u32, img[sec + 8 ..][0..4], 0x100, .little);
    std.mem.writeInt(u32, img[sec + 12 ..][0..4], 0x1000, .little);
    std.mem.writeInt(u32, img[sec + 20 ..][0..4], 0x200, .little);
    const dir = 0x200;
    std.mem.writeInt(u32, img[dir + 12 ..][0..4], 2, .little);
    std.mem.writeInt(u32, img[dir + 16 ..][0..4], 24 + 6, .little);
    std.mem.writeInt(u32, img[dir + 24 ..][0..4], 0x240, .little);
    @memcpy(img[0x240..0x244], "RSDS");
    @memcpy(img[0x244..0x254], &[_]u8{ 0x78, 0x56, 0x34, 0x12, 0x34, 0x12, 0x78, 0x56, 1, 2, 3, 4, 5, 6, 7, 8 });
    std.mem.writeInt(u32, img[0x254..0x258], 0x1a, .little);
    @memcpy(img[0x258..0x25d], "a.pdb");
    var buf: [64]u8 = undefined;
    const cv = (try codeView(&img, &buf)).?;
    try testing.expectEqualStrings("12345678123456780102030405060708" ++ "1A", cv.id);
    try testing.expectEqualStrings("a.pdb", cv.pdb);
    // No debug directory: null.
    std.mem.writeInt(u32, img[opt + 112 + 6 * 8 ..][0..4], 0, .little);
    try testing.expect(try codeView(&img, &buf) == null);
    try testing.expectError(error.NotPe, codeView("ELF", &buf));
}
