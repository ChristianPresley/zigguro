//! Preserve-case replacement (VS Code behaviour): the replacement takes the
//! case pattern of the text it replaces.
//! - Parts separated by `-` or `_`: when the match and the replacement have
//!   the same separator and part count, each part is handled on its own.
//! - All upper (two or more cased letters) -> uppercase replacement.
//! - All lower -> the replacement as typed.
//! - Title (first upper, rest lower) -> first letter capitalized.
//! - camelCase / PascalCase with the same number of segments as the
//!   replacement -> each segment's first letter follows the match's.
//! - Otherwise the first letter follows the match's first letter.

const std = @import("std");
const zg_text = @import("zg_text");

const Allocator = std.mem.Allocator;
const casemap = zg_text.unicode.casemap;

/// Appends `replacement` recased after `matched`.
pub fn apply(out: *std.ArrayList(u8), gpa: Allocator, matched: []const u8, replacement: []const u8) Allocator.Error!void {
    for ([_]u8{ '-', '_' }) |sep| {
        const nm = std.mem.count(u8, matched, &.{sep});
        if (nm > 0 and nm == std.mem.count(u8, replacement, &.{sep})) {
            var im = std.mem.splitScalar(u8, matched, sep);
            var ir = std.mem.splitScalar(u8, replacement, sep);
            var first = true;
            while (im.next()) |pm| {
                const pr = ir.next().?;
                if (!first) try out.append(gpa, sep);
                first = false;
                try applyPart(out, gpa, pm, pr);
            }
            return;
        }
    }
    return applyPart(out, gpa, matched, replacement);
}

fn cased(s: []const u8) usize {
    var n: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |c| {
        if (casemap.caseShape(c) != .uncased) n += 1;
    }
    return n;
}

fn applyPart(out: *std.ArrayList(u8), gpa: Allocator, matched: []const u8, replacement: []const u8) Allocator.Error!void {
    const shape = casemap.caseShape(matched);
    switch (shape) {
        .uncased, .lower => return out.appendSlice(gpa, replacement),
        .upper => {
            if (cased(matched) >= 2) return casemap.toUpper(out, gpa, replacement) catch return error.OutOfMemory;
            return firstLetter(out, gpa, replacement, true);
        },
        .title => return firstLetter(out, gpa, replacement, true),
        .mixed => {
            // camelCase / PascalCase, segment by segment.
            var ms: [16][]const u8 = undefined;
            var rs: [16][]const u8 = undefined;
            const nm = camelSegments(matched, &ms);
            const nr = camelSegments(replacement, &rs);
            if (nm > 1 and nm == nr) {
                for (ms[0..nm], rs[0..nr]) |m, r| try firstLetter(out, gpa, r, casemap.caseShape(firstCp(m)) == .upper);
                return;
            }
            return firstLetter(out, gpa, replacement, casemap.caseShape(firstCp(matched)) == .upper);
        },
    }
}

fn firstCp(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    return s[0..@min(n, s.len)];
}

/// Appends `s` with its first character upper- (or lower-) cased.
fn firstLetter(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8, upper: bool) Allocator.Error!void {
    const f = firstCp(s);
    (if (upper) casemap.toUpper(out, gpa, f) else casemap.toLower(out, gpa, f)) catch return error.OutOfMemory;
    try out.appendSlice(gpa, s[f.len..]);
}

/// Splits at lower-to-upper transitions (`fooBarBaz` -> foo, Bar, Baz).
/// At most `out.len` segments; the last takes the rest.
fn camelSegments(s: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    var prev_lower = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = firstCp(s[i..]);
        const sh = casemap.caseShape(c);
        if (sh == .upper and prev_lower and n + 1 < out.len) {
            out[n] = s[start..i];
            n += 1;
            start = i;
        }
        prev_lower = sh == .lower;
        i += c.len;
    }
    out[n] = s[start..];
    return n + 1;
}
