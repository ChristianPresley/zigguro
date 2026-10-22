//! Highlighter tests with a toy language (block comments, heredocs, a
//! fenced guest language), plus the "incremental equals full" check that
//! every language's fuzz test reuses.

const std = @import("std");
const syntax = @import("../root.zig");

const gpa = std.testing.allocator;
const Highlighter = syntax.Highlighter;
const LineSource = syntax.LineSource;
const Registry = syntax.Registry;
const Language = syntax.Language;
const LexState = syntax.LexState;
const Scanner = syntax.Scanner;
const TokenSink = syntax.TokenSink;
const Token = syntax.Token;
const isIdentByte = syntax.lex.scanner.isIdentByte;

// Toy language. Modes: 0 code, 1 block comment (depth = nesting), 2 heredoc
// body (aux = tag).
const K = struct {
    const ws = 1;
    const ident = 2;
    const keyword = 3 | Token.atomic_bit;
    const number = 4;
    const string = 5;
    const comment = 6;
    const bracket = 7 | Token.atomic_bit;
    const op = 8;
};

fn toyLex(st: *LexState, s: *Scanner, out: *TokenSink) void {
    if (st.mode == 2) {
        // A heredoc line: the tag alone ends it.
        const start = s.pos;
        if (std.mem.eql(u8, s.rest(), st.auxBytes())) {
            st.mode = 0;
            st.clearAux();
            s.emit(out, start, K.keyword, .keyword);
        } else s.emit(out, start, K.string, .string);
        s.skipToEnd();
        return;
    }
    while (!s.atEnd()) {
        const start = s.pos;
        if (st.mode == 1) {
            while (!s.atEnd()) {
                if (s.eat("/*")) {
                    st.depth += 1;
                } else if (s.eat("*/")) {
                    st.depth -= 1;
                    if (st.depth == 0) {
                        st.mode = 0;
                        break;
                    }
                } else s.advance();
            }
            s.emit(out, start, K.comment, .comment);
            continue;
        }
        const c = s.peek().?;
        if (c == ' ' or c == '\t') {
            _ = s.eatWhile(syntax.lex.scanner.isBlank);
            s.emit(out, start, K.ws, .none);
        } else if (s.eat("/*")) {
            st.mode = 1;
            st.depth = 1;
            s.pos = start;
            s.advanceBy(2);
            // Continue in comment mode from after the opener.
            while (!s.atEnd()) {
                if (s.eat("/*")) {
                    st.depth += 1;
                } else if (s.eat("*/")) {
                    st.depth -= 1;
                    if (st.depth == 0) {
                        st.mode = 0;
                        break;
                    }
                } else s.advance();
            }
            s.emit(out, start, K.comment, .comment);
        } else if (c == '#') {
            s.skipToEnd();
            s.emit(out, start, K.comment, .comment);
        } else if (s.eat("<<")) {
            const tag_start = s.pos;
            _ = s.eatIdent();
            if (s.pos > tag_start) {
                st.mode = 2;
                st.setAux(s.line[tag_start..s.pos]);
            }
            s.emit(out, start, K.op, .operator);
        } else if (c == '"') {
            s.advance();
            _ = s.eatUntilAny("\"");
            _ = s.eatByte('"');
            s.emit(out, start, K.string, .string);
        } else if (std.ascii.isDigit(c)) {
            _ = s.eatWhile(std.ascii.isDigit);
            s.emit(out, start, K.number, .number);
        } else if (isIdentByte(c)) {
            const w = s.line[start .. start + s.eatIdent()];
            if (std.mem.eql(u8, w, "fn") or std.mem.eql(u8, w, "if"))
                s.emit(out, start, K.keyword, .keyword)
            else
                s.emit(out, start, K.ident, .variable);
        } else if (std.mem.indexOfScalar(u8, "{}()", c) != null) {
            s.advance();
            s.emit(out, start, K.bracket, .punctuation_bracket);
        } else if (s.eat("```")) {
            // A fence: the rest of the line names the guest.
            s.skipToEnd();
            s.emit(out, start, K.op, .markup_code);
            if (std.mem.eql(u8, s.line[start + 3 ..], "g")) _ = st.push(guest_id);
            return;
        } else {
            s.advance();
            s.emit(out, start, K.op, .operator);
        }
    }
}

const toy_id: syntax.LanguageId = @enumFromInt(200);
const guest_id: syntax.LanguageId = @enumFromInt(201);

fn fenceEnd(_: u16, line: []const u8, from: u32) ?u32 {
    return if (from == 0 and std.mem.eql(u8, line, "```")) 0 else null;
}

fn guestLex(_: *LexState, s: *Scanner, out: *TokenSink) void {
    while (!s.atEnd()) {
        const start = s.pos;
        if (std.ascii.isUpper(s.peek().?)) {
            _ = s.eatIdent();
            s.emit(out, start, 1 | Token.atomic_bit, .keyword);
        } else {
            s.advance();
            s.emit(out, start, 2, .none);
        }
    }
}

fn startsFn(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "fn ");
}

const toy: Language = .{
    .id = toy_id,
    .name = "toy",
    .lexer = .{ .lexLineFn = toyLex },
    .injection_end = fenceEnd,
};
const toy_resync: Language = .{
    .id = toy_id,
    .name = "toy",
    .lexer = .{ .lexLineFn = toyLex },
    .injection_end = fenceEnd,
    .resync = startsFn,
};
const guest: Language = .{ .id = guest_id, .name = "guest", .lexer = .{ .lexLineFn = guestLex } };

fn toyRegistry(lang: *const Language) !Registry {
    var r: Registry = try .init(gpa);
    try r.register(gpa, lang);
    try r.register(gpa, &guest);
    return r;
}

/// Lines with owned text, edited like a document.
pub const Lines = struct {
    items: std.ArrayList([]u8) = .empty,
    view: std.ArrayList([]const u8) = .empty,
    slice: []const []const u8 = &.{},

    pub fn deinit(l: *Lines) void {
        for (l.items.items) |x| gpa.free(x);
        l.items.deinit(gpa);
        l.view.deinit(gpa);
    }

    pub fn append(l: *Lines, text: []const u8) !void {
        try l.items.append(gpa, try gpa.dupe(u8, text));
    }

    /// Replaces `removed` lines at `first` with `new`.
    pub fn splice(l: *Lines, first: usize, removed: usize, new: []const []const u8) !void {
        for (l.items.items[first..][0..removed]) |x| gpa.free(x);
        const dup = try gpa.alloc([]u8, new.len);
        defer gpa.free(dup);
        for (new, dup) |n, *d| d.* = try gpa.dupe(u8, n);
        try l.items.replaceRange(gpa, first, removed, dup);
    }

    pub fn source(l: *Lines) !LineSource {
        l.view.clearRetainingCapacity();
        for (l.items.items) |x| try l.view.append(gpa, x);
        l.slice = l.view.items;
        return LineSource.fromSlice(&l.slice);
    }
};

/// Asserts that `h` (after finishing its work) matches a from-scratch
/// highlight of `lines`.
pub fn expectMatchesFull(h: *Highlighter, lines: *Lines) !void {
    const src = try lines.source();
    _ = try h.idle(src, null);
    var full: Highlighter = try .init(gpa, h.lang, h.reg);
    defer full.deinit();
    try full.reset(src);
    _ = try full.idle(src, null);
    try std.testing.expectEqual(full.lineCount(), h.lineCount());
    var i: u64 = 0;
    while (i < full.lineCount()) : (i += 1) {
        const a = full.tokens(i);
        const b = h.tokens(i);
        if (a.len != b.len or !std.mem.eql(u64, @ptrCast(a), @ptrCast(b)) or !full.endState(i).eql(h.endState(i))) {
            std.debug.print("line {d} differs: \"{s}\" ({d} vs {d} tokens)\n", .{ i, src.get(i, undefined, gpa) catch "", a.len, b.len });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(!h.isApprox(i));
    }
}

/// Random edits from `pieces`, checked against a full highlight. `pick(n)`
/// returns a value below `n` (from a PRNG or a fuzz Smith).
pub fn checkIncremental(lang: *const Language, reg: *const Registry, pieces: []const []const u8, pick: anytype) !void {
    var lines: Lines = .{};
    defer lines.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const n0 = 1 + pick.next(30);
    for (0..n0) |_| {
        buf.clearRetainingCapacity();
        for (0..pick.next(6)) |_| try buf.appendSlice(gpa, pieces[pick.next(pieces.len)]);
        try lines.append(buf.items);
    }
    var h: Highlighter = try .init(gpa, lang, reg);
    defer h.deinit();
    try h.reset(try lines.source());
    _ = try h.idle(try lines.source(), null);

    var new_lines: std.ArrayList([]const u8) = .empty;
    defer new_lines.deinit(gpa);
    var texts: std.ArrayList(u8) = .empty;
    defer texts.deinit(gpa);
    for (0..1 + pick.next(12)) |_| {
        const len = lines.items.items.len;
        const first = pick.next(len);
        const removed = @min(len - first, pick.next(3) + 1);
        var inserted = pick.next(4);
        if (removed == len and inserted == 0) inserted = 1; // keep one line
        texts.clearRetainingCapacity();
        var ends: [4]usize = undefined;
        for (0..inserted) |k| {
            for (0..pick.next(6)) |_| try texts.appendSlice(gpa, pieces[pick.next(pieces.len)]);
            ends[k] = texts.items.len;
        }
        new_lines.clearRetainingCapacity();
        var prev: usize = 0;
        for (ends[0..inserted]) |e| {
            try new_lines.append(gpa, texts.items[prev..e]);
            prev = e;
        }
        // Sometimes a second edit after the first (multi-cursor), applied
        // to the model back to front and to the highlighter at once.
        const e1: syntax.LineEdit = .{ .first = first, .removed = removed, .inserted = inserted };
        const after = first + removed;
        if (after < len and pick.next(3) == 0) {
            const first2 = after + pick.next(len - after);
            const removed2 = @min(len - first2, pick.next(2) + 1);
            try lines.splice(first2, removed2, &.{ "/*", "x" });
            try lines.splice(first, removed, new_lines.items);
            const src = try lines.source();
            try h.onEdits(&.{ e1, .{ .first = first2, .removed = removed2, .inserted = 2 } }, src, null);
        } else {
            try lines.splice(first, removed, new_lines.items);
            try h.onEdit(e1, try lines.source(), null);
        }
        const src = try lines.source();
        switch (pick.next(3)) {
            0 => {
                const a = pick.next(src.lines);
                try h.ensure(src, a, a + pick.next(5));
                try std.testing.expect(h.isExact(@min(a, src.lines - 1)) or h.isApprox(a));
            },
            1 => _ = try h.idle(src, null),
            else => {},
        }
    }
    try expectMatchesFull(&h, &lines);
}

const PrngPick = struct {
    r: std.Random,
    pub fn next(p: PrngPick, n: usize) usize {
        return if (n <= 1) 0 else p.r.uintLessThan(usize, n);
    }
};

const SmithPick = struct {
    s: *std.testing.Smith,
    pub fn next(p: SmithPick, n: usize) usize {
        return if (n <= 1) 0 else p.s.index(n);
    }
};

const toy_pieces = [_][]const u8{ "a", " ", "fn ", "/*", "*/", "\"s", "\"", "<<E", "E", "{", "}", "#x", "12", "```g", "```", "Q" };

fn lineOf(h: *const Highlighter, i: u64) []const Token {
    return h.tokens(i);
}

test "highlighter: convergence stops early" {
    var r = try toyRegistry(&toy);
    defer r.deinit(gpa);
    var lines: Lines = .{};
    defer lines.deinit();
    for (0..100) |_| try lines.append("fn a { 1 }");
    var h: Highlighter = try .init(gpa, &toy, &r);
    defer h.deinit();
    try h.reset(try lines.source());
    try std.testing.expect(try h.idle(try lines.source(), null));
    const before = h.stats.lines_lexed;
    try lines.splice(50, 1, &.{"x y"});
    try h.onEdit(.{ .first = 50, .removed = 1, .inserted = 1 }, try lines.source(), null);
    try std.testing.expectEqual(@as(u64, 1), h.stats.lines_lexed - before);
    try std.testing.expect(h.done());
    try std.testing.expectEqual(syntax.HighlightId.variable, h.tokens(50)[0].hl);
    // A state change runs on until the state converges.
    const b2 = h.stats.lines_lexed;
    try lines.splice(10, 1, &.{"<<E"});
    try lines.splice(13, 1, &.{"E"});
    try h.onEdit(.{ .first = 10, .removed = 1, .inserted = 1 }, try lines.source(), null);
    try h.onEdit(.{ .first = 13, .removed = 1, .inserted = 1 }, try lines.source(), null);
    try std.testing.expect(h.done());
    try std.testing.expect(h.stats.lines_lexed - b2 <= 6);
    try std.testing.expectEqual(syntax.HighlightId.string, h.tokens(12)[0].hl);
    try std.testing.expectEqual(syntax.HighlightId.keyword, h.tokens(14)[0].hl);
    try expectMatchesFull(&h, &lines);
}

test "highlighter: open block comment relexes to end within budget, viewport exact" {
    var r = try toyRegistry(&toy);
    defer r.deinit(gpa);
    var lines: Lines = .{};
    defer lines.deinit();
    const n = 100_000;
    for (0..n) |_| try lines.append("fn a { 1 }");
    var h: Highlighter = try .init(gpa, &toy, &r);
    defer h.deinit();
    try h.reset(try lines.source());
    _ = try h.idle(try lines.source(), null);

    try lines.splice(0, 1, &.{"/* fn a { 1 }"});
    const src = try lines.source();
    try h.onEdit(.{ .first = 0, .removed = 1, .inserted = 1 }, src, null);
    // The budget stops the chain; the top of the file is already exact.
    try std.testing.expect(!h.done());
    try std.testing.expect(h.isExact(Highlighter.edit_line_budget - 1));
    try std.testing.expect(!h.isExact(n - 1));
    // A far viewport is made exact on demand (no resync for this language).
    try h.ensure(src, 60_000, 60_050);
    try std.testing.expect(h.isExact(60_050));
    try std.testing.expectEqual(syntax.HighlightId.comment, h.tokens(60_025)[0].hl);
    try std.testing.expect(try h.idle(src, null));
    try std.testing.expectEqual(syntax.HighlightId.comment, h.tokens(n - 1)[0].hl);
    try std.testing.expectEqual(@as(u16, 1), h.endState(n - 1).mode);

    // Closing it converges right after the edit.
    try lines.splice(1, 1, &.{"*/"});
    try h.onEdit(.{ .first = 1, .removed = 1, .inserted = 1 }, try lines.source(), null);
    try h.ensure(try lines.source(), 0, 40);
    try std.testing.expectEqual(syntax.HighlightId.keyword, h.tokens(2)[0].hl);
    try expectMatchesFull(&h, &lines);
}

test "highlighter: far viewport resyncs approximately, idle makes it exact" {
    var r = try toyRegistry(&toy_resync);
    defer r.deinit(gpa);
    var lines: Lines = .{};
    defer lines.deinit();
    for (0..30_000) |i| try lines.append(if (i % 10 == 0) "fn a {" else "  1 }");
    var h: Highlighter = try .init(gpa, &toy_resync, &r);
    defer h.deinit();
    const src = try lines.source();
    try h.reset(src);
    try h.ensure(src, 20_005, 20_030);
    try std.testing.expect(h.isApprox(20_010));
    try std.testing.expect(!h.isExact(20_010));
    try std.testing.expectEqual(syntax.HighlightId.keyword, h.tokens(20_010)[0].hl);
    try expectMatchesFull(&h, &lines);
}

test "highlighter: long line single token" {
    var r = try toyRegistry(&toy);
    defer r.deinit(gpa);
    var lines: Lines = .{};
    defer lines.deinit();
    const long = try gpa.alloc(u8, syntax.lex.lexer.max_tokenized_line + 1);
    defer gpa.free(long);
    @memset(long, 'a');
    long[0] = '"';
    try lines.append("<<E");
    try lines.append(long);
    try lines.append("x");
    var h: Highlighter = try .init(gpa, &toy, &r);
    defer h.deinit();
    try h.reset(try lines.source());
    _ = try h.idle(try lines.source(), null);
    try std.testing.expectEqual(@as(usize, 1), h.tokens(1).len);
    try std.testing.expectEqual(syntax.HighlightId.none, h.tokens(1)[0].hl);
    // The state passes through unchanged: still in the heredoc.
    try std.testing.expectEqual(@as(u16, 2), h.endState(1).mode);
    try std.testing.expect(h.store.rec(1).flags.long_line);
}

test "injections: push/pop with toy host and guest" {
    var r = try toyRegistry(&toy);
    defer r.deinit(gpa);
    var lines: Lines = .{};
    defer lines.deinit();
    for ([_][]const u8{ "a /* x", "*/ ```g", "AB c /*", "```", "fn" }) |l| try lines.append(l);
    var h: Highlighter = try .init(gpa, &toy, &r);
    defer h.deinit();
    try h.reset(try lines.source());
    _ = try h.idle(try lines.source(), null);
    // Line 1 ends in the guest; the host's comment mode was 0 at the fence.
    try std.testing.expect(h.endState(1).injected());
    try std.testing.expectEqual(guest_id, h.endState(1).top());
    // Guest tokens: keyword AB, injected.
    const t2 = h.tokens(2);
    try std.testing.expectEqual(syntax.HighlightId.keyword, t2[0].hl);
    try std.testing.expect(t2[0].kind & Token.injected_bit != 0);
    // The closing fence pops back to the host, which highlights it.
    try std.testing.expect(!h.endState(3).injected());
    try std.testing.expectEqual(syntax.HighlightId.markup_code, h.tokens(3)[0].hl);
    try std.testing.expect(h.tokens(3)[0].kind & Token.injected_bit == 0);
    try std.testing.expectEqual(syntax.HighlightId.keyword, h.tokens(4)[0].hl);
    // The guest's `/*` is plain text in the guest: no comment leaks out.
    try std.testing.expectEqual(@as(u16, 0), h.endState(4).mode);
}

test "highlighter: kindAt" {
    var r = try toyRegistry(&toy);
    defer r.deinit(gpa);
    var lines: Lines = .{};
    defer lines.deinit();
    for ([_][]const u8{ "a \"str\" # c", "x /* open", "y" }) |l| try lines.append(l);
    var h: Highlighter = try .init(gpa, &toy, &r);
    defer h.deinit();
    try h.reset(try lines.source());
    _ = try h.idle(try lines.source(), null);
    try std.testing.expectEqual(syntax.ContextKind.code, h.kindAt(0, 0, 11));
    try std.testing.expectEqual(syntax.ContextKind.string, h.kindAt(0, 3, 11));
    try std.testing.expectEqual(syntax.ContextKind.comment, h.kindAt(0, 10, 11));
    // End of a line that ends inside a block comment: comment.
    try std.testing.expectEqual(syntax.ContextKind.comment, h.kindAt(1, 9, 9));
    // End of a line that ends in code: code, even after a `#` comment token.
    try std.testing.expectEqual(syntax.ContextKind.code, h.kindAt(0, 11, 11));
}

test "highlighter: incremental equals full" {
    var r = try toyRegistry(&toy);
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    for (0..300) |_| try checkIncremental(&toy, &r, &toy_pieces, PrngPick{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try toyRegistry(&toy);
            defer r.deinit(gpa);
            try checkIncremental(&toy, &r, &toy_pieces, SmithPick{ .s = s });
        }
    }.one, .{});
}

/// Exposed for language tests.
pub const Pick = struct {
    pub const prng = PrngPick;
    pub const smith = SmithPick;
};
