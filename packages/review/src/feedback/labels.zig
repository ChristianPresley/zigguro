//! Conventional Comments labels (E12.F03.S03.T01): `issue (blocking):
//! ...` at the start of a review comment. Pure.
//!
//! - A prefix is `<label> [(<decorations>)]: ` with a known label, case
//!   insensitive, and optional spaces before `(` and `:`.
//! - Decorations are comma separated. `blocking` sets the blocking flag,
//!   `non-blocking` and `if-minor` clear it; the rest are free tags
//!   (organisations define their own, such as `security`).
//! - A body without a known label prefix parses to no label, no flag and
//!   the whole body as `rest`.

const std = @import("std");

pub const Label = enum {
    issue,
    suggestion,
    nitpick,
    question,
    praise,
    todo,
    chore,
    note,
    thought,
    typo,
    polish,
    quibble,

    pub fn parse(s: []const u8) ?Label {
        inline for (@typeInfo(Label).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(s, f.name)) return @field(Label, f.name);
        }
        return null;
    }
};

pub const Prefix = struct {
    label: ?Label = null,
    /// From a `blocking`, `non-blocking` or `if-minor` decoration.
    blocking: ?bool = null,
    /// The text between the parentheses, as written; `tags` iterates the
    /// decorations that are not blocking flags.
    decorations: []const u8 = "",
    /// The body after the prefix.
    rest: []const u8,

    pub fn tags(p: Prefix) TagIterator {
        return .{ .it = std.mem.splitScalar(u8, p.decorations, ',') };
    }
};

/// Yields the free tags of a decoration list, trimmed, skipping empty
/// ones and the blocking flags.
pub const TagIterator = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn next(t: *TagIterator) ?[]const u8 {
        while (t.it.next()) |raw| {
            const d = std.mem.trim(u8, raw, " \t");
            if (d.len == 0 or blockingOf(d) != null) continue;
            return d;
        }
        return null;
    }
};

fn blockingOf(d: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(d, "blocking")) return true;
    if (std.ascii.eqlIgnoreCase(d, "non-blocking")) return false;
    if (std.ascii.eqlIgnoreCase(d, "if-minor")) return false;
    return null;
}

pub fn parseLabelPrefix(body: []const u8) Prefix {
    const none: Prefix = .{ .rest = body };
    var i: usize = 0;
    while (i < body.len and (std.ascii.isAlphabetic(body[i]) or body[i] == '-')) i += 1;
    const label = Label.parse(body[0..i]) orelse return none;
    var j = skipSpaces(body, i);
    var decorations: []const u8 = "";
    if (j < body.len and body[j] == '(') {
        const close = std.mem.indexOfScalarPos(u8, body, j, ')') orelse return none;
        decorations = body[j + 1 .. close];
        if (std.mem.indexOfAny(u8, decorations, "\r\n(") != null) return none;
        j = skipSpaces(body, close + 1);
    }
    if (j >= body.len or body[j] != ':') return none;
    var blocking: ?bool = null;
    var it = std.mem.splitScalar(u8, decorations, ',');
    while (it.next()) |raw| {
        if (blockingOf(std.mem.trim(u8, raw, " \t"))) |b| blocking = b;
    }
    return .{
        .label = label,
        .blocking = blocking,
        .decorations = decorations,
        .rest = std.mem.trimStart(u8, body[j + 1 ..], " \t"),
    };
}

fn skipSpaces(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i;
}

test "comments: label prefix parsing table (all Conventional Comments labels and decorations)" {
    const T = struct { body: []const u8, label: ?Label, blocking: ?bool, rest: []const u8, tags: []const []const u8 = &.{} };
    const cases = [_]T{
        .{ .body = "issue: off by one", .label = .issue, .blocking = null, .rest = "off by one" },
        .{ .body = "suggestion: use a slice", .label = .suggestion, .blocking = null, .rest = "use a slice" },
        .{ .body = "nitpick: spacing", .label = .nitpick, .blocking = null, .rest = "spacing" },
        .{ .body = "question: why?", .label = .question, .blocking = null, .rest = "why?" },
        .{ .body = "praise: nice", .label = .praise, .blocking = null, .rest = "nice" },
        .{ .body = "todo: add a test", .label = .todo, .blocking = null, .rest = "add a test" },
        .{ .body = "chore: bump", .label = .chore, .blocking = null, .rest = "bump" },
        .{ .body = "note: fyi", .label = .note, .blocking = null, .rest = "fyi" },
        .{ .body = "thought: maybe", .label = .thought, .blocking = null, .rest = "maybe" },
        .{ .body = "typo: teh", .label = .typo, .blocking = null, .rest = "teh" },
        .{ .body = "polish: wording", .label = .polish, .blocking = null, .rest = "wording" },
        .{ .body = "quibble: naming", .label = .quibble, .blocking = null, .rest = "naming" },
        .{ .body = "Issue (blocking): leaks", .label = .issue, .blocking = true, .rest = "leaks" },
        .{ .body = "ISSUE(non-blocking):later", .label = .issue, .blocking = false, .rest = "later" },
        .{ .body = "nitpick (if-minor): rename", .label = .nitpick, .blocking = false, .rest = "rename" },
        .{ .body = "issue (security, blocking): token in log", .label = .issue, .blocking = true, .rest = "token in log", .tags = &.{"security"} },
        .{ .body = "suggestion (ux,perf) : cache", .label = .suggestion, .blocking = null, .rest = "cache", .tags = &.{ "ux", "perf" } },
        .{ .body = "remark: not a label", .label = null, .blocking = null, .rest = "remark: not a label" },
        .{ .body = "issue without colon", .label = null, .blocking = null, .rest = "issue without colon" },
        .{ .body = "issue (blocking: unclosed", .label = null, .blocking = null, .rest = "issue (blocking: unclosed" },
        .{ .body = "", .label = null, .blocking = null, .rest = "" },
    };
    for (cases) |c| {
        const p = parseLabelPrefix(c.body);
        try std.testing.expectEqual(c.label, p.label);
        try std.testing.expectEqual(c.blocking, p.blocking);
        try std.testing.expectEqualStrings(c.rest, p.rest);
        var it = p.tags();
        for (c.tags) |want| try std.testing.expectEqualStrings(want, it.next().?);
        try std.testing.expectEqual(@as(?[]const u8, null), it.next());
    }
}
