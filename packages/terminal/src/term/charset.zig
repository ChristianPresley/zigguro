//! SCS (Select Character Set) designators.

const Charset = @import("../screen/Screen.zig").Charset;

/// The G-set (0-3) an SCS intermediate designates, for 94-character sets.
pub fn slot(inter: u8) ?u2 {
    return switch (inter) {
        '(' => 0,
        ')' => 1,
        '*' => 2,
        '+' => 3,
        else => null,
    };
}

/// The charset named by an SCS final byte; unknown designators are null
/// (and ignored by the caller).
pub fn fromFinal(final: u8) ?Charset {
    return switch (final) {
        'B' => .ascii,
        '0' => .dec_special,
        'A' => .uk,
        else => null,
    };
}

test "designators" {
    const std = @import("std");
    try std.testing.expectEqual(@as(?u2, 1), slot(')'));
    try std.testing.expect(slot('-') == null);
    try std.testing.expectEqual(Charset.dec_special, fromFinal('0').?);
    try std.testing.expect(fromFinal('Z') == null);
}
