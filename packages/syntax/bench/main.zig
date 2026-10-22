//! Benchmarks for zg_syntax; run with `zig build bench` at the repo root.
//! The Zig corpus is generated (100k lines of realistic declarations), so
//! runs are reproducible without vendored data.

const std = @import("std");
const zg_core = @import("zg_core");
const syntax = @import("zg_syntax");
const bench = zg_core.bench;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

const template =
    \\/// Returns the {d}th widget, clamped to the table.
    \\pub fn widget{d}(self: *Table, index: usize) ?*const Widget {{
    \\    const i = @min(index, self.items.len -| 1);
    \\    if (self.items.len == 0) return null;
    \\    var sum: u64 = 0x{x};
    \\    for (self.items[0..i], 0..) |w, k| {{
    \\        sum +%= @as(u64, w.weight) * k; // weighted
    \\        if (w.flags.hidden) continue;
    \\    }}
    \\    const label = "widget \x41 {d}\n";
    \\    std.log.debug("{{s}} {{d}}", .{{ label, sum }});
    \\    return &self.items[i];
    \\}}
    \\
    \\
;

fn genZig(gpa: std.mem.Allocator, lines: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var n: usize = 0;
    var i: usize = 0;
    while (n < lines) : (i += 1) {
        try out.writer.print(template, .{ i, i, i * 2654435761 % 0xFFFF, i });
        n += 14;
    }
    return out.toOwnedSlice();
}

fn splitLines(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| try list.append(gpa, l);
    return list.toOwnedSlice(gpa);
}

const LexCtx = struct { reg: *const syntax.Registry, lines: []const []const u8 };

fn lexAll(ctx: LexCtx, s: *bench.State) void {
    var sink: syntax.TokenSink = .{};
    defer sink.deinit(std.heap.smp_allocator);
    var it: u64 = 0;
    while (it < s.iterations()) : (it += 1) {
        var st = syntax.LexState.init(.zig);
        for (ctx.lines) |l| {
            sink.begin(std.heap.smp_allocator, l.len) catch unreachable;
            syntax.lex.lexer.lexLine(ctx.reg, &st, l, &sink);
        }
        bench.doNotOptimizeAway(sink.tokens().len);
    }
    var bytes: u64 = 0;
    for (ctx.lines) |l| bytes += l.len + 1;
    s.setBytes(bytes);
}

const KeyCtx = struct {
    h: *syntax.Highlighter,
    lines: [][]const u8,
    view: *const []const []const u8,
    edited: []const u8,
    original: []const u8,
};

/// Types one character into a line in the middle of the file (alternating
/// two versions of the line) and rehighlights.
fn keystroke(ctx: KeyCtx, s: *bench.State) void {
    const mid = ctx.lines.len / 2;
    var flip = false;
    var it: u64 = 0;
    while (it < s.iterations()) : (it += 1) {
        flip = !flip;
        ctx.lines[mid] = if (flip) ctx.edited else ctx.original;
        const src = syntax.LineSource.fromSlice(ctx.view);
        ctx.h.onEdit(.{ .first = mid, .removed = 1, .inserted = 1 }, src, null) catch unreachable;
        bench.doNotOptimizeAway(ctx.h.tokens(mid).len);
    }
}

// A toy language whose block comments can run on: the worst case for
// convergence when the edit does not change a state.
fn toyLex(st: *syntax.LexState, s: *syntax.Scanner, out: *syntax.TokenSink) void {
    while (!s.atEnd()) {
        const start = s.pos;
        if (st.mode == 1) {
            const i = std.mem.indexOfPos(u8, s.line, s.pos, "*/");
            s.pos = if (i) |x| @intCast(x + 2) else @intCast(s.line.len);
            if (i != null) st.mode = 0;
            s.emit(out, start, 1, .comment);
        } else if (s.eat("/*")) {
            st.mode = 1;
        } else {
            _ = s.eatUntilAny("/");
            if (s.pos == start) s.advance();
            s.emit(out, start, 2, .none);
        }
    }
}

const toy: syntax.Language = .{ .id = @enumFromInt(300), .name = "toy", .lexer = .{ .lexLineFn = toyLex } };

/// Bracket tokens of the corpus with an offset shift past `at`, so the
/// edit bench can insert and delete a byte without copying tokens.
const ShiftSource = struct {
    toks: []const syntax.brackets.bracket_tree.BracketToken,
    len: u64,
    at: u64 = std.math.maxInt(u64),
    by: u64 = 0,
    hint: usize = 0,

    fn source(s: *ShiftSource) syntax.BracketSource {
        return .{ .ctx = s, .len = s.len + s.by, .nextFn = next };
    }

    fn next(ctx: *anyopaque, from: u64) std.mem.Allocator.Error!?syntax.brackets.bracket_tree.BracketToken {
        const s: *ShiftSource = @ptrCast(@alignCast(ctx));
        // Old offset of `from`: tokens at or past `at` moved by `by`.
        const old = if (from >= s.at + s.by) from - s.by else @min(from, s.at);
        // Sequential reads ask for the token after the last one.
        var lo: usize = s.hint;
        if (!(lo < s.toks.len and s.toks[lo].offset >= old and (lo == 0 or s.toks[lo - 1].offset < old))) {
            lo = 0;
            var hi: usize = s.toks.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                if (s.toks[mid].offset < old) lo = mid + 1 else hi = mid;
            }
        }
        s.hint = lo + 1;
        if (lo == s.toks.len) return null;
        var t = s.toks[lo];
        if (t.offset >= s.at) t.offset += s.by;
        return t;
    }
};

/// The corpus's bracket tokens, from the Zig lexer.
fn bracketTokens(gpa: std.mem.Allocator, reg: *const syntax.Registry, lines: []const []const u8) ![]syntax.brackets.bracket_tree.BracketToken {
    var out: std.ArrayList(syntax.brackets.bracket_tree.BracketToken) = .empty;
    var sink: syntax.TokenSink = .{};
    defer sink.deinit(gpa);
    var st = syntax.LexState.init(.zig);
    var off: u64 = 0;
    for (lines) |l| {
        try sink.begin(gpa, l.len);
        syntax.lex.lexer.lexLine(reg, &st, l, &sink);
        for (sink.tokens()) |t| if (t.hl == .punctuation_bracket) {
            const pair: u6 = switch (l[t.start]) {
                '(', ')' => 0,
                '[', ']' => 1,
                else => 2,
            };
            const open = switch (l[t.start]) {
                '(', '[', '{' => true,
                else => false,
            };
            try out.append(gpa, .{ .offset = off + t.start, .len = 1, .pair = pair, .open = open });
        };
        off += l.len + 1;
    }
    return out.toOwnedSlice(gpa);
}

const FallbackCtx = struct { bt: *syntax.BracketTree, text: []const u8 };

const EditCtx = struct { bt: *syntax.BracketTree, src: *ShiftSource, at: u64, line: syntax.brackets.bracket_tree.Range };

/// Types a byte into a line in the middle of the file and deletes it
/// again, updating the bracket tree each time (the edited line counts as
/// retokenized, as the highlighter reports it).
fn bracketEdit(ctx: EditCtx, s: *bench.State) void {
    var it: u64 = 0;
    while (it < s.iterations()) : (it += 1) {
        const inserting = ctx.src.by == 0;
        ctx.src.at = ctx.at;
        ctx.src.by = if (inserting) 1 else 0;
        const e: syntax.brackets.bracket_tree.TextEdit = if (inserting) .{ .start = ctx.at, .end = ctx.at, .new_len = 1 } else .{ .start = ctx.at, .end = ctx.at + 1, .new_len = 0 };
        const line: syntax.brackets.bracket_tree.Range = .{ .start = ctx.line.start, .end = ctx.line.end + ctx.src.by };
        ctx.bt.applyEdits(&.{e}, &.{line}, ctx.src.source()) catch unreachable;
        bench.doNotOptimizeAway(ctx.bt.len());
    }
}

fn register(b: *bench.Bench) !void {
    const gpa = b.gpa;
    var reg = try syntax.defaultRegistry(gpa);
    defer reg.deinit(gpa);
    try reg.register(gpa, &toy);
    const n_lines: usize = if (b.opts.quick) 20_000 else 100_000;
    const text = try genZig(gpa, n_lines);
    defer gpa.free(text);
    const lines = try splitLines(gpa, text);
    defer gpa.free(lines);
    const view: []const []const u8 = lines;

    try b.run("syntax.lex.zig", LexCtx{ .reg = &reg, .lines = lines }, lexAll);
    {
        const z = try gpa.dupeZ(u8, text);
        defer gpa.free(z);
        // Reference: std.zig.Tokenizer over the whole text (no highlights).
        try b.run("syntax.lex.std_tokenizer", z, struct {
            fn f(src: [:0]const u8, st: *bench.State) void {
                var it: u64 = 0;
                while (it < st.iterations()) : (it += 1) {
                    var tz = std.zig.Tokenizer.init(src);
                    var n: usize = 0;
                    while (tz.next().tag != .eof) n += 1;
                    bench.doNotOptimizeAway(n);
                }
                st.setBytes(src.len);
            }
        }.f);
    }
    std.debug.print("  corpus: {d} bytes, {d} lines\n", .{ text.len, lines.len });

    {
        const z = try gpa.dupeZ(u8, text);
        defer gpa.free(z);
        // Reference: std.zig.Ast.parse alone.
        try b.run("syntax.structure.ast_parse_only", z, struct {
            fn f(src: [:0]const u8, st: *bench.State) void {
                var it: u64 = 0;
                while (it < st.iterations()) : (it += 1) {
                    var t = std.zig.Ast.parse(std.heap.smp_allocator, src, .zig) catch unreachable;
                    bench.doNotOptimizeAway(t.nodes.len);
                    t.deinit(std.heap.smp_allocator);
                }
                st.setBytes(src.len);
            }
        }.f);
    }
    try b.run("syntax.structure.zig_100k_full", text, struct {
        fn f(src: []const u8, st: *bench.State) void {
            var it: u64 = 0;
            while (it < st.iterations()) : (it += 1) {
                var s = syntax.langs.zig.zig_language.structure.?(std.heap.smp_allocator, src, it) catch unreachable;
                bench.doNotOptimizeAway(s.folds.len);
                s.deinit();
            }
            st.setBytes(src.len);
        }
    }.f);

    {
        const toks = try bracketTokens(gpa, &reg, lines);
        defer gpa.free(toks);
        var ss: ShiftSource = .{ .toks = toks, .len = text.len };
        try b.run("syntax.brackets.build_100k", &ss, struct {
            fn f(src: *ShiftSource, st: *bench.State) void {
                var it: u64 = 0;
                while (it < st.iterations()) : (it += 1) {
                    var t = syntax.BracketTree.build(std.heap.smp_allocator, src.source()) catch unreachable;
                    bench.doNotOptimizeAway(t.len());
                    t.deinit();
                }
                st.setBytes(src.len);
            }
        }.f);
        var bt = try syntax.BracketTree.build(gpa, ss.source());
        defer bt.deinit();
        std.debug.print("  brackets: {d} tokens, {d} nodes\n", .{ toks.len, bt.nodeCount() });
        // Inside the body of a function in the middle.
        const mid_line = lines.len / 2;
        var off: u64 = 0;
        for (lines[0..mid_line]) |l| off += l.len + 1;
        const at = off + lines[mid_line].len / 2;
        const ctx: EditCtx = .{ .bt = &bt, .src = &ss, .at = at, .line = .{ .start = off, .end = off + lines[mid_line].len } };
        try b.run("syntax.brackets.edit_100k", ctx, bracketEdit);
        if (ss.by != 0) {
            ss.by = 0;
            try bt.applyEdits(&.{.{ .start = at, .end = at + 1, .new_len = 0 }}, &.{ctx.line}, ss.source());
        }

        try b.run("syntax.structure.fallback_100k", FallbackCtx{ .bt = &bt, .text = text }, struct {
            fn f(c: FallbackCtx, st: *bench.State) void {
                var it: u64 = 0;
                while (it < st.iterations()) : (it += 1) {
                    var r = syntax.fallbackStructure(std.heap.smp_allocator, c.text, it, c.bt, &syntax.langs.zig.zig_language, .{}) catch unreachable;
                    bench.doNotOptimizeAway(r.folds.len);
                    r.deinit();
                }
                st.setBytes(c.text.len);
            }
        }.f);
    }

    inline for (.{ .{ "syntax.keystroke.zig_100k", &syntax.langs.zig.zig_language }, .{ "syntax.keystroke.toy_100k", &toy } }) |c| {
        var h: syntax.Highlighter = try .init(gpa, c[1], &reg);
        defer h.deinit();
        const src = syntax.LineSource.fromSlice(&view);
        try h.reset(src);
        _ = try h.idle(src, null);
        const mid = lines.len / 2;
        const original = lines[mid];
        const edited = try std.mem.concat(gpa, u8, &.{ original, "x" });
        defer gpa.free(edited);
        try b.run(c[0], KeyCtx{ .h = &h, .lines = lines, .view = &view, .edited = edited, .original = original }, keystroke);
        lines[mid] = original;
        try h.onEdit(.{ .first = mid, .removed = 1, .inserted = 1 }, src, null);
        _ = try h.idle(src, null);
        if (c[1] == &syntax.langs.zig.zig_language) {
            var toks: usize = 0;
            var i: u64 = 0;
            while (i < h.lineCount()) : (i += 1) toks += h.tokens(i).len;
            std.debug.print("  zig 100k after idle: {d} tokens, {d:.1} bytes/token\n", .{ toks, @as(f64, @floatFromInt(h.store.memoryBytes())) / @as(f64, @floatFromInt(toks)) });
        }
    }
}
