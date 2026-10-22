//! The highlight vocabulary: a fixed set of dotted names that lexers emit
//! and themes (E15) resolve by longest dotted prefix, so a theme that only
//! colors `keyword` still colors `keyword.control`.

const std = @import("std");

/// A highlight name. Values are stable; `none` means "no highlight".
pub const HighlightId = enum(u16) {
    none = 0,
    comment,
    comment_doc,
    string,
    string_escape,
    string_special,
    character,
    number,
    constant,
    constant_builtin,
    keyword,
    keyword_control,
    keyword_operator,
    keyword_storage,
    type,
    type_builtin,
    function,
    function_builtin,
    function_macro,
    variable,
    variable_parameter,
    variable_builtin,
    property,
    label,
    operator,
    punctuation,
    punctuation_bracket,
    punctuation_delimiter,
    tag,
    attribute,
    markup_heading_1,
    markup_heading_2,
    markup_heading_3,
    markup_heading_4,
    markup_heading_5,
    markup_heading_6,
    markup_bold,
    markup_italic,
    markup_link,
    markup_code,
    invalid,
    _,

    /// Number of named highlights.
    pub const count = @typeInfo(HighlightId).@"enum".fields.len;

    /// The dotted name, e.g. "keyword.control"; "" for `none` and unknown ids.
    pub fn name(id: HighlightId) []const u8 {
        const i = @intFromEnum(id);
        return if (i < count) names[i] else "";
    }

    /// The id of a dotted name.
    pub fn fromName(s: []const u8) ?HighlightId {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, s)) return @enumFromInt(i);
        return null;
    }

    /// The nearest named ancestor (`keyword.control` -> `keyword`), or null.
    pub fn parent(id: HighlightId) ?HighlightId {
        var n = id.name();
        while (std.mem.lastIndexOfScalar(u8, n, '.')) |dot| {
            n = n[0..dot];
            if (fromName(n)) |p| return p;
        }
        return null;
    }
};

/// Dotted names, indexed by `HighlightId`.
const names: [HighlightId.count][]const u8 = blk: {
    var out: [HighlightId.count][]const u8 = undefined;
    for (@typeInfo(HighlightId).@"enum".fields, 0..) |f, i| {
        var buf: [f.name.len]u8 = f.name[0..f.name.len].*;
        for (&buf) |*c| {
            if (c.* == '_') c.* = '.';
        }
        const final = buf;
        out[i] = if (i == 0) "" else &final;
    }
    break :blk out;
};

/// Resolves `id` against a theme: the value of the longest dotted prefix
/// present in `table` (indexed by `HighlightId`), or null.
pub fn resolve(comptime T: type, table: []const ?T, id: HighlightId) ?T {
    var cur: ?HighlightId = id;
    while (cur) |c| : (cur = c.parent()) {
        const i = @intFromEnum(c);
        if (i < table.len) if (table[i]) |v| return v;
    }
    return null;
}

test "highlight names: dotted names and prefix resolution" {
    try std.testing.expectEqualStrings("keyword.control", HighlightId.keyword_control.name());
    try std.testing.expectEqualStrings("markup.heading.3", HighlightId.markup_heading_3.name());
    try std.testing.expectEqualStrings("", HighlightId.none.name());
    try std.testing.expectEqual(HighlightId.string_escape, HighlightId.fromName("string.escape").?);
    try std.testing.expectEqual(HighlightId.keyword, HighlightId.keyword_storage.parent().?);
    try std.testing.expectEqual(@as(?HighlightId, null), HighlightId.markup_heading_1.parent());
    try std.testing.expectEqual(@as(?HighlightId, null), HighlightId.comment.parent());

    // A stub theme that colors only `keyword` and `string.escape`.
    var theme = [_]?u32{null} ** HighlightId.count;
    theme[@intFromEnum(HighlightId.keyword)] = 1;
    theme[@intFromEnum(HighlightId.string_escape)] = 2;
    try std.testing.expectEqual(@as(?u32, 1), resolve(u32, &theme, .keyword_control));
    try std.testing.expectEqual(@as(?u32, 2), resolve(u32, &theme, .string_escape));
    try std.testing.expectEqual(@as(?u32, null), resolve(u32, &theme, .string));
}
