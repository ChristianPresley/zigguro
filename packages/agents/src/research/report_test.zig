//! The report note: Markdown golden, block references and link checks.

const std = @import("std");
const zg_ai_proto = @import("zg_ai_proto");
const citations = @import("citations.zig");
const report = @import("report.zig");
const blocks = @import("blocks.zig");
const sources = @import("sources.zig");
const verify = @import("verify.zig");
const fixture = @import("test_fixture.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn answer() zg_ai_proto.Message {
    const S = struct {
        const content = [_]zg_ai_proto.ContentBlock{
            .{ .text = .{ .text = "Zig keeps builds fast.\n\n## Caching\n\n" } },
            .{ .text = .{ .text = "Zig caches build steps by content hash.", .citations_json =
            \\[{"type":"search_result_location","source":"https://alpha.example/zig-build","title":"Zig build cache","cited_text":"The Zig build system caches every step by content hash.","search_result_index":0,"start_block_index":1,"end_block_index":1}]
            } },
            .{ .text = .{ .text = " " } },
            .{ .text = .{ .text = "Incremental compilation is stable.", .citations_json =
            \\[{"type":"search_result_location","source":"https://alpha.example/zig-build","title":"Zig build cache","cited_text":"Incremental compilation is still experimental in Zig 0.16.","search_result_index":0,"start_block_index":2,"end_block_index":2}]
            } },
            .{ .text = .{ .text = "\n\n## I/O\n\n" } },
            .{ .text = .{ .text = "I/O goes through std.Io.", .citations_json =
            \\[{"type":"search_result_location","source":"https://beta.example/release","title":"Release notes","cited_text":"","search_result_index":1,"start_block_index":1,"end_block_index":2},{"type":"search_result_location","source":"https://alpha.example/zig-build","title":"Zig build cache","cited_text":"zig build --summary all","search_result_index":0,"start_block_index":5,"end_block_index":5}]
            } },
            .{ .text = .{ .text = " " } },
            .{ .text = .{ .text = "Builds are content addressed.", .citations_json =
            \\[{"type":"search_result_location","source":"https://alpha.example/zig-build","title":"Zig build cache","cited_text":"The Zig build system caches every step by content hash.","search_result_index":0,"start_block_index":1,"end_block_index":1}]
            } },
            .{ .text = .{ .text = "\n" } },
        };
    };
    return .{ .role = .assistant, .content = &S.content };
}

const golden =
    \\---
    \\type: research-report
    \\question: "How does Zig 0.16 keep \"builds\" fast?"
    \\created: 2026-10-23
    \\run: run_7
    \\sources:
    \\  - "[[sources/alpha.example/zig-build-cache]]"
    \\  - "[[sources/beta.example/release-notes]]"
    \\---
    \\
    \\# Zig build speed
    \\
    \\Zig keeps builds fast.
    \\
    \\## Caching
    \\
    \\Zig caches build steps by content hash.[^1] Incremental compilation is stable.[^2] ⚠ unsupported
    \\
    \\## I/O
    \\
    \\I/O goes through std.Io.[^3][^4] Builds are content addressed.[^1]
    \\
    \\[^1]: [[sources/alpha.example/zig-build-cache#^b1]] — "The Zig build system caches every step by content hash."
    \\[^2]: [[sources/alpha.example/zig-build-cache#^b2]] — "Incremental compilation is still experimental in Zig 0.16." (unsupported)
    \\[^3]: [[sources/beta.example/release-notes#^b1]] — "Zig 0.16 moved I/O behind the std.Io interface. The new interface supports async and threaded backends." (unverifiable)
    \\[^4]: [[sources/alpha.example/zig-build-cache#^b5]] — "zig build --summary all" (unverifiable)
    \\
    \\## Verification
    \\
    \\4 cited claims: 2 supported, 0 partially supported, 1 unsupported, 1 unverifiable.
    \\
    \\Unsupported:
    \\
    \\- "Incremental compilation is stable.": The passage says it is still experimental.
    \\
    \\Not verified:
    \\
    \\- "I/O goes through std.Io.": verification timed out
    \\
;

const Built = struct { r: report.Report, md: []const u8 };

fn buildReport(f: *fixture.Fx, a: std.mem.Allocator, vs: []const verify.Verdict) !Built {
    const msg = answer();
    const claims = try citations.fromProviderCitations(a, &msg, f.lib, &.{ f.alpha, f.beta });
    const r = try report.build(a, "Zig build speed", "How does Zig 0.16 keep \"builds\" fast?", try citations.messageText(a, &msg), claims);
    _ = try report.ensureBlockRefs(f.lib, a, claims);
    var out: std.Io.Writer.Allocating = .init(a);
    try report.writeReportMarkdown(&out.writer, &r, f.lib, .{ .created = "2026-10-23", .run = "run_7", .verdicts = vs });
    return .{ .r = r, .md = out.written() };
}

const verdicts = [_]verify.Verdict{
    .{ .claim = 1, .kind = .supported, .reason = "Stated directly." },
    .{ .claim = 2, .kind = .unsupported, .reason = "The passage says it is still experimental." },
    .{ .claim = 3, .kind = .unverifiable, .reason = "verification timed out" },
    .{ .claim = 4, .kind = .supported },
};

test "report_markdown_golden" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const b = try buildReport(&f, arena.allocator(), &verdicts);
    try testing.expectEqual(@as(usize, 3), b.r.sections.len);
    try testing.expectEqual(@as(usize, 2), b.r.sources.len);
    if (!std.mem.eql(u8, golden, b.md)) {
        std.debug.print("=====BEGIN report=====\n{s}=====END=====\n", .{b.md});
        return error.TestUnexpectedResult;
    }
}

test "block_ref_ids_added_once" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const writes_before = f.notes.writes.items.len;
    const msg = answer();
    const claims = try citations.fromProviderCitations(a, &msg, f.lib, &.{ f.alpha, f.beta });
    try testing.expectEqual(@as(u32, 2), try report.ensureBlockRefs(f.lib, a, claims));
    try testing.expectEqual(writes_before + 2, f.notes.writes.items.len);
    // A second report citing the same passages writes nothing.
    try testing.expectEqual(@as(u32, 0), try report.ensureBlockRefs(f.lib, a, claims));
    try testing.expectEqual(writes_before + 2, f.notes.writes.items.len);

    const note = try f.read(a, f.lib.get(f.alpha).?.path);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, note, "^b1"));
    try testing.expect(std.mem.indexOf(u8, note, "Unchanged steps are skipped. ^b1\n") != null);
    try testing.expect(std.mem.indexOf(u8, note, "```\n^b5\n") != null);
    // The references don't change the blocks.
    const bs = try blocks.split(a, sources.body(note));
    const plain = try blocks.split(a, fixture.alpha_md);
    try testing.expectEqual(plain.len, bs.len);
    for (plain, bs) |x, y| try testing.expectEqualStrings(x.text, y.text);
    // Nor what the library reports for the source.
    const lib_bs = try f.lib.blocks(f.alpha, a);
    try testing.expectEqualStrings(plain[1].text, lib_bs[1].text);
}

test "every footnote resolves to a source note block" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try buildReport(&f, a, &.{});
    var checked: usize = 0;
    var lines = std.mem.splitScalar(u8, b.md, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "[^")) continue;
        const open = std.mem.indexOf(u8, line, "[[").?;
        const close = std.mem.indexOfPos(u8, line, open, "]]").?;
        const target = line[open + 2 .. close];
        const hash = std.mem.indexOf(u8, target, "#^b").?;
        const path = try std.fmt.allocPrint(a, "{s}.md", .{target[0..hash]});
        const n = try std.fmt.parseInt(u32, target[hash + 3 ..], 10);
        const note = try f.read(a, path);
        var found = false;
        for (try blocks.split(a, sources.body(note))) |bk| found = found or bk.ref == n;
        if (!found) {
            std.debug.print("unresolved {s}\n", .{target});
            return error.TestUnexpectedResult;
        }
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 4), checked);
    // Without verdicts there is no verification section or badge.
    try testing.expect(std.mem.indexOf(u8, b.md, "## Verification") == null);
    try testing.expect(std.mem.indexOf(u8, b.md, "⚠") == null);
}

test "unverifiable is never shown as unsupported" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const all_unverifiable = [_]verify.Verdict{
        .{ .claim = 1, .kind = .unverifiable, .reason = "verification request failed" },
        .{ .claim = 2, .kind = .unverifiable },
        .{ .claim = 3, .kind = .unverifiable },
        .{ .claim = 4, .kind = .unverifiable },
    };
    const b = try buildReport(&f, arena.allocator(), &all_unverifiable);
    try testing.expect(std.mem.indexOf(u8, b.md, "⚠") == null);
    try testing.expect(std.mem.indexOf(u8, b.md, "(unsupported)") == null);
    try testing.expect(std.mem.indexOf(u8, b.md, "Unsupported:") == null);
    try testing.expect(std.mem.indexOf(u8, b.md, "0 unsupported, 4 unverifiable") != null);
}
