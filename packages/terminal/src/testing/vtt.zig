//! The `.vtt` conformance script format (see
//! `testdata/conformance/README.md`): a line-based list of directives that
//! feed a headless terminal and assert on its screen, cursor, replies,
//! cells, scrollback, title and shell marks.
//!
//! A file starts with `@cite <url>` and holds one or more cases; each
//! `@case <name>` starts a new case with a fresh terminal. A file without
//! `@case` is one case named after the file.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// One assertion on a cell's attributes.
pub const CellExpect = struct {
    row: u16,
    col: u16,
    /// `key=value` and bare flag words, as written.
    attrs: []const []const u8,
};

/// A shell-mark assertion: the n-th mark is `letter` on 1-based `row`.
pub const MarkExpect = struct { letter: u8, row: u16 };

/// One step.
pub const Step = union(enum) {
    size: [2]u16,
    send: []const u8,
    send_file: []const u8,
    resize: [2]u16,
    mode_2027: bool,
    expect_screen: []const []const u8,
    /// 1-based row, column.
    expect_cursor: [2]u16,
    expect_reply: []const u8,
    expect_cell: CellExpect,
    expect_scrollback: []const []const u8,
    expect_title: []const u8,
    expect_mark: MarkExpect,
};

/// One case.
pub const Script = struct {
    name: []const u8,
    cite: []const u8,
    /// Source line of the case header, for messages.
    line: u32,
    steps: []const Step,
    /// Source line of each step.
    lines: []const u32,
};

/// A parse error with its 1-based line.
pub const Diagnostic = struct { line: u32 = 0, message: []const u8 = "" };

/// Parses every case of `src`. Allocations go to `arena`.
pub fn parseFile(arena: Allocator, file_name: []const u8, src: []const u8, diag: *Diagnostic) ![]Script {
    var scripts: std.ArrayList(Script) = .empty;
    var steps: std.ArrayList(Step) = .empty;
    var step_lines: std.ArrayList(u32) = .empty;
    var cite: ?[]const u8 = null;
    var name: []const u8 = file_name;
    var case_line: u32 = 1;
    var have_case = false;

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| try lines.append(arena, std.mem.trimEnd(u8, l, "\r"));

    var i: usize = 0;
    while (i < lines.items.len) : (i += 1) {
        const ln: u32 = @intCast(i + 1);
        const line = std.mem.trim(u8, lines.items[i], " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != '@') return fail(diag, ln, "expected a directive starting with '@'");
        const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        const dir = line[1..sp];
        const arg = std.mem.trim(u8, line[sp..], " \t");
        if (cite == null) {
            if (!std.mem.eql(u8, dir, "cite") or arg.len == 0) return fail(diag, ln, "the first directive must be @cite <url>");
            cite = arg;
            continue;
        }
        if (std.mem.eql(u8, dir, "case")) {
            if (have_case or steps.items.len > 0) {
                try scripts.append(arena, .{ .name = name, .cite = cite.?, .line = case_line, .steps = try steps.toOwnedSlice(arena), .lines = try step_lines.toOwnedSlice(arena) });
            }
            have_case = true;
            name = if (arg.len > 0) arg else return fail(diag, ln, "@case needs a name");
            case_line = ln;
        } else if (std.mem.eql(u8, dir, "size")) {
            try addStep(arena, &steps, &step_lines, ln, .{ .size = parseSize(arg) orelse return fail(diag, ln, "expected COLSxROWS") });
        } else if (std.mem.eql(u8, dir, "resize")) {
            try addStep(arena, &steps, &step_lines, ln, .{ .resize = parseSize(arg) orelse return fail(diag, ln, "expected COLSxROWS") });
        } else if (std.mem.eql(u8, dir, "send")) {
            try addStep(arena, &steps, &step_lines, ln, .{ .send = unquote(arena, arg) catch return fail(diag, ln, "bad string") });
        } else if (std.mem.eql(u8, dir, "send-file")) {
            try addStep(arena, &steps, &step_lines, ln, .{ .send_file = arg });
        } else if (std.mem.eql(u8, dir, "mode-2027")) {
            const on = std.mem.eql(u8, arg, "on");
            if (!on and !std.mem.eql(u8, arg, "off")) return fail(diag, ln, "expected on or off");
            try addStep(arena, &steps, &step_lines, ln, .{ .mode_2027 = on });
        } else if (std.mem.eql(u8, dir, "expect-screen") or std.mem.eql(u8, dir, "expect-scrollback")) {
            var rows: std.ArrayList([]const u8) = .empty;
            while (i + 1 < lines.items.len) {
                const nl = std.mem.trim(u8, lines.items[i + 1], " \t");
                if (nl.len < 2 or nl[0] != '|' or nl[nl.len - 1] != '|') break;
                try rows.append(arena, nl[1 .. nl.len - 1]);
                i += 1;
            }
            const r = try rows.toOwnedSlice(arena);
            try addStep(arena, &steps, &step_lines, ln, if (std.mem.eql(u8, dir, "expect-screen")) .{ .expect_screen = r } else .{ .expect_scrollback = r });
        } else if (std.mem.eql(u8, dir, "expect-cursor")) {
            const rc = parsePair(arg, ',') orelse return fail(diag, ln, "expected ROW,COL");
            try addStep(arena, &steps, &step_lines, ln, .{ .expect_cursor = rc });
        } else if (std.mem.eql(u8, dir, "expect-reply")) {
            try addStep(arena, &steps, &step_lines, ln, .{ .expect_reply = unquote(arena, arg) catch return fail(diag, ln, "bad string") });
        } else if (std.mem.eql(u8, dir, "expect-title")) {
            try addStep(arena, &steps, &step_lines, ln, .{ .expect_title = unquote(arena, arg) catch return fail(diag, ln, "bad string") });
        } else if (std.mem.eql(u8, dir, "expect-cell")) {
            var words = std.mem.tokenizeAny(u8, arg, " \t");
            const pos = parsePair(words.next() orelse "", ',') orelse return fail(diag, ln, "expected ROW,COL");
            var attrs: std.ArrayList([]const u8) = .empty;
            while (words.next()) |w| try attrs.append(arena, w);
            try addStep(arena, &steps, &step_lines, ln, .{ .expect_cell = .{ .row = pos[0], .col = pos[1], .attrs = try attrs.toOwnedSlice(arena) } });
        } else if (std.mem.eql(u8, dir, "expect-mark")) {
            // `A at 3`
            var words = std.mem.tokenizeAny(u8, arg, " \t");
            const letter = words.next() orelse "";
            const at = words.next() orelse "";
            const row = std.fmt.parseInt(u16, words.next() orelse "", 10) catch return fail(diag, ln, "expected LETTER at ROW");
            if (letter.len != 1 or !std.mem.eql(u8, at, "at")) return fail(diag, ln, "expected LETTER at ROW");
            try addStep(arena, &steps, &step_lines, ln, .{ .expect_mark = .{ .letter = letter[0], .row = row } });
        } else return fail(diag, ln, "unknown directive");
    }
    if (cite == null) return fail(diag, 1, "missing @cite");
    if (have_case or steps.items.len > 0) {
        try scripts.append(arena, .{ .name = name, .cite = cite.?, .line = case_line, .steps = try steps.toOwnedSlice(arena), .lines = try step_lines.toOwnedSlice(arena) });
    }
    return scripts.toOwnedSlice(arena);
}

fn addStep(arena: Allocator, steps: *std.ArrayList(Step), lines: *std.ArrayList(u32), line: u32, step: Step) !void {
    try steps.append(arena, step);
    try lines.append(arena, line);
}

fn fail(diag: *Diagnostic, line: u32, msg: []const u8) error{Syntax} {
    diag.* = .{ .line = line, .message = msg };
    return error.Syntax;
}

fn parsePair(s: []const u8, sep: u8) ?[2]u16 {
    const i = std.mem.indexOfScalar(u8, s, sep) orelse return null;
    const a = std.fmt.parseInt(u16, std.mem.trim(u8, s[0..i], " "), 10) catch return null;
    const b = std.fmt.parseInt(u16, std.mem.trim(u8, s[i + 1 ..], " "), 10) catch return null;
    return .{ a, b };
}

fn parseSize(s: []const u8) ?[2]u16 {
    const p = parsePair(s, 'x') orelse return null;
    if (p[0] == 0 or p[1] == 0) return null;
    return p;
}

/// Decodes a quoted string with `\e \r \n \t \a \\ \" \^ \xHH \u{H+}` and
/// `^X` (control X for `X` in `@`-`_`; `^?` is DEL).
pub fn unquote(gpa: Allocator, s: []const u8) ![]u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return error.BadString;
    const body = s[1 .. s.len - 1];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '^' and i + 1 < body.len) {
            const n = body[i + 1];
            if (n == '?') {
                try out.append(gpa, 0x7f);
            } else if (n >= '@' and n <= '_') {
                try out.append(gpa, n - '@');
            } else return error.BadString; // lowercase too: write `\^` for a literal caret
            i += 2;
            continue;
        }
        if (c != '\\') {
            try out.append(gpa, c);
            i += 1;
            continue;
        }
        if (i + 1 >= body.len) return error.BadString;
        const e = body[i + 1];
        i += 2;
        switch (e) {
            'e' => try out.append(gpa, 0x1b),
            'r' => try out.append(gpa, '\r'),
            'n' => try out.append(gpa, '\n'),
            't' => try out.append(gpa, '\t'),
            'a' => try out.append(gpa, 0x07),
            '\\', '"', '^' => try out.append(gpa, e),
            'x' => {
                if (i + 2 > body.len) return error.BadString;
                try out.append(gpa, std.fmt.parseInt(u8, body[i..][0..2], 16) catch return error.BadString);
                i += 2;
            },
            'u' => {
                if (i >= body.len or body[i] != '{') return error.BadString;
                const end = std.mem.indexOfScalarPos(u8, body, i, '}') orelse return error.BadString;
                const cp = std.fmt.parseInt(u21, body[i + 1 .. end], 16) catch return error.BadString;
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadString;
                try out.appendSlice(gpa, buf[0..n]);
                i = end + 1;
            },
            else => return error.BadString,
        }
    }
    return out.toOwnedSlice(gpa);
}

test "unquote escapes" {
    const gpa = std.testing.allocator;
    const got = try unquote(gpa, "\"a\\e[1m^G^[\\x41\\u{1F600}\\\\\\\"\\^\"");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("a\x1b[1m\x07\x1bA\u{1F600}\\\"^", got);
    try std.testing.expectError(error.BadString, unquote(gpa, "\"\\q\""));
    try std.testing.expectError(error.BadString, unquote(gpa, "\"^bar\""));
}

test "parse: cases, screen blocks, errors with line numbers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const src =
        \\# comment
        \\@cite https://example.test#x
        \\@case one
        \\@size 4x2
        \\@send "ab"
        \\@expect-screen
        \\|ab··|
        \\@expect-cursor 1,3
        \\@case two
        \\@expect-cell 1,1 bold fg=1
        \\@expect-mark A at 2
    ;
    const s = try parseFile(arena.allocator(), "f", src, &d);
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqualStrings("one", s[0].name);
    try std.testing.expectEqual(@as(usize, 4), s[0].steps.len);
    try std.testing.expectEqualStrings("ab··", s[0].steps[2].expect_screen[0]);
    try std.testing.expectEqual([2]u16{ 1, 3 }, s[0].steps[3].expect_cursor);
    try std.testing.expectEqual(@as(usize, 2), s[1].steps[0].expect_cell.attrs.len);
    try std.testing.expectError(error.Syntax, parseFile(arena.allocator(), "f", "@size 1x1\n", &d));
    try std.testing.expectEqual(@as(u32, 1), d.line);
    try std.testing.expectError(error.Syntax, parseFile(arena.allocator(), "f", "@cite x\n\n@bogus\n", &d));
    try std.testing.expectEqual(@as(u32, 3), d.line);
}
