//! Citations: API citation blocks, web search citations, fallback markers
//! and the synthesis request's citation flag.

const std = @import("std");
const zg_ai_proto = @import("zg_ai_proto");
const citations = @import("citations.zig");
const blocks = @import("blocks.zig");
const fixture = @import("test_fixture.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// A synthesis answer in the documented shape: text blocks, some with
/// `search_result_location` citations (search result 0 = alpha, 1 = beta).
fn answer() zg_ai_proto.Message {
    const S = struct {
        const content = [_]zg_ai_proto.ContentBlock{
            .{ .text = .{ .text = "## Caching\n\n" } },
            .{ .text = .{ .text = "Zig caches build steps by content hash", .citations_json =
            \\[{"type":"search_result_location","source":"https://alpha.example/zig-build","title":"Zig build cache","cited_text":"The Zig build system caches every step by content hash. Unchanged steps are skipped.","search_result_index":0,"start_block_index":1,"end_block_index":1}]
            } },
            .{ .text = .{ .text = " and skips unchanged ones.", .citations_json =
            \\[{"type":"search_result_location","source":"https://alpha.example/zig-build","title":"Zig build cache","cited_text":"Unchanged steps are skipped.","search_result_index":0,"start_block_index":1,"end_block_index":1}]
            } },
            .{ .text = .{ .text = "\n\n## I/O\n\n" } },
            .{ .text = .{ .text = "I/O now goes through std.Io, with async and threaded backends.", .citations_json =
            \\[{"type":"search_result_location","source":"https://beta.example/release","title":"Release notes","cited_text":"Zig 0.16 moved I/O behind the std.Io interface.","search_result_index":1,"start_block_index":1,"end_block_index":2},{"type":"char_location","document_index":0,"cited_text":"x","start_char_index":0,"end_char_index":1}]
            } },
            .{ .text = .{ .text = " A stray index is ignored.", .citations_json =
            \\[{"type":"search_result_location","source":"x","title":"x","cited_text":"x","search_result_index":7,"start_block_index":0,"end_block_index":0}]
            } },
            .{ .text = .{ .text = "\n" } },
        };
    };
    return .{ .role = .assistant, .content = &S.content };
}

test "map_search_result_location" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = answer();
    try testing.expect(citations.hasNativeCitations(&msg));
    const claims = try citations.fromProviderCitations(a, &msg, f.lib, &.{ f.alpha, f.beta });
    const text = try citations.messageText(a, &msg);
    try testing.expectEqual(@as(usize, 2), claims.len);

    // The two blocks citing the same passage merge into one claim.
    try testing.expectEqualStrings("Zig caches build steps by content hash and skips unchanged ones.", claims[0].text);
    try testing.expectEqualStrings(claims[0].text, text[claims[0].range.start..claims[0].range.end]);
    try testing.expectEqual(@as(usize, 1), claims[0].citations.len);
    try testing.expectEqualSlices(u8, &f.alpha, &claims[0].citations[0].source);
    try testing.expectEqual(@as(u32, 1), claims[0].citations[0].start_block);
    try testing.expectEqual(@as(u32, 1), claims[0].citations[0].end_block);

    // Document citations are dropped; the block range is inclusive.
    try testing.expectEqual(@as(u32, 2), claims[1].id);
    try testing.expectEqual(@as(usize, 1), claims[1].citations.len);
    try testing.expectEqualSlices(u8, &f.beta, &claims[1].citations[0].source);
    try testing.expectEqual(@as(u32, 1), claims[1].citations[0].start_block);
    try testing.expectEqual(@as(u32, 2), claims[1].citations[0].end_block);
    try testing.expectEqualStrings("Zig 0.16 moved I/O behind the std.Io interface.", claims[1].citations[0].cited_text);
}

test "map_web_search_location_by_url" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\[{"type":"web_search_result_location","url":"http://www.beta.example/release?utm_source=x","title":"Release notes","encrypted_index":"Eo8B","cited_text":"The new interface supports async and\n threaded backends."},
        \\ {"type":"web_search_result_location","url":"https://alpha.example/zig-build","title":"Zig build cache","encrypted_index":"Eo8C","cited_text":"Incremental compilation is still experimental in Zig 0.16. - The cache lives in .zig-cache"},
        \\ {"type":"web_search_result_location","url":"https://beta.example/release","title":"Release notes","encrypted_index":"Eo8D","cited_text":"Not in the page at all."},
        \\ {"type":"web_search_result_location","url":"https://gamma.example/news","title":"Gamma","encrypted_index":"Eo8E","cited_text":"The 0.16 release shipped in October."},
        \\ {"type":"web_search_result_location","url":"https://unknown.example/","title":"?","encrypted_index":"Eo8F","cited_text":"anything"}]
    ;
    const before = f.lib.count();
    const cs = try citations.parseCitations(a, json, f.lib, &.{});
    try testing.expectEqual(@as(usize, 4), cs.len);
    // Found by dedupe key, located by whitespace-folded text.
    try testing.expectEqualSlices(u8, &f.beta, &cs[0].source);
    try testing.expectEqual(@as(u32, 2), cs[0].start_block);
    try testing.expect(cs[0].located);
    // A quote spanning blocks.
    try testing.expectEqual(@as(u32, 2), cs[1].start_block);
    try testing.expectEqual(@as(u32, 3), cs[1].end_block);
    // Text not found: the source is kept, unlocated.
    try testing.expect(!cs[2].located);
    try testing.expectEqual(@as(u32, 0), cs[2].start_block);
    // An unknown URL is captured through the fetch port; a page that
    // can't be fetched drops the citation.
    try testing.expectEqual(before + 1, f.lib.count());
    try testing.expectEqual(@as(u32, 2), f.web.fetches);
    const gamma = f.lib.get(cs[3].source).?;
    try testing.expectEqualStrings("Gamma news", gamma.title);
    try testing.expectEqual(@as(u32, 1), cs[3].start_block);
}

test "fallback_marker_parsing" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try std.fmt.allocPrint(a,
        \\## Findings
        \\
        \\Zig caches steps by hash. [[src:{s}#b1-1]] Builds skip work.
        \\I/O moved to std.Io [[src:{s}#b1]] [[src:{s}#b2-2]].
        \\Ghost claim [[src:ffffffffffffffffffffffffffffffff#b1]] stays plain.
        \\Broken [[src:nope]] marker.
        \\
    , .{ &f.alpha, &f.beta, &f.alpha });
    const p = try citations.parseMarkers(a, text, f.lib);
    try testing.expectEqualStrings(
        \\## Findings
        \\
        \\Zig caches steps by hash. Builds skip work.
        \\I/O moved to std.Io.
        \\Ghost claim stays plain.
        \\Broken [[src:nope]] marker.
        \\
    , p.text);
    try testing.expectEqual(@as(usize, 2), p.claims.len);
    try testing.expectEqualStrings("Zig caches steps by hash.", p.claims[0].text);
    try testing.expectEqual(@as(u32, 1), p.claims[0].citations[0].start_block);
    try testing.expectEqualStrings("I/O moved to std.Io", p.claims[1].text);
    try testing.expectEqual(@as(usize, 2), p.claims[1].citations.len);
    try testing.expectEqualSlices(u8, &f.beta, &p.claims[1].citations[0].source);
    try testing.expectEqual(@as(u32, 1), p.claims[1].citations[0].end_block);
    try testing.expectEqualSlices(u8, &f.alpha, &p.claims[1].citations[1].source);
    for (p.claims) |c| try testing.expectEqualStrings(c.text, p.text[c.range.start..c.range.end]);
    try testing.expect(std.mem.indexOf(u8, citations.marker_instructions, "[[src:<id>#b<start>-<end>]]") != null);
}

test "all_or_none_citations_flag" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ids = [_][32]u8{ f.alpha, f.beta };
    for ([_]bool{ true, false }) |on| {
        const s = try citations.synthesisContent(a, f.lib, &ids, "How does Zig cache builds?", on);
        try testing.expectEqual(@as(usize, 3), s.content.len);
        try testing.expectEqual(@as(usize, 2), s.order.len);
        const want = if (on) "\"citations\":{\"enabled\":true}" else "\"citations\":{\"enabled\":false}";
        for (s.content[0..2]) |b| try testing.expect(std.mem.indexOf(u8, b.provider_opaque.raw_json, want) != null);
        try testing.expectEqualStrings("How does Zig cache builds?", s.content[2].text.text);
        const msgs = [_]zg_ai_proto.Message{.{ .role = .user, .content = s.content }};
        try testing.expect(citations.citationsUniform(a, &msgs));
    }
    const on = try citations.synthesisContent(a, f.lib, &ids, "q", true);
    const off = try citations.synthesisContent(a, f.lib, &ids, "q", false);
    const mixed = [_]zg_ai_proto.Message{ .{ .role = .user, .content = on.content }, .{ .role = .user, .content = off.content } };
    try testing.expect(!citations.citationsUniform(a, &mixed));
}

test "blocks keep indices when references are added" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try blocks.split(a, fixture.alpha_md);
    const with_refs =
        \\# Zig build cache
        \\
        \\The Zig build system caches every step by content hash. Unchanged steps are skipped. ^b1
        \\
        \\Incremental compilation is still experimental in Zig 0.16.
        \\
        \\- The cache lives in .zig-cache ^b3
        \\- The global cache lives in ~/.cache/zig
        \\
        \\```sh
        \\zig build --summary all
        \\```
        \\^b5
        \\
    ;
    const refd = try blocks.split(a, with_refs);
    try testing.expectEqual(plain.len, refd.len);
    for (plain, refd) |x, y| try testing.expectEqualStrings(x.text, y.text);
    try testing.expectEqual(@as(?u32, 1), refd[1].ref);
    try testing.expectEqual(@as(?u32, null), refd[2].ref);
    try testing.expectEqual(@as(?u32, 3), refd[3].ref);
    try testing.expectEqual(@as(?u32, 5), refd[5].ref);
    try testing.expect(refd[5].fence);
    try testing.expect(blocks.trailingRef("costs 5^b2") == null);
    try testing.expectEqual(@as(u32, 12), blocks.trailingRef("text ^b12").?.n);
}
