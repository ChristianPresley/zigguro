//! Split debug info for 64-bit little-endian ELF executables
//! (E17.F01.S01.T02), because `zig objcopy` cannot strip ELF in 0.16:
//!
//! - `strip` drops every `.debug*`/`.zdebug*` section, keeps everything
//!   else (`.symtab` included, like `--strip-debug`) and adds a
//!   `.gnu_debuglink` naming the debug file with its CRC-32. Loaded
//!   segments are copied byte for byte; the non-allocated sections after
//!   them, a new `.shstrtab` and the section header table are rewritten.
//! - The debug file is the unstripped binary itself, which GDB and the
//!   symbolizer accept (same build-id, full DWARF).
//! - `buildId` reads the GNU build-id note.

const std = @import("std");
const Allocator = std.mem.Allocator;
const elf = std.elf;

pub const Error = error{ NotElf, Unsupported, Malformed, OutOfMemory };

const Shdr = elf.Elf64_Shdr;
const Ehdr = elf.Elf64_Ehdr;
const Phdr = elf.Elf64_Phdr;

/// A parsed ELF image (views into `bytes`).
pub const Image = struct {
    bytes: []const u8,
    ehdr: Ehdr,
    shdrs: []align(1) const Shdr,
    phdrs: []align(1) const Phdr,
    shstrtab: []const u8,

    pub fn parse(bytes: []const u8) Error!Image {
        if (bytes.len < @sizeOf(Ehdr) or !std.mem.eql(u8, bytes[0..4], elf.MAGIC)) return error.NotElf;
        if (bytes[elf.EI.CLASS] != elf.ELFCLASS64 or bytes[elf.EI.DATA] != elf.ELFDATA2LSB) return error.Unsupported;
        const eh = std.mem.bytesToValue(Ehdr, bytes[0..@sizeOf(Ehdr)]);
        const shdrs = try table(Shdr, bytes, eh.e_shoff, eh.e_shnum, eh.e_shentsize);
        const phdrs = try table(Phdr, bytes, eh.e_phoff, eh.e_phnum, eh.e_phentsize);
        if (eh.e_shstrndx >= shdrs.len) return error.Malformed;
        return .{ .bytes = bytes, .ehdr = eh, .shdrs = shdrs, .phdrs = phdrs, .shstrtab = try contents(bytes, shdrs[eh.e_shstrndx]) };
    }

    fn table(comptime T: type, bytes: []const u8, off: u64, n: u16, entsize: u16) Error![]align(1) const T {
        if (n == 0) return &.{};
        if (entsize != @sizeOf(T)) return error.Malformed;
        const end = std.math.add(u64, off, @as(u64, n) * @sizeOf(T)) catch return error.Malformed;
        if (end > bytes.len) return error.Malformed;
        return std.mem.bytesAsSlice(T, bytes[@intCast(off)..@intCast(end)]);
    }

    /// The name of section `s`.
    pub fn name(img: *const Image, s: Shdr) []const u8 {
        if (s.sh_name >= img.shstrtab.len) return "";
        return std.mem.sliceTo(img.shstrtab[s.sh_name..], 0);
    }

    /// The first section called `n`, or null.
    pub fn section(img: *const Image, n: []const u8) ?Shdr {
        for (img.shdrs) |s| if (std.mem.eql(u8, img.name(s), n)) return s;
        return null;
    }

    /// The bytes of section `s` (empty for NOBITS).
    pub fn data(img: *const Image, s: Shdr) Error![]const u8 {
        return contents(img.bytes, s);
    }
};

fn contents(bytes: []const u8, s: Shdr) Error![]const u8 {
    if (s.sh_type == elf.SHT_NOBITS) return &.{};
    const end = std.math.add(u64, s.sh_offset, s.sh_size) catch return error.Malformed;
    if (end > bytes.len) return error.Malformed;
    return bytes[@intCast(s.sh_offset)..@intCast(end)];
}

/// Whether a section named `n` is debug info that `strip` removes.
pub fn isDebug(n: []const u8) bool {
    return std.mem.startsWith(u8, n, ".debug") or std.mem.startsWith(u8, n, ".zdebug");
}

/// The GNU build-id as lowercase hex in `out`, or null without one.
pub fn buildId(img: *const Image, out: []u8) Error!?[]const u8 {
    for (img.shdrs) |s| {
        if (s.sh_type != elf.SHT_NOTE) continue;
        var notes = try img.data(s);
        while (notes.len >= 12) {
            const namesz = std.mem.readInt(u32, notes[0..4], .little);
            const descsz = std.mem.readInt(u32, notes[4..8], .little);
            const ntype = std.mem.readInt(u32, notes[8..12], .little);
            const name_end = 12 + std.mem.alignForward(usize, namesz, 4);
            const desc_end = name_end + std.mem.alignForward(usize, descsz, 4);
            if (desc_end > notes.len) return error.Malformed;
            if (ntype == 3 and namesz == 4 and std.mem.eql(u8, notes[12..16], "GNU\x00")) {
                const desc = notes[name_end..][0..descsz];
                if (out.len < desc.len * 2) return error.Malformed;
                const digits = "0123456789abcdef";
                for (desc, 0..) |byte, k| {
                    out[2 * k] = digits[byte >> 4];
                    out[2 * k + 1] = digits[byte & 15];
                }
                return out[0 .. desc.len * 2];
            }
            notes = notes[desc_end..];
        }
    }
    return null;
}

/// The `.gnu_debuglink` file name and CRC-32, or null.
pub fn debugLink(img: *const Image) Error!?struct { name: []const u8, crc: u32 } {
    const s = img.section(".gnu_debuglink") orelse return null;
    const d = try img.data(s);
    const n = std.mem.indexOfScalar(u8, d, 0) orelse return error.Malformed;
    const crc_at = std.mem.alignForward(usize, n + 1, 4);
    if (crc_at + 4 > d.len) return error.Malformed;
    return .{ .name = d[0..n], .crc = std.mem.readInt(u32, d[crc_at..][0..4], .little) };
}

/// The CRC-32 `.gnu_debuglink` records (the IEEE polynomial, like zlib).
pub fn linkCrc(debug_file: []const u8) u32 {
    return std.hash.Crc32.hash(debug_file);
}

/// `input` without debug sections, with a `.gnu_debuglink` to
/// `link_name` whose contents are `debug_file`.
pub fn strip(gpa: Allocator, input: []const u8, link_name: []const u8, debug_file: []const u8) Error![]u8 {
    const img = try Image.parse(input);
    // Everything up to the end of the loaded segments and headers stays put.
    var fixed_end: u64 = @max(@sizeOf(Ehdr), img.ehdr.e_phoff + @as(u64, img.ehdr.e_phnum) * @sizeOf(Phdr));
    for (img.phdrs) |p| fixed_end = @max(fixed_end, p.p_offset + p.p_filesz);
    if (fixed_end > input.len) return error.Malformed;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, input[0..@intCast(fixed_end)]);

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    try names.append(gpa, 0);
    var shdrs: std.ArrayList(Shdr) = .empty;
    defer shdrs.deinit(gpa);
    // Old index -> new index (0 = dropped).
    const remap = try gpa.alloc(u32, img.shdrs.len);
    defer gpa.free(remap);
    @memset(remap, 0);

    for (img.shdrs, 0..) |s, i| {
        const n = img.name(s);
        if (i != 0 and (isDebug(n) or i == img.ehdr.e_shstrndx)) continue;
        var ns = s;
        if (i != 0) {
            ns.sh_name = @intCast(names.items.len);
            try names.appendSlice(gpa, n);
            try names.append(gpa, 0);
            const in_fixed = s.sh_type == elf.SHT_NOBITS or s.sh_size == 0 or s.sh_offset + s.sh_size <= fixed_end;
            if (!in_fixed) {
                if (s.sh_flags & elf.SHF_ALLOC != 0) return error.Unsupported;
                ns.sh_offset = try place(gpa, &out, try img.data(s), s.sh_addralign);
            }
        }
        remap[i] = @intCast(shdrs.items.len);
        try shdrs.append(gpa, ns);
    }
    for (shdrs.items) |*s| {
        if (s.sh_link < remap.len) s.sh_link = remap[s.sh_link];
        const info_is_index = s.sh_flags & elf.SHF_INFO_LINK != 0 or s.sh_type == elf.SHT_REL or s.sh_type == elf.SHT_RELA;
        if (info_is_index and s.sh_info < remap.len) s.sh_info = remap[s.sh_info];
    }

    // .gnu_debuglink: the name, padding to 4, the CRC.
    var link: std.ArrayList(u8) = .empty;
    defer link.deinit(gpa);
    try link.appendSlice(gpa, link_name);
    try link.append(gpa, 0);
    try link.appendNTimes(gpa, 0, std.mem.alignForward(usize, link.items.len, 4) - link.items.len);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, linkCrc(debug_file), .little);
    try link.appendSlice(gpa, &crc);
    const link_name_off: u32 = @intCast(names.items.len);
    try names.appendSlice(gpa, ".gnu_debuglink\x00");
    try shdrs.append(gpa, .{ .sh_name = link_name_off, .sh_type = elf.SHT_PROGBITS, .sh_flags = 0, .sh_addr = 0, .sh_offset = try place(gpa, &out, link.items, 4), .sh_size = link.items.len, .sh_link = 0, .sh_info = 0, .sh_addralign = 4, .sh_entsize = 0 });

    const shstr_name: u32 = @intCast(names.items.len);
    try names.appendSlice(gpa, ".shstrtab\x00");
    const shstrndx: u16 = @intCast(shdrs.items.len);
    try shdrs.append(gpa, .{ .sh_name = shstr_name, .sh_type = elf.SHT_STRTAB, .sh_flags = 0, .sh_addr = 0, .sh_offset = try place(gpa, &out, names.items, 1), .sh_size = names.items.len, .sh_link = 0, .sh_info = 0, .sh_addralign = 1, .sh_entsize = 0 });

    const shoff = try place(gpa, &out, std.mem.sliceAsBytes(shdrs.items), 8);
    var eh = img.ehdr;
    eh.e_shoff = shoff;
    eh.e_shnum = @intCast(shdrs.items.len);
    eh.e_shstrndx = shstrndx;
    @memcpy(out.items[0..@sizeOf(Ehdr)], std.mem.asBytes(&eh));
    return out.toOwnedSlice(gpa);
}

/// Appends `bytes` at the next multiple of `align_to`; returns its offset.
fn place(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8, align_to: u64) Error!u64 {
    const a: usize = @intCast(@max(align_to, 1));
    try out.appendNTimes(gpa, 0, std.mem.alignForward(usize, out.items.len, a) - out.items.len);
    const off = out.items.len;
    try out.appendSlice(gpa, bytes);
    return off;
}

const testing = std.testing;

/// A small ELF: one PT_LOAD over `.text`, a build-id note, a debug
/// section, `.symtab` linked to `.strtab`, and `.shstrtab` in the middle.
fn fixture(gpa: Allocator) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendNTimes(gpa, 0, @sizeOf(Ehdr) + @sizeOf(Phdr));
    const note_off = b.items.len;
    const note = "\x04\x00\x00\x00\x04\x00\x00\x00\x03\x00\x00\x00GNU\x00\xde\xad\xbe\xef";
    try b.appendSlice(gpa, note);
    const text_off = b.items.len;
    try b.appendSlice(gpa, "\xc3" ** 16);
    const load_end = b.items.len;
    const dbg_off = b.items.len;
    try b.appendSlice(gpa, "DWARF!" ** 10);
    const shstr_off = b.items.len;
    const shstr = "\x00.note.gnu.build-id\x00.text\x00.debug_info\x00.shstrtab\x00.symtab\x00.strtab\x00";
    try b.appendSlice(gpa, shstr);
    while (b.items.len % 8 != 0) try b.append(gpa, 0);
    const sym_off = b.items.len;
    try b.appendNTimes(gpa, 0, 2 * @sizeOf(elf.Elf64_Sym));
    const str_off = b.items.len;
    try b.appendSlice(gpa, "\x00main\x00");
    while (b.items.len % 8 != 0) try b.append(gpa, 0);
    const shoff = b.items.len;
    const S = struct {
        fn h(n: u32, t: u32, f: u64, off: usize, size: usize, link: u32, info: u32, al: u64, ent: u64) Shdr {
            return .{ .sh_name = n, .sh_type = t, .sh_flags = f, .sh_addr = if (f & elf.SHF_ALLOC != 0) 0x400000 + off else 0, .sh_offset = off, .sh_size = size, .sh_link = link, .sh_info = info, .sh_addralign = al, .sh_entsize = ent };
        }
    };
    const shdrs = [_]Shdr{
        std.mem.zeroes(Shdr),
        S.h(1, elf.SHT_NOTE, elf.SHF_ALLOC, note_off, note.len, 0, 0, 4, 0),
        S.h(20, elf.SHT_PROGBITS, elf.SHF_ALLOC | elf.SHF_EXECINSTR, text_off, 16, 0, 0, 16, 0),
        S.h(26, elf.SHT_PROGBITS, 0, dbg_off, 60, 0, 0, 1, 0),
        S.h(38, elf.SHT_STRTAB, 0, shstr_off, shstr.len, 0, 0, 1, 0),
        S.h(48, elf.SHT_SYMTAB, 0, sym_off, 2 * @sizeOf(elf.Elf64_Sym), 6, 1, 8, @sizeOf(elf.Elf64_Sym)),
        S.h(56, elf.SHT_STRTAB, 0, str_off, 6, 0, 0, 1, 0),
    };
    try b.appendSlice(gpa, std.mem.sliceAsBytes(&shdrs));
    var eh = std.mem.zeroes(Ehdr);
    @memcpy(eh.e_ident[0..4], elf.MAGIC);
    eh.e_ident[elf.EI.CLASS] = elf.ELFCLASS64;
    eh.e_ident[elf.EI.DATA] = elf.ELFDATA2LSB;
    eh.e_ident[elf.EI.VERSION] = 1;
    eh.e_type = .EXEC;
    eh.e_machine = .X86_64;
    eh.e_version = 1;
    eh.e_entry = 0x400000 + text_off;
    eh.e_phoff = @sizeOf(Ehdr);
    eh.e_shoff = shoff;
    eh.e_ehsize = @sizeOf(Ehdr);
    eh.e_phentsize = @sizeOf(Phdr);
    eh.e_phnum = 1;
    eh.e_shentsize = @sizeOf(Shdr);
    eh.e_shnum = shdrs.len;
    eh.e_shstrndx = 4;
    @memcpy(b.items[0..@sizeOf(Ehdr)], std.mem.asBytes(&eh));
    const ph: Phdr = .{ .p_type = elf.PT_LOAD, .p_flags = elf.PF_R | elf.PF_X, .p_offset = 0, .p_vaddr = 0x400000, .p_paddr = 0x400000, .p_filesz = load_end, .p_memsz = load_end, .p_align = 0x1000 };
    @memcpy(b.items[@sizeOf(Ehdr)..][0..@sizeOf(Phdr)], std.mem.asBytes(&ph));
    return b.toOwnedSlice(gpa);
}

test "elf_debug: strip drops debug sections and links the debug file" {
    const gpa = testing.allocator;
    const in = try fixture(gpa);
    defer gpa.free(in);
    const orig = try Image.parse(in);
    var idbuf: [128]u8 = undefined;
    try testing.expectEqualStrings("deadbeef", (try buildId(&orig, &idbuf)).?);
    try testing.expect(orig.section(".debug_info") != null);

    const out = try strip(gpa, in, "zg.debug", in);
    defer gpa.free(out);
    try testing.expect(out.len < in.len + 200);
    const img = try Image.parse(out);
    try testing.expect(img.section(".debug_info") == null);
    try testing.expectEqualStrings("deadbeef", (try buildId(&img, &idbuf)).?);
    const link = (try debugLink(&img)).?;
    try testing.expectEqualStrings("zg.debug", link.name);
    try testing.expectEqual(linkCrc(in), link.crc);
    // Loaded bytes are unchanged; .symtab still links .strtab.
    try testing.expectEqualSlices(u8, in[@sizeOf(Ehdr)..0x9c], out[@sizeOf(Ehdr)..0x9c]);
    const symtab = img.section(".symtab").?;
    try testing.expectEqualStrings(".strtab", img.name(img.shdrs[symtab.sh_link]));
    try testing.expectEqualStrings("\x00main\x00", try img.data(img.shdrs[symtab.sh_link]));
    try testing.expectEqualStrings(".shstrtab", img.name(img.shdrs[img.ehdr.e_shstrndx]));
}

test "elf_debug: rejects what it cannot handle" {
    try testing.expectError(error.NotElf, Image.parse("MZ not an elf file at all, padding padding padding padding padding"));
    var b32 = [_]u8{0} ** 64;
    @memcpy(b32[0..4], elf.MAGIC);
    b32[elf.EI.CLASS] = elf.ELFCLASS32;
    try testing.expectError(error.Unsupported, Image.parse(&b32));
}
