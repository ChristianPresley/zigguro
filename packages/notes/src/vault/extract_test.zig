//! Note extractor tests (E08.F06.S01.T01).

const std = @import("std");
const extract_mod = @import("extract.zig");
const note = @import("note.zig");
const vault = @import("vault.zig");

const testing = std.testing;
const cfg: vault.VaultConfig = .{};

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    meta: note.NoteMeta,

    fn init(bytes: []const u8, path: []const u8) !Fixture {
        var f: Fixture = .{ .arena = .init(testing.allocator), .meta = undefined };
        f.meta = try extract_mod.extract(f.arena.allocator(), bytes, path, &cfg);
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
    }

    fn tagList(f: *Fixture) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(f.arena.allocator());
        for (f.meta.tags, 0..) |t, i| {
            if (i > 0) try out.writer.writeByte(',');
            try out.writer.writeAll(t.display);
        }
        return out.written();
    }
};

test "extract: property typing table" {
    var f = try Fixture.init(
        \\---
        \\tags: a, b c
        \\aliases: [One, "Two"]
        \\cssclasses: wide
        \\done: true
        \\count: 3
        \\ratio: 0.5
        \\due: 2024-05-01
        \\at: 2024-05-01T10:00
        \\text: hello
        \\empty:
        \\nested: {a: 1}
        \\---
        \\body
    , "n.md");
    defer f.deinit();
    const want = [_]struct { []const u8, note.PropertyType }{
        .{ "tags", .tags },     .{ "aliases", .aliases }, .{ "cssclasses", .list },
        .{ "done", .checkbox }, .{ "count", .number },    .{ "ratio", .number },
        .{ "due", .date },      .{ "at", .datetime },     .{ "text", .text },
        .{ "empty", .unknown }, .{ "nested", .unknown },
    };
    for (want) |w| try testing.expectEqual(w[1], f.meta.prop(w[0]).?.ty);
    try testing.expectEqualStrings("a,b,c", try f.tagList());
    try testing.expect(f.meta.tags[0].in_frontmatter);
    try testing.expectEqual(@as(usize, 2), f.meta.aliases.len);
    try testing.expectEqualStrings("Two", f.meta.aliases[1]);
    // Conflicting types are per note; the registry settles them.
    var g = try Fixture.init("---\ncount: many\n---\n", "m.md");
    defer g.deinit();
    try testing.expectEqual(note.PropertyType.text, g.meta.prop("count").?.ty);
    // Block-list tags with `#`.
    var h = try Fixture.init("---\ntags:\n  - '#x'\n  - y/z\n---\n", "h.md");
    defer h.deinit();
    try testing.expectEqualStrings("x,y/z", try h.tagList());
}

test "extract: title precedence" {
    {
        var f = try Fixture.init("---\ntitle: From FM\n---\n# Heading\n", "dir/file.md");
        defer f.deinit();
        try testing.expectEqualStrings("From FM", f.meta.title);
    }
    {
        var f = try Fixture.init("intro\n\n## Two\n# The **Real** [[target|Title]]\n", "dir/file.md");
        defer f.deinit();
        try testing.expectEqualStrings("The Real Title", f.meta.title);
    }
    {
        var f = try Fixture.init("Setext *one*\n===\n", "x.md");
        defer f.deinit();
        try testing.expectEqualStrings("Setext one", f.meta.title);
    }
    {
        var f = try Fixture.init("no headings\n", "dir/My Note.md");
        defer f.deinit();
        try testing.expectEqualStrings("My Note", f.meta.title);
    }
    {
        var f = try Fixture.init("---\ntitle: 42\n---\n", "dir/n.md");
        defer f.deinit();
        try testing.expectEqualStrings("n", f.meta.title);
    }
}

test "extract: inline tags rules" {
    var f = try Fixture.init(
        \\#start and #mid-dle, (#paren) #a/b/c/ #Café
        \\not#tag &#38; ## #1984 #y1984 `#code` #emoji🚀
        \\https://x.org/#frag [link #in](http://y) [[Note#Heading]] \#escaped
        \\```
        \\#fenced
        \\```
        \\# Heading #inheading
        \\%% #comment %% <!-- #html --> $#math$ #last.
        \\    #indented-code-after-text-is-paragraph
        \\
        \\    #indented-code
    , "t.md");
    defer f.deinit();
    try testing.expectEqualStrings("start,mid-dle,paren,a/b/c,Caf\u{e9},y1984,emoji\u{1F680},inheading,last,indented-code-after-text-is-paragraph", try f.tagList());
    // Keys are folded, nesting kept.
    try testing.expectEqualStrings("caf\u{e9}", f.meta.tags[4].key);
    try testing.expect(f.meta.hasTag("a"));
    try testing.expect(f.meta.hasTag("a/b"));
    try testing.expect(!f.meta.hasTag("a/bc"));
    // The tag range covers `#tag`.
    const src = "x #t y";
    var g = try Fixture.init(src, "g.md");
    defer g.deinit();
    try testing.expectEqualStrings("#t", src[g.meta.tags[0].src[0]..g.meta.tags[0].src[1]]);
}

test "extract: wikilink subpaths and aliases; embeds; markdown .md links with %20" {
    const src =
        \\See [[Target]], [[folder/Note.md|shown]], [[A#H1#H2]], [[B#^blk|alias]] and [[#Local]].
        \\Embed ![[image.png]] and ![[Doc#Sec]].
        \\| [[Table\|alias]] |
        \\[md](other%20note.md) [rel](../up/x.md#Head%20ing) ![img](assets/p.png) [ext](https://e.com) [mail](mailto:a@b.c)
        \\[ang](<with space.md>) [none](noext) `[[code]]` [[unclosed
    ;
    var f = try Fixture.init(src, "l.md");
    defer f.deinit();
    const L = f.meta.links;
    try testing.expectEqual(@as(usize, 13), L.len);
    try testing.expectEqualStrings("Target", L[0].target);
    try testing.expectEqualStrings("[[Target]]", src[L[0].src[0]..L[0].src[1]]);
    try testing.expectEqualStrings("Target", src[L[0].target_src[0]..L[0].target_src[1]]);
    try testing.expectEqualStrings("folder/Note.md", L[1].target);
    try testing.expectEqualStrings("shown", L[1].alias.?);
    try testing.expectEqual(@as(usize, 2), L[2].subpath.?.heading.len);
    try testing.expectEqualStrings("H2", L[2].subpath.?.heading[1]);
    try testing.expectEqualStrings("blk", L[3].subpath.?.block);
    try testing.expectEqualStrings("alias", L[3].alias.?);
    try testing.expectEqualStrings("", L[4].target);
    try testing.expectEqualStrings("Local", L[4].subpath.?.heading[0]);
    try testing.expectEqual(note.LinkKind.embed, L[5].kind);
    try testing.expectEqualStrings("![[image.png]]", src[L[5].src[0]..L[5].src[1]]);
    try testing.expectEqualStrings("Sec", L[6].subpath.?.heading[0]);
    try testing.expectEqualStrings("Table", L[7].target);
    try testing.expectEqualStrings("alias", L[7].alias.?);
    try testing.expectEqual(note.LinkKind.markdown, L[8].kind);
    try testing.expectEqualStrings("other note.md", L[8].target);
    try testing.expect(L[8].encoded);
    try testing.expectEqualStrings("other%20note.md", src[L[8].target_src[0]..L[8].target_src[1]]);
    try testing.expectEqualStrings("../up/x.md", L[9].target);
    try testing.expectEqualStrings("Head ing", L[9].subpath.?.heading[0]);
    try testing.expectEqual(note.LinkKind.markdown_embed, L[10].kind);
    try testing.expectEqualStrings("with space.md", L[11].target);
    try testing.expect(L[11].angle);
    try testing.expectEqualStrings("noext", L[12].target);
    try testing.expectEqual(@as(usize, 2), f.meta.external_links.len);
    try testing.expectEqualStrings("https://e.com", f.meta.external_links[0]);
}

test "extract: headings, tasks and block ids placement rules" {
    const src =
        \\# Top ##
        \\Para line one
        \\continues here ^para-1
        \\
        \\- item one ^item
        \\- [ ] todo
        \\- [x] done thing
        \\  - [/] half
        \\1. [>] forwarded
        \\
        \\> quote line
        \\
        \\^quote
        \\
        \\| a | b |
        \\|---|---|
        \\
        \\^table
        \\## Sub
        \\text^notid
        \\Lazy
        \\^lazy
    ;
    var f = try Fixture.init(src, "b.md");
    defer f.deinit();
    const H = f.meta.headings;
    try testing.expectEqual(@as(usize, 2), H.len);
    try testing.expectEqualStrings("Top", H[0].text);
    try testing.expectEqual(@as(u8, 2), H[1].level);
    try testing.expectEqual(@as(u32, 18), H[1].line);
    const T = f.meta.tasks;
    try testing.expectEqual(@as(usize, 4), T.len);
    try testing.expectEqual(@as(u8, ' '), T[0].status);
    try testing.expect(T[1].done());
    try testing.expectEqualStrings("done thing", src[T[1].text[0]..T[1].text[1]]);
    try testing.expectEqual(@as(u8, '/'), T[2].status);
    try testing.expectEqual(@as(u8, '>'), T[3].status);
    const B = f.meta.blocks;
    try testing.expectEqual(@as(usize, 5), B.len);
    try testing.expectEqualStrings("para-1", B[0].id);
    try testing.expectEqualStrings("Para line one\ncontinues here ^para-1", src[B[0].range[0]..B[0].range[1]]);
    try testing.expectEqualStrings("item", B[1].id);
    try testing.expectEqualStrings("- item one ^item", src[B[1].range[0]..B[1].range[1]]);
    try testing.expectEqualStrings("quote", B[2].id);
    try testing.expectEqualStrings("> quote line", src[B[2].range[0]..B[2].range[1]]);
    try testing.expectEqualStrings("table", B[3].id);
    try testing.expectEqualStrings("| a | b |\n|---|---|", src[B[3].range[0]..B[3].range[1]]);
    try testing.expectEqualStrings("lazy", B[4].id);
    try testing.expectEqualStrings("text^notid\nLazy", src[B[4].range[0]..B[4].range[1]]);
}

test "extract: never fails on malformed frontmatter" {
    const broken = [_][]const u8{
        "---\n: x\n---\n#ok",         "---\na: [1\n---\n#ok",   "---\na: \"x\n---\n#ok",          "---\n  bad\nb: 1\n---\n#ok",
        "---\na: &x 1\n---\n#ok",     "---\n- item\n---\n#ok",  "---\na: |\n---\n#ok",            "---\na:\n  - x: 1\n---\n#ok",
        "---\n? x\n---\n#ok",         "---\na: !t\n---\n#ok",   "---\n{a\n---\n#ok",              "---\na: b: c\n---\n#ok",
        "---\na: {x: [1}\n---\n#ok",  "---\n\t\ta\n---\n#ok",   "---\n\"a\n---\n#ok",             "---\na: \"\\q\"\n---\n#ok",
        "---\ntags: [[x]]\n---\n#ok", "---\ntags: 5\n---\n#ok", "---\naliases: {a: 1}\n---\n#ok", "---\n:::\n---\n#ok",
    };
    for (broken) |b| {
        var f = try Fixture.init(b, "x.md");
        defer f.deinit();
        try testing.expect(f.meta.hasTag("ok"));
        try testing.expect(f.meta.fm_range != null);
    }
}

test "extract: word count and line numbers" {
    var f = try Fixture.init("---\na: 1\n---\none two\n\n```\nnot counted here\n```\nthree [[x]]\n", "w.md");
    defer f.deinit();
    try testing.expectEqual(@as(u32, 4), f.meta.word_count);
    try testing.expectEqual(@as(u32, 8), f.meta.links[0].line);
}
