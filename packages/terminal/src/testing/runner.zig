//! Runs `.vtt` conformance cases headlessly against `Terminal` and reports
//! failures with the expected and actual screen, cursor, cell attributes
//! and replies. Invariants are checked after every step.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const Terminal = @import("../term/Terminal.zig");
const PageList = @import("../screen/PageList.zig");
const style = @import("../screen/style.zig");
const Cell = @import("../screen/cell.zig").Cell;
const mark = @import("../shell/mark.zig");
const vtt = @import("vtt.zig");
const dump = @import("dump.zig");
const invariants = @import("invariants.zig");

/// A file the scripts can `@send-file`, by path relative to the corpus root.
pub const File = struct { []const u8, []const u8 };

/// Run options.
pub const RunOptions = struct {
    /// Source file name, for messages.
    file: []const u8 = "",
    /// Files for `@send-file`.
    files: []const File = &.{},
};

/// The outcome of one case.
pub const RunResult = struct {
    passed: bool,
    /// The failure report (empty when passed), owned by the caller's `gpa`.
    report: []u8,

    /// Frees the report.
    pub fn deinit(r: *RunResult, gpa: Allocator) void {
        gpa.free(r.report);
    }
};

const default_size: [2]u16 = .{ 80, 24 };

/// Records marks with their 1-based active-area row.
const Marks = struct {
    gpa: Allocator,
    t: *Terminal = undefined,
    list: std.ArrayList(struct { letter: u8, row: u16 }) = .empty,
    /// Index of the next mark `@expect-mark` may match.
    next: usize = 0,

    fn sink(m: *Marks) mark.MarkSink {
        return .{ .ctx = m, .onMarkFn = onMark };
    }

    fn onMark(ctx: *anyopaque, m: mark.Mark, at: PageList.Pin) void {
        const self: *Marks = @ptrCast(@alignCast(ctx));
        const letter: u8 = switch (m) {
            .prompt_start => 'A',
            .input_start => 'B',
            .command_executed => 'C',
            .command_finished => 'D',
            .command_line => 'E',
            .property => 'P',
            .cwd => 'W',
            .bookmark => 'M',
        };
        const pl = &dump.activeScreen(self.t).pages;
        const abs = pl.rowIndex(at);
        const sb = pl.scrollbackRows();
        const row: u16 = if (abs >= sb) @intCast(abs - sb + 1) else 0;
        self.list.append(self.gpa, .{ .letter = letter, .row = row }) catch {};
    }
};

/// Runs `s` on a fresh terminal. The terminal is created at the first step
/// that is not `@size` (80x24 unless a `@size` came first).
pub fn run(gpa: Allocator, s: vtt.Script, o: RunOptions) !RunResult {
    var size = default_size;
    var term: ?Terminal = null;
    defer if (term) |*t| t.deinit();
    var marks: Marks = .{ .gpa = gpa };
    defer marks.list.deinit(gpa);
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    const w = &report.writer;

    for (s.steps, s.lines) |step, line| {
        if (step == .size and term == null) {
            size = step.size;
            continue;
        }
        if (term == null) {
            term = try Terminal.init(gpa, .{ .cols = size[0], .rows = size[1] });
            marks.t = &term.?;
            term.?.mark_sink = marks.sink();
        }
        const t = &term.?;
        const ok = try runStep(gpa, t, &marks, step, o, w);
        if (ok) {
            invariants.checkInvariants(t) catch |err| {
                try w.print("invariant broken after this step: {t}\n", .{err});
                try writeState(gpa, t, w);
                return failed(gpa, s, o, line, &report);
            };
            continue;
        }
        try writeState(gpa, t, w);
        return failed(gpa, s, o, line, &report);
    }
    return .{ .passed = true, .report = try gpa.dupe(u8, "") };
}

fn failed(gpa: Allocator, s: vtt.Script, o: RunOptions, line: u32, report: *std.Io.Writer.Allocating) !RunResult {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("FAIL {s}:{d}: {s}\n  cite: {s}\n", .{ o.file, line, s.name, s.cite });
    try out.writer.writeAll(report.written());
    return .{ .passed = false, .report = try out.toOwnedSlice() };
}

/// Runs one step; false (with a message in `w`) when an expectation fails.
fn runStep(gpa: Allocator, t: *Terminal, marks: *Marks, step: vtt.Step, o: RunOptions, w: *std.Io.Writer) !bool {
    switch (step) {
        .size, .resize => |sz| try t.resize(sz[0], sz[1]),
        .send => |bytes| t.feed(bytes),
        .send_file => |name| {
            for (o.files) |f| if (std.mem.eql(u8, f[0], name)) {
                t.feed(f[1]);
                return true;
            };
            try w.print("@send-file: no file {s} under testdata/conformance\n", .{name});
            return false;
        },
        .mode_2027 => |on| t.feed(if (on) "\x1b[?2027h" else "\x1b[?2027l"),
        .expect_screen => |want| return expectScreen(gpa, t, want, w),
        .expect_scrollback => |want| return expectScrollback(gpa, t, want, w),
        .expect_cursor => |rc| {
            const c = dump.activeScreen(t).cursor;
            if (c.y + 1 == rc[0] and c.x + 1 == rc[1]) return true;
            try w.print("@expect-cursor: expected {d},{d}, got {d},{d}\n", .{ rc[0], rc[1], c.y + 1, c.x + 1 });
            return false;
        },
        .expect_reply => |want| {
            if (std.mem.eql(u8, want, t.replies.items)) {
                t.clearReplies();
                return true;
            }
            try w.print("@expect-reply:\n  expected \"{f}\"\n  got      \"{f}\"\n", .{ std.zig.fmtString(want), std.zig.fmtString(t.replies.items) });
            return false;
        },
        .expect_title => |want| {
            if (std.mem.eql(u8, want, t.title.items)) return true;
            try w.print("@expect-title: expected \"{f}\", got \"{f}\"\n", .{ std.zig.fmtString(want), std.zig.fmtString(t.title.items) });
            return false;
        },
        .expect_cell => |e| return expectCell(t, e, w),
        .expect_mark => |e| {
            while (marks.next < marks.list.items.len) {
                const m = marks.list.items[marks.next];
                marks.next += 1;
                if (m.letter != e.letter) continue;
                if (m.row == e.row) return true;
                try w.print("@expect-mark: {c} is at row {d}, expected {d}\n", .{ e.letter, m.row, e.row });
                return false;
            }
            try w.print("@expect-mark: no further {c} mark\n", .{e.letter});
            return false;
        },
    }
    return true;
}

/// Rows past the expected ones must be blank.
fn expectScreen(gpa: Allocator, t: *Terminal, want: []const []const u8, w: *std.Io.Writer) !bool {
    const got = try screenLines(gpa, t, .screen);
    defer freeLines(gpa, got);
    var ok = want.len <= got.len;
    for (got, 0..) |g, i| {
        const exp = if (i < want.len) want[i] else null;
        if (exp) |e| {
            if (!std.mem.eql(u8, e, g)) ok = false;
        } else if (!isBlank(g)) ok = false;
    }
    if (ok) return true;
    try w.writeAll("@expect-screen: mismatch (expected | actual, ! marks a differing row)\n");
    const n = @max(want.len, got.len);
    for (0..n) |i| {
        const e: []const u8 = if (i < want.len) want[i] else "";
        const g: []const u8 = if (i < got.len) got[i] else "";
        const same = if (i < want.len) std.mem.eql(u8, e, g) else isBlank(g);
        try w.print("  {s} |{s}| |{s}|\n", .{ if (same) " " else "!", e, g });
    }
    return false;
}

fn expectScrollback(gpa: Allocator, t: *Terminal, want: []const []const u8, w: *std.Io.Writer) !bool {
    const got = try screenLines(gpa, t, .scrollback);
    defer freeLines(gpa, got);
    const same = want.len == got.len and for (want, got) |e, g| {
        if (!std.mem.eql(u8, e, g)) break false;
    } else true;
    if (same) return true;
    const a = try std.mem.join(gpa, "\n", want);
    defer gpa.free(a);
    const b = try std.mem.join(gpa, "\n", got);
    defer gpa.free(b);
    try w.print("@expect-scrollback: {d} rows expected, {d} present\n", .{ want.len, got.len });
    try zg_core.testkit.diff.unifiedDiff(gpa, a, b, 3, w);
    return false;
}

fn isBlank(line: []const u8) bool {
    var rest = line;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "·")) {
            rest = rest["·".len..];
        } else return false;
    }
    return true;
}

fn screenLines(gpa: Allocator, t: *const Terminal, which: enum { screen, scrollback }) ![][]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    switch (which) {
        .screen => try dump.dumpScreen(t, &out.writer, .{}),
        .scrollback => try dump.dumpScrollback(t, &out.writer, .{}),
    }
    var lines: std.ArrayList([]u8) = .empty;
    errdefer freeLines(gpa, lines.items);
    var it = std.mem.splitScalar(u8, out.written(), '\n');
    while (it.next()) |l| {
        if (it.index == null and l.len == 0) break;
        try lines.append(gpa, try gpa.dupe(u8, l));
    }
    return lines.toOwnedSlice(gpa);
}

fn freeLines(gpa: Allocator, lines: []const []u8) void {
    for (lines) |l| gpa.free(l);
    gpa.free(lines);
}

/// The full state on failure: screen, cursor and unread replies.
fn writeState(gpa: Allocator, t: *Terminal, w: *std.Io.Writer) !void {
    const got = try screenLines(gpa, t, .screen);
    defer freeLines(gpa, got);
    try w.writeAll("  screen:\n");
    for (got) |g| try w.print("    |{s}|\n", .{g});
    const c = dump.activeScreen(t).cursor;
    try w.print("  cursor: {d},{d}{s}\n", .{ c.y + 1, c.x + 1, if (c.pending_wrap) " (pending wrap)" else "" });
    try w.print("  replies: \"{f}\"\n", .{std.zig.fmtString(t.replies.items)});
}

/// Checks `key=value` and flag words on one cell; `!flag` asserts a flag
/// is off and `plain` asserts the default style.
fn expectCell(t: *Terminal, e: vtt.CellExpect, w: *std.Io.Writer) !bool {
    const s = dump.activeScreen(t);
    if (e.row == 0 or e.col == 0 or e.row > s.height() or e.col > s.width()) {
        try w.print("@expect-cell: {d},{d} is outside the screen\n", .{ e.row, e.col });
        return false;
    }
    const p = s.rowPin(e.row - 1);
    const cell = &p.cells()[e.col - 1];
    const page = &p.node.page;
    const st = page.styleOf(cell.*).*;
    var ok = true;
    for (e.attrs) |attr| {
        const good = checkAttr(attr, cell, page, st) catch |err| {
            try w.print("@expect-cell {d},{d}: bad attribute {s} ({t})\n", .{ e.row, e.col, attr, err });
            return false;
        };
        if (!good) {
            ok = false;
            try w.print("@expect-cell {d},{d}: {s} does not hold\n", .{ e.row, e.col, attr });
        }
    }
    if (!ok) {
        try w.print("  cell: char U+{X:0>4} wide={t} fg={f} bg={f} ul={f} underline={t} flags:", .{ cell.codepoint(), cell.wide, fmtColor(st.fg), fmtColor(cellBg(cell.*, st)), fmtColor(st.ul_color), st.underline });
        inline for (flag_names) |name| if (@field(st.flags, name)) try w.print(" {s}", .{name});
        if (page.hyperlinkOf(cell)) |l| try w.print(" link={s}", .{l.uri});
        try w.writeByte('\n');
    }
    return ok;
}

const flag_names = .{ "bold", "faint", "italic", "blink", "inverse", "invisible", "strike", "overline" };

fn checkAttr(attr: []const u8, cell: anytype, page: anytype, st: style.Style) !bool {
    if (std.mem.eql(u8, attr, "plain")) return st.eql(.default);
    if (std.mem.eql(u8, attr, "wide")) return cell.wide == .wide;
    if (std.mem.eql(u8, attr, "underline")) return st.underline != .none;
    if (std.mem.eql(u8, attr, "nolink")) return page.hyperlinkOf(cell) == null;
    const negate = attr[0] == '!';
    const word = if (negate) attr[1..] else attr;
    inline for (flag_names) |name| {
        if (std.mem.eql(u8, word, name)) return @field(st.flags, name) != negate;
    }
    const eq = std.mem.indexOfScalar(u8, attr, '=') orelse return error.UnknownAttribute;
    const key = attr[0..eq];
    const val = attr[eq + 1 ..];
    if (std.mem.eql(u8, key, "fg")) return st.fg.eql(try parseColor(val));
    if (std.mem.eql(u8, key, "bg")) return cellBg(cell.*, st).eql(try parseColor(val));
    if (std.mem.eql(u8, key, "ul")) return st.ul_color.eql(try parseColor(val));
    if (std.mem.eql(u8, key, "underline")) return st.underline == (std.meta.stringToEnum(style.Underline, val) orelse return error.BadUnderline);
    if (std.mem.eql(u8, key, "link")) {
        const l = page.hyperlinkOf(cell) orelse return false;
        return std.mem.eql(u8, l.uri, val);
    }
    if (std.mem.eql(u8, key, "char")) {
        const want = std.unicode.utf8Decode(val) catch return error.BadChar;
        return cell.codepoint() == want;
    }
    return error.UnknownAttribute;
}

/// The background a cell shows: a BCE-erased cell carries its own.
fn cellBg(c: Cell, st: style.Style) style.Color {
    return switch (c.tag) {
        .bg_palette => .palette(@intCast(c.content)),
        .bg_rgb => .rgb(@truncate(c.content >> 16), @truncate(c.content >> 8), @truncate(c.content)),
        .codepoint, .grapheme => st.bg,
    };
}

/// `default`, a palette index `0`-`255`, or `rgb:rrggbb`.
fn parseColor(v: []const u8) !style.Color {
    if (std.mem.eql(u8, v, "default")) return .default;
    if (std.mem.startsWith(u8, v, "rgb:")) {
        const hex = v[4..];
        if (hex.len != 6) return error.BadColor;
        const n = try std.fmt.parseInt(u24, hex, 16);
        return .rgb(@truncate(n >> 16), @truncate(n >> 8), @truncate(n));
    }
    return .palette(try std.fmt.parseInt(u8, v, 10));
}

fn fmtColor(c: style.Color) std.fmt.Alt(style.Color, writeColor) {
    return .{ .data = c };
}

fn writeColor(c: style.Color, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (c.tag) {
        .default => try w.writeAll("default"),
        .palette => try w.print("{d}", .{c.r}),
        .rgb => try w.print("rgb:{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }),
    }
}

/// Parses and runs every case in `files` whose path ends in `.vtt`,
/// writing failure reports to `w`. Returns the number of failed cases.
pub fn runCorpus(gpa: Allocator, files: []const File, w: *std.Io.Writer) !struct { cases: usize, failed: usize } {
    var cases: usize = 0;
    var bad: usize = 0;
    for (files) |f| {
        if (!std.mem.endsWith(u8, f[0], ".vtt")) continue;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        var diag: vtt.Diagnostic = .{};
        const scripts = vtt.parseFile(arena.allocator(), f[0], f[1], &diag) catch |err| {
            try w.print("FAIL {s}:{d}: {s} ({t})\n", .{ f[0], diag.line, diag.message, err });
            bad += 1;
            continue;
        };
        for (scripts) |s| {
            cases += 1;
            var r = try run(gpa, s, .{ .file = f[0], .files = files });
            defer r.deinit(gpa);
            if (!r.passed) {
                bad += 1;
                try w.writeAll(r.report);
            }
        }
    }
    return .{ .cases = cases, .failed = bad };
}

fn runSrc(src: []const u8) !RunResult {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var d: vtt.Diagnostic = .{};
    const scripts = try vtt.parseFile(arena.allocator(), "t.vtt", src, &d);
    return run(gpa, scripts[0], .{ .file = "t.vtt" });
}

test "a passing case" {
    var r = try runSrc(
        \\@cite https://example.test#x
        \\@size 4x2
        \\@send "a\e[1;31mb\e[0m\e[c"
        \\@expect-screen
        \\|ab··|
        \\@expect-cursor 1,3
        \\@expect-cell 1,2 bold fg=1 !italic
        \\@expect-cell 1,1 plain char=a
        \\@expect-reply "\e[?62;22c"
    );
    defer r.deinit(std.testing.allocator);
    if (!r.passed) std.debug.print("{s}", .{r.report});
    try std.testing.expect(r.passed);
}

test "a wrong expectation fails with a readable diff" {
    var r = try runSrc(
        \\@cite https://example.test#x
        \\@size 4x2
        \\@send "ab\r\ncd"
        \\@expect-screen
        \\|ab··|
        \\|cx··|
    );
    defer r.deinit(std.testing.allocator);
    try std.testing.expect(!r.passed);
    try std.testing.expect(std.mem.indexOf(u8, r.report, "t.vtt:4") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.report, "! |cx··| |cd··|") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.report, "cursor: 2,3") != null);
}
