//! Post-processing (E12.F07.S01.T04): raw model text to the ghost text
//! that is shown, or the reason it is not. In order:
//!
//! 1. A trailing end-token remnant (`<|endoftext`, `<EOT`) is stripped.
//! 2. Line endings follow the document's (CRLF when the prefix has one).
//! 3. Suffix overlap: the longest tail of the completion that is how the
//!    rest of the cursor's line starts (spaces and tabs ignored) is cut, so
//!    `foo(|)` with `bar)` shows `bar`.
//! 4. A single-line request keeps the first line.
//! 5. A multi-line request stops at the first line indented less than the
//!    cursor's line, unless it closes a bracket the completion opened, and
//!    at two blank lines in a row.
//! 6. Closers the completion has in excess are cut from its end when the
//!    rest of the line already has them. Brackets are never added.
//! 7. Empty or blank text, text equal to the line after the cursor's, and
//!    a line that repeats the one above are dropped.
//! 8. At most 30 lines are kept.
//!
//! While streaming (`final == false`) only complete lines count, and steps
//! 1, 3 and 6 wait for the end, so the first whole line shows as soon as
//! it arrives and the ghost grows from there.

const std = @import("std");
const context = @import("context.zig");

const Allocator = std.mem.Allocator;
const CompletionRequest = context.CompletionRequest;

pub const Drop = enum { empty, whitespace_only, duplicate_of_suffix, duplicate_of_prev_line, unbalanced, too_long };

pub const PostResult = union(enum) {
    show: []const u8,
    drop: Drop,
};

pub const max_lines = 30;
/// A single line longer than this is not code worth showing.
pub const max_line_bytes = 1000;

pub fn postprocess(arena: Allocator, req: *const CompletionRequest, raw: []const u8, final: bool) !PostResult {
    var text = raw;
    if (!final) {
        // Complete lines only.
        const nl = std.mem.lastIndexOfScalar(u8, text, '\n') orelse return .{ .drop = .empty };
        text = text[0..nl];
    } else {
        text = stripRemnant(text);
    }
    // Work in LF; convert back at the end.
    const crlf = std.mem.indexOf(u8, req.prefix, "\r\n") != null;
    if (std.mem.indexOfScalar(u8, text, '\r') != null) {
        text = try std.mem.replaceOwned(u8, arena, text, "\r\n", "\n");
    }
    const rest_of_line = firstLine(req.suffix);

    if (final) text = text[0 .. text.len - suffixOverlap(text, rest_of_line)];

    if (!req.multiline) {
        text = firstLine(text);
    } else {
        text = dedentStop(text, indentOf(lastLine(req.prefix)));
    }

    if (final) text = trimExcessClosers(text, rest_of_line);

    if (text.len == 0) return .{ .drop = .empty };
    if (std.mem.trim(u8, text, " \t\n").len == 0) return .{ .drop = .whitespace_only };
    if (firstLine(text).len > max_line_bytes) return .{ .drop = .too_long };

    const trimmed = std.mem.trim(u8, text, " \t\n");
    const next_line = std.mem.trim(u8, nextLine(req.suffix), " \t");
    if (next_line.len > 0 and std.mem.eql(u8, trimmed, next_line)) return .{ .drop = .duplicate_of_suffix };
    if (std.mem.indexOfScalar(u8, text, '\n') == null) {
        const prev = std.mem.trim(u8, prevLine(req.prefix), " \t");
        const cur = try std.mem.concat(arena, u8, &.{ lastLine(req.prefix), text });
        if (prev.len > 0 and std.mem.eql(u8, std.mem.trim(u8, cur, " \t"), prev)) return .{ .drop = .duplicate_of_prev_line };
    }

    text = capLines(text, max_lines);
    if (crlf) text = try std.mem.replaceOwned(u8, arena, text, "\n", "\r\n");
    return .{ .show = text };
}

/// Removes a cut-off end token at the very end (`<|endoftext`, `<EOT`,
/// `<|fim_`): a `<` followed only by token characters.
fn stripRemnant(text: []const u8) []const u8 {
    const lt = std.mem.lastIndexOfScalar(u8, text, '<') orelse return text;
    const tail = text[lt + 1 ..];
    if (tail.len == 0) return text[0..lt];
    if (tail[0] != '|' and !std.ascii.isUpper(tail[0])) return text;
    for (tail) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '|', '>' => {},
        else => return text,
    };
    return std.mem.trimEnd(u8, text[0..lt], " ");
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn lastLine(s: []const u8) []const u8 {
    const nl = std.mem.lastIndexOfScalar(u8, s, '\n') orelse return s;
    return std.mem.trimEnd(u8, s[nl + 1 ..], "\r");
}

fn prevLine(prefix: []const u8) []const u8 {
    const nl = std.mem.lastIndexOfScalar(u8, prefix, '\n') orelse return "";
    const before = std.mem.trimEnd(u8, prefix[0..nl], "\r");
    return lastLine(before);
}

fn nextLine(suffix: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, suffix, '\n') orelse return "";
    return std.mem.trimEnd(u8, firstLine(suffix[nl + 1 ..]), "\r");
}

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| switch (c) {
        ' ' => n += 1,
        '\t' => n += 4,
        else => break,
    };
    return n;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Bytes at the end of `text` that repeat how `rest` starts, spaces and
/// tabs ignored; only within the completion's last line.
pub fn suffixOverlap(text: []const u8, rest_in: []const u8) usize {
    const rest = std.mem.trimEnd(u8, rest_in, "\r");
    if (rest.len == 0) return 0;
    const line_start = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |nl| nl + 1 else 0;
    var i = line_start;
    while (i < text.len) : (i += 1) {
        if (isSpace(text[i])) continue;
        if (prefixIgnoringSpace(text[i..], rest)) return text.len - i;
    }
    return 0;
}

/// `a`, spaces and tabs removed, is how `b` (likewise) starts.
fn prefixIgnoringSpace(a: []const u8, b: []const u8) bool {
    var j: usize = 0;
    var any = false;
    for (a) |c| {
        if (isSpace(c)) continue;
        while (j < b.len and isSpace(b[j])) j += 1;
        if (j == b.len or b[j] != c) return false;
        j += 1;
        any = true;
    }
    return any;
}

/// Cuts a multi-line completion at the first line indented less than
/// `base` (unless it closes a bracket opened in the completion) and before
/// two blank lines in a row.
fn dedentStop(text: []const u8, base: usize) []const u8 {
    var depth: i32 = 0;
    var start: usize = 0;
    var line_no: usize = 0;
    var blanks: usize = 0;
    var last_end: usize = 0;
    while (start <= text.len) : (line_no += 1) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const line = text[start..end];
        const blank = std.mem.trim(u8, line, " \t").len == 0;
        if (line_no > 0) {
            if (blank) {
                blanks += 1;
                if (blanks == 2) return std.mem.trimEnd(u8, text[0..last_end], "\n");
            } else {
                blanks = 0;
                const closes = depth > 0 and isCloser(std.mem.trimStart(u8, line, " \t")[0]);
                if (indentOf(line) < base and !closes) return std.mem.trimEnd(u8, text[0..start -| 1], "\n");
            }
        }
        for (line) |c| switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -= 1,
            else => {},
        };
        if (!blank) last_end = end;
        if (end == text.len) break;
        start = end + 1;
    }
    return text;
}

fn isCloser(c: u8) bool {
    return c == ')' or c == ']' or c == '}';
}

fn opener(c: u8) u8 {
    return switch (c) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        else => 0,
    };
}

/// Cuts closers from the end of `text` that it has more of than openers,
/// when `rest` (the rest of the cursor's line) already has them.
fn trimExcessClosers(text_in: []const u8, rest: []const u8) []const u8 {
    var text = text_in;
    while (true) {
        const t = std.mem.trimEnd(u8, text, " \t;");
        if (t.len == 0) return text;
        const c = t[t.len - 1];
        if (!isCloser(c)) return text;
        const opens = std.mem.count(u8, t, &.{opener(c)});
        const closes = std.mem.count(u8, t, &.{c});
        if (closes <= opens or std.mem.indexOfScalar(u8, rest, c) == null) return text;
        text = t[0 .. t.len - 1];
    }
}

fn capLines(text: []const u8, max: usize) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '\n')) |nl| {
        n += 1;
        if (n == max) return text[0..nl];
        i = nl + 1;
    }
    return text;
}
