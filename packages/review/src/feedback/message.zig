//! The fix request an agent gets from review comments (E12.F03.S03.T02):
//! deterministic, model-agnostic Markdown. Pure.
//!
//! ```
//! Review feedback on changeset #12 ("Turn 7: add retry to fetch"):
//! 1. [issue, blocking] src/net.zig:41-44
//!    ```zig
//!    <quoted proposed lines>
//!    ```
//!    this leaks `buf` on error
//!    > agent: <a reply>
//! Additional request: also add a test
//! Please revise your pending changes (...). Reply with what you changed.
//! ```
//!
//! - Lines are 1-based in the text. Quotes come from the proposal (what
//!   the thread is anchored to), at most `max_quote_lines` per thread,
//!   the middle cut with `…`. A thread on removed lines says so.
//! - Each thread is also a context item (`range`), so E10 can merge it
//!   with context it already has.
//! - When the text is over `max_tokens` (by `estimate`), quotes are
//!   dropped and only locations and comments stay.

const std = @import("std");
const proto = @import("zg_ai_proto");
const model = @import("../model/root.zig");
const comments = @import("comments.zig");
const anchor_mod = @import("anchor.zig");
const labels = @import("labels.zig");

const Allocator = std.mem.Allocator;
const Thread = comments.Thread;
const ChangesetId = model.ChangesetId;

pub const max_quote_lines = 40;

pub const FeedbackMessage = struct {
    text: []const u8,
    context: []const proto.ContextItem,
    revises: ChangesetId,
    /// The quotes were dropped to stay under the token cap.
    quotes_dropped: bool = false,
};

/// Tokens of a text (E10's estimator through the agent port).
pub const Estimate = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, text: []const u8) u32 = charsOver4,

    fn charsOver4(_: ?*anyopaque, text: []const u8) u32 {
        return @intCast((text.len + 3) / 4);
    }
};

pub const Options = struct {
    /// `review.feedbackMaxTokens`.
    max_tokens: u32 = 4000,
    estimate: Estimate = .{},
};

/// What a thread's anchor points into: the file's proposed (or base)
/// text, for the quote.
pub const TextOf = struct {
    ctx: *anyopaque,
    /// The text of `path` on `side`, or null when it is not known.
    text: *const fn (ctx: *anyopaque, arena: Allocator, path: []const u8, side: comments.Side) anyerror!?[]const u8,
};

pub fn compose(
    arena: Allocator,
    cs: ChangesetId,
    label: []const u8,
    threads: []const *const Thread,
    extra: []const u8,
    texts: ?TextOf,
    o: Options,
) !FeedbackMessage {
    const quotes = try arena.alloc(?[]const u8, threads.len);
    for (threads, quotes) |t, *q| q.* = if (texts) |tx| try quoteOf(arena, t, tx) else null;
    var text = try render(arena, cs, label, threads, extra, quotes);
    var dropped = false;
    if (o.estimate.f(o.estimate.ctx, text) > o.max_tokens) {
        @memset(quotes, null);
        text = try render(arena, cs, label, threads, extra, quotes);
        dropped = true;
    }
    const items = try arena.alloc(proto.ContextItem, threads.len);
    for (threads, items, 0..) |t, *it, i| {
        const l = t.anchor.lines;
        const body = if (quotes[i]) |q| q else t.anchor.text;
        it.* = .{
            .ref = .{ .range = .{ .path = t.anchor.path, .lines = .{ l.start + 1, l.start + @max(l.count, 1) } } },
            .title = try std.fmt.allocPrint(arena, "{s}:{d}", .{ t.anchor.path, l.start + 1 }),
            .mime = "text/plain",
            .text = body,
            .tokens = o.estimate.f(o.estimate.ctx, body),
            .version_hash = t.anchor.content_hash,
        };
    }
    return .{ .text = text, .context = items, .revises = cs, .quotes_dropped = dropped };
}

fn render(arena: Allocator, cs: ChangesetId, label: []const u8, threads: []const *const Thread, extra: []const u8, quotes: []const ?[]const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print("Review feedback on changeset {f} (\"{s}\"):\n", .{ cs, label });
    for (threads, quotes, 1..) |t, q, n| {
        try w.print("{d}. ", .{n});
        if (t.label != null or t.blocking) {
            try w.writeByte('[');
            if (t.label) |l| try w.writeAll(@tagName(l));
            if (t.blocking) try w.writeAll(if (t.label != null) ", blocking" else "blocking");
            try w.writeAll("] ");
        }
        try location(w, t);
        try w.writeByte('\n');
        if (q) |quote| {
            try w.print("   ```{s}\n", .{fenceLang(t.anchor.path)});
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, quote, "\n"), '\n');
            while (it.next()) |line| try w.print("   {s}\n", .{std.mem.trimEnd(u8, line, "\r")});
            try w.writeAll("   ```\n");
        }
        for (t.comments.items, 0..) |c, i| {
            // The label is in the item's header already.
            const body = std.mem.trim(u8, if (i == 0) labels.parseLabelPrefix(c.body).rest else c.body, " \t\r\n");
            var lines = std.mem.splitScalar(u8, body, '\n');
            var first = true;
            while (lines.next()) |line| {
                const l = std.mem.trimEnd(u8, line, "\r");
                if (i == 0) {
                    try w.print("   {s}\n", .{l});
                } else if (first) {
                    try w.writeAll("   > ");
                    try author(w, c.author);
                    try w.print(": {s}\n", .{l});
                } else try w.print("   > {s}\n", .{l});
                first = false;
            }
        }
    }
    const ex = std.mem.trim(u8, extra, " \t\r\n");
    if (ex.len > 0) try w.print("Additional request: {s}\n", .{ex});
    try w.writeAll("Please revise your pending changes (they are still pending; your file view includes them). Reply with what you changed.\n");
    return aw.written();
}

fn location(w: *std.Io.Writer, t: *const Thread) !void {
    const l = t.anchor.lines;
    try w.writeAll(t.anchor.path);
    if (l.count <= 1) try w.print(":{d}", .{l.start + 1}) else try w.print(":{d}-{d}", .{ l.start + 1, l.start + l.count });
    if (t.anchor.side == .base) try w.writeAll(" (removed lines)");
    if (t.outdated) try w.writeAll(" (outdated: those lines changed since)");
}

fn author(w: *std.Io.Writer, a: comments.Author) !void {
    switch (a) {
        .user => |u| try w.writeAll(u),
        .agent => try w.writeAll("agent"),
        .code_review => try w.writeAll("code review"),
    }
}

/// The anchored lines of the thread's file text, cut to
/// `max_quote_lines`; the thread's last known text when the file text is
/// not known or the thread is outdated.
fn quoteOf(arena: Allocator, t: *const Thread, tx: TextOf) !?[]const u8 {
    if (t.anchor.lines.count == 0) return null;
    const raw = blk: {
        if (!t.outdated) if (try tx.text(tx.ctx, arena, t.anchor.path, t.anchor.side)) |text| {
            break :blk try anchor_mod.rangeText(arena, text, t.anchor.lines);
        };
        break :blk t.anchor.text;
    };
    if (raw.len == 0) return null;
    return try cut(arena, raw);
}

fn cut(arena: Allocator, text: []const u8) ![]const u8 {
    const n = std.mem.count(u8, std.mem.trimEnd(u8, text, "\n"), "\n") + 1;
    if (n <= max_quote_lines) return text;
    const head = max_quote_lines / 2;
    const tail = max_quote_lines - head - 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    var aw: std.Io.Writer.Allocating = .init(arena);
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i < head or (i >= n - tail and i < n)) {
            try aw.writer.print("{s}\n", .{line});
        } else if (i == head) try aw.writer.writeAll("…\n");
    }
    return aw.written();
}

fn fenceLang(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = [_][2][]const u8{
        .{ ".zig", "zig" },   .{ ".rs", "rust" },   .{ ".go", "go" },       .{ ".py", "python" },
        .{ ".ts", "ts" },     .{ ".tsx", "tsx" },   .{ ".js", "js" },       .{ ".c", "c" },
        .{ ".h", "c" },       .{ ".cpp", "cpp" },   .{ ".md", "markdown" }, .{ ".json", "json" },
        .{ ".toml", "toml" }, .{ ".yaml", "yaml" }, .{ ".yml", "yaml" },    .{ ".sh", "sh" },
    };
    for (map) |m| if (std.mem.eql(u8, ext, m[0])) return m[1];
    return "";
}
