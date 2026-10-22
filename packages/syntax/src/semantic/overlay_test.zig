//! SemanticOverlay: decoding, deltas, late results and merging with
//! lexical tokens.

const std = @import("std");
const legend_mod = @import("legend.zig");
const overlay = @import("overlay.zig");
const names_mod = @import("../highlight_names.zig");
const highlighter = @import("../highlight/highlighter.zig");
const Token = @import("../lex/scanner.zig").Token;

const gpa = std.testing.allocator;
const HighlightId = names_mod.HighlightId;
const HighlightNames = names_mod.HighlightNames;
const LineSource = highlighter.LineSource;
const SemanticOverlay = overlay.SemanticOverlay;
const SemToken = overlay.SemToken;

/// The spec example's legend and highlight names.
const Fixture = struct {
    names: HighlightNames,
    legend: legend_mod.CompiledLegend,

    fn init(f: *Fixture) !void {
        f.names = .init(gpa);
        f.legend = try (legend_mod.Legend{
            .types = &.{ "property", "type", "class" },
            .modifiers = &.{ "private", "static" },
        }).compile(gpa, &f.names);
    }

    fn deinit(f: *Fixture) void {
        f.legend.deinit();
        f.names.deinit();
    }

    fn name(f: *Fixture, id: HighlightId) []const u8 {
        return f.names.name(id);
    }
};

fn expectToks(f: *Fixture, o: *const SemanticOverlay, line: u64, want: []const struct { u32, u32, []const u8 }) !void {
    const got = o.lineTokens(line);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try std.testing.expectEqual(w[0], g.start);
        try std.testing.expectEqual(w[1], g.end);
        try std.testing.expectEqualStrings(w[2], f.name(g.hl));
    }
}

const spec_lines = [_][]const u8{ "", "", "{ const someProperty: string", "", "", "  int Cls x" };
const spec_data = [_]u32{ 2, 5, 3, 0, 3, 0, 5, 4, 1, 0, 3, 2, 7, 2, 0 };

test "semantic: decode spec example" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lines: []const []const u8 = &spec_lines;
    var o: SemanticOverlay = try .init(gpa, lines.len, 1);
    defer o.deinit();
    try std.testing.expect(try o.applyFull(1, "r1", &spec_data, &f.legend, .fromSlice(&lines)));
    try expectToks(&f, &o, 2, &.{ .{ 5, 8, "property.static" }, .{ 10, 14, "type" } });
    try expectToks(&f, &o, 5, &.{.{ 2, 9, "type.class" }});
    try std.testing.expectEqual(@as(usize, 0), o.lineTokens(3).len);
    try std.testing.expectEqualStrings("r1", o.lastResultId().?);
}

test "semantic: utf16 columns with surrogate pairs" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // "😀" is 2 UTF-16 units and 4 bytes; "é" is 1 unit and 2 bytes.
    const lines: []const []const u8 = &.{"😀é ab cd"};
    var o: SemanticOverlay = try .init(gpa, 1, 1);
    defer o.deinit();
    // "ab" at units 4..6, "cd" at 7..9.
    _ = try o.applyFull(1, null, &.{ 0, 4, 2, 1, 0, 0, 3, 2, 0, 0 }, &f.legend, .fromSlice(&lines));
    try expectToks(&f, &o, 0, &.{ .{ 7, 9, "type" }, .{ 10, 12, "property" } });
    o.enc = .utf32;
    _ = try o.applyFull(1, null, &.{ 0, 3, 2, 1, 0 }, &f.legend, .fromSlice(&lines));
    try expectToks(&f, &o, 0, &.{.{ 7, 9, "type" }});
    o.enc = .utf8;
    // A length past the line end clamps.
    _ = try o.applyFull(1, null, &.{ 0, 10, 99, 1, 0 }, &f.legend, .fromSlice(&lines));
    try expectToks(&f, &o, 0, &.{.{ 10, 12, "type" }});
}

test "semantic: delta equals full" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lines: []const []const u8 = &spec_lines;
    var a: SemanticOverlay = try .init(gpa, lines.len, 1);
    defer a.deinit();
    _ = try a.applyFull(1, "r1", &spec_data, &f.legend, .fromSlice(&lines));
    // Drop the middle token and retype the last one, as two edits.
    const edits = [_]overlay.DeltaEdit{
        .{ .start = 14, .delete_count = 1, .data = &.{1} },
        .{ .start = 5, .delete_count = 5, .data = &.{} },
    };
    try std.testing.expect(try a.applyDelta(1, "r2", &edits, &f.legend, .fromSlice(&lines)));
    var b: SemanticOverlay = try .init(gpa, lines.len, 1);
    defer b.deinit();
    const after = [_]u32{ 2, 5, 3, 0, 3, 3, 2, 7, 2, 1 };
    _ = try b.applyFull(1, "r2", &after, &f.legend, .fromSlice(&lines));
    try std.testing.expectEqualSlices(u32, &after, a.raw.items);
    for (0..lines.len) |l| try std.testing.expectEqualSlices(SemToken, b.lineTokens(l), a.lineTokens(l));
    try expectToks(&f, &a, 5, &.{.{ 2, 9, "type.class.private" }});
    // An edit outside the previous array fails and drops the result id.
    try std.testing.expect(!try a.applyDelta(1, "r3", &.{.{ .start = 99, .delete_count = 1, .data = &.{} }}, &f.legend, .fromSlice(&lines)));
    try std.testing.expectEqual(@as(?[]const u8, null), a.lastResultId());
    try std.testing.expect(!try a.applyDelta(1, "r3", &.{}, &f.legend, .fromSlice(&lines)));
}

test "semantic: stale version mapped through changes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var o: SemanticOverlay = try .init(gpa, 6, 1);
    defer o.deinit();
    // Version 2 inserts two lines before line 1; version 3 edits line 0.
    try o.onEdits(&.{.{ .first = 1, .removed = 0, .inserted = 2 }}, 2);
    try o.onEdits(&.{.{ .first = 0, .removed = 1, .inserted = 1 }}, 3);
    const lines: []const []const u8 = &.{ "x", "new", "new", "", "{ const someProperty: string", "", "", "  int Cls x" };
    // The result for version 1 lands on the shifted lines.
    try std.testing.expect(try o.applyFull(1, "r1", &spec_data, &f.legend, .fromSlice(&lines)));
    try expectToks(&f, &o, 4, &.{ .{ 5, 8, "property.static" }, .{ 10, 14, "type" } });
    try expectToks(&f, &o, 7, &.{.{ 2, 9, "type.class" }});
    // Results from the future, or older than the log, are refused.
    try std.testing.expect(!try o.applyFull(4, null, &spec_data, &f.legend, .fromSlice(&lines)));
    for (0..overlay.max_log + 1) |k| try o.onEdits(&.{}, 4 + k);
    try std.testing.expect(!try o.applyFull(3, null, &.{}, &f.legend, .fromSlice(&lines)));
}

test "semantic: edited line falls back to lexical, others keep semantic" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const lines: []const []const u8 = &spec_lines;
    var o: SemanticOverlay = try .init(gpa, lines.len, 1);
    defer o.deinit();
    _ = try o.applyFull(1, null, &spec_data, &f.legend, .fromSlice(&lines));
    try o.onEdits(&.{.{ .first = 2, .removed = 1, .inserted = 1 }}, 2);
    try std.testing.expectEqual(@as(usize, 0), o.lineTokens(2).len);
    try std.testing.expect(o.isStale(2, 1));
    try std.testing.expectEqual(@as(usize, 1), o.lineTokens(5).len);
    // A late result for version 1 leaves the edited line alone.
    _ = try o.applyFull(1, null, &spec_data, &f.legend, .fromSlice(&lines));
    try std.testing.expectEqual(@as(usize, 0), o.lineTokens(2).len);
    // A range result for the current version fills it in.
    _ = try o.applyRange(2, 2, 3, &.{ 2, 0, 1, 1, 0 }, &f.legend, .fromSlice(&lines));
    try expectToks(&f, &o, 2, &.{.{ 0, 1, "type" }});
    try expectToks(&f, &o, 5, &.{.{ 2, 9, "type.class" }});
    // Merging an edited line yields its lexical tokens unchanged.
    var out: std.ArrayList(Token) = .empty;
    defer out.deinit(gpa);
    const lex = [_]Token{.{ .start = 0, .kind = 1, .hl = .keyword }};
    try o.mergeLine(3, &lex, 4, &out, gpa);
    try std.testing.expectEqualSlices(Token, &lex, out.items);
}

test "semantic: merge precedence keeps string escapes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // `x = "a\n" + y;` with semantic tokens over x, the string and y.
    const lines: []const []const u8 = &.{"x = \"a\\n\" + y;"};
    var o: SemanticOverlay = try .init(gpa, 1, 1);
    defer o.deinit();
    _ = try o.applyFull(1, null, &.{ 0, 0, 1, 0, 2, 0, 4, 5, 1, 0, 0, 8, 1, 0, 0 }, &f.legend, .fromSlice(&lines));
    const lex = [_]Token{
        .{ .start = 0, .kind = 1, .hl = .variable },
        .{ .start = 1, .kind = 2, .hl = .none },
        .{ .start = 2, .kind = 3, .hl = .operator },
        .{ .start = 3, .kind = 2, .hl = .none },
        .{ .start = 4, .kind = 4, .hl = .string },
        .{ .start = 6, .kind = 5, .hl = .string_escape },
        .{ .start = 8, .kind = 4, .hl = .string },
        .{ .start = 9, .kind = 2, .hl = .none },
        .{ .start = 10, .kind = 3, .hl = .operator },
        .{ .start = 11, .kind = 2, .hl = .none },
        .{ .start = 12, .kind = 1, .hl = .variable },
        .{ .start = 13, .kind = 6 | Token.atomic_bit, .hl = .punctuation },
    };
    var out: std.ArrayList(Token) = .empty;
    defer out.deinit(gpa);
    try o.mergeLine(0, &lex, 14, &out, gpa);
    try std.testing.expectEqualStrings("property.static", f.name(out.items[0].hl));
    // The string and its escape stay lexical; the `+` operator stays too.
    for (out.items) |t| switch (t.start) {
        4, 8 => try std.testing.expectEqual(HighlightId.string, t.hl),
        6 => try std.testing.expectEqual(HighlightId.string_escape, t.hl),
        10 => try std.testing.expectEqual(HighlightId.operator, t.hl),
        12 => try std.testing.expectEqual(HighlightId.property, t.hl),
        else => {},
    };
    // Every lexical boundary survives and the line stays covered.
    for (lex) |l| {
        const found = for (out.items) |t| {
            if (t.start == l.start) break true;
        } else false;
        try std.testing.expect(found or l.start == 1 or l.start == 3 or l.start == 9 or l.start == 11);
    }
    try std.testing.expectEqual(@as(u32, 0), out.items[0].start);
    for (out.items[1..], out.items[0 .. out.items.len - 1]) |b, a| try std.testing.expect(b.start > a.start);
}

test "semantic: apply and edit without leaks" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var prng: std.Random.DefaultPrng = .init(494);
    const r = prng.random();
    var store: std.ArrayList([]const u8) = .empty;
    defer store.deinit(gpa);
    for (0..40) |_| try store.append(gpa, "  some text here  ");
    var o: SemanticOverlay = try .init(gpa, store.items.len, 0);
    defer o.deinit();
    var data: std.ArrayList(u32) = .empty;
    defer data.deinit(gpa);
    var version: u64 = 0;
    for (0..10_000) |_| {
        if (r.boolean()) {
            const first = r.uintLessThan(u64, store.items.len);
            const removed = @min(store.items.len - first, r.uintLessThan(u64, 3));
            const inserted = r.uintLessThan(u64, 3);
            if (store.items.len - removed + inserted == 0) continue;
            store.replaceRange(gpa, @intCast(first), @intCast(removed), &[_][]const u8{"edited line"} ** 2) catch unreachable;
            for (0..2 - inserted) |_| _ = store.orderedRemove(@intCast(first));
            version += 1;
            try o.onEdits(&.{.{ .first = first, .removed = removed, .inserted = inserted }}, version);
        } else {
            data.clearRetainingCapacity();
            for (0..r.uintLessThan(usize, 30)) |_| try data.appendSlice(gpa, &.{ r.uintLessThan(u32, 3), r.uintLessThan(u32, 6), 1 + r.uintLessThan(u32, 5), r.uintLessThan(u32, 4), r.uintLessThan(u32, 4) });
            const lines: []const []const u8 = store.items;
            _ = try o.applyFull(version -| r.uintLessThan(u64, 3), "id", data.items, &f.legend, .fromSlice(&lines));
        }
        try std.testing.expectEqual(store.items.len, o.lines.items.len);
    }
}
