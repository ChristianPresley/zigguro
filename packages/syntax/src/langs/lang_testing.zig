//! Test helpers shared by the per-language lexer tests: golden highlight
//! runs and single-line lexing with a chosen start state.

const std = @import("std");
const syntax = @import("../root.zig");
const golden = @import("zg_core").testkit.golden;
const options = @import("zg_options");

const gpa = std.testing.allocator;
const io = std.testing.io;

/// A registry with every built-in language.
pub fn registry() !syntax.Registry {
    return syntax.defaultRegistry(gpa);
}

/// Renders highlights: per line, `n| hl:text` for each highlighted token,
/// with ` ~mode` appended when the line ends in a non-initial mode.
pub fn render(h: *const syntax.Highlighter, lines: []const []const u8, out: *std.Io.Writer) !void {
    for (lines, 0..) |line, i| {
        try out.print("{d}|", .{i + 1});
        const toks = h.tokens(i);
        for (toks, 0..) |t, k| {
            if (t.hl == .none) continue;
            const end = if (k + 1 < toks.len) toks[k + 1].start else line.len;
            try out.print(" {s}:{s}", .{ t.hl.name(), line[t.start..end] });
        }
        try out.writeByte('\n');
    }
}

/// Highlights `testdata/<dir>/<name><ext>.txt` for each name and compares
/// the rendering with `testdata/golden/<dir>/<name>.golden`.
pub fn expectGoldens(lang: *const syntax.Language, dir: []const u8, ext: []const u8, names: []const []const u8) !void {
    var r = try registry();
    defer r.deinit(gpa);
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    const golden_dir = try std.fmt.allocPrint(gpa, "testdata/golden/{s}", .{dir});
    defer gpa.free(golden_dir);
    for (names) |name| {
        const path = try std.fmt.allocPrint(gpa, "testdata/{s}/{s}{s}.txt", .{ dir, name, ext });
        defer gpa.free(path);
        const text = try root.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(text);
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(gpa);
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (it.next()) |l| try lines.append(gpa, l);
        const slice: []const []const u8 = lines.items;
        const src = syntax.LineSource.fromSlice(&slice);
        var h: syntax.Highlighter = try .init(gpa, lang, &r);
        defer h.deinit();
        try h.reset(src);
        _ = try h.idle(src, null);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try render(&h, slice, &out.writer);
        try golden.expectGoldenOpts(io, @src(), name, out.written(), .{ .root = options.package_root, .dir = golden_dir });
    }
}

/// One lexed line: its tokens and end state.
pub const Lexed = struct {
    sink: syntax.TokenSink = .{},
    state: syntax.LexState,
    line: []const u8 = "",

    pub fn deinit(l: *Lexed) void {
        l.sink.deinit(gpa);
    }

    /// The highlight of the token covering byte `at`.
    pub fn hlAt(l: *const Lexed, at: usize) syntax.HighlightId {
        const toks = l.sink.tokens();
        var hl: syntax.HighlightId = .none;
        for (toks) |t| {
            if (t.start > at) break;
            hl = t.hl;
        }
        return hl;
    }

    /// The text of the token covering byte `at`.
    pub fn textAt(l: *const Lexed, at: usize) []const u8 {
        const toks = l.sink.tokens();
        var k: usize = 0;
        for (toks, 0..) |t, i| {
            if (t.start > at) break;
            k = i;
        }
        const end = if (k + 1 < toks.len) toks[k + 1].start else l.line.len;
        return l.line[toks[k].start..end];
    }
};

/// Lexes `line` with `lex` from `state`.
pub fn lexWith(lex: *const fn (*syntax.LexState, *syntax.Scanner, *syntax.TokenSink) void, state: syntax.LexState, line: []const u8) !Lexed {
    var l: Lexed = .{ .state = state, .line = line };
    errdefer l.deinit();
    try l.sink.begin(gpa, line.len);
    var s: syntax.Scanner = .{ .line = line };
    lex(&l.state, &s, &l.sink);
    try std.testing.expectEqual(@as(u32, @intCast(line.len)), s.pos);
    return l;
}

/// Lexes consecutive lines through the registry, returning the end state
/// of the last one.
pub fn lexLines(r: *const syntax.Registry, id: syntax.LanguageId, lines: []const []const u8) !syntax.LexState {
    var st = syntax.LexState.init(id);
    var sink: syntax.TokenSink = .{};
    defer sink.deinit(gpa);
    for (lines) |l| {
        try sink.begin(gpa, l.len);
        syntax.lex.lexer.lexLine(r, &st, l, &sink);
    }
    return st;
}
