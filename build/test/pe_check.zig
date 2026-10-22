//! `pe-check <exe> <a.b.c.d> [needle...]` (E17.F01.S01.T02): asserts that
//! a Windows executable's `.rsrc` holds RT_MANIFEST, RT_VERSION and
//! RT_GROUP_ICON, that its VERSIONINFO fixed file version is `a.b.c.d`,
//! and that the manifest contains every needle. Runs on any host.

const std = @import("std");

pub const rt_icon = 3;
pub const rt_group_icon = 14;
pub const rt_version = 16;
pub const rt_manifest = 24;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len < 3) {
        std.debug.print("usage: pe-check <exe> <a.b.c.d> [needle...]\n", .{});
        return 2;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, argv[1], gpa, .limited(512 * 1024 * 1024));
    const pe = Pe.parse(bytes) catch |err| {
        std.debug.print("pe-check: {s}: {t}\n", .{ argv[1], err });
        return 1;
    };
    var failed = false;
    for ([_]u32{ rt_manifest, rt_version, rt_group_icon, rt_icon }) |t| {
        if (pe.resource(t) == null) {
            std.debug.print("pe-check: {s}: no resource of type {d}\n", .{ argv[1], t });
            failed = true;
        }
    }
    if (pe.resource(rt_version)) |v| {
        const want = try parseVersion4(argv[2]);
        const got = fixedFileVersion(v) orelse {
            std.debug.print("pe-check: {s}: VERSIONINFO has no fixed file info\n", .{argv[1]});
            return 1;
        };
        if (!std.mem.eql(u16, &want, &got)) {
            std.debug.print("pe-check: {s}: file version {any}, want {any}\n", .{ argv[1], got, want });
            failed = true;
        }
    }
    if (pe.resource(rt_manifest)) |m| for (argv[3..]) |needle| {
        if (std.mem.indexOf(u8, m, needle) == null) {
            std.debug.print("pe-check: {s}: manifest lacks \"{s}\"\n", .{ argv[1], needle });
            failed = true;
        }
    };
    return if (failed) 1 else 0;
}

pub const Pe = struct {
    bytes: []const u8,
    sections: []const u8,
    nsections: u16,
    rsrc_rva: u32,
    rsrc_size: u32,

    pub const Error = error{ NotPe, Truncated, NoResources };

    pub fn parse(bytes: []const u8) Error!Pe {
        if (bytes.len < 0x40 or !std.mem.eql(u8, bytes[0..2], "MZ")) return error.NotPe;
        const pe = rd(u32, bytes, 0x3c) orelse return error.Truncated;
        if (pe + 24 > bytes.len or !std.mem.eql(u8, bytes[pe..][0..4], "PE\x00\x00")) return error.NotPe;
        const nsec = rd(u16, bytes, pe + 6) orelse return error.Truncated;
        const opt_size = rd(u16, bytes, pe + 20) orelse return error.Truncated;
        const opt = pe + 24;
        const magic = rd(u16, bytes, opt) orelse return error.Truncated;
        // Data directories start at 96 (PE32) or 112 (PE32+); index 2 is resources.
        const dd: usize = opt + @as(usize, if (magic == 0x20b) 112 else 96) + 2 * 8;
        const rva = rd(u32, bytes, dd) orelse return error.Truncated;
        const size = rd(u32, bytes, dd + 4) orelse return error.Truncated;
        if (rva == 0) return error.NoResources;
        const sec = opt + opt_size;
        if (sec + @as(usize, nsec) * 40 > bytes.len) return error.Truncated;
        return .{ .bytes = bytes, .sections = bytes[sec..][0 .. @as(usize, nsec) * 40], .nsections = nsec, .rsrc_rva = rva, .rsrc_size = size };
    }

    /// The file offset of `rva`.
    fn offset(p: Pe, rva: u32) ?usize {
        for (0..p.nsections) |i| {
            const s = p.sections[i * 40 ..][0..40];
            const vsize = std.mem.readInt(u32, s[8..12], .little);
            const vaddr = std.mem.readInt(u32, s[12..16], .little);
            const raw = std.mem.readInt(u32, s[20..24], .little);
            if (rva >= vaddr and rva < vaddr + vsize) return raw + (rva - vaddr);
        }
        return null;
    }

    /// The data of the first resource of type `type_id` (first name, first
    /// language).
    pub fn resource(p: Pe, type_id: u32) ?[]const u8 {
        const base = p.offset(p.rsrc_rva) orelse return null;
        const by_name = p.entry(base, 0, type_id) orelse return null;
        const by_lang = p.entry(base, by_name, null) orelse return null;
        const leaf = p.entry(base, by_lang, null) orelse return null;
        const data_rva = rd(u32, p.bytes, base + leaf) orelse return null;
        const size = rd(u32, p.bytes, base + leaf + 4) orelse return null;
        const off = p.offset(data_rva) orelse return null;
        if (off + size > p.bytes.len) return null;
        return p.bytes[off..][0..size];
    }

    /// In the directory at `dir` (relative to the resource base), the
    /// target of the entry with id `id` (or the first entry), relative to
    /// the base. Subdirectory offsets have their high bit cleared.
    fn entry(p: Pe, base: usize, dir: usize, id: ?u32) ?usize {
        const named = rd(u16, p.bytes, base + dir + 12) orelse return null;
        const ids = rd(u16, p.bytes, base + dir + 14) orelse return null;
        const n = @as(usize, named) + ids;
        for (0..n) |i| {
            const e = base + dir + 16 + i * 8;
            const name = rd(u32, p.bytes, e) orelse return null;
            const target = rd(u32, p.bytes, e + 4) orelse return null;
            if (id == null or (name & 0x8000_0000 == 0 and name == id.?)) return target & 0x7fff_ffff;
        }
        return null;
    }
};

/// The four u16 fields of VS_FIXEDFILEINFO's file version.
pub fn fixedFileVersion(v: []const u8) ?[4]u16 {
    var sig: [4]u8 = undefined;
    std.mem.writeInt(u32, &sig, 0xFEEF04BD, .little);
    const at = std.mem.indexOf(u8, v, &sig) orelse return null;
    const ms = rd(u32, v, at + 8) orelse return null;
    const ls = rd(u32, v, at + 12) orelse return null;
    return .{ @truncate(ms >> 16), @truncate(ms), @truncate(ls >> 16), @truncate(ls) };
}

pub fn parseVersion4(s: []const u8) ![4]u16 {
    var out: [4]u16 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&out) |*o| o.* = try std.fmt.parseInt(u16, it.next() orelse return error.BadVersion, 10);
    if (it.next() != null) return error.BadVersion;
    return out;
}

fn rd(comptime T: type, b: []const u8, at: usize) ?T {
    if (at + @sizeOf(T) > b.len) return null;
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

test "pe_check: version parsing and fixed file info" {
    try std.testing.expectEqual([4]u16{ 1, 2, 3, 4 }, try parseVersion4("1.2.3.4"));
    try std.testing.expectError(error.BadVersion, parseVersion4("1.2.3"));
    var v: [32]u8 = @splat(0);
    std.mem.writeInt(u32, v[4..8], 0xFEEF04BD, .little);
    std.mem.writeInt(u32, v[12..16], 0x0001_0002, .little);
    std.mem.writeInt(u32, v[16..20], 0x0003_0004, .little);
    try std.testing.expectEqual([4]u16{ 1, 2, 3, 4 }, fixedFileVersion(&v).?);
    try std.testing.expectError(error.NotPe, Pe.parse(&v ** 3));
}
