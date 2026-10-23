//! The source library: extraction fixtures, dedupe, the note format,
//! passage blocks, `search_result` export, capture modes and the write
//! policy, fetch events and the tools.

const std = @import("std");
const builtin = @import("builtin");
const zg_ai = @import("zg_ai");
const sources = @import("sources.zig");
const extract = @import("extract.zig");
const blocks = @import("blocks.zig");
const tools = @import("tools.zig");
const runs = @import("../runs/root.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const names = [_][]const u8{ "01_blog_article", "02_news_main", "03_docs_density", "04_canonical", "05_table", "06_lists_menu", "07_entities", "08_scripts", "09_forum", "10_minimal" };
const pages = blk: {
    var out: [names.len][]const u8 = undefined;
    for (names, 0..) |n, i| out[i] = @embedFile("testdata/html/" ++ n ++ ".html");
    break :blk out;
};
const expected = blk: {
    var out: [names.len][]const u8 = undefined;
    for (names, 0..) |n, i| out[i] = @embedFile("testdata/html/" ++ n ++ ".md");
    break :blk out;
};

fn describe(a: std.mem.Allocator, ex: extract.Extracted) ![]const u8 {
    return std.fmt.allocPrint(a, "title: {s}\nsite: {s}\npublished: {s}\ncanonical: {s}\n---\n{s}\n", .{ ex.title, ex.site, ex.published orelse "-", ex.canonical orelse "-", ex.markdown });
}

test "extract fixtures" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var failed = false;
    for (names, pages, expected) |n, html, want| {
        const url = try std.fmt.allocPrint(a, "https://www.example.com/{s}?utm_source=feed", .{n});
        const got = try describe(a, try extract.extract(a, html, url));
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("=====BEGIN {s}=====\n{s}=====END=====\n", .{ n, got });
            failed = true;
        }
    }
    if (failed) return error.TestUnexpectedResult;
}

/// E12 stand-in: applied writes land in the vault; others are pending.
const Notes = struct {
    dir: std.Io.Dir,
    writes: std.ArrayList(struct { path: []const u8, auto: bool }) = .empty,
    next_cs: u64 = 100,
    arena: std.heap.ArenaAllocator,

    fn write(ctx: *anyopaque, w: sources.NoteWrite) anyerror!sources.WriteOutcome {
        const n: *Notes = @ptrCast(@alignCast(ctx));
        try n.writes.append(n.arena.allocator(), .{ .path = try n.arena.allocator().dupe(u8, w.path), .auto = w.auto_apply });
        n.next_cs += 1;
        if (w.auto_apply) {
            if (std.fs.path.dirname(w.path)) |d| try n.dir.createDirPath(io, d);
            try n.dir.writeFile(io, .{ .sub_path = w.path, .data = w.content });
        }
        return .{ .applied = w.auto_apply, .changeset = n.next_cs };
    }
};

const Web = struct {
    pages: []const struct { url: []const u8, body: []const u8, ctype: []const u8 = "text/html; charset=utf-8" },
    fetches: u32 = 0,

    fn fetch(ctx: *anyopaque, a: std.mem.Allocator, url: []const u8) anyerror!sources.Fetched {
        const w: *Web = @ptrCast(@alignCast(ctx));
        w.fetches += 1;
        for (w.pages) |p| if (std.mem.eql(u8, p.url, url)) return .{ .body = try a.dupe(u8, p.body), .content_type = p.ctype };
        return error.NotFound;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    clock: zg_ai.ratelimit.FakeClock,
    notes: Notes,
    web: Web,
    lib: *sources.SourceLibrary,

    fn init(f: *Fx, mode: sources.Mode) !void {
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .clock = .init(1_792_756_800_000), .notes = undefined, .web = .{ .pages = &.{
            .{ .url = "https://www.example.com/blog/zig?utm_source=feed", .body = pages[0] },
            .{ .url = "https://example.com/plain.txt", .body = "# Plain notes\n\nSome text.", .ctype = "text/plain" },
        } }, .lib = undefined };
        f.notes = .{ .dir = f.tmp.dir, .arena = .init(gpa) };
        f.lib = try f.open(mode);
    }

    fn open(f: *Fx, mode: sources.Mode) !*sources.SourceLibrary {
        return sources.SourceLibrary.open(gpa, io, f.tmp.dir, .{
            .clock = f.clock.clock(),
            .fetch = .{ .ctx = &f.web, .fetch = Web.fetch },
            .notes = .{ .ctx = &f.notes, .write = Notes.write },
            .config = .{ .capture = mode },
        });
    }

    fn deinit(f: *Fx) void {
        f.lib.close();
        f.notes.arena.deinit();
        f.tmp.cleanup();
    }

    fn read(f: *Fx, path: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(io, path, gpa, .limited(1 << 20));
    }
};

const note_golden =
    \\---
    \\url: "https://www.example.com/blog/zig?utm_source=feed"
    \\canonical_url: "https://www.example.com/blog/zig"
    \\title: "Why Zig Builds Are Fast"
    \\site: "Tiny Blog"
    \\published: 2025-03-14
    \\fetched: 2026-10-23
    \\content_hash: "HASH"
    \\fetch_count: "1"
    \\captured_by: "RUN"
    \\tags:
    \\  - source
    \\---
    \\> Captured from <https://www.example.com/blog/zig?utm_source=feed> on 2026-10-23
    \\
    \\# Why Zig Builds Are Fast
    \\
;

test "note frontmatter golden" {
    var f: Fx = undefined;
    try f.init(.always);
    defer f.deinit();
    const run = runs.RunId.fromInt(7);
    const r = try f.lib.capture("https://www.example.com/blog/zig?utm_source=feed", .{ .run = run });
    try testing.expectEqual(sources.CaptureKind.captured, r.kind);
    try testing.expectEqualStrings("sources/tiny-blog/why-zig-builds-are-fast.md", r.path.?);
    const note = try f.read(r.path.?);
    defer gpa.free(note);
    const s = f.lib.get(r.id.?).?;
    const run_text = run.text();
    const want = try std.mem.replaceOwned(u8, gpa, note_golden, "HASH", s.content_hash);
    defer gpa.free(want);
    const want2 = try std.mem.replaceOwned(u8, gpa, want, "RUN", &run_text);
    defer gpa.free(want2);
    try testing.expectEqualStrings(want2, note[0..want2.len]);
    try testing.expect(std.mem.indexOf(u8, note, "the follow-up") != null);
    // Plain text is captured as is.
    const p = try f.lib.capture("https://example.com/plain.txt", .{});
    try testing.expectEqualStrings("sources/example.com/plain-notes.md", p.path.?);
    // The index comes back from the notes alone.
    f.lib.close();
    f.lib = try f.open(.always);
    try testing.expectEqual(@as(usize, 2), f.lib.count());
    const back = f.lib.get(r.id.?).?;
    try testing.expectEqualStrings("Why Zig Builds Are Fast", back.title);
    try testing.expectEqualStrings("2025-03-14", back.published.?);
    try testing.expectEqual(@as(u32, 1), back.fetch_count);
}

test "dedupe same and changed content" {
    var f: Fx = undefined;
    try f.init(.always);
    defer f.deinit();
    const r1 = try f.lib.capture("https://www.example.com/blog/zig?utm_source=feed", .{});
    // Same page under another spelling: a duplicate, counted.
    const r2 = try f.lib.capture("http://example.com/blog/zig#comments", .{ .html = pages[0] });
    try testing.expectEqual(sources.CaptureKind.duplicate, r2.kind);
    try testing.expectEqualStrings(&r1.id.?, &r2.id.?);
    try testing.expectEqual(@as(u32, 2), f.lib.get(r1.id.?).?.fetch_count);
    try testing.expectEqual(@as(usize, 1), f.lib.count());
    // New content: the note is updated in place and marked.
    const changed = try std.mem.replaceOwned(u8, gpa, pages[0], "nothing runs", "almost nothing runs");
    defer gpa.free(changed);
    const r3 = try f.lib.capture("https://example.com/blog/zig", .{ .html = changed });
    try testing.expectEqual(sources.CaptureKind.updated, r3.kind);
    try testing.expectEqualStrings(r1.path.?, r3.path.?);
    const note = try f.read(r1.path.?);
    defer gpa.free(note);
    try testing.expect(std.mem.indexOf(u8, note, "updated: 2026-10-23") != null);
    try testing.expect(std.mem.indexOf(u8, note, "almost nothing runs") != null);
    try testing.expect(std.mem.indexOf(u8, note, "fetch_count: \"3\"") != null);
    // Re-running the same capture after reopening makes no new note.
    f.lib.close();
    f.lib = try f.open(.always);
    const r4 = try f.lib.capture("https://www.example.com/blog/zig?utm_source=feed", .{ .html = changed });
    try testing.expectEqual(sources.CaptureKind.duplicate, r4.kind);
    try testing.expectEqual(@as(usize, 1), f.lib.count());
    // A different page with the same title gets its own file.
    const other = try f.lib.capture("https://www.example.com/blog/zig-2", .{ .html = pages[0] });
    try testing.expectEqualStrings("sources/tiny-blog/why-zig-builds-are-fast-2.md", other.path.?);
}

test "ask mode leaves notes pending; never skips" {
    var f: Fx = undefined;
    try f.init(.ask);
    defer f.deinit();
    const r = try f.lib.capture("https://www.example.com/blog/zig?utm_source=feed", .{});
    try testing.expectEqual(sources.CaptureKind.pending_approval, r.kind);
    try testing.expect(f.lib.get(r.id.?).?.pending);
    try testing.expectError(error.FileNotFound, f.tmp.dir.access(io, r.path.?, .{}));
    try testing.expect(!f.notes.writes.items[0].auto);
    // Pending sources can still be read and cited.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expect((try f.lib.blocks(r.id.?, arena.allocator())).len > 0);
    const n = try f.lib.capture("https://example.com/plain.txt", .{ .mode = .never });
    try testing.expectEqual(sources.CaptureKind.skipped, n.kind);
}

test "auto-apply never writes outside the sources folder" {
    var f: Fx = undefined;
    try f.init(.always);
    defer f.deinit();
    for ([_][]const u8{ "sources/a/b.md", "sources/x.md" }) |p| try testing.expect(f.lib.underSources(p));
    for ([_][]const u8{ "sources", "sources/", "notes/a.md", "sources/../notes/a.md", "sourcesx/a.md", "sources//a.md", "sources/a\\..\\..\\b.md" }) |p| try testing.expect(!f.lib.underSources(p));
    // Hostile titles and hosts stay inside it.
    const html = "<html><head><title>../../etc/passwd</title><meta property=\"og:site_name\" content=\"../../..\"></head><body><p>x</p></body></html>";
    const r = try f.lib.capture("https://evil.example/a", .{ .html = html });
    try testing.expectEqualStrings("sources/unknown/etc-passwd.md", r.path.?);
    for (f.notes.writes.items) |w| if (w.auto) try testing.expect(f.lib.underSources(w.path));
}

test "blocks stable and bounded" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var long: std.ArrayList(u8) = .empty;
    for (0..60) |i| try long.print(a, "Sentence number {d} is here. ", .{i});
    const body = try std.fmt.allocPrint(a, "# Title\n\nFirst paragraph\nwraps here.\n\n- item one\n- item two\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\ncode\n\nmore code\n```\n\n{s}\n\n" ++ ("é" ** 700) ++ "\n", .{long.items});
    const bs = try blocks.split(a, body);
    try testing.expectEqualStrings("# Title", bs[0].text);
    try testing.expectEqualStrings("First paragraph\nwraps here.", bs[1].text);
    try testing.expectEqualStrings("- item one", bs[2].text);
    try testing.expectEqualStrings("| 1 | 2 |", bs[5].text);
    try testing.expectEqualStrings("```\ncode\n\nmore code\n```", bs[6].text);
    for (bs, 0..) |b, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), b.index);
        try testing.expect(b.text.len <= blocks.max_chars);
        try testing.expect(std.unicode.utf8ValidateSlice(b.text));
    }
    // The long paragraph splits at a sentence end.
    try testing.expect(std.mem.endsWith(u8, bs[7].text, "here."));
    try testing.expect(std.mem.startsWith(u8, bs[8].text, "Sentence number"));
    // Same text, same blocks.
    const again = try blocks.split(a, body);
    try testing.expectEqual(bs.len, again.len);
    for (bs, again) |x, y| try testing.expectEqualStrings(x.text, y.text);
}

test "search result blocks shape" {
    var f: Fx = undefined;
    try f.init(.always);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try f.lib.capture("https://www.example.com/blog/zig?utm_source=feed", .{});
    const out = try f.lib.asSearchResults(&.{r.id.?}, a);
    try testing.expectEqual(@as(usize, 1), out.len);
    const o = out[0].provider_opaque;
    try testing.expectEqual(.anthropic, o.origin);
    try testing.expectEqualStrings("search_result", o.kind);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, o.raw_json, .{});
    try testing.expectEqualStrings("search_result", v.object.get("type").?.string);
    try testing.expectEqualStrings("https://www.example.com/blog/zig?utm_source=feed", v.object.get("source").?.string);
    try testing.expectEqualStrings("Why Zig Builds Are Fast", v.object.get("title").?.string);
    try testing.expect(v.object.get("citations").?.object.get("enabled").?.bool);
    const content = v.object.get("content").?.array.items;
    const bs = try f.lib.blocks(r.id.?, a);
    try testing.expectEqual(bs.len, content.len);
    for (content, bs) |c, b| {
        try testing.expectEqualStrings("text", c.object.get("type").?.string);
        try testing.expectEqualStrings(b.text, c.object.get("text").?.string);
    }
    try testing.expectEqual(@as(usize, 5), v.object.count());
}

test "web fetch events and source tools" {
    var f: Fx = undefined;
    try f.init(.ask);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Outside a research run, `ask` mode does not capture fetches.
    f.lib.onWebFetch(.{ .url = "https://docs.example.org/guide", .markdown = "# Guide\n\nRead me." });
    try testing.expectEqual(@as(usize, 0), f.lib.count());
    // In a research run it does, from the Markdown already made.
    f.lib.onWebFetch(.{ .url = "https://docs.example.org/guide", .markdown = "# Guide\n\nRead me.", .research = true });
    try testing.expectEqual(@as(usize, 1), f.lib.count());
    try testing.expectEqual(@as(u32, 0), f.web.fetches);
    // Other tools and failed fetches are ignored.
    f.lib.onWebFetch(.{ .tool = "mcp__web__fetch", .url = "https://x.example/", .markdown = "x", .research = true });
    f.lib.onWebFetch(.{ .url = "https://y.example/", .markdown = "y", .research = true, .is_error = true });
    try testing.expectEqual(@as(usize, 1), f.lib.count());

    var src: tools.Source = .{ .lib = f.lib };
    const cap = try tools.run(&src, a, "source_capture", "{\"url\":\"https://www.example.com/blog/zig?utm_source=feed\"}");
    try testing.expect(!cap.is_error);
    try testing.expect(cap.changeset != null);
    try testing.expect(std.mem.indexOf(u8, cap.text, "\"result\":\"pending_approval\"") != null);
    const found = try tools.run(&src, a, "source_search", "{\"query\":\"zig builds\"}");
    try testing.expect(std.mem.indexOf(u8, found.text, "Why Zig Builds Are Fast") != null);
    try testing.expect(std.mem.indexOf(u8, found.text, "Guide") == null);
    const id_at = std.mem.indexOf(u8, found.text, "\"id\":\"").? + 6;
    const id = found.text[id_at .. id_at + 32];
    const read = try tools.run(&src, a, "source_read", try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"blocks\":[1,1]}}", .{id}));
    try testing.expect(std.mem.indexOf(u8, read.text, "\"blocks\":[{\"index\":1,") != null);
    const bad = try tools.run(&src, a, "source_read", "{\"id\":\"nope\"}");
    try testing.expect(bad.is_error);
}

test "capture of a 200 KB page" {
    var f: Fx = undefined;
    try f.init(.always);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var html: std.ArrayList(u8) = .empty;
    try html.appendSlice(a, "<html><head><title>Big page</title></head><body><nav><a href=\"/\">Home</a></nav><article>");
    var i: usize = 0;
    while (html.items.len < 200 * 1024) : (i += 1) try html.print(a, "<p>Paragraph {d} with <a href=\"/l{d}\">a link</a> and <em>emphasis</em>, long enough to look like prose.</p>\n", .{ i, i });
    try html.appendSlice(a, "</article></body></html>");
    const t0 = std.Io.Timestamp.now(io, .awake);
    const r = try f.lib.capture("https://big.example/page", .{ .html = html.items });
    const ms = t0.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    try testing.expectEqual(sources.CaptureKind.captured, r.kind);
    if (builtin.mode != .Debug) try testing.expect(ms < 20);
}
