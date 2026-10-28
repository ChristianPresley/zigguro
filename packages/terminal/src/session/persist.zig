//! Persistent terminal sessions (E06.F05.S04.T02): what a terminal showed,
//! saved when the window closes and shown again, read-only above a
//! separator, when the folder is opened next time, with a fresh shell
//! started below it in the folder it was in.
//!
//! A terminal's content is kept as the escape sequences that redraw it
//! (`capture`): text with SGR styles and OSC 8 links, soft-wrapped rows
//! joined so the text re-wraps at whatever width it is restored at, and
//! the command blocks' OSC 133 / 633 marks in place, so the restored
//! terminal's `Blocks` rebuild them. The marks carry no nonce: restored
//! command lines are untrusted and never run again without asking. Only
//! the primary screen is saved (a full-screen program's screen is not),
//! and only its last `CaptureOptions.lines` logical lines.
//!
//! Nothing else about the session is kept: no environment, no nonce, no
//! pending input. An optional `Redact` hook rewrites the text before it
//! is stored.
//!
//! File format (`terminals.zgts`, little-endian): magic `ZGTS`, version
//! (u16), save time (i64, Unix seconds), record count (u32), the records, then a CRC-32 of everything
//! before it. A record: id (u32), tab group (u32), cols and rows (u16
//! each), owner (u8: 0 user, 1 agent), then length-prefixed (u32) shell,
//! cwd, title, name and agent name, then the content's raw length (u32)
//! and its deflated bytes (length-prefixed). `read` returns null for a
//! missing, foreign, truncated or corrupt file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const flate = std.compress.flate;
const Terminal = @import("../term/Terminal.zig");
const PageList = @import("../screen/PageList.zig");
const Page = @import("../screen/Page.zig");
const Style = @import("../screen/style.zig").Style;
const Color = @import("../screen/style.zig").Color;
const blocks_mod = @import("../shell/blocks.zig");
const Pin = PageList.Pin;

pub const magic = "ZGTS";
pub const version: u16 = 1;
pub const file_name = "terminals.zgts";

pub const Owner = enum(u8) { user = 0, agent = 1 };

/// One terminal as saved.
pub const TerminalRecord = struct {
    id: u32,
    /// Terminals sharing a group were split side by side.
    group: u32 = 0,
    cols: u16,
    rows: u16,
    owner: Owner = .user,
    /// The shell program it ran (empty: the default).
    shell: []const u8 = "",
    /// The folder the shell was last in (empty: unknown).
    cwd: []const u8 = "",
    title: []const u8 = "",
    /// The tab's name, if the user gave one.
    name: []const u8 = "",
    agent_name: []const u8 = "",
    /// The escape sequences that redraw the saved content (`capture`).
    content: []const u8 = "",
};

pub const Snapshot = struct {
    /// When it was saved (Unix seconds, UTC).
    saved_s: i64 = 0,
    terminals: []TerminalRecord = &.{},
    /// Owns every slice in `terminals` when read from a file.
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(s: *Snapshot) void {
        if (s.arena) |*a| a.deinit();
        s.* = .{};
    }
};

/// Rewrites text before it is stored (secrets masked); may change it in
/// place only.
pub const Redact = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, text: []u8) void,
};

pub const CaptureOptions = struct {
    /// `terminal.integrated.persistentSessions.scrollback`: logical lines
    /// kept (0 keeps none).
    lines: u32 = 1000,
};

// ---------------------------------------------------------------------------
// Capture.

/// Appends to `out` the escape sequences that redraw the last
/// `o.lines` logical lines of `term`'s primary screen (through the cursor
/// row), with `blocks`' marks in place when given.
pub fn capture(gpa: Allocator, term: *Terminal, blocks: ?*const blocks_mod.Blocks, o: CaptureOptions, out: *std.ArrayList(u8)) !void {
    if (o.lines == 0) return;
    const s = &term.primary;
    const pl = &s.pages;
    // The last row worth keeping: the cursor's, or a later non-blank one.
    var last = s.rowPin(s.cursor.y);
    var p: ?Pin = last;
    while (p) |pin| : (p = PageList.next(pin)) {
        if (!blankRow(pin)) last = pin;
    }
    // Back `o.lines` logical lines, hot rows only.
    var first = last;
    var lines: u32 = 1;
    while (PageList.prev(first)) |q| {
        if (!q.row().wrap) {
            if (lines == o.lines) break;
            lines += 1;
        }
        first = q;
    }
    var row = pl.evicted + pl.rowIndex(first);
    const items: []const blocks_mod.Block = if (blocks) |b| b.items() else &.{};
    var bi: usize = 0;
    // Blocks that ended before the first row are not replayed.
    while (bi < items.len and blockEnd(items, bi) <= row) bi += 1;

    var w: Writer = .{ .gpa = gpa, .out = out };
    p = first;
    while (p) |pin| : ({
        p = if (pin.node == last.node and pin.y == last.y) null else PageList.next(pin);
        row += 1;
    }) {
        // Marks at the start of the row, in block order: a prompt, an
        // output start, an output end.
        var input_col: ?u16 = null;
        var k = bi;
        while (k < items.len and items[k].prompt <= row) : (k += 1) {
            const blk = &items[k];
            if (blk.prompt == row and !blk.truncated) try w.raw("\x1b]133;A\x07");
            if (blk.input) |in| if (in.row == row) {
                input_col = in.col;
            };
            if (blk.output) |o_row| if (o_row == row and blk.prompt < row) try w.started(blocks.?.commandText(blk.id));
            if (finishesAt(items, k, row) == .start) try w.finish(blk.exit);
        }
        // A prompt and its output on one row: the output mark goes at the
        // end of the row.
        try w.row(pin, input_col);
        k = bi;
        while (k < items.len and items[k].prompt <= row) : (k += 1) {
            const blk = &items[k];
            if (blk.output) |o_row| if (o_row == row and blk.prompt == row) try w.started(blocks.?.commandText(blk.id));
            if (finishesAt(items, k, row) == .end) try w.finish(blk.exit);
        }
        while (bi < items.len and blockEnd(items, bi) <= row) bi += 1;
        const is_last = pin.node == last.node and pin.y == last.y;
        if (!pin.row().wrap and !is_last) try w.raw("\r\n");
    }
    try w.reset();
}

/// Where on `row` block `i`'s output end mark goes: at the start when its
/// output ended on an earlier row or was empty (the next prompt follows on
/// the same row), else at the end of the row.
fn finishesAt(items: []const blocks_mod.Block, i: usize, row: u64) enum { no, start, end } {
    const blk = &items[i];
    const e = blk.end orelse return .no;
    const o = blk.output orelse return .no;
    if (e != row or blk.state != .finished) return .no;
    if (o < row) return .start;
    if (blk.prompt < row and i + 1 < items.len and items[i + 1].prompt == row) return .start;
    return .end;
}

/// The row after a block (its end, else the next block's prompt).
fn blockEnd(items: []const blocks_mod.Block, i: usize) u64 {
    if (items[i].end) |e| return e;
    if (i + 1 < items.len) return items[i + 1].prompt;
    return std.math.maxInt(u64);
}

fn blankRow(p: Pin) bool {
    for (p.cells()) |c| if (!c.isEmpty() or c.style != 0) return false;
    return true;
}

const Writer = struct {
    gpa: Allocator,
    out: *std.ArrayList(u8),
    style: Style = .{},
    link: ?Page.Link = null,

    fn raw(w: *Writer, s: []const u8) !void {
        try w.out.appendSlice(w.gpa, s);
    }

    fn finish(w: *Writer, exit: ?i32) !void {
        try w.reset();
        if (exit) |e| try w.out.print(w.gpa, "\x1b]133;D;{d}\x07", .{e}) else try w.raw("\x1b]133;D\x07");
    }

    fn started(w: *Writer, command: []const u8) !void {
        try w.raw("\x1b]633;E;");
        for (command) |ch| switch (ch) {
            '\\' => try w.raw("\\\\"),
            ';' => try w.raw("\\x3b"),
            0...0x1f, 0x7f => try w.out.print(w.gpa, "\\x{x:0>2}", .{ch}),
            else => try w.out.append(w.gpa, ch),
        };
        try w.raw("\x07\x1b]133;C\x07");
    }

    fn reset(w: *Writer) !void {
        if (w.link != null) try w.raw("\x1b]8;;\x07");
        w.link = null;
        if (!w.style.isDefault()) try w.raw("\x1b[0m");
        w.style = .{};
    }

    /// One row's cells, trailing default blanks dropped; `input_col` gets
    /// an OSC 133 B mark.
    fn row(w: *Writer, p: Pin, input_col: ?u16) !void {
        const page = &p.node.page;
        const cells = p.cells();
        var end = cells.len;
        if (!p.row().wrap) while (end > 0 and cells[end - 1].isEmpty() and cells[end - 1].style == 0 and !cells[end - 1].hyperlink) {
            end -= 1;
        };
        for (cells, 0..) |*c, x| {
            if (input_col) |ic| if (ic == x) try w.raw("\x1b]133;B\x07");
            if (x >= end) {
                if (input_col == null or input_col.? <= x) break;
                continue;
            }
            if (c.wide == .spacer_tail or c.wide == .spacer_head) continue;
            try w.setStyle(page.styleOf(c.*).*);
            try w.setLink(page.hyperlinkOf(c));
            const cp = c.codepoint();
            if (cp == 0) {
                try w.out.append(w.gpa, ' ');
                continue;
            }
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            try w.raw(buf[0..n]);
            if (page.grapheme(c)) |extra| for (extra) |x2| {
                const k = std.unicode.utf8Encode(x2, &buf) catch continue;
                try w.raw(buf[0..k]);
            };
        }
        // Styles and links do not run past the end of a line.
        if (!p.row().wrap) try w.reset();
    }

    fn setLink(w: *Writer, l: ?Page.Link) !void {
        if (l == null and w.link == null) return;
        if (l != null and w.link != null and std.mem.eql(u8, l.?.uri, w.link.?.uri) and std.mem.eql(u8, l.?.id, w.link.?.id)) return;
        if (l) |x| {
            if (x.id.len > 0) try w.out.print(w.gpa, "\x1b]8;id={s};{s}\x07", .{ x.id, x.uri }) else try w.out.print(w.gpa, "\x1b]8;;{s}\x07", .{x.uri});
        } else try w.raw("\x1b]8;;\x07");
        w.link = l;
    }

    fn setStyle(w: *Writer, s: Style) !void {
        if (s.eql(w.style)) return;
        try w.raw("\x1b[0");
        const f = s.flags;
        if (f.bold) try w.raw(";1");
        if (f.faint) try w.raw(";2");
        if (f.italic) try w.raw(";3");
        switch (s.underline) {
            .none => {},
            .single => try w.raw(";4"),
            .double => try w.raw(";4:2"),
            .curly => try w.raw(";4:3"),
            .dotted => try w.raw(";4:4"),
            .dashed => try w.raw(";4:5"),
        }
        if (f.blink) try w.raw(";5");
        if (f.inverse) try w.raw(";7");
        if (f.invisible) try w.raw(";8");
        if (f.strike) try w.raw(";9");
        if (f.overline) try w.raw(";53");
        try w.color(s.fg, 38);
        try w.color(s.bg, 48);
        try w.color(s.ul_color, 58);
        try w.raw("m");
        w.style = s;
    }

    fn color(w: *Writer, c: Color, base: u8) !void {
        switch (c.tag) {
            .default => {},
            .palette => try w.out.print(w.gpa, ";{d}:5:{d}", .{ base, c.r }),
            .rgb => try w.out.print(w.gpa, ";{d}:2::{d}:{d}:{d}", .{ base, c.r, c.g, c.b }),
        }
    }
};

/// The line restored content ends with: a faint rule naming when the
/// session was saved (`saved_s`: Unix seconds, UTC).
pub fn separator(buf: []u8, saved_s: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, saved_s)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "\x1b[0m\r\n\x1b[2m\u{2500}\u{2500} Restored session, saved {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC \u{2500}\u{2500}\x1b[0m\r\n", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch "\r\n";
}

// ---------------------------------------------------------------------------
// File.

/// Encodes `s` (deflating each terminal's content).
pub fn encode(gpa: Allocator, s: *const Snapshot) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, magic);
    try putInt(gpa, &out, u16, version);
    try putInt(gpa, &out, i64, s.saved_s);
    try putInt(gpa, &out, u32, @intCast(s.terminals.len));
    for (s.terminals) |t| {
        try putInt(gpa, &out, u32, t.id);
        try putInt(gpa, &out, u32, t.group);
        try putInt(gpa, &out, u16, t.cols);
        try putInt(gpa, &out, u16, t.rows);
        try out.append(gpa, @intFromEnum(t.owner));
        inline for (.{ "shell", "cwd", "title", "name", "agent_name" }) |f| try putStr(gpa, &out, @field(t, f));
        try putInt(gpa, &out, u32, @intCast(t.content.len));
        const z = try deflate(gpa, t.content);
        defer gpa.free(z);
        try putStr(gpa, &out, z);
    }
    try putInt(gpa, &out, u32, std.hash.Crc32.hash(out.items));
    return out.toOwnedSlice(gpa);
}

/// Decodes a file's bytes; null when they are not a valid snapshot.
pub fn decode(gpa: Allocator, bytes: []const u8) !?Snapshot {
    if (bytes.len < magic.len + 2 + 8 + 4 + 4) return null;
    const body = bytes[0 .. bytes.len - 4];
    if (std.hash.Crc32.hash(body) != std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .little)) return null;
    if (!std.mem.eql(u8, body[0..4], magic)) return null;
    var r: Reader = .{ .b = body, .i = 4 };
    if ((r.int(u16) orelse return null) != version) return null;
    const saved_s = r.int(i64) orelse return null;
    const n = r.int(u32) orelse return null;
    if (n > 1024) return null;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const ts = try a.alloc(TerminalRecord, n);
    for (ts) |*t| {
        t.* = .{
            .id = r.int(u32) orelse return fail(&arena),
            .group = r.int(u32) orelse return fail(&arena),
            .cols = r.int(u16) orelse return fail(&arena),
            .rows = r.int(u16) orelse return fail(&arena),
            .owner = std.enums.fromInt(Owner, r.int(u8) orelse return fail(&arena)) orelse return fail(&arena),
        };
        inline for (.{ "shell", "cwd", "title", "name", "agent_name" }) |f| @field(t, f) = try a.dupe(u8, r.str() orelse return fail(&arena));
        const raw_len = r.int(u32) orelse return fail(&arena);
        if (raw_len > 256 << 20) return fail(&arena);
        const z = r.str() orelse return fail(&arena);
        t.content = (try inflate(a, z, raw_len)) orelse return fail(&arena);
    }
    if (r.i != body.len) return fail(&arena);
    return .{ .saved_s = saved_s, .terminals = ts, .arena = arena };
}

fn fail(arena: *std.heap.ArenaAllocator) ?Snapshot {
    arena.deinit();
    return null;
}

/// Writes `s` to `dir/terminals.zgts`, replacing it atomically.
pub fn write(gpa: Allocator, io: Io, dir: Io.Dir, s: *const Snapshot) !void {
    const bytes = try encode(gpa, s);
    defer gpa.free(bytes);
    var af = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.replace(io);
}

/// Reads `dir/terminals.zgts`: null when absent, of another version or
/// corrupt.
pub fn read(gpa: Allocator, io: Io, dir: Io.Dir) !?Snapshot {
    const bytes = dir.readFileAlloc(io, file_name, gpa, .limited(512 << 20)) catch |e| switch (e) {
        error.FileNotFound => return null,
        error.OutOfMemory => return e,
        else => return null,
    };
    defer gpa.free(bytes);
    return decode(gpa, bytes);
}

/// Deletes the saved snapshot, if any.
pub fn remove(io: Io, dir: Io.Dir) void {
    dir.deleteFile(io, file_name) catch {};
}

const Reader = struct {
    b: []const u8,
    i: usize,

    fn int(r: *Reader, comptime T: type) ?T {
        const n = @sizeOf(T);
        if (r.b.len - r.i < n) return null;
        defer r.i += n;
        return std.mem.readInt(T, r.b[r.i..][0..n], .little);
    }

    fn str(r: *Reader) ?[]const u8 {
        const n = r.int(u32) orelse return null;
        if (r.b.len - r.i < n) return null;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }
};

fn putInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn putStr(gpa: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try putInt(gpa, out, u32, @intCast(s.len));
    try out.appendSlice(gpa, s);
}

fn deflate(gpa: Allocator, raw: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = try .initCapacity(gpa, raw.len / 3 + 64);
    defer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    c.* = try flate.Compress.init(&out.writer, window, .raw, .default);
    try c.writer.writeAll(raw);
    try c.finish();
    return try out.toOwnedSlice();
}

fn inflate(gpa: Allocator, z: []const u8, raw_len: u32) !?[]u8 {
    const out = try gpa.alloc(u8, raw_len);
    errdefer gpa.free(out);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var in: Io.Reader = .fixed(z);
    var d: flate.Decompress = .init(&in, .raw, window);
    d.reader.readSliceAll(out) catch {
        gpa.free(out);
        return null;
    };
    return out;
}
