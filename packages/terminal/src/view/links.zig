//! Links in terminal output (E06.F05.S03.T02, first cut): explicit OSC 8
//! hyperlinks, then URLs and file references found in the text.
//!
//! `Detector.linkAt` looks at the logical line (soft wraps joined) under a
//! cell, so it costs one line's text and a few regex passes, run on hover.
//! Patterns, tried in order:
//! - URLs with a scheme (`https://`, `file://`, `ssh://`, ...), trailing
//!   punctuation and unbalanced closing brackets trimmed;
//! - Python tracebacks, `File "path", line N`;
//! - `path:line[:col]` (gcc, clang, zig, rustc, tsc, Go, Node frames) and
//!   `path(line[,col])` (MSBuild, tsc), Windows drive letters included;
//! - bare paths with a directory separator and an extension (`src/a.zig`).
//!
//! The owner decides what opening means (`TerminalView.on_open_link`):
//! whether a file exists, which schemes open. Open: grouping OSC 8 cells
//! by `id=`, a resolver that hides file links until they are known to
//! exist, and the agent hook over command blocks.

const std = @import("std");
const zg_terminal = @import("zg_terminal");
const zg_regex = @import("zg_regex");
const sel = @import("selection.zig");
const search = @import("search.zig");

const Allocator = std.mem.Allocator;
const PageList = zg_terminal.screen.PageList;
const Point = sel.Point;

/// What a link points at. Slices live as long as the `Link`'s owner says.
pub const Target = union(enum) {
    uri: []const u8,
    file: File,

    pub const File = struct { path: []const u8, line: ?u32 = null, col: ?u32 = null };
};

/// A link: its cells (inclusive) and target.
pub const Link = struct {
    lo: Point,
    hi: Point,
    target: Target,
    /// From OSC 8 rather than found in the text.
    explicit: bool = false,

    /// Whether it covers cell `p`.
    pub fn contains(l: *const Link, p: Point, cols: u16) bool {
        const s: sel.Selection = .{ .kind = .stream, .anchor_lo = l.lo, .anchor_hi = l.hi, .lo = l.lo, .hi = l.hi };
        return s.contains(p, cols);
    }
};

const url_pattern = "\\b(?:https?|file|ftp|mailto|ssh|git)://[^\\s<>\"'`]+";
const python_pattern = "File \"([^\"]+)\", line (\\d+)";
const file_line_pattern = "(?:[A-Za-z]:)?[\\w./\\\\~-]*[\\w~-]\\.\\w+(?::\\d+(?::\\d+)?|\\(\\d+(?:,\\d+)?\\))";
const path_pattern = "(?:[A-Za-z]:)?[\\w.~-]*(?:[/\\\\][\\w.~-]+)+\\.\\w+";

/// The compiled patterns and scratch space for finding links.
pub const Detector = struct {
    gpa: Allocator,
    url: zg_regex.Regex,
    python: zg_regex.Regex,
    file_line: zg_regex.Regex,
    path: zg_regex.Regex,
    text: std.ArrayList(u8) = .empty,
    rows: std.ArrayList(search.RowStart) = .empty,
    /// Holds the strings of the last link returned.
    out: std.ArrayList(u8) = .empty,

    pub fn init(gpa: Allocator) !Detector {
        var url = try zg_regex.Regex.compile(gpa, url_pattern, .{});
        errdefer url.deinit(gpa);
        var python = try zg_regex.Regex.compile(gpa, python_pattern, .{});
        errdefer python.deinit(gpa);
        var file_line = try zg_regex.Regex.compile(gpa, file_line_pattern, .{});
        errdefer file_line.deinit(gpa);
        const path = try zg_regex.Regex.compile(gpa, path_pattern, .{});
        return .{ .gpa = gpa, .url = url, .python = python, .file_line = file_line, .path = path };
    }

    pub fn deinit(d: *Detector) void {
        d.url.deinit(d.gpa);
        d.python.deinit(d.gpa);
        d.file_line.deinit(d.gpa);
        d.path.deinit(d.gpa);
        d.text.deinit(d.gpa);
        d.rows.deinit(d.gpa);
        d.out.deinit(d.gpa);
    }

    /// The link over cell `at`, or null. Its strings stay valid until the
    /// next call.
    pub fn linkAt(d: *Detector, pl: *const PageList, at: Point) !?Link {
        if (try d.explicitAt(pl, at)) |l| return l;
        const line = sel.lineBounds(pl, at);
        d.text.clearRetainingCapacity();
        d.rows.clearRetainingCapacity();
        try search.buildText(pl, d.gpa, &d.text, &d.rows, line[0].row, line[1].row);
        if (try d.find(pl, &d.url, at, .url)) |l| return l;
        if (try d.find(pl, &d.python, at, .python)) |l| return l;
        if (try d.find(pl, &d.file_line, at, .file_line)) |l| return l;
        return d.find(pl, &d.path, at, .path);
    }

    const Kind = enum { url, python, file_line, path };

    fn find(d: *Detector, pl: *const PageList, re: *const zg_regex.Regex, at: Point, kind: Kind) !?Link {
        var cache = try re.newCache(d.gpa);
        defer cache.deinit();
        var it = re.findIter(&cache, zg_regex.Input.fromSlice(d.text.items));
        while (it.next()) |m| {
            var start: usize = @intCast(m.start);
            var end: usize = @intCast(m.end);
            if (kind == .url) end = start + trimUrl(d.text.items[start..end]);
            if (kind == .python) {
                // Just the quoted path and the line number.
                start += "File \"".len;
            }
            if (end <= start) continue;
            const lo = search.pointAt(pl, d.rows.items, @intCast(start)) orelse continue;
            const hi = search.pointAt(pl, d.rows.items, @intCast(end - 1)) orelse continue;
            var link: Link = .{ .lo = lo, .hi = hi, .target = undefined };
            if (!link.contains(at, pl.cols)) continue;
            const s = d.text.items[@intCast(m.start)..end];
            link.target = switch (kind) {
                .url => .{ .uri = try d.keep(s) },
                .python => blk: {
                    const q = std.mem.indexOfScalarPos(u8, s, "File \"".len, '"') orelse continue;
                    const digits = s[std.mem.lastIndexOfScalar(u8, s, ' ').? + 1 ..];
                    break :blk .{ .file = .{ .path = try d.keep(s["File \"".len..q]), .line = std.fmt.parseInt(u32, digits, 10) catch null } };
                },
                .file_line, .path => .{ .file = try d.parseFile(s) },
            };
            return link;
        }
        return null;
    }

    /// `path:line:col`, `path(line,col)` or a bare path.
    fn parseFile(d: *Detector, s: []const u8) !Target.File {
        if (s.len > 0 and s[s.len - 1] == ')') if (std.mem.lastIndexOfScalar(u8, s, '(')) |open| {
            var nums = std.mem.splitScalar(u8, s[open + 1 .. s.len - 1], ',');
            const line = std.fmt.parseInt(u32, nums.next() orelse "", 10) catch null;
            const col = if (nums.next()) |c| std.fmt.parseInt(u32, c, 10) catch null else null;
            return .{ .path = try d.keep(s[0..open]), .line = line, .col = col };
        };
        // Trailing `:N` or `:N:N` (a drive letter's colon is followed by
        // a separator, not digits).
        var path = s;
        var nums: [2]?u32 = .{ null, null };
        var n: usize = 0;
        while (n < 2) : (n += 1) {
            const c = std.mem.lastIndexOfScalar(u8, path, ':') orelse break;
            const v = std.fmt.parseInt(u32, path[c + 1 ..], 10) catch break;
            nums[n] = v;
            path = path[0..c];
        }
        const line, const col = switch (n) {
            0 => .{ null, null },
            1 => .{ nums[0], null },
            else => .{ nums[1], nums[0] },
        };
        return .{ .path = try d.keep(path), .line = line, .col = col };
    }

    /// A copy of `s` that lives until the next `linkAt`.
    fn keep(d: *Detector, s: []const u8) ![]const u8 {
        d.out.clearRetainingCapacity();
        try d.out.appendSlice(d.gpa, s);
        return d.out.items;
    }

    /// The OSC 8 link of the cell, spanning the neighbouring cells on the
    /// row with the same URI.
    fn explicitAt(d: *Detector, pl: *const PageList, at: Point) !?Link {
        const pin = sel.rowPin(pl, at.row) orelse return null;
        const cells = pin.cells();
        if (at.col >= cells.len) return null;
        const page = &pin.node.page;
        const id = page.linkId(&cells[at.col]) orelse return null;
        const link = page.hyperlinkOf(&cells[at.col]) orelse return null;
        const uri = link.uri;
        var lo = at.col;
        while (lo > 0 and page.linkId(&cells[lo - 1]) == id) lo -= 1;
        var hi = at.col;
        while (hi + 1 < cells.len and page.linkId(&cells[hi + 1]) == id) hi += 1;
        return .{ .lo = .{ .row = at.row, .col = lo }, .hi = .{ .row = at.row, .col = hi }, .target = .{ .uri = try d.keep(uri) }, .explicit = true };
    }
};

/// The length of `s` without trailing punctuation and unbalanced closing
/// brackets.
pub fn trimUrl(s: []const u8) usize {
    var n = s.len;
    while (n > 0) {
        const c = s[n - 1];
        switch (c) {
            '.', ',', ';', ':', '!', '?' => n -= 1,
            ')', ']', '}' => {
                const open: u8 = switch (c) {
                    ')' => '(',
                    ']' => '[',
                    else => '{',
                };
                if (std.mem.count(u8, s[0..n], &.{open}) >= std.mem.count(u8, s[0..n], &.{c})) break;
                n -= 1;
            },
            else => break,
        }
    }
    return n;
}

const testing = std.testing;

const Got = struct {
    uri: bool,
    buf: [256]u8,
    len: usize,
    line: ?u32,
    col: ?u32,
    lo: u16,
    hi: u16,

    fn str(g: *const Got) []const u8 {
        return g.buf[0..g.len];
    }
};

fn linkIn(text: []const u8, col: u16) !?Got {
    var t: zg_terminal.Terminal = try .init(testing.allocator, .{ .cols = 100, .rows = 3 });
    defer t.deinit();
    t.feed(text);
    const pl = &t.screen().pages;
    var d = try Detector.init(testing.allocator);
    defer d.deinit();
    const r0 = sel.absRow(pl, pl.activeRow(0));
    const l = (try d.linkAt(pl, .{ .row = r0, .col = col })) orelse return null;
    var g: Got = .{ .uri = l.target == .uri, .buf = undefined, .len = 0, .line = null, .col = null, .lo = l.lo.col, .hi = l.hi.col };
    const s = switch (l.target) {
        .uri => |u| u,
        .file => |f| blk: {
            g.line = f.line;
            g.col = f.col;
            break :blk f.path;
        },
    };
    @memcpy(g.buf[0..s.len], s);
    g.len = s.len;
    return g;
}

fn expectFile(text: []const u8, col: u16, path: []const u8, line: ?u32, c: ?u32) !void {
    const got = (try linkIn(text, col)) orelse return error.NoLink;
    try testing.expect(!got.uri);
    try testing.expectEqualStrings(path, got.str());
    try testing.expectEqual(line, got.line);
    try testing.expectEqual(c, got.col);
}

test "links: compiler, runner and traceback formats" {
    try expectFile("src/main.zig:12:5: error: oops", 3, "src/main.zig", 12, 5);
    try expectFile("  --> src/main.rs:3:5", 8, "src/main.rs", 3, 5);
    try expectFile("file.ts(12,5): error TS2322", 2, "file.ts", 12, 5);
    try expectFile("C:\\work\\a.cpp(7): warning", 4, "C:\\work\\a.cpp", 7, null);
    try expectFile("  File \"/usr/lib/x.py\", line 42, in f", 10, "/usr/lib/x.py", 42, null);
    try expectFile("    at run (/app/index.js:10:3)", 15, "/app/index.js", 10, 3);
    try expectFile("main.go:8 +0x1d", 2, "main.go", 8, null);
    try expectFile("edit lib/util.zig now", 8, "lib/util.zig", null, null);
    // Plain words and version numbers are not links.
    try testing.expect(try linkIn("version 1.2 is out", 9) == null);
    try testing.expect(try linkIn("hello world", 2) == null);
}

test "links: URLs, trimmed punctuation and brackets" {
    var got = (try linkIn("see https://x.io/a_(b). next", 8)).?;
    try testing.expectEqualStrings("https://x.io/a_(b)", got.str());
    got = (try linkIn("(https://x.io/q), done", 5)).?;
    try testing.expectEqualStrings("https://x.io/q", got.str());
    try testing.expectEqual(@as(u16, 1), got.lo);
    try testing.expectEqual(@as(u16, 14), got.hi);
    // Outside the URL: nothing.
    try testing.expect(try linkIn("(https://x.io/q), done", 20) == null);
}

test "links: OSC 8 spans its cells" {
    const got = (try linkIn("a \x1b]8;;https://ziglang.org\x1b\\Zig site\x1b]8;;\x1b\\ b", 4)).?;
    try testing.expectEqualStrings("https://ziglang.org", got.str());
    try testing.expectEqual(@as(u16, 2), got.lo);
    try testing.expectEqual(@as(u16, 9), got.hi);
}
