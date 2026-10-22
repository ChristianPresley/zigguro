//! Content classification: what kind of bytes a file holds, decided from
//! its first bytes and its size. Plugins use the class to skip binaries,
//! and search ranks generated and minified files lower.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");

/// The class of a file's content.
pub const ContentClass = enum(u8) {
    /// Valid UTF-8 (with or without a BOM).
    text,
    /// UTF-16 little-endian (BOM FF FE); transcode with `utf16ToUtf8`.
    text_utf16le,
    /// UTF-16 big-endian (BOM FE FF); transcode with `utf16ToUtf8`.
    text_utf16be,
    /// No NUL but invalid UTF-8 (shown as Latin-1, indexed as bytes).
    text_other,
    /// Text carrying a generated-code marker; indexed, ranked lower.
    generated,
    /// Text with very long lines and few newlines (bundles, minified JS).
    minified,
    /// A NUL byte in the first 8 000 bytes.
    binary,
    /// Larger than `IndexConfig.max_file_bytes`; not read.
    too_large,

    /// Whether plugins should see the bytes as text.
    pub fn isText(c: ContentClass) bool {
        return switch (c) {
            .binary, .too_large => false,
            else => true,
        };
    }
};

/// Indexer settings.
pub const IndexConfig = struct {
    /// Worker count; 0 picks from the CPU count (see the scheduler).
    max_workers: u8 = 0,
    /// Larger files are `too_large` and not read.
    max_file_bytes: u64 = 8 << 20,
    /// A line at least this long (in the first 64 KB) suggests minified code.
    minified_line_len: u32 = 1000,
    /// Per-worker read buffer.
    read_buf: u32 = 256 << 10,
};

/// Bytes `classify` wants to see (more is fine).
pub const head_len = 64 * 1024;
/// git's `buffer_is_binary` window.
pub const binary_window = 8000;
const marker_window = 1024;

/// Classifies a file from its first bytes (`head`, ideally `head_len` of
/// them or the whole file) and its total size.
pub fn classify(head: []const u8, total_len: u64, path: []const u8, cfg: *const IndexConfig) ContentClass {
    if (total_len > cfg.max_file_bytes) return .too_large;
    if (std.mem.startsWith(u8, head, "\xFF\xFE")) return .text_utf16le;
    if (std.mem.startsWith(u8, head, "\xFE\xFF")) return .text_utf16be;
    const bom = std.mem.startsWith(u8, head, "\xEF\xBB\xBF");
    const body = if (bom) head[3..] else head;
    if (std.mem.indexOfScalar(u8, body[0..@min(body.len, binary_window)], 0) != null) return .binary;
    if (isMinified(body, path, cfg)) return .minified;
    if (hasGeneratedMarker(body[0..@min(body.len, marker_window)])) return .generated;
    // A truncated head may end mid-sequence; only the complete part counts.
    const check = if (head.len < total_len) trimPartial(body) else body;
    if (!zg_core.utf8.validate(check)) return .text_other;
    return .text;
}

fn isMinified(body: []const u8, path: []const u8, cfg: *const IndexConfig) bool {
    if (std.mem.endsWith(u8, path, ".min.js") or std.mem.endsWith(u8, path, ".min.css")) return true;
    const window = body[0..@min(body.len, head_len)];
    if (window.len < cfg.minified_line_len) return false;
    var newlines: usize = 0;
    var longest: usize = 0;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, window, start, '\n')) |nl| {
        newlines += 1;
        longest = @max(longest, nl - start);
        start = nl + 1;
    }
    longest = @max(longest, window.len - start);
    // Fewer than one newline per 2 KB.
    return longest >= cfg.minified_line_len and newlines * 2048 < window.len;
}

fn hasGeneratedMarker(w: []const u8) bool {
    if (std.mem.indexOf(u8, w, "@generated") != null) return true;
    if (std.mem.indexOf(u8, w, "DO NOT EDIT") != null) return true;
    return false;
}

/// Drops an incomplete UTF-8 sequence at the end of `b`.
fn trimPartial(b: []const u8) []const u8 {
    var i = b.len;
    var back: usize = 0;
    while (i > 0 and back < 4) {
        i -= 1;
        back += 1;
        const c = b[i];
        if (c & 0xC0 != 0x80) {
            const need: usize = if (c < 0x80) 1 else if (c >> 5 == 0b110) 2 else if (c >> 4 == 0b1110) 3 else if (c >> 3 == 0b11110) 4 else 1;
            return if (need > back) b[0..i] else b;
        }
    }
    return b;
}

/// Transcodes UTF-16 bytes (after the BOM) to UTF-8. The bytes need no
/// alignment; a trailing odd byte is dropped. Caller owns the result.
pub fn utf16ToUtf8(gpa: Allocator, bytes: []const u8, big_endian: bool) ![]u8 {
    const n = bytes.len / 2;
    const units = try gpa.alloc(u16, n);
    defer gpa.free(units);
    for (units, 0..) |*u, i| {
        const pair = bytes[2 * i ..][0..2];
        u.* = if (big_endian) std.mem.readInt(u16, pair, .big) else std.mem.readInt(u16, pair, .little);
    }
    if (bytes.len % 2 == 1 and !@import("builtin").is_test) std.log.scoped(.indexer).warn("UTF-16 text has an odd trailing byte; dropped", .{});
    return std.unicode.utf16LeToUtf8Alloc(gpa, units) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        // Unpaired surrogates: keep what is valid, replace the rest.
        else => lossy(gpa, units),
    };
}

fn lossy(gpa: Allocator, units: []const u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.unicode.Utf16LeIterator.init(units);
    while (true) {
        const cp = it.nextCodepoint() catch {
            try out.appendSlice(gpa, "\u{FFFD}");
            continue;
        } orelse break;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch 0;
        try out.appendSlice(gpa, buf[0..len]);
    }
    return out.toOwnedSlice(gpa);
}

test "content_class: table" {
    const cfg: IndexConfig = .{};
    const C = ContentClass;
    const T = struct { bytes: []const u8, path: []const u8 = "a.txt", want: C };
    var nul7999: [8001]u8 = @splat('a');
    nul7999[7999] = 0;
    var nul8001: [8002]u8 = @splat('a');
    for (0..100) |i| nul8001[i * 80] = '\n';
    nul8001[8001] = 0;
    var minified: [6000]u8 = @splat('x');
    minified[3000] = '\n';
    var lines: [6000]u8 = @splat('x');
    for (0..60) |i| lines[i * 100] = '\n';
    const cases = [_]T{
        .{ .bytes = "hello\nworld\n", .want = .text },
        .{ .bytes = "", .want = .text },
        .{ .bytes = "\xEF\xBB\xBFbom text", .want = .text },
        .{ .bytes = "\xFF\xFEh\x00i\x00", .want = .text_utf16le },
        .{ .bytes = "\xFE\xFF\x00h\x00i", .want = .text_utf16be },
        .{ .bytes = &nul7999, .want = .binary },
        .{ .bytes = &nul8001, .want = .text },
        .{ .bytes = &minified, .path = "bundle.js", .want = .minified },
        .{ .bytes = &lines, .path = "long.js", .want = .text },
        .{ .bytes = "x", .path = "lib.min.js", .want = .minified },
        .{ .bytes = "// Code generated by protoc. DO NOT EDIT.\npackage x\n", .want = .generated },
        .{ .bytes = "/* @generated */\n", .want = .generated },
        .{ .bytes = "caf\xE9 latin-1", .want = .text_other },
    };
    for (cases) |c| {
        const got = classify(c.bytes, c.bytes.len, c.path, &cfg);
        std.testing.expectEqual(c.want, got) catch |err| {
            std.debug.print("case {s}: got {t}\n", .{ c.path, got });
            return err;
        };
    }
    try std.testing.expectEqual(C.too_large, classify("x", 9 << 20, "big", &cfg));
    // A head cut inside a multi-byte sequence is still valid UTF-8.
    try std.testing.expectEqual(C.text, classify("ab\xC3", 100, "a", &cfg));
    try std.testing.expect(!C.binary.isText());
}

test "content_class: utf16 transcode (unaligned, big-endian, odd byte)" {
    const gpa = std.testing.allocator;
    const le = "\x00h\x00i\x00"; // offset by one to force misalignment
    const a = try utf16ToUtf8(gpa, le[1..], false);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("hi", a);
    const b = try utf16ToUtf8(gpa, "\x00h\x00i\x00", true);
    defer gpa.free(b);
    try std.testing.expectEqualStrings("hi", b);
    const c = try utf16ToUtf8(gpa, "\x00\xD8x\x00", false); // unpaired high surrogate
    defer gpa.free(c);
    try std.testing.expectEqualStrings("\u{FFFD}x", c);
}
