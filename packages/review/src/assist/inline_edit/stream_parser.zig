//! The `<rewrite>` stream parser (E12.F06.S01.T01): a tolerant state
//! machine over response chunks. Text before `<rewrite>` is skipped (a
//! preamble or a code fence); the body streams until `</rewrite>`, with a
//! tag split across chunks held back until it resolves. One newline right
//! after the open tag and one Markdown code fence wrapping the body are
//! not part of the text. A stream that ends without the close tag keeps
//! what came, less a cut-off close tag (`warning = .unterminated`); one
//! without an open tag is
//! taken whole (`warning = .no_open_tag`).

const std = @import("std");

const Allocator = std.mem.Allocator;

const open_tag = "<rewrite>";
const close_tag = "</rewrite>";

pub const Warning = enum { none, unterminated, no_open_tag };

pub const StreamParser = struct {
    gpa: Allocator,
    /// Before the open tag: what came so far; after it: the body.
    buf: std.ArrayList(u8) = .empty,
    state: enum { seek, body, closed } = .seek,
    warning: Warning = .none,
    /// The stream ended (`finish`).
    ended: bool = false,

    pub fn init(gpa: Allocator) StreamParser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *StreamParser) void {
        p.buf.deinit(p.gpa);
    }

    /// Takes the next chunk of the response.
    pub fn feed(p: *StreamParser, chunk: []const u8) Allocator.Error!void {
        if (p.state == .closed or p.ended) return;
        const from = p.buf.items.len -| (close_tag.len - 1);
        try p.buf.appendSlice(p.gpa, chunk);
        switch (p.state) {
            .seek => if (std.mem.indexOf(u8, p.buf.items, open_tag)) |i| {
                const rest = i + open_tag.len;
                std.mem.copyForwards(u8, p.buf.items, p.buf.items[rest..]);
                p.buf.shrinkRetainingCapacity(p.buf.items.len - rest);
                p.state = .body;
                p.checkClose(0);
            },
            .body => p.checkClose(from),
            .closed => {},
        }
    }

    fn checkClose(p: *StreamParser, from: usize) void {
        if (std.mem.indexOfPos(u8, p.buf.items, from, close_tag)) |i| {
            p.buf.shrinkRetainingCapacity(i);
            p.state = .closed;
        }
    }

    /// The stream ended.
    pub fn finish(p: *StreamParser) void {
        if (p.ended) return;
        p.ended = true;
        switch (p.state) {
            .seek => p.warning = .no_open_tag,
            .body => p.warning = .unterminated,
            .closed => {},
        }
    }

    /// Whether the close tag came.
    pub fn closed(p: *const StreamParser) bool {
        return p.state == .closed;
    }

    /// The rewrite so far (valid until the next `feed`).
    pub fn text(p: *const StreamParser) []const u8 {
        if (p.state == .seek and !p.ended) return "";
        var t: []const u8 = p.buf.items;
        // A tag still arriving is not text.
        if (p.state == .body) t = t[0 .. t.len - partialSuffix(t, close_tag)];
        if (std.mem.startsWith(u8, t, "\n")) t = t[1..] else if (std.mem.startsWith(u8, t, "\r\n")) t = t[2..];
        // One wrapping code fence.
        const lead = std.mem.trimStart(u8, t, " \t");
        if (std.mem.startsWith(u8, lead, "```")) {
            const nl = std.mem.indexOfScalar(u8, lead, '\n') orelse return "";
            t = lead[nl + 1 ..];
            const trimmed = std.mem.trimEnd(u8, t, " \t\r\n");
            if (std.mem.endsWith(u8, trimmed, "```")) {
                t = t[0 .. trimmed.len - 3];
            } else if (!p.stateDone()) {
                // A closing fence may be arriving.
                const k = partialSuffix(trimmed, "\n```");
                if (k > 0) t = t[0 .. trimmed.len - k + 1];
            }
        }
        return t;
    }

    fn stateDone(p: *const StreamParser) bool {
        return p.state == .closed or p.ended;
    }
};

/// The length of the longest proper prefix of `tag` that `s` ends with.
fn partialSuffix(s: []const u8, tag: []const u8) usize {
    var k = @min(tag.len - 1, s.len);
    while (k > 0) : (k -= 1) {
        if (std.mem.endsWith(u8, s, tag[0..k])) return k;
    }
    return 0;
}

const testing = std.testing;

fn feedAll(chunks: []const []const u8) !StreamParser {
    var p: StreamParser = .init(testing.allocator);
    for (chunks) |c| try p.feed(c);
    return p;
}

test "inline: stream parser handles split tags, fences, unterminated" {
    // Tags split across chunks; the newline after the open tag goes.
    {
        var p = try feedAll(&.{ "Sure!\n<rewr", "ite>\nconst x = 1;\n</re" });
        defer p.deinit();
        try testing.expectEqualStrings("const x = 1;\n", p.text());
        try testing.expect(!p.closed());
        try p.feed("write> trailing chatter");
        try testing.expect(p.closed());
        try testing.expectEqualStrings("const x = 1;\n", p.text());
        try p.feed("ignored");
        p.finish();
        try testing.expectEqual(Warning.none, p.warning);
    }
    // Nothing shows before the open tag.
    {
        var p = try feedAll(&.{"<rew"});
        defer p.deinit();
        try testing.expectEqualStrings("", p.text());
    }
    // A code fence inside the tags is stripped, also while it streams.
    {
        var p = try feedAll(&.{ "<rewrite>\n```zig\nfn f() void {}\n", "``" });
        defer p.deinit();
        try testing.expectEqualStrings("fn f() void {}\n", p.text());
        try p.feed("`\n</rewrite>");
        try testing.expectEqualStrings("fn f() void {}\n", p.text());
    }
    // No close tag: the text so far, with a warning.
    {
        var p = try feedAll(&.{"<rewrite>a\nb\n</rew"});
        defer p.deinit();
        p.finish();
        try testing.expectEqual(Warning.unterminated, p.warning);
        try testing.expectEqualStrings("a\nb\n", p.text());
    }
    // No open tag at all: taken whole.
    {
        var p = try feedAll(&.{"x = 2\n"});
        defer p.deinit();
        try testing.expectEqualStrings("", p.text());
        p.finish();
        try testing.expectEqual(Warning.no_open_tag, p.warning);
        try testing.expectEqualStrings("x = 2\n", p.text());
    }
}
