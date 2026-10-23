//! The research report note (E13.F05.S02.T01): the synthesis answer as
//! Markdown with footnote citations into the source notes.
//!
//! Each claim is followed by footnote references (`[^3]`); each footnote
//! links the cited passage with an Obsidian block reference
//! (`[[sources/site/slug#^b12]]`) and quotes up to 150 characters of it.
//! The block references are added to the source notes the first time a
//! passage is cited (`ensureBlockRefs`, one write per note through the
//! E12 port), so every footnote resolves. A claim the verifier found
//! unsupported gets a `⚠ unsupported` badge; an unverifiable one is never
//! shown as unsupported. The report ends with a "Verification" section.

const std = @import("std");
const sources = @import("sources.zig");
const blocks_mod = @import("blocks.zig");
const citations = @import("citations.zig");
const verify = @import("verify.zig");

const Allocator = std.mem.Allocator;
const SourceLibrary = sources.SourceLibrary;
const SourceId = sources.SourceId;
const Claim = citations.Claim;
const Citation = citations.Citation;
const Verdict = verify.Verdict;

/// A run of the report: plain text or a claim (by index into
/// `Report.claims`).
pub const Part = union(enum) { text: []const u8, claim: u32 };

pub const ReportSection = struct {
    /// The `##` heading text; null for text before the first heading.
    heading: ?[]const u8 = null,
    parts: []const Part,
};

pub const Report = struct {
    title: []const u8,
    question: []const u8,
    sections: []const ReportSection,
    claims: []const Claim,
    /// Every cited source, in first-cited order.
    sources: []const SourceId,
};

pub const ReportOpts = struct {
    /// `YYYY-MM-DD`.
    created: []const u8,
    run: ?[]const u8 = null,
    /// Verdicts by claim (any order); claims without one show no badge.
    verdicts: []const Verdict = &.{},
    max_quote: usize = 150,
};

/// Splits `text` (the answer with claim `ranges` into it) into sections at
/// Markdown headings.
pub fn build(arena: Allocator, title: []const u8, question: []const u8, text: []const u8, claims: []const Claim) !Report {
    var parts: std.ArrayList(Part) = .empty;
    var pos: usize = 0;
    for (claims, 0..) |c, i| {
        if (c.range.start < pos or c.range.end > text.len) continue;
        if (c.range.start > pos) try parts.append(arena, .{ .text = text[pos..c.range.start] });
        try parts.append(arena, .{ .claim = @intCast(i) });
        pos = c.range.end;
    }
    if (pos < text.len) try parts.append(arena, .{ .text = text[pos..] });

    var sections: std.ArrayList(ReportSection) = .empty;
    var cur: std.ArrayList(Part) = .empty;
    var heading: ?[]const u8 = null;
    for (parts.items) |p| {
        const t = switch (p) {
            .claim => {
                try cur.append(arena, p);
                continue;
            },
            .text => |t| t,
        };
        // Headings start new sections; split the text at each one.
        var rest = t;
        while (findHeading(rest)) |h| {
            if (h.start > 0) try cur.append(arena, .{ .text = rest[0..h.start] });
            if (heading != null or cur.items.len > 0) try sections.append(arena, .{ .heading = heading, .parts = try cur.toOwnedSlice(arena) });
            heading = h.text;
            rest = std.mem.trimStart(u8, rest[h.end..], "\r\n");
        }
        if (rest.len > 0) try cur.append(arena, .{ .text = rest });
    }
    if (heading != null or cur.items.len > 0) try sections.append(arena, .{ .heading = heading, .parts = cur.items });

    var ids: std.ArrayList(SourceId) = .empty;
    for (claims) |c| for (c.citations) |ct| {
        for (ids.items) |x| {
            if (std.mem.eql(u8, &x, &ct.source)) break;
        } else try ids.append(arena, ct.source);
    };
    return .{ .title = title, .question = question, .sections = sections.items, .claims = claims, .sources = ids.items };
}

/// The first heading line (`#`..`######` then a space) in `t`: its text
/// and the line's span (with its newline).
fn findHeading(t: []const u8) ?struct { start: usize, end: usize, text: []const u8 } {
    var pos: usize = 0;
    while (pos < t.len) {
        const nl = std.mem.indexOfScalarPos(u8, t, pos, '\n');
        const end = nl orelse t.len;
        const line = std.mem.trimEnd(u8, t[pos..end], "\r");
        var h: usize = 0;
        while (h < line.len and line[h] == '#') h += 1;
        // Only whole lines: a heading must start the text or follow a newline.
        if (h >= 1 and h <= 6 and h < line.len and line[h] == ' ' and nl != null) {
            return .{ .start = pos, .end = end + 1, .text = std.mem.trim(u8, line[h..], " #") };
        }
        pos = if (nl) |x| x + 1 else t.len;
    }
    return null;
}

/// The wikilink target of a source note (its vault path without `.md`).
pub fn linkTarget(path: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, path, ".md")) path[0 .. path.len - 3] else path;
}

/// Adds a block reference to every cited passage that lacks one: one
/// write per source note, through the library's note port. Returns the
/// number of notes written.
pub fn ensureBlockRefs(lib: *SourceLibrary, arena: Allocator, claims: []const Claim) !u32 {
    var by_source: std.AutoArrayHashMapUnmanaged(SourceId, std.ArrayList(u32)) = .empty;
    for (claims) |c| for (c.citations) |ct| {
        const g = try by_source.getOrPut(arena, ct.source);
        if (!g.found_existing) g.value_ptr.* = .empty;
        try g.value_ptr.append(arena, ct.start_block);
    };
    var written: u32 = 0;
    for (by_source.keys(), by_source.values()) |id, wanted| {
        const s = lib.get(id) orelse continue;
        const note = (try lib.readNote(arena, s)) orelse continue;
        const body = sources.body(note);
        const off = @intFromPtr(body.ptr) - @intFromPtr(note.ptr);
        const bs = try blocks_mod.split(arena, body);
        // Units needing a reference, by insertion point (ascending).
        var units: std.ArrayList(blocks_mod.Block) = .empty;
        for (wanted.items) |i| {
            if (i >= bs.len) continue;
            const u = bs[bs[i].unit];
            if (u.ref != null) continue;
            for (units.items) |x| {
                if (x.unit == u.unit) break;
            } else try units.append(arena, u);
        }
        if (units.items.len == 0) continue;
        std.mem.sort(blocks_mod.Block, units.items, {}, struct {
            fn lt(_: void, x: blocks_mod.Block, y: blocks_mod.Block) bool {
                return x.insert_at < y.insert_at;
            }
        }.lt);
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        for (units.items) |u| {
            const at = off + u.insert_at;
            try out.appendSlice(arena, note[pos..at]);
            try out.appendSlice(arena, try u.refText(arena, u.unit));
            pos = at;
        }
        try out.appendSlice(arena, note[pos..]);
        const r = try lib.o.notes.write(lib.o.notes.ctx, .{
            .path = s.path,
            .content = out.items,
            .base = note,
            .auto_apply = true,
            .summary = try std.fmt.allocPrint(arena, "Add citation block references to {s}", .{s.title}),
        });
        _ = r;
        try lib.setNote(id, out.items);
        written += 1;
    }
    return written;
}

/// The block reference number a footnote links for `c`.
fn refFor(bs: []const blocks_mod.Block, c: Citation) u32 {
    if (c.start_block >= bs.len) return c.start_block;
    const b = bs[c.start_block];
    return b.ref orelse b.unit;
}

fn verdictOf(opts: ReportOpts, claim: u32) ?Verdict {
    for (opts.verdicts) |v| if (v.claim == claim) return v;
    return null;
}

fn yamlString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => {},
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// `s` on one line, cut to `max` bytes (at a UTF-8 boundary) with "…".
fn quote(a: Allocator, s: []const u8, max: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var space = false;
    for (std.mem.trim(u8, s, " \t\r\n")) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            space = true;
            continue;
        }
        if (space) try out.append(a, ' ');
        space = false;
        try out.append(a, if (c == '"') '\'' else c);
    }
    if (out.items.len <= max) return out.items;
    var cut = max;
    while (cut > 0 and (out.items[cut] & 0xC0) == 0x80) cut -= 1;
    return std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, out.items[0..cut], " "), "…" });
}

/// Writes the report note. Call `ensureBlockRefs` first so the links
/// resolve.
pub fn writeReportMarkdown(w: *std.Io.Writer, r: *const Report, lib: *SourceLibrary, opts: ReportOpts) !void {
    var arena_state: std.heap.ArenaAllocator = .init(lib.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try w.writeAll("---\ntype: research-report\nquestion: ");
    try yamlString(w, r.question);
    try w.print("\ncreated: {s}\n", .{opts.created});
    if (opts.run) |run| try w.print("run: {s}\n", .{run});
    try w.writeAll("sources:\n");
    for (r.sources) |id| {
        const s = lib.get(id) orelse continue;
        try w.print("  - \"[[{s}]]\"\n", .{linkTarget(s.path)});
    }
    try w.print("---\n\n# {s}\n\n", .{r.title});

    // Footnotes: one per distinct passage, numbered in first-cited order.
    const Note = struct { c: Citation, n: u32, claim: u32 };
    var notes: std.ArrayList(Note) = .empty;
    var last: u8 = '\n';
    for (r.sections, 0..) |sec, si| {
        if (sec.heading) |h| try w.print("## {s}\n\n", .{h}) else if (si > 0) try w.writeAll("\n");
        for (sec.parts) |p| switch (p) {
            .text => |t| {
                try w.writeAll(t);
                if (t.len > 0) last = t[t.len - 1];
            },
            .claim => |ci| {
                const c = r.claims[ci];
                const body = std.mem.trimEnd(u8, c.text, " \t\r\n");
                try w.writeAll(body);
                for (c.citations) |ct| {
                    const n = for (notes.items) |x| {
                        if (x.c.samePassage(ct)) break x.n;
                    } else blk: {
                        const n: u32 = @intCast(notes.items.len + 1);
                        try notes.append(a, .{ .c = ct, .n = n, .claim = c.id });
                        break :blk n;
                    };
                    try w.print("[^{d}]", .{n});
                }
                if (verdictOf(opts, c.id)) |v| switch (v.kind) {
                    .unsupported => try w.writeAll(" ⚠ unsupported"),
                    .partially_supported => try w.writeAll(" ⚠ partially supported"),
                    .supported, .unverifiable => {},
                };
                const tail = c.text[body.len..];
                try w.writeAll(tail);
                last = if (tail.len > 0) tail[tail.len - 1] else ' ';
            },
        };
    }
    if (notes.items.len > 0) try w.writeAll(if (last == '\n') "\n" else "\n\n");
    for (notes.items) |x| {
        const s = lib.get(x.c.source) orelse continue;
        const bs = blk: {
            const note = (try lib.readNote(a, s)) orelse break :blk &[_]blocks_mod.Block{};
            break :blk try blocks_mod.split(a, sources.body(note));
        };
        const text = if (x.c.cited_text.len > 0) x.c.cited_text else blk: {
            var parts: std.ArrayList(u8) = .empty;
            var i = x.c.start_block;
            while (i <= x.c.end_block and i < bs.len) : (i += 1) {
                if (parts.items.len > 0) try parts.append(a, ' ');
                try parts.appendSlice(a, bs[i].text);
            }
            break :blk parts.items;
        };
        try w.print("[^{d}]: [[{s}#^b{d}]] — \"{s}\"", .{ x.n, linkTarget(s.path), refFor(bs, x.c), try quote(a, text, opts.max_quote) });
        if (verdictOf(opts, x.claim)) |v| switch (v.kind) {
            .supported => {},
            else => try w.print(" ({s})", .{v.kind.label()}),
        };
        try w.writeAll("\n");
    }

    try writeVerification(w, a, r, opts);
}

fn writeVerification(w: *std.Io.Writer, a: Allocator, r: *const Report, opts: ReportOpts) !void {
    if (opts.verdicts.len == 0) return;
    var counts = std.EnumArray(verify.Kind, u32).initFill(0);
    for (r.claims) |c| if (verdictOf(opts, c.id)) |v| {
        counts.getPtr(v.kind).* += 1;
    };
    try w.print("\n## Verification\n\n{d} cited claims: {d} supported, {d} partially supported, {d} unsupported, {d} unverifiable.\n", .{
        r.claims.len,
        counts.get(.supported),
        counts.get(.partially_supported),
        counts.get(.unsupported),
        counts.get(.unverifiable),
    });
    const groups = [_]struct { kind: verify.Kind, head: []const u8 }{
        .{ .kind = .unsupported, .head = "Unsupported" },
        .{ .kind = .partially_supported, .head = "Partially supported" },
        .{ .kind = .unverifiable, .head = "Not verified" },
    };
    for (groups) |g| {
        if (counts.get(g.kind) == 0) continue;
        try w.print("\n{s}:\n\n", .{g.head});
        for (r.claims) |c| {
            const v = verdictOf(opts, c.id) orelse continue;
            if (v.kind != g.kind) continue;
            try w.print("- \"{s}\"", .{try quote(a, c.text, 120)});
            if (v.reason.len > 0) try w.print(": {s}", .{try quote(a, v.reason, 200)});
            try w.writeAll("\n");
        }
    }
}
