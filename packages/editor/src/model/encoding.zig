//! File encodings: detection, streaming decoders to the internal UTF-8
//! (WTF-8 for unpaired surrogates) and encoders back, byte-exact for every
//! supported encoding. UTF-8 passes through untouched (invalid bytes
//! included); legacy single-byte encodings use the WHATWG indexes with a
//! private sentinel for undefined bytes (see encoding/single_byte.zig).

const std = @import("std");
const detect_mod = @import("encoding/detect.zig");
const utf16 = @import("encoding/utf16.zig");
const wtf8 = @import("encoding/wtf8.zig");
pub const single_byte = @import("encoding/single_byte.zig");

const Allocator = std.mem.Allocator;

pub const Encoding = enum {
    utf8,
    utf8_bom,
    utf16le,
    utf16le_bom,
    utf16be,
    utf16be_bom,
    utf32le_bom,
    utf32be_bom,
    windows_1250,
    windows_1251,
    windows_1252,
    windows_1253,
    windows_1254,
    windows_1255,
    windows_1256,
    windows_1257,
    windows_1258,
    windows_874,
    iso_8859_2,
    iso_8859_3,
    iso_8859_4,
    iso_8859_5,
    iso_8859_6,
    iso_8859_7,
    iso_8859_8,
    iso_8859_10,
    iso_8859_13,
    iso_8859_14,
    iso_8859_15,
    iso_8859_16,
    koi8_r,
    koi8_u,
    ibm866,
    macintosh,
    /// Not text: bytes 0x80..0xFF decode to the sentinel range so the file
    /// still round-trips.
    binary,

    /// The BOM written before the text.
    pub fn bom(e: Encoding) []const u8 {
        return switch (e) {
            .utf8_bom => "\xEF\xBB\xBF",
            .utf16le_bom => "\xFF\xFE",
            .utf16be_bom => "\xFE\xFF",
            .utf32le_bom => "\xFF\xFE\x00\x00",
            .utf32be_bom => "\x00\x00\xFE\xFF",
            else => "",
        };
    }

    /// The single-byte index, for legacy encodings.
    pub fn singleByte(e: Encoding) ?single_byte.Index {
        return std.meta.stringToEnum(single_byte.Index, @tagName(e));
    }
};

pub const Detection = struct {
    encoding: Encoding,
    confidence: enum { bom, certain, heuristic, default },
    bom_len: u3,
};

/// Detects a file's encoding from its first bytes (see encoding/detect.zig);
/// `fallback` is `files.fallbackEncoding` (WHATWG's default is
/// windows-1252).
pub fn detect(head: []const u8, hint: ?Encoding, fallback: Encoding) Detection {
    return detect_mod.detect(head, hint, fallback);
}

/// Streaming decoder: feed chunks split anywhere; partial code units carry
/// over. A BOM at the start of a BOM encoding is skipped.
pub const Decoder = struct {
    enc: Encoding,
    pending: [4]u8 = undefined,
    pending_len: u3 = 0,
    high: ?u16 = null,
    /// Bytes of the BOM still to skip.
    bom_left: u3,
    started: bool = false,

    pub fn init(e: Encoding) Decoder {
        return .{ .enc = e, .bom_left = @intCast(e.bom().len) };
    }

    /// Appends the decoded text of `in` to `out`. `last` flushes what is
    /// left (a cut code unit becomes U+FFFD).
    pub fn decode(d: *Decoder, in_all: []const u8, out: *std.ArrayList(u8), gpa: Allocator, last: bool) !void {
        var in = in_all;
        // Skip the BOM, which may itself be split across chunks.
        while (!d.started and in.len > 0) {
            const bom = d.enc.bom();
            const at = bom.len - d.bom_left;
            if (d.bom_left == 0) {
                d.started = true;
                break;
            }
            if (in[0] != bom[at]) {
                // No BOM after all: replay what matched.
                d.started = true;
                try d.feed(bom[0..at], out, gpa);
                break;
            }
            d.bom_left -= 1;
            in = in[1..];
            if (d.bom_left == 0) d.started = true;
        }
        try d.feed(in, out, gpa);
        if (last) try d.flush(out, gpa);
    }

    fn unitLen(d: *const Decoder) u3 {
        return switch (d.enc) {
            .utf16le, .utf16le_bom, .utf16be, .utf16be_bom => 2,
            .utf32le_bom, .utf32be_bom => 4,
            else => 1,
        };
    }

    fn feed(d: *Decoder, in_all: []const u8, out: *std.ArrayList(u8), gpa: Allocator) !void {
        var in = in_all;
        const unit = d.unitLen();
        if (unit == 1) return decodeBytes(d.enc, in, out, gpa);
        // Complete a code unit started in the previous chunk.
        if (d.pending_len > 0) {
            const need = unit - d.pending_len;
            const take = @min(need, in.len);
            @memcpy(d.pending[d.pending_len..][0..take], in[0..take]);
            d.pending_len += @intCast(take);
            in = in[take..];
            if (d.pending_len < unit) return;
            try d.units(d.pending[0..unit], out, gpa);
            d.pending_len = 0;
        }
        const whole = in.len - in.len % unit;
        try d.units(in[0..whole], out, gpa);
        const rest = in[whole..];
        @memcpy(d.pending[0..rest.len], rest);
        d.pending_len = @intCast(rest.len);
    }

    fn units(d: *Decoder, in: []const u8, out: *std.ArrayList(u8), gpa: Allocator) !void {
        switch (d.enc) {
            .utf16le, .utf16le_bom => try utf16.decode16(in, .little, &d.high, out, gpa),
            .utf16be, .utf16be_bom => try utf16.decode16(in, .big, &d.high, out, gpa),
            .utf32le_bom => try utf16.decode32(in, .little, out, gpa),
            .utf32be_bom => try utf16.decode32(in, .big, out, gpa),
            else => unreachable,
        }
    }

    fn flush(d: *Decoder, out: *std.ArrayList(u8), gpa: Allocator) !void {
        if (!d.started and d.bom_left > 0 and d.bom_left < d.enc.bom().len) {
            // The input was a partial BOM only.
            d.started = true;
            try d.feed(d.enc.bom()[0 .. d.enc.bom().len - d.bom_left], out, gpa);
        }
        try utf16.finish16(&d.high, out, gpa);
        if (d.pending_len > 0) try wtf8.append(out, gpa, 0xFFFD);
        d.pending_len = 0;
    }
};

fn decodeBytes(e: Encoding, in: []const u8, out: *std.ArrayList(u8), gpa: Allocator) !void {
    switch (e) {
        .utf8, .utf8_bom => try out.appendSlice(gpa, in),
        .binary => {
            try out.ensureUnusedCapacity(gpa, in.len);
            var i: usize = 0;
            while (i < in.len) {
                const run = single_byte.asciiLen(in[i..]);
                try out.appendSlice(gpa, in[i..][0..run]);
                i += run;
                if (i == in.len) break;
                try wtf8.append(out, gpa, single_byte.sentinel_base + in[i]);
                i += 1;
            }
        },
        else => try single_byte.decode(single_byte.table(e.singleByte().?), in, out, gpa),
    }
}

/// Decodes a whole file's bytes (BOM included) in one call.
pub fn decodeAll(e: Encoding, bytes: []const u8, gpa: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var d: Decoder = .init(e);
    try d.decode(bytes, &out, gpa, true);
    return out.toOwnedSlice(gpa);
}

/// Appends `utf8` (the document text) encoded as `e`, BOM first. Fails
/// with `Unrepresentable` when some character has no encoding in `e`;
/// `firstUnrepresentable` gives its offset.
pub fn encode(e: Encoding, utf8: []const u8, out: *std.ArrayList(u8), gpa: Allocator) error{ Unrepresentable, OutOfMemory }!void {
    try out.appendSlice(gpa, e.bom());
    try encodeBody(e, utf8, out, gpa);
}

/// `encode` without the BOM, for streaming a text in pieces that each end
/// on a character boundary.
pub fn encodeBody(e: Encoding, utf8: []const u8, out: *std.ArrayList(u8), gpa: Allocator) error{ Unrepresentable, OutOfMemory }!void {
    switch (e) {
        .utf8, .utf8_bom => try out.appendSlice(gpa, utf8),
        .utf16le, .utf16le_bom => try utf16.encode16(utf8, .little, out, gpa),
        .utf16be, .utf16be_bom => try utf16.encode16(utf8, .big, out, gpa),
        .utf32le_bom => try utf16.encode32(utf8, .little, out, gpa),
        .utf32be_bom => try utf16.encode32(utf8, .big, out, gpa),
        else => {
            try out.ensureUnusedCapacity(gpa, utf8.len);
            var i: usize = 0;
            while (i < utf8.len) {
                const run = single_byte.asciiLen(utf8[i..]);
                out.appendSliceAssumeCapacity(utf8[i..][0..run]);
                i += run;
                if (i == utf8.len) break;
                const n, const b = encodeOne(e, utf8, i) orelse return error.Unrepresentable;
                out.appendAssumeCapacity(b);
                i += n;
            }
        },
    }
}

/// One single-byte output for the code point at `utf8[i]`, with its
/// length, or null when `e` cannot hold it.
fn encodeOne(e: Encoding, utf8: []const u8, i: usize) ?struct { usize, u8 } {
    if (utf8[i] < 0x80) return .{ 1, utf8[i] };
    const d = wtf8.next(utf8, i) orelse return null;
    const b = if (e == .binary)
        (if (d.cp >= single_byte.sentinel_base + 0x80 and d.cp <= single_byte.sentinel_base + 0xFF) @as(u8, @intCast(d.cp - single_byte.sentinel_base)) else return null)
    else
        single_byte.table(e.singleByte().?).toByte(d.cp) orelse return null;
    return .{ d.len, b };
}

/// The byte offset in `utf8` of the first character `e` cannot encode.
pub fn firstUnrepresentable(e: Encoding, utf8: []const u8) ?usize {
    switch (e) {
        .utf8, .utf8_bom => return null,
        .utf16le, .utf16le_bom, .utf16be, .utf16be_bom, .utf32le_bom, .utf32be_bom => return utf16.firstInvalid(utf8),
        else => {
            var i: usize = 0;
            while (i < utf8.len) {
                const n, _ = encodeOne(e, utf8, i) orelse return i;
                i += n;
            }
            return null;
        },
    }
}

/// The name shown in the UI: WHATWG's canonical name, with the BOM noted.
pub fn label(e: Encoding) []const u8 {
    return switch (e) {
        .utf8 => "UTF-8",
        .utf8_bom => "UTF-8 with BOM",
        .utf16le => "UTF-16LE",
        .utf16le_bom => "UTF-16LE with BOM",
        .utf16be => "UTF-16BE",
        .utf16be_bom => "UTF-16BE with BOM",
        .utf32le_bom => "UTF-32LE",
        .utf32be_bom => "UTF-32BE",
        .koi8_r => "KOI8-R",
        .koi8_u => "KOI8-U",
        .ibm866 => "IBM866",
        .macintosh => "macintosh",
        .binary => "binary",
        inline else => |t| comptime blk: {
            @setEvalBranchQuota(10_000);
            const n = @tagName(t);
            var out: [n.len]u8 = n[0..n.len].*;
            for (&out) |*c| c.* = if (c.* == '_') '-' else if (std.mem.startsWith(u8, n, "iso")) std.ascii.toUpper(c.*) else c.*;
            const final = out;
            break :blk &final;
        },
    };
}

/// WHATWG labels (lowercase) for each encoding this editor supports.
const labels = [_]struct { []const u8, Encoding }{
    .{ "unicode-1-1-utf-8", .utf8 },        .{ "unicode11utf8", .utf8 },          .{ "unicode20utf8", .utf8 },
    .{ "utf-8", .utf8 },                    .{ "utf8", .utf8 },                   .{ "x-unicode20utf8", .utf8 },
    .{ "unicodefffe", .utf16be },           .{ "utf-16be", .utf16be },            .{ "csunicode", .utf16le },
    .{ "iso-10646-ucs-2", .utf16le },       .{ "ucs-2", .utf16le },               .{ "unicode", .utf16le },
    .{ "unicodefeff", .utf16le },           .{ "utf-16", .utf16le },              .{ "utf-16le", .utf16le },
    .{ "utf-32le", .utf32le_bom },          .{ "utf-32be", .utf32be_bom },        .{ "utf-32", .utf32le_bom },
    .{ "866", .ibm866 },                    .{ "cp866", .ibm866 },                .{ "csibm866", .ibm866 },
    .{ "ibm866", .ibm866 },                 .{ "csisolatin2", .iso_8859_2 },      .{ "iso-8859-2", .iso_8859_2 },
    .{ "iso-ir-101", .iso_8859_2 },         .{ "iso8859-2", .iso_8859_2 },        .{ "iso88592", .iso_8859_2 },
    .{ "iso_8859-2", .iso_8859_2 },         .{ "l2", .iso_8859_2 },               .{ "latin2", .iso_8859_2 },
    .{ "csisolatin3", .iso_8859_3 },        .{ "iso-8859-3", .iso_8859_3 },       .{ "iso8859-3", .iso_8859_3 },
    .{ "iso88593", .iso_8859_3 },           .{ "l3", .iso_8859_3 },               .{ "latin3", .iso_8859_3 },
    .{ "csisolatin4", .iso_8859_4 },        .{ "iso-8859-4", .iso_8859_4 },       .{ "iso8859-4", .iso_8859_4 },
    .{ "iso88594", .iso_8859_4 },           .{ "l4", .iso_8859_4 },               .{ "latin4", .iso_8859_4 },
    .{ "csisolatincyrillic", .iso_8859_5 }, .{ "cyrillic", .iso_8859_5 },         .{ "iso-8859-5", .iso_8859_5 },
    .{ "iso8859-5", .iso_8859_5 },          .{ "iso88595", .iso_8859_5 },         .{ "arabic", .iso_8859_6 },
    .{ "csisolatinarabic", .iso_8859_6 },   .{ "iso-8859-6", .iso_8859_6 },       .{ "iso8859-6", .iso_8859_6 },
    .{ "iso88596", .iso_8859_6 },           .{ "csisolatingreek", .iso_8859_7 },  .{ "greek", .iso_8859_7 },
    .{ "greek8", .iso_8859_7 },             .{ "iso-8859-7", .iso_8859_7 },       .{ "iso8859-7", .iso_8859_7 },
    .{ "iso88597", .iso_8859_7 },           .{ "csisolatinhebrew", .iso_8859_8 }, .{ "hebrew", .iso_8859_8 },
    .{ "iso-8859-8", .iso_8859_8 },         .{ "iso8859-8", .iso_8859_8 },        .{ "iso88598", .iso_8859_8 },
    .{ "visual", .iso_8859_8 },             .{ "csisolatin6", .iso_8859_10 },     .{ "iso-8859-10", .iso_8859_10 },
    .{ "iso8859-10", .iso_8859_10 },        .{ "iso885910", .iso_8859_10 },       .{ "l6", .iso_8859_10 },
    .{ "latin6", .iso_8859_10 },            .{ "iso-8859-13", .iso_8859_13 },     .{ "iso8859-13", .iso_8859_13 },
    .{ "iso885913", .iso_8859_13 },         .{ "iso-8859-14", .iso_8859_14 },     .{ "iso8859-14", .iso_8859_14 },
    .{ "iso885914", .iso_8859_14 },         .{ "csisolatin9", .iso_8859_15 },     .{ "iso-8859-15", .iso_8859_15 },
    .{ "iso8859-15", .iso_8859_15 },        .{ "iso885915", .iso_8859_15 },       .{ "l9", .iso_8859_15 },
    .{ "iso-8859-16", .iso_8859_16 },       .{ "cskoi8r", .koi8_r },              .{ "koi", .koi8_r },
    .{ "koi8", .koi8_r },                   .{ "koi8-r", .koi8_r },               .{ "koi8_r", .koi8_r },
    .{ "koi8-ru", .koi8_u },                .{ "koi8-u", .koi8_u },               .{ "csmacintosh", .macintosh },
    .{ "mac", .macintosh },                 .{ "macintosh", .macintosh },         .{ "x-mac-roman", .macintosh },
    .{ "dos-874", .windows_874 },           .{ "iso-8859-11", .windows_874 },     .{ "tis-620", .windows_874 },
    .{ "windows-874", .windows_874 },       .{ "cp1250", .windows_1250 },         .{ "windows-1250", .windows_1250 },
    .{ "x-cp1250", .windows_1250 },         .{ "cp1251", .windows_1251 },         .{ "windows-1251", .windows_1251 },
    .{ "x-cp1251", .windows_1251 },         .{ "ansi_x3.4-1968", .windows_1252 }, .{ "ascii", .windows_1252 },
    .{ "cp1252", .windows_1252 },           .{ "cp819", .windows_1252 },          .{ "csisolatin1", .windows_1252 },
    .{ "ibm819", .windows_1252 },           .{ "iso-8859-1", .windows_1252 },     .{ "iso-ir-100", .windows_1252 },
    .{ "iso8859-1", .windows_1252 },        .{ "iso88591", .windows_1252 },       .{ "iso_8859-1", .windows_1252 },
    .{ "l1", .windows_1252 },               .{ "latin1", .windows_1252 },         .{ "us-ascii", .windows_1252 },
    .{ "windows-1252", .windows_1252 },     .{ "x-cp1252", .windows_1252 },       .{ "cp1253", .windows_1253 },
    .{ "windows-1253", .windows_1253 },     .{ "x-cp1253", .windows_1253 },       .{ "cp1254", .windows_1254 },
    .{ "csisolatin5", .windows_1254 },      .{ "iso-8859-9", .windows_1254 },     .{ "iso8859-9", .windows_1254 },
    .{ "iso88599", .windows_1254 },         .{ "l5", .windows_1254 },             .{ "latin5", .windows_1254 },
    .{ "windows-1254", .windows_1254 },     .{ "x-cp1254", .windows_1254 },       .{ "cp1255", .windows_1255 },
    .{ "windows-1255", .windows_1255 },     .{ "x-cp1255", .windows_1255 },       .{ "cp1256", .windows_1256 },
    .{ "windows-1256", .windows_1256 },     .{ "x-cp1256", .windows_1256 },       .{ "cp1257", .windows_1257 },
    .{ "windows-1257", .windows_1257 },     .{ "x-cp1257", .windows_1257 },       .{ "cp1258", .windows_1258 },
    .{ "windows-1258", .windows_1258 },     .{ "x-cp1258", .windows_1258 },       .{ "binary", .binary },
};

/// The encoding a WHATWG label names (ASCII case-insensitive, surrounding
/// whitespace ignored).
pub fn fromLabel(s: []const u8) ?Encoding {
    const t = std.mem.trim(u8, s, " \t\n\r\x0C");
    if (t.len > 32) return null;
    var buf: [32]u8 = undefined;
    const low = std.ascii.lowerString(&buf, t);
    for (labels) |l| if (std.mem.eql(u8, l[0], low)) return l[1];
    return null;
}

test {
    _ = single_byte;
    _ = wtf8;
    _ = @import("encoding/encoding_test.zig");
}
