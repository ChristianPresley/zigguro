//! The tailoring table for word movement: the class of every ASCII code
//! point (identifier characters are letters, digits and `_`; other
//! printable characters are punctuation) and the scripts whose runs move
//! as their own class (CJK).

const std = @import("std");
const zg_text = @import("zg_text");
const WordClass = @import("word.zig").WordClass;

const Script = zg_text.unicode.Script;

/// Classes of U+0000..U+007F.
pub const ascii: [128]WordClass = blk: {
    var t: [128]WordClass = undefined;
    for (&t, 0..) |*c, i| {
        const b: u8 = @intCast(i);
        c.* = if (b == '\n' or b == '\r')
            .newline
        else if (b == ' ' or b == '\t' or b == 0x0b or b == 0x0c)
            .space
        else if (std.ascii.isAlphanumeric(b) or b == '_')
            .ident
        else if (b < 0x20 or b == 0x7f)
            .other
        else
            .punct;
    }
    break :blk t;
};

/// Scripts whose characters move as one run, apart from identifiers.
pub fn isCjkScript(s: Script) bool {
    return switch (s) {
        .Hani, .Hira, .Kana, .Hang, .Bopo => true,
        else => false,
    };
}
