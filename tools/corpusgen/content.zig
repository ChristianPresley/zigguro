//! File contents (E14.F06.S01.T01): code-like sources, logs, minified
//! JSON, Markdown notes and mixed Unicode text. Every generator writes
//! into a `Sink`, which buffers 64 KiB, hashes with Blake3 and counts
//! bytes and lines. Contents depend only on the PRNG they are given.

const std = @import("std");
const profiles = @import("profiles.zig");
const names = @import("names.zig");

/// Buffered output that hashes and counts what passes through it.
pub const Sink = struct {
    buf: []u8,
    len: usize = 0,
    file: ?std.Io.File = null,
    io: ?std.Io = null,
    hasher: std.crypto.hash.Blake3 = .init(.{}),
    bytes: u64 = 0,
    lines: u64 = 0,
    failed: ?anyerror = null,

    pub fn put(s: *Sink, data: []const u8) void {
        var d = data;
        while (d.len > 0) {
            if (s.len == s.buf.len) s.flush();
            const n = @min(d.len, s.buf.len - s.len);
            @memcpy(s.buf[s.len..][0..n], d[0..n]);
            s.len += n;
            d = d[n..];
        }
    }

    pub fn byte(s: *Sink, b: u8) void {
        if (s.len == s.buf.len) s.flush();
        s.buf[s.len] = b;
        s.len += 1;
    }

    pub fn flush(s: *Sink) void {
        const chunk = s.buf[0..s.len];
        s.hasher.update(chunk);
        s.bytes += chunk.len;
        s.lines += std.mem.count(u8, chunk, "\n");
        if (s.file) |f| if (s.failed == null) f.writeStreamingAll(s.io.?, chunk) catch |e| {
            s.failed = e;
        };
        s.len = 0;
    }

    /// Flushes and returns the digest.
    pub fn finish(s: *Sink) [32]u8 {
        s.flush();
        var out: [32]u8 = undefined;
        s.hasher.final(&out);
        return out;
    }

    /// Bytes written so far, including the buffer.
    pub fn written(s: *const Sink) u64 {
        return s.bytes + s.len;
    }
};

/// One line being built (lines stay well under 1 KiB).
const Line = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn put(l: *Line, data: []const u8) void {
        const n = @min(data.len, l.buf.len - l.len);
        @memcpy(l.buf[l.len..][0..n], data[0..n]);
        l.len += n;
    }

    fn text(l: *const Line) []const u8 {
        return l.buf[0..l.len];
    }

    fn indent(l: *Line, depth: usize, tabs: bool) void {
        for (0..depth) |_| l.put(if (tabs) "\t" else "    ");
    }

    fn words(l: *Line, r: std.Random, len: usize) void {
        var n: usize = 0;
        while (n < len) {
            const w = names.syllables[names.pick(r, names.syllables.len)];
            l.put(w);
            l.put(" ");
            n += w.len + 1;
        }
    }
};

/// Puts `text`, cut so the total stays at most `size` (a cut line still
/// ends with a newline).
fn putCapped(s: *Sink, text: []const u8, size: u64) void {
    const remaining = size - s.written();
    if (text.len <= remaining) {
        s.put(text);
    } else if (remaining > 0) {
        s.put(text[0 .. remaining - 1]);
        s.byte('\n');
    }
}

const keywords = [_][]const u8{ "if", "for", "while", "return", "static", "const", "struct", "unsigned", "int", "void", "switch", "case", "break", "goto", "else" };
const ops = [_][]const u8{ " = ", " == ", " != ", " + ", " - ", " & ", " | ", " << ", " -> ", ", ", "; ", "(", ")", "[", "]" };

/// A code line of about `len` bytes after `indent` tabs or spaces.
fn codeLine(l: *Line, r: std.Random, len: usize, indent: usize, tabs: bool, scratch: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    scratch.clearRetainingCapacity();
    l.indent(indent, tabs);
    while (scratch.items.len < len) {
        switch (r.uintLessThan(u8, 6)) {
            0 => scratch.appendSlice(gpa, keywords[names.pick(r, keywords.len)]) catch {},
            1, 2 => scratch.appendSlice(gpa, ops[names.pick(r, ops.len)]) catch {},
            3 => scratch.print(gpa, "{d}", .{r.uintLessThan(u32, 4096)}) catch {},
            else => names.identifier(r, scratch, gpa, 1, 3, '_') catch {},
        }
        if (r.uintLessThan(u8, 3) == 0) scratch.append(gpa, ' ') catch {};
    }
    l.put(scratch.items);
}

/// Source-like text of exactly `size` bytes: 70 % code lines, 20 %
/// comments, 10 % blank, with braces moving the indentation.
pub fn source(s: *Sink, r: std.Random, size: u64, tabs: bool, gpa: std.mem.Allocator) void {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var depth: usize = 0;
    while (s.written() < size) {
        var l: Line = .{};
        const kind = r.uintLessThan(u8, 10);
        const len = profiles.pickBucket(u8, r, &profiles.line_lengths);
        if (kind < 7) {
            codeLine(&l, r, len, depth, tabs, &scratch, gpa);
            const opener = r.uintLessThan(u8, 8);
            if (opener == 0 and depth < 6) {
                l.put(" {");
                depth += 1;
            } else if (opener == 1 and depth > 0) {
                depth -= 1;
                l.put(";\n");
                l.indent(depth, tabs);
                l.put("}");
            } else l.put(";");
        } else if (kind < 9) {
            l.indent(depth, tabs);
            l.put("/* ");
            l.words(r, len);
            l.put("*/");
        }
        l.put("\n");
        putCapped(s, l.text(), size);
    }
}

/// `lines` Zig-like lines (the `lines_100k` file).
pub fn zigLines(s: *Sink, r: std.Random, lines: u64, gpa: std.mem.Allocator) void {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var depth: usize = 0;
    for (0..lines) |_| {
        var l: Line = .{};
        const len = profiles.pickBucket(u8, r, &profiles.line_lengths);
        switch (r.uintLessThan(u8, 10)) {
            0 => {
                l.indent(depth, false);
                l.put("// ");
                l.words(r, len);
            },
            1 => {},
            2 => if (depth < 5) {
                l.indent(depth, false);
                l.put("pub fn ");
                scratch.clearRetainingCapacity();
                names.identifier(r, &scratch, gpa, 1, 3, '_') catch {};
                l.put(scratch.items);
                l.put("(x: u32) u32 {");
                depth += 1;
            },
            3 => if (depth > 0) {
                depth -= 1;
                l.indent(depth, false);
                l.put("}");
            },
            else => {
                codeLine(&l, r, len, depth, false, &scratch, gpa);
                l.put(";");
            },
        }
        l.put("\n");
        s.put(l.text());
    }
}

const levels = [_][]const u8{ "DEBUG", "INFO ", "INFO ", "INFO ", "WARN ", "ERROR" };

/// Log lines with increasing timestamps, `size` bytes.
pub fn log(s: *Sink, r: std.Random, size: u64, gpa: std.mem.Allocator) void {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var ms: u64 = 0;
    while (s.written() < size) {
        ms += 1 + r.uintLessThan(u64, 250);
        var l: Line = .{};
        var tb: [64]u8 = undefined;
        const sec = ms / 1000;
        l.put(std.fmt.bufPrint(&tb, "2026-10-21T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z ", .{ (sec / 3600) % 24, (sec / 60) % 60, sec % 60, ms % 1000 }) catch "");
        l.put(levels[names.pick(r, levels.len)]);
        l.put(" ");
        scratch.clearRetainingCapacity();
        names.identifier(r, &scratch, gpa, 1, 2, '.') catch {};
        l.put(scratch.items);
        l.put(": ");
        l.words(r, profiles.pickBucket(u8, r, &profiles.line_lengths));
        l.put("\n");
        putCapped(s, l.text(), size);
    }
}

/// One line of JSON/JS-like tokens, `size` bytes including the final
/// newline.
pub fn minified(s: *Sink, r: std.Random, size: u64, gpa: std.mem.Allocator) void {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    s.put("[");
    while (s.written() + 2 < size) {
        scratch.clearRetainingCapacity();
        scratch.appendSlice(gpa, "{\"") catch {};
        names.identifier(r, &scratch, gpa, 1, 2, '_') catch {};
        scratch.print(gpa, "\":{d},\"v\":\"", .{r.uintLessThan(u32, 100000)}) catch {};
        names.identifier(r, &scratch, gpa, 1, 3, '-') catch {};
        scratch.appendSlice(gpa, "\"},") catch {};
        const remaining = size - 2 - s.written();
        s.put(scratch.items[0..@min(scratch.items.len, remaining)]);
    }
    if (s.written() + 2 <= size) s.put("]");
    s.byte('\n');
}

const tags = [_][]const u8{ "project", "idea", "todo", "meeting", "reference", "draft", "zig", "perf", "design", "review" };

/// One Markdown note linking to `links` (names without `.md`).
pub fn note(s: *Sink, r: std.Random, title: []const u8, links: []const []const u8, gpa: std.mem.Allocator) void {
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    s.put("---\ntitle: ");
    s.put(title);
    s.put("\ntags: [");
    const nt = 1 + names.pick(r, 3);
    for (0..nt) |i| {
        if (i > 0) s.put(", ");
        s.put(tags[names.pick(r, tags.len)]);
    }
    var db: [32]u8 = undefined;
    s.put("]\ncreated: ");
    s.put(std.fmt.bufPrint(&db, "2026-{d:0>2}-{d:0>2}", .{ 1 + r.uintLessThan(u8, 12), 1 + r.uintLessThan(u8, 28) }) catch "");
    s.put("\n---\n\n# ");
    s.put(title);
    s.put("\n\n");
    var li: usize = 0;
    const sections = 1 + names.pick(r, 4);
    for (0..sections) |sec| {
        if (sec > 0) {
            s.put("## ");
            scratch.clearRetainingCapacity();
            names.identifier(r, &scratch, gpa, 1, 3, ' ') catch {};
            s.put(scratch.items);
            s.put("\n\n");
        }
        const sentences = 2 + names.pick(r, 6);
        for (0..sentences) |_| {
            const words = 4 + names.pick(r, 12);
            for (0..words) |w| {
                if (w > 0) s.byte(' ');
                if (li < links.len and r.uintLessThan(u8, 10) == 0) {
                    s.put("[[");
                    s.put(links[li]);
                    s.put("]]");
                    li += 1;
                } else s.put(names.syllables[names.pick(r, names.syllables.len)]);
            }
            s.put(". ");
        }
        s.put("\n\n");
    }
    // Links that did not land in the text go in a list.
    while (li < links.len) : (li += 1) {
        s.put("- [[");
        s.put(links[li]);
        s.put("]]\n");
    }
}

/// Assigned codepoints only: CJK unified ideographs, Hebrew and Arabic
/// letters, Latin letters with combining marks, and emoji ZWJ sequences.
const cjk = [2]u21{ 0x4E00, 0x9FA5 };
const hebrew = [2]u21{ 0x05D0, 0x05EA };
const arabic = [2]u21{ 0x0627, 0x064A };
const combining = [_]u21{ 0x0300, 0x0301, 0x0302, 0x0303, 0x0308, 0x030A, 0x0327 };
const zwj_sequences = [_][]const u8{
    "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
    "\u{1F469}\u{200D}\u{1F4BB}",
    "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}",
    "\u{1F9D1}\u{1F3FD}\u{200D}\u{1F680}",
    "\u{2764}\u{FE0F}\u{200D}\u{1F525}",
};

fn putCp(s: *Sink, cp: u21) void {
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &b) catch return;
    s.put(b[0..n]);
}

/// Mixed-script text of `size` bytes (lines never split a character:
/// the last bytes are ASCII padding).
pub fn unicode(s: *Sink, r: std.Random, size: u64) void {
    while (s.written() + 32 < size) {
        switch (r.uintLessThan(u8, 6)) {
            0, 1 => for (0..4 + names.pick(r, 12)) |_| putCp(s, cjk[0] + r.uintLessThan(u21, cjk[1] - cjk[0] + 1)),
            2 => for (0..3 + names.pick(r, 8)) |_| putCp(s, hebrew[0] + r.uintLessThan(u21, hebrew[1] - hebrew[0] + 1)),
            3 => for (0..3 + names.pick(r, 8)) |_| putCp(s, arabic[0] + r.uintLessThan(u21, arabic[1] - arabic[0] + 1)),
            4 => for (0..3 + names.pick(r, 6)) |_| {
                s.byte('a' + r.uintLessThan(u8, 26));
                if (r.boolean()) putCp(s, combining[names.pick(r, combining.len)]);
            },
            else => s.put(zwj_sequences[names.pick(r, zwj_sequences.len)]),
        }
        s.byte(if (r.uintLessThan(u8, 8) == 0) '\n' else ' ');
    }
    while (s.written() + 1 < size) s.byte('.');
    s.byte('\n');
}

test "corpusgen content: exact sizes and valid text" {
    const gpa = std.testing.allocator;
    var buf: [64 * 1024]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(3);
    for ([_]u64{ 1, 2, 100, 6144, 70_000 }) |size| {
        var s: Sink = .{ .buf = &buf };
        source(&s, prng.random(), size, true, gpa);
        _ = s.finish();
        try std.testing.expectEqual(size, s.bytes);
        var l: Sink = .{ .buf = &buf };
        log(&l, prng.random(), size, gpa);
        _ = l.finish();
        try std.testing.expectEqual(size, l.bytes);
    }
    var m: Sink = .{ .buf = &buf };
    minified(&m, prng.random(), 10_000, gpa);
    _ = m.finish();
    try std.testing.expectEqual(@as(u64, 10_000), m.bytes);
    try std.testing.expectEqual(@as(u64, 1), m.lines);
}
