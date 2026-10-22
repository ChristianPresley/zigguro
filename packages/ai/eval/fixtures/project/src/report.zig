const util = @import("util.zig");

pub fn summary(text: []const u8) usize {
    return util.countWords(text) * 2;
}
