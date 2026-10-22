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
    /// GFM `~~strikethrough~~` (appended: values are stable).
    markup_strikethrough,
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

/// Highlight names beyond the fixed set, such as the semantic-token names
/// `variable.readonly` or `semantic.lifetime`: interned on first use with
/// ids from `HighlightId.count` up. Themes resolve them by dotted prefix
/// through `parentOf`, so `variable.readonly` falls back to `variable`.
pub const HighlightNames = struct {
    gpa: std.mem.Allocator,
    extra: std.ArrayList([]const u8) = .empty,
    map: std.StringHashMapUnmanaged(u16) = .empty,

    /// An empty registry.
    pub fn init(gpa: std.mem.Allocator) HighlightNames {
        return .{ .gpa = gpa };
    }

    /// Frees the names.
    pub fn deinit(n: *HighlightNames) void {
        for (n.extra.items) |s| n.gpa.free(s);
        n.extra.deinit(n.gpa);
        n.map.deinit(n.gpa);
        n.* = undefined;
    }

    /// The id of `dotted`, adding it when new.
    pub fn intern(n: *HighlightNames, dotted: []const u8) std.mem.Allocator.Error!HighlightId {
        if (HighlightId.fromName(dotted)) |id| return id;
        if (n.map.get(dotted)) |v| return @enumFromInt(v);
        const owned = try n.gpa.dupe(u8, dotted);
        errdefer n.gpa.free(owned);
        const v: u16 = @intCast(HighlightId.count + n.extra.items.len);
        try n.extra.append(n.gpa, owned);
        errdefer _ = n.extra.pop();
        try n.map.put(n.gpa, owned, v);
        return @enumFromInt(v);
    }

    /// The dotted name of any id ("" when unknown).
    pub fn name(n: *const HighlightNames, id: HighlightId) []const u8 {
        const i = @intFromEnum(id);
        if (i < HighlightId.count) return id.name();
        const k = i - HighlightId.count;
        return if (k < n.extra.items.len) n.extra.items[k] else "";
    }

    /// The nearest named ancestor of any id, fixed or interned.
    pub fn parentOf(n: *const HighlightNames, id: HighlightId) ?HighlightId {
        var s = n.name(id);
        while (std.mem.lastIndexOfScalar(u8, s, '.')) |dot| {
            s = s[0..dot];
            if (HighlightId.fromName(s)) |p| return p;
            if (n.map.get(s)) |v| return @enumFromInt(v);
        }
        return null;
    }

    /// Whether `id` is `ancestor` or below it.
    pub fn isWithin(n: *const HighlightNames, id: HighlightId, ancestor: HighlightId) bool {
        var cur: ?HighlightId = id;
        while (cur) |c| : (cur = n.parentOf(c)) if (c == ancestor) return true;
        return false;
    }
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

test "highlight names: interned extra names" {
    var n: HighlightNames = .init(std.testing.allocator);
    defer n.deinit();
    const ro = try n.intern("variable.readonly");
    try std.testing.expect(@intFromEnum(ro) >= HighlightId.count);
    try std.testing.expectEqual(ro, try n.intern("variable.readonly"));
    try std.testing.expectEqual(HighlightId.function_builtin, try n.intern("function.builtin"));
    try std.testing.expectEqualStrings("variable.readonly", n.name(ro));
    try std.testing.expectEqual(HighlightId.variable, n.parentOf(ro).?);
    const deep = try n.intern("variable.readonly.static");
    try std.testing.expectEqual(ro, n.parentOf(deep).?);
    try std.testing.expect(n.isWithin(deep, .variable));
    try std.testing.expect(!n.isWithin(deep, .string));
}
