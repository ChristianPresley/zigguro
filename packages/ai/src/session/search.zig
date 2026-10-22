//! Full-text search over the session files of a workspace
//! (E10.F08.S01.T02). Sessions are searched newest first; hits stream to a
//! sink as `{session, seq, snippet}` and the search stops when the sink
//! says so or `cancel` is set.
//!
//! Literal queries are matched first against the raw JSON line (with the
//! query JSON-escaped), so only candidate lines are decoded. Regex
//! queries (`zg_regex`) decode every message line. Either way the match
//! must be in the searchable text of the record (message text, tool names,
//! inputs and text results, titles), never in JSON keys.

const std = @import("std");
const proto = @import("zg_ai_proto");
const zg_regex = @import("zg_regex");
const records = @import("records.zig");
const loader = @import("loader.zig");
const index = @import("index.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// What to look for.
pub const Query = struct {
    text: []const u8,
    /// Treat `text` as a `zg_regex` pattern instead of a literal.
    regex: bool = false,
    case_insensitive: bool = true,
    /// Sessions to search (null: all), applied before reading files.
    filter: index.Filter = .{},
    /// Stop after this many hits.
    max_hits: u32 = 1000,
    /// Bytes of context on each side of the match in the snippet.
    context_bytes: u32 = 60,
};

/// One hit. `snippet` is valid only during the callback.
pub const Hit = struct {
    session: proto.SessionId,
    seq: u64,
    snippet: []const u8,
    /// The match inside `snippet`.
    match_start: u32,
    match_end: u32,
};

/// Receives hits; returning false stops the search.
pub const SearchSink = struct {
    ctx: *anyopaque,
    on_hit: *const fn (ctx: *anyopaque, hit: Hit) bool,
};

/// How a search ended.
pub const Outcome = struct {
    hits: u32 = 0,
    sessions_searched: u32 = 0,
    canceled: bool = false,
};

/// Searches the sessions of `ix` for `q`. Fails with
/// `error.InvalidPattern` when a regex query does not compile.
pub fn search(ix: *index.SessionIndex, io: Io, q: Query, sink: SearchSink, cancel: *const std.atomic.Value(bool)) !Outcome {
    const gpa = ix.gpa;
    var re = zg_regex.Regex.compile(gpa, q.text, .{ .literal = !q.regex, .case_insensitive = q.case_insensitive }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidPattern,
    };
    defer re.deinit(gpa);
    var cache = try re.newCache(gpa);
    defer cache.deinit();

    // Raw-line prefilter for literals: the query as it appears in JSON.
    var pre: ?zg_regex.Regex = null;
    defer if (pre) |*p| p.deinit(gpa);
    var pre_cache = try re.newCache(gpa);
    defer pre_cache.deinit();
    if (!q.regex) {
        var esc: Io.Writer.Allocating = .init(gpa);
        defer esc.deinit();
        std.json.Stringify.encodeJsonStringChars(q.text, .{}, &esc.writer) catch return error.OutOfMemory;
        pre = try zg_regex.Regex.compile(gpa, esc.written(), .{ .literal = true, .case_insensitive = q.case_insensitive });
    }

    // Session order: newest first.
    var ids: std.ArrayList(proto.SessionId) = .empty;
    defer ids.deinit(gpa);
    {
        var metas: std.ArrayList(*const index.SessionMeta) = .empty;
        defer metas.deinit(gpa);
        ix.mutex.lockUncancelable(io);
        defer ix.mutex.unlock(io);
        for (ix.entries.items) |*m| if (q.filter.matches(m)) try metas.append(gpa, m);
        std.mem.sort(*const index.SessionMeta, metas.items, {}, struct {
            fn lt(_: void, a: *const index.SessionMeta, b: *const index.SessionMeta) bool {
                return a.updated_ms > b.updated_ms;
            }
        }.lt);
        for (metas.items) |m| try ids.append(gpa, m.id);
    }

    var out: Outcome = .{};
    var tmp: std.heap.ArenaAllocator = .init(gpa);
    defer tmp.deinit();
    for (ids.items) |id| {
        if (cancel.load(.acquire)) {
            out.canceled = true;
            return out;
        }
        const name = proto.agent_ref.format(id) ++ ".jsonl".*;
        const f = ix.dir.openFile(io, &name, .{}) catch continue;
        defer f.close(io);
        out.sessions_searched += 1;
        var it: loader.Forward = .{ .file = f, .pos = 0, .end = try f.length(io), .gpa = gpa };
        defer it.deinit();
        var first = true;
        while (try it.next(io)) |raw| {
            if (first) {
                // The header holds no searchable text.
                first = false;
                continue;
            }
            if (cancel.load(.acquire)) {
                out.canceled = true;
                return out;
            }
            if (pre) |*p| if (!p.isMatch(&pre_cache, .fromSlice(raw))) continue;
            _ = tmp.reset(.retain_capacity);
            const a = tmp.allocator();
            const line = records.decode(a, raw) catch continue;
            const text = try searchableText(a, line.record) orelse continue;
            const m = re.find(&cache, .fromSlice(text)) orelse continue;
            const snip = try snippet(a, text, @intCast(m.start), @intCast(m.end), q.context_bytes);
            out.hits += 1;
            const more = sink.on_hit(sink.ctx, .{ .session = id, .seq = line.seq, .snippet = snip.text, .match_start = snip.start, .match_end = snip.end });
            if (!more or out.hits >= q.max_hits) return out;
        }
    }
    return out;
}

/// The text a record can be found by (blocks joined with `\n`), or null.
pub fn searchableText(a: Allocator, r: records.Record) Allocator.Error!?[]const u8 {
    switch (r) {
        .title => |t| return t,
        .user, .assistant, .tool_results => |m| {
            var out: std.ArrayList(u8) = .empty;
            for (m.content) |b| {
                switch (b) {
                    .text => |t| try out.appendSlice(a, t.text),
                    .tool_use => |t| {
                        try out.appendSlice(a, t.name);
                        try out.append(a, ' ');
                        try out.appendSlice(a, t.input_json);
                    },
                    .tool_result => |t| for (t.parts) |p| switch (p) {
                        .text => |s| {
                            try out.appendSlice(a, s);
                            try out.append(a, '\n');
                        },
                        else => {},
                    },
                    else => continue,
                }
                try out.append(a, '\n');
            }
            return if (out.items.len == 0) null else out.items;
        },
        else => return null,
    }
}

const Snippet = struct { text: []const u8, start: u32, end: u32 };

/// `ctx` bytes on each side of `[s, e)`, cut at UTF-8 boundaries, with
/// newlines and tabs flattened to spaces and "…" marking cut ends.
pub fn snippet(a: Allocator, text: []const u8, s: usize, e: usize, ctx: u32) Allocator.Error!Snippet {
    var lo = s -| ctx;
    var hi = @min(text.len, e + ctx);
    while (lo > 0 and lo < text.len and isCont(text[lo])) lo -= 1;
    while (hi < text.len and isCont(text[hi])) hi += 1;
    var out: std.ArrayList(u8) = .empty;
    const ell = "…";
    if (lo > 0) try out.appendSlice(a, ell);
    const ms: u32 = @intCast(out.items.len + (s - lo));
    for (text[lo..hi]) |c| try out.append(a, if (c == '\n' or c == '\r' or c == '\t') ' ' else c);
    if (hi < text.len) try out.appendSlice(a, ell);
    return .{ .text = out.items, .start = ms, .end = ms + @as(u32, @intCast(e - s)) };
}

fn isCont(c: u8) bool {
    return c & 0xC0 == 0x80;
}

test "snippet cuts at utf-8 boundaries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = "héllo wörld\nfoo bar";
    const at = std.mem.indexOf(u8, t, "foo").?;
    const s = try snippet(arena.allocator(), t, at, at + 3, 4);
    try std.testing.expect(std.unicode.utf8ValidateSlice(s.text));
    try std.testing.expectEqualStrings("foo", s.text[s.start..s.end]);
    try std.testing.expect(std.mem.indexOfScalar(u8, s.text, '\n') == null);
}
