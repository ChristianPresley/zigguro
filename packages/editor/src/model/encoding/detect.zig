//! Encoding detection from a file's first bytes: BOM, then an explicit
//! hint, then UTF-16 without a BOM, binary (a NUL), valid UTF-8, else the
//! fallback. The NUL check runs before the UTF-8 one because most binary
//! files are also valid UTF-8 in their first 8 KiB.

const std = @import("std");
const zg_core = @import("zg_core");
const enc = @import("../encoding.zig");

const Encoding = enc.Encoding;
const Detection = enc.Detection;

/// Bytes the heuristics look at.
pub const sample_len = 8192;

/// Detects the encoding of a file starting with `head`. `hint` (a user
/// setting or modeline) beats the heuristics but not a BOM; `fallback`
/// is used when nothing else decides (`files.fallbackEncoding`).
pub fn detect(head: []const u8, hint: ?Encoding, fallback: Encoding) Detection {
    if (sniffBom(head)) |d| return d;
    if (hint) |h| return .{ .encoding = h, .confidence = .certain, .bom_len = 0 };
    const s = head[0..@min(head.len, sample_len)];
    if (utf16Guess(s)) |e| return .{ .encoding = e, .confidence = .heuristic, .bom_len = 0 };
    if (std.mem.indexOfScalar(u8, s, 0) != null) return .{ .encoding = .binary, .confidence = .heuristic, .bom_len = 0 };
    // Valid UTF-8, allowing a sequence cut off by the end of the sample.
    const valid = zg_core.utf8.validatePrefix(s);
    if (valid == s.len or (s.len == sample_len and s.len - valid < 4 and cutSequence(s[valid..]))) {
        return .{ .encoding = .utf8, .confidence = .certain, .bom_len = 0 };
    }
    return .{ .encoding = fallback, .confidence = .default, .bom_len = 0 };
}

/// Whether `tail` is the start of a UTF-8 sequence that the sample cut.
fn cutSequence(tail: []const u8) bool {
    const n = std.unicode.utf8ByteSequenceLength(tail[0]) catch return false;
    if (tail.len >= n) return false;
    for (tail[1..]) |b| if (b & 0xC0 != 0x80) return false;
    return true;
}

/// The encoding a BOM at the start of `head` names. UTF-32LE is checked
/// before UTF-16LE (both start FF FE).
pub fn sniffBom(head: []const u8) ?Detection {
    const boms = [_]struct { bytes: []const u8, e: Encoding }{
        .{ .bytes = "\xFF\xFE\x00\x00", .e = .utf32le_bom },
        .{ .bytes = "\x00\x00\xFE\xFF", .e = .utf32be_bom },
        .{ .bytes = "\xEF\xBB\xBF", .e = .utf8_bom },
        .{ .bytes = "\xFE\xFF", .e = .utf16be_bom },
        .{ .bytes = "\xFF\xFE", .e = .utf16le_bom },
    };
    for (boms) |b| if (std.mem.startsWith(u8, head, b.bytes)) {
        return .{ .encoding = b.e, .confidence = .bom, .bom_len = @intCast(b.bytes.len) };
    };
    return null;
}

/// UTF-16 without a BOM: at least 40% of the high bytes are 0 and under
/// 5% of the low bytes are (or zeros sit only in high bytes), and the
/// sample decodes with no unpaired surrogates or unusual controls.
fn utf16Guess(s: []const u8) ?Encoding {
    if (s.len < 4) return null;
    const n = s.len / 2;
    var zero_even: usize = 0;
    var zero_odd: usize = 0;
    for (0..n) |k| {
        if (s[2 * k] == 0) zero_even += 1;
        if (s[2 * k + 1] == 0) zero_odd += 1;
    }
    // Zeros only in one byte of each unit also count: CJK text has few
    // zero high bytes (only its ASCII, such as line breaks).
    // Short samples with a stray NUL are too ambiguous for that.
    const one_sided = n >= 32;
    const e: Encoding = if ((zero_even * 100 >= n * 40 and zero_odd * 100 < n * 5) or (one_sided and zero_even >= 2 and zero_odd == 0))
        .utf16be
    else if ((zero_odd * 100 >= n * 40 and zero_even * 100 < n * 5) or (one_sided and zero_odd >= 2 and zero_even == 0))
        .utf16le
    else
        return null;
    const endian: std.builtin.Endian = if (e == .utf16be) .big else .little;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const u = std.mem.readInt(u16, s[2 * k ..][0..2], endian);
        if (u >= 0xD800 and u <= 0xDBFF) {
            // A pair cut by the end of the sample is fine.
            if (k + 1 == n) break;
            const v = std.mem.readInt(u16, s[2 * k + 2 ..][0..2], endian);
            if (v < 0xDC00 or v > 0xDFFF) return null;
            k += 1;
        } else if (u >= 0xDC00 and u <= 0xDFFF) return null;
        // Controls other than tab, LF, CR, FF suggest binary.
        if (u < 0x20 and u != '\t' and u != '\n' and u != '\r' and u != 0x0C) return null;
    }
    return e;
}
