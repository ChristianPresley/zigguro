//! CSV/TSV records (E13.F06.S01.T01): RFC 4180 plus the deviations real
//! files have.
//!
//! RFC 4180: fields separated by the delimiter, records by CRLF; a quoted
//! field may hold delimiters, line breaks and doubled quotes. Also
//! accepted: LF or CR-only line ends, blank lines (skipped), a trailing
//! delimiter, ragged rows (`shape` says whether a row was padded or cut),
//! quotes inside an unquoted field (literal), spaces around a quoted field
//! (dropped), text after a closing quote (the raw field is kept), an
//! unterminated quote (runs to the end of the file), backslash escapes
//! (dialect), and null tokens (`\N`, and empty fields by default).
//!
//! Fields are offsets into the file's bytes; `fieldText` copies only when
//! a field has escapes to undo.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Escape = enum { doubled, backslash };

pub const Dialect = struct {
    delimiter: u8 = ',',
    /// Null when the file never quotes.
    quote: ?u8 = '"',
    escape: Escape = .doubled,
    /// Unquoted fields equal to one of these are null.
    null_tokens: []const []const u8 = &.{"\\N"},
    /// Unquoted empty fields are null.
    empty_is_null: bool = true,
};

pub const Field = struct {
    start: u64,
    len: u32,
    quoted: bool = false,
    has_escapes: bool = false,
};

pub fn isTerminator(c: u8) bool {
    return c == '\n' or c == '\r';
}

pub const CsvReader = struct {
    bytes: []const u8,
    d: Dialect,
    pos: u64 = 0,

    pub fn init(bytes: []const u8, d: Dialect) CsvReader {
        return .{ .bytes = bytes, .d = d };
    }

    /// A reader starting at `offset` (a record start).
    pub fn initAt(bytes: []const u8, d: Dialect, offset: u64) CsvReader {
        return .{ .bytes = bytes, .d = d, .pos = offset };
    }

    /// Reads the next record's fields into `fields` (cleared first).
    /// Returns the record's start offset, or null at the end.
    pub fn nextRecord(r: *CsvReader, fields: *std.ArrayList(Field), gpa: Allocator) Allocator.Error!?u64 {
        fields.clearRetainingCapacity();
        const b = r.bytes;
        var p: usize = @intCast(r.pos);
        while (p < b.len and isTerminator(b[p])) p += 1;
        if (p >= b.len) {
            r.pos = b.len;
            return null;
        }
        const start = p;
        while (true) {
            const f = r.field(&p);
            try fields.append(gpa, f);
            if (p >= b.len) break;
            const c = b[p];
            if (c == r.d.delimiter) {
                p += 1;
                // A delimiter at the end of the record starts an empty field.
                if (p >= b.len or isTerminator(b[p])) {
                    try fields.append(gpa, .{ .start = p, .len = 0 });
                    if (p < b.len) p = endLine(b, p);
                    break;
                }
                continue;
            }
            p = endLine(b, p);
            break;
        }
        r.pos = p;
        return start;
    }

    fn isBlank(r: *const CsvReader, c: u8) bool {
        return (c == ' ' or c == '\t') and c != r.d.delimiter;
    }

    /// One field from `p.*`; leaves `p.*` at the delimiter, terminator or
    /// end.
    fn field(r: *const CsvReader, p: *usize) Field {
        const b = r.bytes;
        const s = p.*;
        var i = s;
        if (r.d.quote) |q| {
            // Spaces before an opening quote are dropped.
            while (i < b.len and r.isBlank(b[i])) i += 1;
            if (i < b.len and b[i] == q) return r.quotedField(p, s, i);
        }
        i = s;
        while (i < b.len and b[i] != r.d.delimiter and !isTerminator(b[i])) i += 1;
        p.* = i;
        return .{ .start = s, .len = @intCast(i - s) };
    }

    fn quotedField(r: *const CsvReader, p: *usize, raw_start: usize, open: usize) Field {
        const b = r.bytes;
        const q = r.d.quote.?;
        var i = open + 1;
        var esc = false;
        var close: ?usize = null;
        while (i < b.len) {
            const c = b[i];
            if (r.d.escape == .backslash and c == '\\' and i + 1 < b.len) {
                esc = true;
                i += 2;
            } else if (c == q) {
                if (r.d.escape == .doubled and i + 1 < b.len and b[i + 1] == q) {
                    esc = true;
                    i += 2;
                } else {
                    close = i;
                    i += 1;
                    break;
                }
            } else i += 1;
        }
        const end = close orelse b.len;
        // Spaces after the closing quote are dropped; other text keeps the
        // whole raw field.
        var j = i;
        while (j < b.len and r.isBlank(b[j])) j += 1;
        if (close != null and j < b.len and b[j] != r.d.delimiter and !isTerminator(b[j])) {
            while (j < b.len and b[j] != r.d.delimiter and !isTerminator(b[j])) j += 1;
            p.* = j;
            return .{ .start = raw_start, .len = @intCast(j - raw_start) };
        }
        p.* = j;
        return .{ .start = open + 1, .len = @intCast(end - open - 1), .quoted = true, .has_escapes = esc };
    }

    /// The field's text, with escapes undone (copied into `arena` only
    /// when it has any).
    pub fn fieldText(r: *const CsvReader, f: Field, arena: Allocator) Allocator.Error![]const u8 {
        const t = r.raw(f);
        if (!f.has_escapes) return t;
        const out = try arena.alloc(u8, t.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            const c = t[i];
            if (r.d.escape == .backslash and c == '\\' and i + 1 < t.len) {
                i += 1;
                out[n] = switch (t[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    else => t[i],
                };
            } else if (r.d.escape == .doubled and c == r.d.quote.? and i + 1 < t.len and t[i + 1] == c) {
                i += 1;
                out[n] = c;
            } else out[n] = c;
            n += 1;
        }
        return out[0..n];
    }

    pub fn raw(r: *const CsvReader, f: Field) []const u8 {
        return r.bytes[@intCast(f.start)..][0..f.len];
    }

    /// Whether the field is null under the dialect's null rules.
    pub fn isNull(r: *const CsvReader, f: Field) bool {
        if (f.quoted) return false;
        if (f.len == 0) return r.d.empty_is_null;
        const t = r.raw(f);
        for (r.d.null_tokens) |tok| if (std.mem.eql(u8, t, tok)) return true;
        return false;
    }
};

/// Past the line end at `p` (CRLF, LF or CR).
fn endLine(b: []const u8, p: usize) usize {
    if (p < b.len and b[p] == '\r') {
        return if (p + 1 < b.len and b[p + 1] == '\n') p + 2 else p + 1;
    }
    return if (p < b.len and b[p] == '\n') p + 1 else p;
}

pub const Shape = enum { ok, padded, truncated };

/// How a record of `n` fields fits `columns`: an extra empty last field
/// (a trailing delimiter) is fine.
pub fn shape(fields: []const Field, columns: usize) Shape {
    if (fields.len == columns) return .ok;
    if (fields.len < columns) return .padded;
    if (fields.len == columns + 1 and fields[fields.len - 1].len == 0 and !fields[fields.len - 1].quoted) return .ok;
    return .truncated;
}
