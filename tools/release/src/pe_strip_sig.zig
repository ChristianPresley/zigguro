//! Removes an Authenticode signature from a PE image for reproducibility
//! comparison: zero the IMAGE_DIRECTORY_ENTRY_SECURITY data directory
//! (index 4), truncate the image at the certificate table, and zero the
//! optional header CheckSum. Images without a signature only lose their
//! CheckSum, so a signed and an unsigned build compare equal.

const std = @import("std");

/// True when `bytes` starts like a PE image (`MZ` and `PE\0\0` at e_lfanew).
pub fn isPe(bytes: []const u8) bool {
    return peOffset(bytes) != null;
}

fn peOffset(bytes: []const u8) ?usize {
    if (bytes.len < 0x40 or !std.mem.eql(u8, bytes[0..2], "MZ")) return null;
    const off = std.mem.readInt(u32, bytes[0x3c..0x40], .little);
    if (@as(u64, off) + 24 > bytes.len) return null;
    if (!std.mem.eql(u8, bytes[off..][0..4], "PE\x00\x00")) return null;
    return off;
}

/// Errors of `strip`.
pub const Error = error{ NotPe, Malformed };

/// Strips the signature in place and returns the (possibly shorter) image.
pub fn strip(bytes: []u8) Error![]u8 {
    const pe = peOffset(bytes) orelse return error.NotPe;
    const opt = pe + 24;
    if (opt + 2 > bytes.len) return error.Malformed;
    const magic = std.mem.readInt(u16, bytes[opt..][0..2], .little);
    const dirs_at: usize = switch (magic) {
        0x10b => opt + 96, // PE32
        0x20b => opt + 112, // PE32+
        else => return error.Malformed,
    };
    const checksum_at = opt + 64;
    if (dirs_at + 5 * 8 > bytes.len) return error.Malformed;
    @memset(bytes[checksum_at..][0..4], 0);
    const sec = dirs_at + 4 * 8;
    const cert_off = std.mem.readInt(u32, bytes[sec..][0..4], .little);
    const cert_len = std.mem.readInt(u32, bytes[sec + 4 ..][0..4], .little);
    @memset(bytes[sec..][0..8], 0);
    if (cert_len != 0 and cert_off != 0 and cert_off <= bytes.len) return bytes[0..cert_off];
    return bytes;
}

/// A minimal PE32+ image for tests: headers only, optionally followed by a
/// fake certificate table referenced from the security directory.
pub fn testImage(buf: []u8, with_cert: bool, checksum: u32) []u8 {
    @memset(buf, 0);
    buf[0] = 'M';
    buf[1] = 'Z';
    std.mem.writeInt(u32, buf[0x3c..0x40], 0x80, .little);
    @memcpy(buf[0x80..0x84], "PE\x00\x00");
    const opt = 0x80 + 24;
    std.mem.writeInt(u16, buf[opt..][0..2], 0x20b, .little);
    std.mem.writeInt(u32, buf[opt + 64 ..][0..4], checksum, .little);
    const len: usize = 0x200;
    if (!with_cert) return buf[0..len];
    const sec = opt + 112 + 32;
    std.mem.writeInt(u32, buf[sec..][0..4], len, .little);
    std.mem.writeInt(u32, buf[sec + 4 ..][0..4], 16, .little);
    @memset(buf[len..][0..16], 0xAA);
    return buf[0 .. len + 16];
}

test "pe: strip signature" {
    var a: [0x400]u8 = undefined;
    var b: [0x400]u8 = undefined;
    const signed = testImage(&a, true, 0x1234);
    const plain = testImage(&b, false, 0);
    try std.testing.expect(isPe(signed));
    try std.testing.expect(!std.mem.eql(u8, signed, plain));
    try std.testing.expectEqualSlices(u8, try strip(plain), try strip(signed));
    var junk = [_]u8{0} ** 64;
    try std.testing.expectError(error.NotPe, strip(&junk));
}
