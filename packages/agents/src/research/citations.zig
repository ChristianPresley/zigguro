//! Citations (E13.F05.S02.T01): how a research report points at the
//! passages it rests on.
//!
//! The synthesis agent gets its sources as `search_result` blocks with
//! citations on (`synthesisContent`; the API wants every search result in
//! a request to agree). Claude's answer comes back as text blocks, each
//! with a `citations` array:
//!   * `search_result_location` names the search result by its index in
//!     the request (`sr_order` maps it back to a source) and the cited
//!     blocks (`start_block_index`..`end_block_index`, both inclusive);
//!   * `web_search_result_location` names a URL and the cited text: the
//!     source is found by URL (captured first when the library can fetch)
//!     and the text is located in its blocks.
//! Providers without native citations are asked (`marker_instructions`)
//! to write `[[src:<id>#b<start>-<end>]]` after each claim instead;
//! `parseMarkers` strips the markers and turns them into the same claims.
//!
//! A claim is a text block carrying at least one citation (API citations
//! cover whole blocks); adjacent blocks citing the same passages merge
//! into one claim. A citation whose source can't be found is dropped, so
//! every citation left resolves to a source note.

const std = @import("std");
const zg_ai_proto = @import("zg_ai_proto");
const sources = @import("sources.zig");
const blocks_mod = @import("blocks.zig");

const Allocator = std.mem.Allocator;
const SourceLibrary = sources.SourceLibrary;
const SourceId = sources.SourceId;
const Block = blocks_mod.Block;

/// Byte range in the report text (`messageText`, or the text with markers
/// removed).
pub const Range = struct { start: usize, end: usize };

pub const Citation = struct {
    source: SourceId,
    /// Cited blocks, both inclusive.
    start_block: u32,
    end_block: u32,
    cited_text: []const u8 = "",
    /// False when a web search citation's text wasn't found in the
    /// source's blocks (the citation then points at block 0).
    located: bool = true,

    pub fn samePassage(x: Citation, y: Citation) bool {
        return std.mem.eql(u8, &x.source, &y.source) and x.start_block == y.start_block and x.end_block == y.end_block;
    }
};

pub const Claim = struct {
    id: u32,
    text: []const u8,
    range: Range,
    citations: []const Citation,
};

/// The answer's text: its text blocks joined (Claude splits a paragraph
/// into blocks at citation boundaries, so nothing goes between them).
pub fn messageText(arena: Allocator, msg: *const zg_ai_proto.Message) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (msg.content) |b| switch (b) {
        .text => |t| try out.appendSlice(arena, t.text),
        else => {},
    };
    return out.items;
}

/// True when any text block of `msg` has API citations.
pub fn hasNativeCitations(msg: *const zg_ai_proto.Message) bool {
    for (msg.content) |b| switch (b) {
        .text => |t| if (t.citations_json != null) return true,
        else => {},
    };
    return false;
}

/// Claims from the API citations on `msg`'s text blocks. Ranges index
/// `messageText(msg)`. `sr_order[i]` is the source sent as the request's
/// i-th search result.
pub fn fromProviderCitations(arena: Allocator, msg: *const zg_ai_proto.Message, lib: *SourceLibrary, sr_order: []const SourceId) ![]Claim {
    var out: std.ArrayList(Claim) = .empty;
    var pos: usize = 0;
    for (msg.content) |b| {
        const t = switch (b) {
            .text => |t| t,
            else => continue,
        };
        const start = pos;
        pos += t.text.len;
        const cj = t.citations_json orelse continue;
        const cs = try parseCitations(arena, cj, lib, sr_order);
        if (cs.len == 0) continue;
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (last.range.end == start and samePassages(last.citations, cs)) {
                last.range.end = pos;
                continue;
            }
        }
        try out.append(arena, .{ .id = @intCast(out.items.len + 1), .text = "", .range = .{ .start = start, .end = pos }, .citations = cs });
    }
    // Claim text is set once merging is done.
    const text = try messageText(arena, msg);
    for (out.items) |*c| c.text = text[c.range.start..c.range.end];
    return out.items;
}

fn samePassages(x: []const Citation, y: []const Citation) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!p.samePassage(q)) return false;
    return true;
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn int(o: std.json.ObjectMap, key: []const u8) ?u32 {
    const v = o.get(key) orelse return null;
    return if (v == .integer and v.integer >= 0 and v.integer <= std.math.maxInt(u32)) @intCast(v.integer) else null;
}

/// The citations in one text block's `citations` JSON array that resolve
/// to a source; the rest (document locations, unknown URLs) are dropped.
pub fn parseCitations(arena: Allocator, json: []const u8, lib: *SourceLibrary, sr_order: []const SourceId) ![]const Citation {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return &.{};
    if (parsed != .array) return &.{};
    var out: std.ArrayList(Citation) = .empty;
    for (parsed.array.items) |v| {
        if (v != .object) continue;
        const o = v.object;
        const kind = str(o, "type") orelse continue;
        const cited = str(o, "cited_text") orelse "";
        var c: Citation = undefined;
        if (std.mem.eql(u8, kind, "search_result_location")) {
            const i = int(o, "search_result_index") orelse continue;
            if (i >= sr_order.len) continue;
            const s = int(o, "start_block_index") orelse 0;
            const e = int(o, "end_block_index") orelse s;
            c = .{ .source = sr_order[i], .start_block = s, .end_block = @max(s, e), .cited_text = cited };
        } else if (std.mem.eql(u8, kind, "web_search_result_location")) {
            const url = str(o, "url") orelse continue;
            const id = (try lookupOrCapture(lib, arena, url)) orelse continue;
            const bs = lib.blocks(id, arena) catch continue;
            c = if (locate(bs, cited)) |r|
                .{ .source = id, .start_block = r.start, .end_block = r.end, .cited_text = cited }
            else
                .{ .source = id, .start_block = 0, .end_block = 0, .cited_text = cited, .located = false };
        } else continue;
        if (lib.get(c.source) == null) continue;
        var dup = false;
        for (out.items) |x| dup = dup or x.samePassage(c);
        if (!dup) try out.append(arena, c);
    }
    return out.items;
}

fn lookupOrCapture(lib: *SourceLibrary, arena: Allocator, url: []const u8) !?SourceId {
    if (try lib.lookup(arena, url)) |id| return id;
    if (lib.o.fetch == null) return null;
    const r = lib.capture(url, .{}) catch return null;
    return r.id;
}

/// Blocks `start..end` (inclusive) holding `cited`, compared with runs of
/// whitespace folded; a quote spanning blocks is found by its first and
/// last 24 characters.
pub fn locate(bs: []const Block, cited: []const u8) ?struct { start: u32, end: u32 } {
    var buf: [512]u8 = undefined;
    const q = fold(&buf, cited);
    if (q.len == 0) return null;
    var hay: [8192]u8 = undefined;
    for (bs) |b| if (contains(&hay, b.text, q)) return .{ .start = b.index, .end = b.index };
    const n = @min(q.len, 24);
    const head = q[0..n];
    const tail = q[q.len - n ..];
    for (bs, 0..) |b, i| {
        if (!contains(&hay, b.text, head)) continue;
        for (bs[i + 1 ..]) |e| if (contains(&hay, e.text, tail)) return .{ .start = b.index, .end = e.index };
    }
    return null;
}

fn contains(buf: []u8, text: []const u8, folded: []const u8) bool {
    return std.mem.indexOf(u8, fold(buf, text), folded) != null;
}

/// `s` trimmed with whitespace runs as one space (cut to `buf`).
fn fold(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var space = false;
    for (std.mem.trim(u8, s, " \t\r\n")) |c| {
        if (n == buf.len) break;
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            space = true;
            continue;
        }
        if (space and n < buf.len - 1) {
            buf[n] = ' ';
            n += 1;
        }
        space = false;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

// ---- providers without native citations ----

pub const marker_instructions =
    \\Cite every factual claim. After the sentence it supports, write a marker
    \\[[src:<id>#b<start>-<end>]] naming the source id and the first and last
    \\passage numbers you relied on, e.g. [[src:3fa9c2d1e0b74f6a8c5d2e1f0a9b8c7d#b4-5]].
    \\Use several markers for several sources. Never cite a passage you were not given.
;

pub const Parsed = struct { text: []const u8, claims: []Claim };

/// Strips `[[src:<id>#b<s>-<e>]]` markers from `text`. Each run of markers
/// cites the text before it back to the previous marker, line start or
/// sentence end. Markers naming unknown sources are removed and ignored.
pub fn parseMarkers(arena: Allocator, text: []const u8, lib: *SourceLibrary) !Parsed {
    var out: std.ArrayList(u8) = .empty;
    var claims: std.ArrayList(Claim) = .empty;
    var cites: std.ArrayList(Citation) = .empty;
    var claim_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (parseMarker(text[i..])) |m| {
            if (lib.get(m.c.source) != null) {
                var dup = false;
                for (cites.items) |x| dup = dup or x.samePassage(m.c);
                if (!dup) try cites.append(arena, m.c);
            }
            // Drop the space before the marker.
            while (out.items.len > claim_start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
            i += m.len;
            const more = blk: {
                var j = i;
                while (j < text.len and text[j] == ' ') j += 1;
                break :blk parseMarker(text[j..]) != null;
            };
            if (!more and cites.items.len > 0) {
                const start = claimStart(out.items, claim_start);
                try claims.append(arena, .{ .id = @intCast(claims.items.len + 1), .text = "", .range = .{ .start = start, .end = out.items.len }, .citations = try cites.toOwnedSlice(arena) });
                claim_start = out.items.len;
            } else if (!more) cites.clearRetainingCapacity();
            if (more) {
                while (i < text.len and text[i] == ' ') i += 1;
            }
            continue;
        }
        try out.append(arena, text[i]);
        if (text[i] == '\n') claim_start = out.items.len;
        i += 1;
    }
    for (claims.items) |*c| c.text = out.items[c.range.start..c.range.end];
    return .{ .text = out.items, .claims = claims.items };
}

/// Where the sentence ending at `out.len` starts (not before `floor`).
fn claimStart(out: []const u8, floor: usize) usize {
    var i = out.len;
    // Skip the sentence's own final punctuation.
    while (i > floor and (out[i - 1] == '.' or out[i - 1] == '!' or out[i - 1] == '?')) i -= 1;
    while (i > floor + 1) : (i -= 1) {
        const c = out[i - 2];
        if ((c == '.' or c == '!' or c == '?') and out[i - 1] == ' ') break;
    }
    if (i == floor + 1) i = floor;
    while (i < out.len and out[i] == ' ') i += 1;
    return i;
}

fn parseMarker(s: []const u8) ?struct { c: Citation, len: usize } {
    const open = "[[src:";
    if (!std.mem.startsWith(u8, s, open)) return null;
    const close = std.mem.indexOf(u8, s, "]]") orelse return null;
    const inner = s[open.len..close];
    const hash = std.mem.indexOf(u8, inner, "#b") orelse return null;
    const id = inner[0..hash];
    if (id.len != 32) return null;
    for (id) |ch| if (!std.ascii.isHex(ch)) return null;
    const range = inner[hash + 2 ..];
    const dash = std.mem.indexOfScalar(u8, range, '-');
    const s0 = std.fmt.parseInt(u32, if (dash) |d| range[0..d] else range, 10) catch return null;
    const e0 = if (dash) |d| std.fmt.parseInt(u32, range[d + 1 ..], 10) catch return null else s0;
    var c: Citation = .{ .source = undefined, .start_block = s0, .end_block = @max(s0, e0) };
    for (id, 0..) |ch, k| c.source[k] = std.ascii.toLower(ch);
    return .{ .c = c, .len = close + 2 };
}

// ---- the synthesis request ----

/// The user turn for the synthesis agent: one `search_result` block per
/// source (citations on for every one, or off for every one) and then the
/// question. Returns the order used, for `fromProviderCitations`.
pub fn synthesisContent(arena: Allocator, lib: *SourceLibrary, ids: []const SourceId, question: []const u8, citing: bool) !struct { content: []const zg_ai_proto.ContentBlock, order: []const SourceId } {
    var content: std.ArrayList(zg_ai_proto.ContentBlock) = .empty;
    var order: std.ArrayList(SourceId) = .empty;
    for (ids) |id| {
        const s = lib.get(id) orelse continue;
        const bs = try lib.blocks(id, arena);
        try content.append(arena, .{ .provider_opaque = .{ .origin = .anthropic, .kind = "search_result", .raw_json = try sources.searchResultJsonCiting(arena, s.url, s.title, bs, citing) } });
        try order.append(arena, id);
    }
    try content.append(arena, .{ .text = .{ .text = question } });
    return .{ .content = content.items, .order = order.items };
}

/// Whether the `search_result` blocks in `msgs` all agree on
/// `citations.enabled` (the API rejects a mix).
pub fn citationsUniform(arena: Allocator, msgs: []const zg_ai_proto.Message) bool {
    var seen: ?bool = null;
    for (msgs) |m| for (m.content) |b| {
        const raw = switch (b) {
            .provider_opaque => |p| if (std.mem.eql(u8, p.kind, "search_result")) p.raw_json else continue,
            else => continue,
        };
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return false;
        if (v != .object) return false;
        var on = false;
        if (v.object.get("citations")) |c| if (c == .object) if (c.object.get("enabled")) |e| {
            on = e == .bool and e.bool;
        };
        if (seen) |s| if (s != on) return false;
        seen = on;
    };
    return true;
}
