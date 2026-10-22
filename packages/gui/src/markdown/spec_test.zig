//! Conformance (E04.F06.S01.T03): every example of the CommonMark 0.31.2
//! spec, and the GFM 0.29 extension examples (tables, task lists,
//! strikethrough, extended autolinks), parsed and rendered as HTML must
//! match the spec's output exactly.

const std = @import("std");
const ast = @import("ast.zig");
const stream = @import("stream.zig");
const serializer = @import("html_test_serializer.zig");

const testing = std.testing;
const gpa = testing.allocator;

const fence = "````````````````````````````````";

const Example = struct {
    line: usize,
    tag: []const u8,
    markdown: []u8,
    html: []u8,
};

fn readSpec(name: []const u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/testdata/markdown/{s}", .{ @import("zg_options").package_root, name });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
}

/// Replaces `→` with a tab, as the spec's examples write tabs.
fn tabs(arena: std.mem.Allocator, s: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, arena, s, "\u{2192}", "\t");
}

fn examples(arena: std.mem.Allocator, spec: []const u8) ![]Example {
    var out: std.ArrayList(Example) = .empty;
    var lines = std.mem.splitScalar(u8, spec, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (!std.mem.startsWith(u8, line, fence ++ " example")) continue;
        const tag = std.mem.trim(u8, line[fence.len + " example".len ..], " ");
        const start = line_no;
        var md: std.ArrayList(u8) = .empty;
        var html: std.ArrayList(u8) = .empty;
        var in_html = false;
        while (lines.next()) |l| {
            line_no += 1;
            if (std.mem.eql(u8, l, fence)) break;
            if (!in_html and std.mem.eql(u8, l, ".")) {
                in_html = true;
                continue;
            }
            const target = if (in_html) &html else &md;
            try target.appendSlice(arena, l);
            try target.append(arena, '\n');
        }
        try out.append(arena, .{
            .line = start,
            .tag = tag,
            .markdown = try tabs(arena, md.items),
            .html = try tabs(arena, html.items),
        });
    }
    return out.items;
}

const commonmark: ast.Options = .{
    .gfm = false,
    .wikilinks = false,
    .callouts = false,
    .front_matter = false,
    .math = false,
};

fn runExamples(file: []const u8, opts: ast.Options, only_tagged: bool) !void {
    const spec = try readSpec(file);
    defer gpa.free(spec);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const all = try examples(arena_state.allocator(), spec);
    var total: usize = 0;
    var failed: usize = 0;
    for (all) |ex| {
        const tagged = ex.tag.len > 0;
        if (tagged != only_tagged) continue;
        if (std.mem.eql(u8, ex.tag, "tagfilter")) continue; // zigguro never renders raw HTML.
        total += 1;
        var d = try stream.parse(gpa, ex.markdown, opts);
        defer d.deinit();
        const got = try serializer.render(gpa, &d);
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, ex.html)) {
            failed += 1;
            if (failed <= 40) std.debug.print("\n--- {s}:{d} {s}\n{s}--- expected\n{s}--- got\n{s}", .{ file, ex.line, ex.tag, ex.markdown, ex.html, got });
        }
    }
    if (failed > 0) {
        std.debug.print("\n{s}: {d} of {d} examples failed\n", .{ file, failed, total });
        return error.SpecExamplesFailed;
    }
    try testing.expect(total > 0);
}

test "CommonMark 0.31.2 spec examples" {
    try runExamples("spec-0.31.2.txt", commonmark, false);
}

test "GFM extension examples" {
    var opts = commonmark;
    opts.gfm = true;
    try runExamples("spec-gfm.txt", opts, true);
}
