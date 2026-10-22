//! Zig lexer tests: token boundaries against `std.zig.Tokenizer` over the
//! repository's own sources, golden highlights, and incremental-vs-full.

const std = @import("std");
const syntax = @import("../root.zig");
const zig = @import("zig.zig");
const hl_test = @import("../highlight/highlighter_test.zig");
const golden = @import("zg_core").testkit.golden;
const options = @import("zg_options");

const gpa = std.testing.allocator;
const io = std.testing.io;
const Kind = zig.Kind;
const Token = syntax.Token;

fn registry() !syntax.Registry {
    var r: syntax.Registry = try .init(gpa);
    try r.register(gpa, &zig.zig_language);
    return r;
}

fn lexOne(r: *const syntax.Registry, line: []const u8, sink: *syntax.TokenSink) !void {
    var st = syntax.LexState.init(.zig);
    try sink.begin(gpa, line.len);
    syntax.lex.lexer.lexLine(r, &st, line, sink);
    try std.testing.expectEqual(@as(u16, 0), st.mode);
}

const Span = struct { start: usize, end: usize };

/// Our tokens as tokenizer tokens: whitespace and plain comments dropped,
/// string pieces joined.
fn coarse(toks: []const Token, line_len: usize, out: *std.ArrayList(Span)) !void {
    out.clearRetainingCapacity();
    for (toks, 0..) |t, i| {
        const end = if (i + 1 < toks.len) toks[i + 1].start else line_len;
        switch (t.kind) {
            Kind.ws, Kind.comment => continue,
            Kind.str_escape, Kind.str_cont => {
                if (out.items.len > 0 and out.items[out.items.len - 1].end == t.start)
                    out.items[out.items.len - 1].end = end;
                continue;
            },
            else => try out.append(gpa, .{ .start = t.start, .end = end }),
        }
    }
}

/// Tokenizer tokens of one line, or null when the line has an invalid one.
fn reference(line: []const u8, buf: *std.ArrayList(u8), out: *std.ArrayList(Span)) !?void {
    buf.clearRetainingCapacity();
    try buf.appendSlice(gpa, line);
    try buf.append(gpa, 0);
    const src: [:0]const u8 = buf.items[0..line.len :0];
    var tz = std.zig.Tokenizer.init(src);
    out.clearRetainingCapacity();
    while (true) {
        const t = tz.next();
        switch (t.tag) {
            .eof => return {},
            .invalid, .invalid_periodasterisks => return null,
            else => try out.append(gpa, .{ .start = t.loc.start, .end = t.loc.end }),
        }
    }
}

test "zig: token boundaries equal std.zig.Tokenizer" {
    var r = try registry();
    defer r.deinit(gpa);
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var pkgs = try root.openDir(io, "..", .{ .iterate = true });
    defer pkgs.close(io);
    var walker = try pkgs.walkSelectively(gpa);
    defer walker.deinit();

    var sink: syntax.TokenSink = .{};
    defer sink.deinit(gpa);
    var ours: std.ArrayList(Span) = .empty;
    defer ours.deinit(gpa);
    var want: std.ArrayList(Span) = .empty;
    defer want.deinit(gpa);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var lines: usize = 0;
    var skipped: usize = 0;
    while (try walker.next(io)) |e| {
        switch (e.kind) {
            .directory => {
                if (e.basename[0] != '.' and !std.mem.eql(u8, e.basename, "zig-out")) try walker.enter(io, e);
                continue;
            },
            .file => if (!std.mem.endsWith(u8, e.basename, ".zig")) continue,
            else => continue,
        }
        const text = try e.dir.readFileAlloc(io, e.basename, gpa, .limited(64 << 20));
        defer gpa.free(text);
        var it = std.mem.splitScalar(u8, text, '\n');
        var n: usize = 0;
        while (it.next()) |raw| : (n += 1) {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if ((try reference(line, &buf, &want)) == null) {
                skipped += 1;
                continue;
            }
            try lexOne(&r, line, &sink);
            try coarse(sink.tokens(), line.len, &ours);
            lines += 1;
            if (ours.items.len != want.items.len or !std.mem.eql(u8, std.mem.sliceAsBytes(ours.items), std.mem.sliceAsBytes(want.items))) {
                std.debug.print("{s}:{d}: token boundaries differ\n  {s}\n", .{ e.path, n + 1, line });
                for (want.items) |s| std.debug.print("  want [{d},{d}) {s}\n", .{ s.start, s.end, line[s.start..s.end] });
                for (ours.items) |s| std.debug.print("  got  [{d},{d}) {s}\n", .{ s.start, s.end, line[s.start..s.end] });
                return error.TestUnexpectedResult;
            }
        }
    }
    // The repository is a large corpus; make sure it was found.
    try std.testing.expect(lines > 50_000);
    try std.testing.expect(skipped * 100 < lines);
}

const golden_files = [_][]const u8{
    "multiline_strings", "doc_comments", "labeled_blocks",  "builtins",       "quoted_ident",
    "numbers",           "hex_floats",   "char_escapes",    "string_escapes", "keywords",
    "primitives",        "operators",    "functions_types", "comments",       "invalid",
};

/// Renders highlights: per line, `n| hl:text` for each highlighted token.
fn render(h: *const syntax.Highlighter, lines: []const []const u8, out: *std.Io.Writer) !void {
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

test "zig: golden highlights" {
    var r = try registry();
    defer r.deinit(gpa);
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    for (golden_files) |name| {
        const path = try std.fmt.allocPrint(gpa, "testdata/zig/{s}.zig.txt", .{name});
        defer gpa.free(path);
        const text = try root.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(text);
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(gpa);
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (it.next()) |l| try lines.append(gpa, l);
        const slice: []const []const u8 = lines.items;
        const src = syntax.LineSource.fromSlice(&slice);
        var h: syntax.Highlighter = try .init(gpa, &zig.zig_language, &r);
        defer h.deinit();
        try h.reset(src);
        _ = try h.idle(src, null);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try render(&h, slice, &out.writer);
        try golden.expectGoldenOpts(io, @src(), name, out.written(), .{ .root = options.package_root, .dir = "testdata/golden/zig" });
    }
}

const zig_pieces = [_][]const u8{ "const ", "x", " = ", "\"s\\n", "\"", "\\\\ m", "// c", "/// d", "@f(", ")", "{", "}", "blk: ", "break :blk", "0x1p-3", "'a'", ".*", "+%=", "fn ", "Foo", "\t", "é" };

test "zig: incremental equals full" {
    var r = try registry();
    defer r.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x219);
    for (0..200) |_| try hl_test.checkIncremental(&zig.zig_language, &r, &zig_pieces, hl_test.Pick.prng{ .r = prng.random() });
}

test "fuzz: incremental highlight equals full (zig)" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var r = try registry();
            defer r.deinit(gpa);
            try hl_test.checkIncremental(&zig.zig_language, &r, &zig_pieces, hl_test.Pick.smith{ .s = s });
        }
    }.one, .{});
}

test "zig: every line ends in the initial state" {
    var r = try registry();
    defer r.deinit(gpa);
    var sink: syntax.TokenSink = .{};
    defer sink.deinit(gpa);
    for ([_][]const u8{ "\\\\ multi", "\"open string", "/// doc", "'x", "@\"q", "fn f() void {" }) |l| try lexOne(&r, l, &sink);
}
