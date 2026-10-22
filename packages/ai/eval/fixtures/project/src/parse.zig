const util = @import("util.zig");

pub fn parse(text: []const u8) usize {
    return util.countWords(text);
}
