//! `CFF ` and `CFF2`: INDEX and DICT parsing, the Top/Font/Private DICTs,
//! CID FDSelect, charsets (for `seac`), and the CFF2 VariationStore. Glyph
//! programs run in `cff_charstring.zig`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const reader = @import("reader.zig");
const ivs = @import("var/ivs.zig");
const path_mod = @import("../outline/path.zig");
const charstring = @import("cff_charstring.zig");

const GlyphId = reader.GlyphId;

/// Which table the bytes come from.
pub const Version = enum { cff1, cff2 };

/// Region scalars of the CFF2 VariationStore at an instance (see
/// `ItemVariationStore.regionScalars`).
pub const BlendCtx = struct { scalars: []const f32 };

/// A CFF INDEX: `count` objects addressed by 1-based offsets.
pub const Index = struct {
    count: u32 = 0,
    off_size: u8 = 1,
    offsets: []const u8 = &.{},
    /// The object data; offsets are relative to the byte before it.
    data: []const u8 = &.{},

    /// Parses the INDEX at `pos` of `bytes`; also returns the offset just
    /// past it.
    pub fn parse(bytes: []const u8, pos: usize, version: Version) error{Malformed}!struct { Index, usize } {
        var r = try reader.Reader.at(bytes, pos);
        const count: u32 = if (version == .cff1) try r.u16_() else try r.u32_();
        if (count == 0) return .{ .{}, r.pos };
        const off_size = try r.u8_();
        if (off_size < 1 or off_size > 4) return error.Malformed;
        const offsets = try r.slice((@as(usize, count) + 1) * off_size);
        var ix: Index = .{ .count = count, .off_size = off_size, .offsets = offsets };
        const last = ix.offsetAt(count);
        if (last < 1) return error.Malformed;
        ix.data = try r.slice(last - 1);
        return .{ ix, r.pos };
    }

    fn offsetAt(ix: *const Index, i: usize) u32 {
        const b = ix.offsets[i * ix.off_size ..][0..ix.off_size];
        var v: u32 = 0;
        for (b) |x| v = (v << 8) | x;
        return v;
    }

    /// Object `i`; offsets must be monotonic and in range.
    pub fn get(ix: *const Index, i: usize) error{Malformed}![]const u8 {
        if (i >= ix.count) return error.Malformed;
        const a = ix.offsetAt(i);
        const b = ix.offsetAt(i + 1);
        if (a < 1 or a > b or b - 1 > ix.data.len) return error.Malformed;
        return ix.data[a - 1 .. b - 1];
    }
};

/// The bias added to subroutine numbers for an INDEX of `count` subrs.
pub fn subrBias(count: u32) i32 {
    if (count < 1240) return 107;
    if (count < 33900) return 1131;
    return 32768;
}

/// DICT operator codes; two-byte operators are 1200 + the second byte.
pub const Op = struct {
    pub const charset = 15;
    pub const char_strings = 17;
    pub const private = 18;
    pub const subrs = 19;
    pub const default_width_x = 20;
    pub const nominal_width_x = 21;
    pub const vsindex = 22;
    pub const blend = 23;
    pub const vstore = 24;
    pub const charstring_type = 1206;
    pub const font_matrix = 1207;
    pub const ros = 1230;
    pub const fd_array = 1236;
    pub const fd_select = 1237;
};

/// Iterates DICT entries. Operands are kept as f64. CFF2 `blend` keeps
/// the default values (DICT data does not vary here); it needs the store
/// to know how many deltas follow each value.
pub const DictIter = struct {
    r: reader.Reader,
    stack: [513]f64 = undefined,
    n: usize = 0,
    store: ?*const ivs.ItemVariationStore = null,
    vsindex: u16 = 0,

    /// An iterator over the DICT `data`.
    pub fn init(data: []const u8) DictIter {
        return .{ .r = .{ .data = data } };
    }

    /// One DICT entry.
    pub const Entry = struct { op: u16, args: []const f64 };

    /// The next entry, or null at the end.
    pub fn next(d: *DictIter) error{Malformed}!?Entry {
        d.n = 0;
        while (d.r.remaining() > 0) {
            const b0 = try d.r.u8_();
            if (b0 <= 21 or b0 == 23 or b0 == 24) {
                const op: u16 = if (b0 == 12) 1200 + @as(u16, try d.r.u8_()) else b0;
                if (op == Op.blend) {
                    // n defaults, n*k deltas, n: keep the defaults.
                    const st = d.store orelse return error.Malformed;
                    const k = (try st.itemData(d.vsindex)).regionCount();
                    if (d.n < 1) return error.Malformed;
                    const nv: usize = @intFromFloat(std.math.clamp(d.stack[d.n - 1], 0, 513));
                    const used = nv * (@as(usize, k) + 1);
                    if (used > d.n - 1) return error.Malformed;
                    d.n = d.n - 1 - used + nv;
                    continue;
                }
                if (op == Op.vsindex and d.n > 0) d.vsindex = @intFromFloat(std.math.clamp(d.stack[0], 0, 65535));
                return .{ .op = op, .args = d.stack[0..d.n] };
            }
            const v: f64 = switch (b0) {
                28 => @floatFromInt(try d.r.i16_()),
                29 => @floatFromInt(try d.r.i32_()),
                30 => try d.real(),
                32...246 => @floatFromInt(@as(i32, b0) - 139),
                247...250 => @floatFromInt((@as(i32, b0) - 247) * 256 + try d.r.u8_() + 108),
                251...254 => @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, try d.r.u8_()) - 108),
                else => return error.Malformed,
            };
            if (d.n == d.stack.len) return error.Malformed;
            d.stack[d.n] = v;
            d.n += 1;
        }
        return null;
    }

    fn real(d: *DictIter) error{Malformed}!f64 {
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        while (true) {
            const b = try d.r.u8_();
            for ([2]u4{ @intCast(b >> 4), @intCast(b & 0xF) }) |nib| {
                const s: []const u8 = switch (nib) {
                    0...9 => &.{'0' + @as(u8, nib)},
                    0xa => ".",
                    0xb => "E",
                    0xc => "E-",
                    0xd => return error.Malformed,
                    0xe => "-",
                    0xf => return std.fmt.parseFloat(f64, buf[0..n]) catch error.Malformed,
                };
                if (n + s.len > buf.len) return error.Malformed;
                @memcpy(buf[n..][0..s.len], s);
                n += s.len;
            }
        }
    }
};

/// What a Private DICT gives the charstring interpreter.
pub const Private = struct {
    subrs: Index = .{},
    default_width_x: f32 = 0,
    nominal_width_x: f32 = 0,
    /// CFF2 default `vsindex`.
    vsindex: u16 = 0,
};

fn parsePrivate(table: []const u8, size: f64, offset: f64, version: Version, store: ?*const ivs.ItemVariationStore) error{Malformed}!Private {
    if (size < 0 or offset < 0 or size > 1 << 30 or offset > 1 << 30) return error.Malformed;
    const off: usize = @intFromFloat(offset);
    const data = try reader.subLen(table, off, @intFromFloat(size));
    var p: Private = .{};
    var it = DictIter.init(data);
    it.store = store;
    while (try it.next()) |e| {
        const a0: f64 = if (e.args.len > 0) e.args[0] else 0;
        switch (e.op) {
            Op.subrs => {
                if (a0 < 0 or a0 > 1 << 30) return error.Malformed;
                p.subrs = (try Index.parse(table, off + @as(usize, @intFromFloat(a0)), version))[0];
            },
            Op.default_width_x => p.default_width_x = @floatCast(a0),
            Op.nominal_width_x => p.nominal_width_x = @floatCast(a0),
            Op.vsindex => p.vsindex = @intFromFloat(std.math.clamp(a0, 0, 65535)),
            else => {},
        }
    }
    return p;
}

/// A parsed `CFF ` or `CFF2` table (first font only).
pub const Cff = struct {
    table: []const u8,
    version: Version,
    char_strings: Index,
    gsubrs: Index,
    /// The Private DICT of a non-CID CFF1 font (CID and CFF2 fonts use
    /// `fd_array`).
    private: Private = .{},
    fd_array: ?Index = null,
    /// Offset of FDSelect, when present.
    fd_select: ?usize = null,
    /// CFF1 charset offset (0 = ISOAdobe, 1 = Expert, 2 = ExpertSubset).
    charset: usize = 0,
    font_matrix: ?[6]f32 = null,
    /// The CFF2 VariationStore.
    store: ?ivs.ItemVariationStore = null,

    /// Parses the header, Top DICT and the INDEXes the outlines need.
    pub fn init(table: []const u8, version: Version) error{ Malformed, Unsupported }!Cff {
        var c: Cff = .{ .table = table, .version = version, .char_strings = .{}, .gsubrs = .{} };
        const major = try reader.readAt(u8, table, 0);
        const hdr = try reader.readAt(u8, table, 2);
        var top: []const u8 = undefined;
        switch (version) {
            .cff1 => {
                if (major != 1) return error.Unsupported;
                const names, const after_names = try Index.parse(table, hdr, .cff1);
                if (names.count < 1) return error.Malformed;
                const tops, const after_tops = try Index.parse(table, after_names, .cff1);
                top = try tops.get(0);
                _, const after_strings = try Index.parse(table, after_tops, .cff1);
                c.gsubrs = (try Index.parse(table, after_strings, .cff1))[0];
            },
            .cff2 => {
                if (major != 2) return error.Unsupported;
                const top_len = try reader.readAt(u16, table, 3);
                top = try reader.subLen(table, hdr, top_len);
                c.gsubrs = (try Index.parse(table, @as(usize, hdr) + top_len, .cff2))[0];
            },
        }
        var priv: ?[2]f64 = null;
        var it = DictIter.init(top);
        var have_cs = false;
        while (try it.next()) |e| {
            const a = e.args;
            switch (e.op) {
                Op.char_strings => {
                    c.char_strings = (try Index.parse(table, try offsetArg(a), version))[0];
                    have_cs = true;
                },
                Op.private => if (a.len >= 2) {
                    priv = .{ a[0], a[1] };
                },
                Op.fd_array => c.fd_array = (try Index.parse(table, try offsetArg(a), version))[0],
                Op.fd_select => c.fd_select = try offsetArg(a),
                Op.charset => c.charset = try offsetArg(a),
                Op.charstring_type => if (a.len > 0 and a[0] != 2) return error.Unsupported,
                Op.font_matrix => if (a.len == 6) {
                    var m: [6]f32 = undefined;
                    for (&m, a) |*x, v| x.* = @floatCast(v);
                    c.font_matrix = m;
                },
                Op.vstore => if (version == .cff2) {
                    // A u16 length precedes the store.
                    const off = try offsetArg(a);
                    c.store = try ivs.ItemVariationStore.init(try reader.sub(table, off + 2));
                },
                else => {},
            }
        }
        if (!have_cs) return error.Malformed;
        if (c.fd_array == null) {
            if (version == .cff2) return error.Malformed;
            const p = priv orelse return error.Malformed;
            c.private = try parsePrivate(table, p[0], p[1], version, null);
        }
        return c;
    }

    fn offsetArg(a: []const f64) error{Malformed}!usize {
        if (a.len < 1 or a[a.len - 1] < 0 or a[a.len - 1] > 1 << 30) return error.Malformed;
        return @intFromFloat(a[a.len - 1]);
    }

    /// Number of glyphs (CharStrings).
    pub fn glyphCount(c: *const Cff) u32 {
        return c.char_strings.count;
    }

    /// The FontMatrix as an affine map from charstring units to em units
    /// (default: 0.001 scale). Scale by units_per_em for font units.
    pub fn fontMatrix(c: *const Cff) path_mod.Affine {
        const m = c.font_matrix orelse return .{ .xx = 0.001, .yy = 0.001 };
        return .{ .xx = m[0], .yx = m[1], .xy = m[2], .yy = m[3], .dx = m[4], .dy = m[5] };
    }

    /// The Font DICT index of `gid` (0 without FDSelect).
    pub fn fdIndex(c: *const Cff, gid: GlyphId) error{Malformed}!u16 {
        const off = c.fd_select orelse return 0;
        const t = c.table;
        const format = try reader.readAt(u8, t, off);
        switch (format) {
            0 => return try reader.readAt(u8, t, off + 1 + @as(usize, gid)),
            3, 4 => {
                const wide = format == 4;
                const n: u32 = if (wide) try reader.readAt(u32, t, off + 1) else try reader.readAt(u16, t, off + 1);
                const rec: usize = if (wide) 6 else 3;
                const base = off + (if (wide) @as(usize, 5) else 3);
                _ = try reader.subLen(t, base, @as(usize, n) * rec + rec);
                // Binary search the last range whose first glyph <= gid.
                var lo: usize = 0;
                var hi: usize = n;
                while (lo < hi) {
                    const mid = (lo + hi) / 2;
                    const first: u32 = if (wide) std.mem.readInt(u32, t[base + mid * rec ..][0..4], .big) else std.mem.readInt(u16, t[base + mid * rec ..][0..2], .big);
                    if (first <= gid) lo = mid + 1 else hi = mid;
                }
                if (lo == 0) return error.Malformed;
                const r = base + (lo - 1) * rec;
                const sentinel: u32 = if (wide) std.mem.readInt(u32, t[base + n * rec ..][0..4], .big) else std.mem.readInt(u16, t[base + n * rec ..][0..2], .big);
                if (gid >= sentinel) return error.Malformed;
                return if (wide) std.mem.readInt(u16, t[r + 4 ..][0..2], .big) else t[r + 2];
            },
            else => return error.Malformed,
        }
    }

    /// The Private DICT for `gid`.
    pub fn privateFor(c: *const Cff, gid: GlyphId) error{Malformed}!Private {
        const fa = c.fd_array orelse return c.private;
        const fd = try c.fdIndex(gid);
        var it = DictIter.init(try fa.get(fd));
        while (try it.next()) |e| if (e.op == Op.private and e.args.len >= 2) {
            return parsePrivate(c.table, e.args[0], e.args[1], c.version, if (c.store) |*st| st else null);
        };
        return .{};
    }

    /// The glyph whose charset SID is `sid` (for `seac`), or null.
    pub fn glyphForSid(c: *const Cff, sid: u16) error{Malformed}!?GlyphId {
        const n = c.glyphCount();
        if (c.charset == 0) return if (sid < n and sid < 229) sid else null; // ISOAdobe: gid = SID
        if (c.charset <= 2) return null;
        const t = c.table;
        const format = try reader.readAt(u8, t, c.charset);
        var r = try reader.Reader.at(t, c.charset + 1);
        var gid: u32 = 1;
        while (gid < n) {
            switch (format) {
                0 => {
                    if (try r.u16_() == sid) return @intCast(gid);
                    gid += 1;
                },
                1, 2 => {
                    const first = try r.u16_();
                    const left: u32 = if (format == 1) try r.u8_() else try r.u16_();
                    if (sid >= first and sid - first <= left) return @intCast(gid + sid - first);
                    gid += left + 1;
                },
                else => return error.Malformed,
            }
        }
        return null;
    }

    /// Appends the outline of `gid`, in charstring units, to `out`. CFF2
    /// `blend` uses `blend` (the default instance when null).
    pub fn outline(c: *const Cff, gid: GlyphId, blend: ?BlendCtx, out: *path_mod.Path, gpa: Allocator) error{ Malformed, OutOfMemory, LimitExceeded }!void {
        return charstring.run(c, gid, blend, out, gpa);
    }
};

/// StandardEncoding code to SID, for `seac`.
pub const standard_encoding = [256]u8{
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    1,   2,   3,   4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,
    17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,
    33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,
    49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,
    65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,  79,  80,
    81,  82,  83,  84,  85,  86,  87,  88,  89,  90,  91,  92,  93,  94,  95,  0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   96,  97,  98,  99,  100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110,
    0,   111, 112, 113, 114, 0,   115, 116, 117, 118, 119, 120, 121, 122, 0,   123,
    0,   124, 125, 126, 127, 128, 129, 130, 131, 0,   132, 133, 0,   134, 135, 136,
    137, 0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   138, 0,   139, 0,   0,   0,   0,   140, 141, 142, 143, 0,   0,   0,   0,
    0,   144, 0,   0,   0,   145, 0,   0,   146, 147, 148, 149, 0,   0,   0,   0,
};

test {
    _ = @import("cff_test.zig");
}
