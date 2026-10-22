//! Markdown files with an optional `---` YAML frontmatter block, as used
//! by rules, skills, commands and agent definitions (E10.F07.S01.T01).
//!
//! The YAML subset covers what harness files use: block mappings and
//! sequences by indentation (spaces only), flow sequences, plain, single-
//! and double-quoted scalars, `|`/`>` block scalars with chomping, and
//! comments. Anchors, aliases, tags, flow mappings and complex keys are
//! rejected with a position. Scalars stay strings; `decode` converts them
//! into typed structs by reflection.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A parsed file: its frontmatter (null when absent) and the Markdown body.
pub const Doc = struct {
    meta: ?Node,
    body: []const u8,
    /// 1-based line number of the first body line.
    body_line: u32,
};

/// One YAML node. Scalars keep their decoded text.
pub const Node = union(enum) {
    scalar: []const u8,
    seq: []const Node,
    map: []const Entry,

    /// The value of `key` in a mapping (exact match), else null.
    pub fn get(n: Node, key: []const u8) ?Node {
        if (n != .map) return null;
        for (n.map) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }

    /// Writes `n` as compact JSON (mappings keep their order).
    pub fn writeJson(n: Node, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var s: std.json.Stringify = .{ .writer = w };
        try n.stringify(&s);
    }

    fn stringify(n: Node, s: *std.json.Stringify) std.Io.Writer.Error!void {
        switch (n) {
            .scalar => |t| try s.write(t),
            .seq => |items| {
                try s.beginArray();
                for (items) |i| try i.stringify(s);
                try s.endArray();
            },
            .map => |entries| {
                try s.beginObject();
                for (entries) |e| {
                    try s.objectField(e.key);
                    try e.value.stringify(s);
                }
                try s.endObject();
            },
        }
    }
};

/// One mapping entry.
pub const Entry = struct {
    key: []const u8,
    value: Node,
    /// 1-based source line of the key.
    line: u32 = 0,
};

/// Error position and unknown keys. Strings live in the caller's arena.
pub const Diag = struct {
    line: u32 = 0,
    col: usize = 0,
    message: []const u8 = "",
    /// Keys `decode` found no field for (for `/doctor` warnings).
    unknown_keys: std.ArrayList([]const u8) = .empty,
};

/// Parse failures; details are in `Diag`.
pub const ParseError = error{ InvalidFrontmatter, Unsupported, OutOfMemory };

/// Decode failures; details are in `Diag`.
pub const DecodeError = error{ TypeMismatch, MissingField, OutOfMemory };

/// Splits `src` into frontmatter and body and parses the frontmatter.
/// Without a leading `---` line, `meta` is null and the body is the whole
/// file (minus a UTF-8 BOM). Slices point into `src` or `arena`.
pub fn parse(arena: Allocator, src: []const u8, diag: ?*Diag) ParseError!Doc {
    var text = src;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    const first_end = std.mem.indexOfScalar(u8, text, '\n') orelse return .{ .meta = null, .body = text, .body_line = 1 };
    if (!std.mem.eql(u8, trimCr(text[0..first_end]), "---")) return .{ .meta = null, .body = text, .body_line = 1 };

    var lines: std.ArrayList(Line) = .empty;
    var pos = first_end + 1;
    var line_no: u32 = 2;
    var closed: ?usize = null;
    while (pos < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const raw = trimCr(text[pos..end]);
        if (std.mem.eql(u8, raw, "---") or std.mem.eql(u8, raw, "...")) {
            closed = if (end < text.len) end + 1 else text.len;
            break;
        }
        try lines.append(arena, .{ .raw = raw, .no = line_no });
        pos = end + 1;
        line_no += 1;
    }
    const body_start = closed orelse return fail(diag, 1, 1, "frontmatter is not closed by a '---' line", error.InvalidFrontmatter);
    var p: Parser = .{ .arena = arena, .lines = lines.items, .diag = diag };
    try p.prepare();
    const meta: Node = if (p.next() == null) .{ .map = &.{} } else try p.block(0);
    if (p.next()) |i| return p.err(i, p.lines[i].indent, "unexpected indentation", error.InvalidFrontmatter);
    return .{ .meta = meta, .body = text[body_start..], .body_line = line_no + 1 };
}

fn trimCr(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '\r') s[0 .. s.len - 1] else s;
}

fn fail(diag: ?*Diag, line: u32, col: usize, msg: []const u8, e: anytype) @TypeOf(e) {
    if (diag) |d| {
        d.line = line;
        d.col = @intCast(col);
        d.message = msg;
    }
    return e;
}

const Line = struct {
    raw: []const u8,
    no: u32,
    /// Leading spaces.
    indent: u32 = 0,
    /// Text after the indentation with any comment removed, trimmed right.
    content: []const u8 = "",
    blank: bool = true,
};

const Parser = struct {
    arena: Allocator,
    lines: []Line,
    diag: ?*Diag,
    i: usize = 0,

    fn err(p: *Parser, li: usize, col0: usize, msg: []const u8, e: anytype) @TypeOf(e) {
        return fail(p.diag, p.lines[li].no, col0 + 1, msg, e);
    }

    fn prepare(p: *Parser) ParseError!void {
        for (p.lines, 0..) |*l, li| {
            var n: usize = 0;
            while (n < l.raw.len and l.raw[n] == ' ') n += 1;
            l.indent = @intCast(n);
            const rest = l.raw[n..];
            const c = std.mem.trimEnd(u8, stripComment(rest), " \t");
            l.content = c;
            l.blank = c.len == 0;
            if (!l.blank and rest.len > 0 and rest[0] == '\t') return p.err(li, n, "tab in indentation", error.InvalidFrontmatter);
        }
    }

    /// Index of the next non-blank line at or after the cursor.
    fn next(p: *Parser) ?usize {
        while (p.i < p.lines.len and p.lines[p.i].blank) p.i += 1;
        return if (p.i < p.lines.len) p.i else null;
    }

    /// A mapping or sequence whose first line is at the cursor, with
    /// indentation greater than or equal to `min`.
    fn block(p: *Parser, min: u32) ParseError!Node {
        const li = p.next().?;
        const l = p.lines[li];
        if (l.indent < min) return p.err(li, l.indent, "expected an indented block", error.InvalidFrontmatter);
        if (isSeqItem(l.content)) return p.seq(l.indent);
        return p.map(l.indent);
    }

    fn map(p: *Parser, indent: u32) ParseError!Node {
        var entries: std.ArrayList(Entry) = .empty;
        while (p.next()) |li| {
            const l = p.lines[li];
            if (l.indent < indent) break;
            if (l.indent > indent) return p.err(li, l.indent, "unexpected indentation", error.InvalidFrontmatter);
            if (isSeqItem(l.content)) return p.err(li, l.indent, "sequence item where a mapping key was expected", error.InvalidFrontmatter);
            const c = l.content;
            try p.rejectUnsupported(li, l.indent, c);
            var key: []const u8 = undefined;
            var after: usize = undefined;
            if (c[0] == '"' or c[0] == '\'') {
                const q = try p.quoted(li, l.indent, c);
                key = q.text;
                after = q.len;
                if (after >= c.len or c[after] != ':') return p.err(li, l.indent + after, "expected ':' after the key", error.InvalidFrontmatter);
            } else {
                after = keyEnd(c) orelse return p.err(li, l.indent, "expected 'key: value'", error.InvalidFrontmatter);
                key = std.mem.trimEnd(u8, c[0..after], " ");
            }
            for (entries.items) |e| if (std.mem.eql(u8, e.key, key)) return p.err(li, l.indent, "duplicate key", error.InvalidFrontmatter);
            const vcol = indent + after + 1;
            const rest = std.mem.trimStart(u8, c[after + 1 ..], " ");
            const value_col = vcol + (c.len - after - 1 - rest.len);
            p.i = li + 1;
            const v = try p.value(li, value_col, rest, indent, true);
            try entries.append(p.arena, .{ .key = key, .value = v, .line = l.no });
        }
        return .{ .map = entries.items };
    }

    fn seq(p: *Parser, indent: u32) ParseError!Node {
        var items: std.ArrayList(Node) = .empty;
        while (p.next()) |li| {
            const l = p.lines[li];
            if (l.indent < indent) break;
            if (l.indent > indent) return p.err(li, l.indent, "unexpected indentation", error.InvalidFrontmatter);
            if (!isSeqItem(l.content)) break;
            const rest_full = l.content[1..];
            const rest = std.mem.trimStart(u8, rest_full, " ");
            const col: usize = indent + 1 + (rest_full.len - rest.len);
            if (rest.len > 0 and !isQuoteStart(rest) and rest[0] != '[' and keyEnd(rest) != null) {
                // `- key: value` starts a mapping at the item's column.
                p.lines[li].indent = @intCast(col);
                p.lines[li].content = rest;
                try items.append(p.arena, try p.map(@intCast(col)));
                continue;
            }
            p.i = li + 1;
            try items.append(p.arena, try p.value(li, col, rest, indent, false));
        }
        return .{ .seq = items.items };
    }

    /// The value after `key:` or `- ` on line `li` (`rest` starts at
    /// column `col`); nested blocks must be deeper than `parent`.
    fn value(p: *Parser, li: usize, col: usize, rest: []const u8, parent: u32, in_map: bool) ParseError!Node {
        if (rest.len == 0) {
            const ni = p.next() orelse return .{ .scalar = "" };
            const nl = p.lines[ni];
            if (nl.indent > parent) return p.block(parent + 1);
            // YAML allows a sequence at the key's own indentation.
            if (in_map and nl.indent == parent and isSeqItem(nl.content)) return p.seq(parent);
            return .{ .scalar = "" };
        }
        try p.rejectUnsupported(li, col, rest);
        switch (rest[0]) {
            '|', '>' => return p.blockScalar(li, col, rest, parent),
            '[' => {
                var fp: Flow = .{ .p = p, .li = li, .s = rest, .col = col };
                const n = try fp.seq();
                fp.skipSpaces();
                if (fp.pos != rest.len) return p.err(li, col + fp.pos, "unexpected text after ']'", error.InvalidFrontmatter);
                return n;
            },
            '"', '\'' => {
                const q = try p.quoted(li, col, rest);
                if (q.len != rest.len) return p.err(li, col + q.len, "unexpected text after the quoted scalar", error.InvalidFrontmatter);
                return .{ .scalar = q.text };
            },
            else => {},
        }
        if (in_map and keyEnd(rest) != null) return p.err(li, col, "nested mapping on one line; put it on the next line", error.InvalidFrontmatter);
        // Plain scalar, possibly continued on deeper lines (folded with spaces).
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.arena, rest);
        while (p.next()) |ni| {
            const nl = p.lines[ni];
            if (nl.indent <= parent or isSeqItem(nl.content) or keyEnd(nl.content) != null) break;
            try out.append(p.arena, ' ');
            try out.appendSlice(p.arena, nl.content);
            p.i = ni + 1;
        }
        return .{ .scalar = out.items };
    }

    fn rejectUnsupported(p: *Parser, li: usize, col: usize, s: []const u8) ParseError!void {
        const what: ?[]const u8 = switch (s[0]) {
            '&' => "anchor",
            '*' => "alias",
            '!' => "tag",
            '{' => "flow mapping",
            '?' => if (s.len == 1 or s[1] == ' ') "complex key" else null,
            '%' => "directive",
            '@', '`' => "reserved indicator",
            else => null,
        };
        if (what) |w| {
            const msg = std.fmt.allocPrint(p.arena, "unsupported YAML feature: {s}", .{w}) catch return error.OutOfMemory;
            return p.err(li, col, msg, error.Unsupported);
        }
    }

    const Quoted = struct { text: []const u8, len: usize };

    fn quoted(p: *Parser, li: usize, col: usize, s: []const u8) ParseError!Quoted {
        return quotedAt(p, li, col, s);
    }

    fn blockScalar(p: *Parser, li: usize, col: usize, header: []const u8, parent: u32) ParseError!Node {
        const folded = header[0] == '>';
        var chomp: enum { clip, strip, keep } = .clip;
        var explicit: ?u32 = null;
        for (header[1..], 1..) |ch, k| switch (ch) {
            '-' => chomp = .strip,
            '+' => chomp = .keep,
            '1'...'9' => explicit = ch - '0',
            else => return p.err(li, col + k, "invalid block scalar header", error.InvalidFrontmatter),
        };
        // Content: following lines that are blank or deeper than `parent`.
        var end = p.i;
        var content_indent: ?u32 = if (explicit) |e| parent + e else null;
        while (end < p.lines.len) : (end += 1) {
            const l = p.lines[end];
            const all_space = std.mem.trim(u8, l.raw, " ").len == 0;
            if (all_space) continue;
            if (l.indent <= parent) break;
            if (content_indent == null) content_indent = l.indent;
            if (l.indent < content_indent.?) return p.err(end, l.indent, "block scalar line is less indented than its first line", error.InvalidFrontmatter);
        }
        // Trailing blank lines belong to the chomping, not the next key.
        var last = end;
        while (last > p.i and std.mem.trim(u8, p.lines[last - 1].raw, " ").len == 0) last -= 1;
        const ci = content_indent orelse parent + 1;
        var out: std.ArrayList(u8) = .empty;
        var prev_more = false;
        var first = true;
        var pending_blank: usize = 0;
        for (p.lines[p.i..last]) |l| {
            const blank = std.mem.trim(u8, l.raw, " ").len == 0;
            if (blank) {
                pending_blank += 1;
                continue;
            }
            const text = if (l.raw.len > ci) l.raw[ci..] else "";
            const more = text.len > 0 and (text[0] == ' ' or text[0] == '\t');
            if (!first) {
                if (!folded or more or prev_more) {
                    try out.append(p.arena, '\n');
                    try out.appendNTimes(p.arena, '\n', pending_blank);
                } else if (pending_blank > 0) {
                    try out.appendNTimes(p.arena, '\n', pending_blank);
                } else try out.append(p.arena, ' ');
            } else try out.appendNTimes(p.arena, '\n', pending_blank);
            pending_blank = 0;
            try out.appendSlice(p.arena, text);
            prev_more = more;
            first = false;
        }
        const trailing = end - last;
        switch (chomp) {
            .strip => {},
            .clip => if (!first) try out.append(p.arena, '\n'),
            .keep => {
                if (!first) try out.append(p.arena, '\n');
                try out.appendNTimes(p.arena, '\n', trailing + pending_blank);
            },
        }
        p.i = end;
        return .{ .scalar = out.items };
    }
};

/// Parses a quoted scalar at the start of `s`.
fn quotedAt(p: *Parser, li: usize, col: usize, s: []const u8) ParseError!Parser.Quoted {
    const q = s[0];
    var out: std.ArrayList(u8) = .empty;
    var k: usize = 1;
    while (k < s.len) : (k += 1) {
        const ch = s[k];
        if (q == '\'') {
            if (ch == '\'') {
                if (k + 1 < s.len and s[k + 1] == '\'') {
                    try out.append(p.arena, '\'');
                    k += 1;
                    continue;
                }
                return .{ .text = out.items, .len = k + 1 };
            }
            try out.append(p.arena, ch);
            continue;
        }
        if (ch == '"') return .{ .text = out.items, .len = k + 1 };
        if (ch != '\\') {
            try out.append(p.arena, ch);
            continue;
        }
        k += 1;
        if (k >= s.len) break;
        switch (s[k]) {
            'n' => try out.append(p.arena, '\n'),
            't' => try out.append(p.arena, '\t'),
            'r' => try out.append(p.arena, '\r'),
            '0' => try out.append(p.arena, 0),
            '"', '\\', '/', ' ' => try out.append(p.arena, s[k]),
            'u' => {
                if (k + 4 >= s.len) return p.err(li, col + k, "truncated \\u escape", error.InvalidFrontmatter);
                const cp = std.fmt.parseInt(u21, s[k + 1 .. k + 5], 16) catch return p.err(li, col + k, "invalid \\u escape", error.InvalidFrontmatter);
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return p.err(li, col + k, "invalid \\u code point", error.InvalidFrontmatter);
                try out.appendSlice(p.arena, buf[0..n]);
                k += 4;
            },
            else => return p.err(li, col + k, "unknown escape sequence", error.InvalidFrontmatter),
        }
    }
    return p.err(li, col, "unterminated quoted scalar", error.InvalidFrontmatter);
}

/// A one-line flow sequence `[a, "b", [c]]`.
const Flow = struct {
    p: *Parser,
    li: usize,
    s: []const u8,
    col: usize,
    pos: usize = 0,

    fn skipSpaces(f: *Flow) void {
        while (f.pos < f.s.len and f.s[f.pos] == ' ') f.pos += 1;
    }

    fn seq(f: *Flow) ParseError!Node {
        std.debug.assert(f.s[f.pos] == '[');
        f.pos += 1;
        var items: std.ArrayList(Node) = .empty;
        f.skipSpaces();
        if (f.pos < f.s.len and f.s[f.pos] == ']') {
            f.pos += 1;
            return .{ .seq = items.items };
        }
        while (true) {
            f.skipSpaces();
            if (f.pos >= f.s.len) return f.p.err(f.li, f.col + f.pos, "unterminated flow sequence", error.InvalidFrontmatter);
            const c = f.s[f.pos];
            if (c == '[') {
                try items.append(f.p.arena, try f.seq());
            } else if (c == '"' or c == '\'') {
                const q = try quotedAt(f.p, f.li, f.col + f.pos, f.s[f.pos..]);
                f.pos += q.len;
                try items.append(f.p.arena, .{ .scalar = q.text });
            } else {
                try f.p.rejectUnsupported(f.li, f.col + f.pos, f.s[f.pos..]);
                const start = f.pos;
                while (f.pos < f.s.len and f.s[f.pos] != ',' and f.s[f.pos] != ']') f.pos += 1;
                try items.append(f.p.arena, .{ .scalar = std.mem.trimEnd(u8, f.s[start..f.pos], " ") });
            }
            f.skipSpaces();
            if (f.pos >= f.s.len) return f.p.err(f.li, f.col + f.pos, "unterminated flow sequence", error.InvalidFrontmatter);
            if (f.s[f.pos] == ']') {
                f.pos += 1;
                return .{ .seq = items.items };
            }
            if (f.s[f.pos] != ',') return f.p.err(f.li, f.col + f.pos, "expected ',' or ']'", error.InvalidFrontmatter);
            f.pos += 1;
        }
    }
};

fn isSeqItem(c: []const u8) bool {
    return c.len > 0 and c[0] == '-' and (c.len == 1 or c[1] == ' ');
}

fn isQuoteStart(c: []const u8) bool {
    return c[0] == '"' or c[0] == '\'';
}

/// Position of the `:` ending a plain key (followed by a space or the end).
fn keyEnd(c: []const u8) ?usize {
    if (c.len == 0 or isQuoteStart(c) or c[0] == '[') return null;
    var k: usize = 0;
    while (k < c.len) : (k += 1) {
        if (c[k] == ':' and (k + 1 == c.len or c[k + 1] == ' ')) return if (k == 0) null else k;
    }
    return null;
}

/// Removes a `#` comment that starts the text or follows whitespace,
/// outside quotes.
fn stripComment(s: []const u8) []const u8 {
    var quote: u8 = 0;
    var k: usize = 0;
    while (k < s.len) : (k += 1) {
        const c = s[k];
        if (quote != 0) {
            if (c == '\\' and quote == '"') {
                k += 1;
            } else if (c == quote) quote = 0;
            continue;
        }
        if ((c == '"' or c == '\'') and (k == 0 or s[k - 1] == ' ' or s[k - 1] == '[' or s[k - 1] == ',' or s[k - 1] == '-' or s[k - 1] == ':')) {
            quote = c;
        } else if (c == '#' and (k == 0 or s[k - 1] == ' ' or s[k - 1] == '\t')) return s[0..k];
    }
    return s;
}

// ---------------------------------------------------------------- decode

/// Converts `n` into `T` by reflection. Struct fields match mapping keys
/// in snake_case, kebab-case or camelCase; missing fields take their
/// defaults (`MissingField` otherwise); unknown keys go to
/// `diag.unknown_keys`. Scalars convert to bools (`true/false/yes/no/on/off`),
/// ints, floats and enums (by tag name); string lists also accept a
/// comma-separated scalar. A `Node` field receives the raw node.
pub fn decode(comptime T: type, arena: Allocator, n: Node, diag: ?*Diag) DecodeError!T {
    return decodeAt(T, arena, n, diag, "");
}

fn decodeAt(comptime T: type, arena: Allocator, n: Node, diag: ?*Diag, path: []const u8) DecodeError!T {
    if (T == Node) return n;
    if (T == []const u8) return switch (n) {
        .scalar => |s| s,
        else => mismatch(diag, path, "a string"),
    };
    switch (@typeInfo(T)) {
        .optional => |o| {
            if (n == .scalar and (n.scalar.len == 0 or std.mem.eql(u8, n.scalar, "null") or std.mem.eql(u8, n.scalar, "~"))) return null;
            return try decodeAt(o.child, arena, n, diag, path);
        },
        .bool => {
            const s = scalarOf(n) orelse return mismatch(diag, path, "a boolean");
            inline for (.{ "true", "yes", "on", "True", "TRUE", "Yes" }) |t| if (std.mem.eql(u8, s, t)) return true;
            inline for (.{ "false", "no", "off", "False", "FALSE", "No" }) |t| if (std.mem.eql(u8, s, t)) return false;
            return mismatch(diag, path, "a boolean");
        },
        .int => {
            const s = scalarOf(n) orelse return mismatch(diag, path, "an integer");
            return std.fmt.parseInt(T, s, 0) catch mismatch(diag, path, "an integer");
        },
        .float => {
            const s = scalarOf(n) orelse return mismatch(diag, path, "a number");
            return std.fmt.parseFloat(T, s) catch mismatch(diag, path, "a number");
        },
        .@"enum" => {
            const s = scalarOf(n) orelse return mismatch(diag, path, "one of the allowed names");
            const norm = try normalizeKey(arena, s);
            return std.meta.stringToEnum(T, norm) orelse mismatch(diag, path, "one of the allowed names");
        },
        .pointer => |ptr| {
            if (ptr.size != .slice) @compileError("unsupported field type " ++ @typeName(T));
            const items: []const Node = switch (n) {
                .seq => |s| s,
                .scalar => |s| blk: {
                    if (ptr.child != []const u8) return mismatch(diag, path, "a list");
                    if (s.len == 0) break :blk &.{};
                    var parts: std.ArrayList(Node) = .empty;
                    var it = std.mem.splitScalar(u8, s, ',');
                    while (it.next()) |part| {
                        const t = std.mem.trim(u8, part, " ");
                        if (t.len > 0) try parts.append(arena, .{ .scalar = t });
                    }
                    break :blk parts.items;
                },
                .map => return mismatch(diag, path, "a list"),
            };
            const out = try arena.alloc(ptr.child, items.len);
            for (items, out) |item, *o| o.* = try decodeAt(ptr.child, arena, item, diag, path);
            return out;
        },
        .@"struct" => |st| {
            if (n != .map) return mismatch(diag, path, "a mapping");
            var out: T = undefined;
            var seen = [_]bool{false} ** st.fields.len;
            for (n.map) |e| {
                const norm = try normalizeKey(arena, e.key);
                var matched = false;
                inline for (st.fields, 0..) |f, fi| {
                    if (!matched and std.mem.eql(u8, f.name, norm)) {
                        matched = true;
                        seen[fi] = true;
                        const sub = if (path.len == 0) e.key else try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, e.key });
                        @field(out, f.name) = try decodeAt(f.type, arena, e.value, diag, sub);
                    }
                }
                if (!matched) if (diag) |d| {
                    const full = if (path.len == 0) e.key else try std.fmt.allocPrint(arena, "{s}.{s}", .{ path, e.key });
                    try d.unknown_keys.append(arena, full);
                };
            }
            inline for (st.fields, 0..) |f, fi| {
                if (!seen[fi]) {
                    if (f.defaultValue()) |dv| {
                        @field(out, f.name) = dv;
                    } else if (@typeInfo(f.type) == .optional) {
                        @field(out, f.name) = null;
                    } else {
                        if (diag) |d| d.message = f.name;
                        return error.MissingField;
                    }
                }
            }
            return out;
        },
        else => @compileError("unsupported field type " ++ @typeName(T)),
    }
}

fn scalarOf(n: Node) ?[]const u8 {
    return if (n == .scalar) n.scalar else null;
}

fn mismatch(diag: ?*Diag, path: []const u8, want: []const u8) error{TypeMismatch} {
    if (diag) |d| d.message = if (path.len > 0) path else want;
    return error.TypeMismatch;
}

/// Maps `allowed-tools` and `disableModelInvocation` to snake_case.
pub fn normalizeKey(arena: Allocator, key: []const u8) Allocator.Error![]const u8 {
    var needs = false;
    for (key) |c| needs = needs or c == '-' or std.ascii.isUpper(c) or c == ' ';
    if (!needs) return key;
    var out: std.ArrayList(u8) = .empty;
    for (key, 0..) |c, k| {
        if (c == '-' or c == ' ') {
            try out.append(arena, '_');
        } else if (std.ascii.isUpper(c)) {
            if (k > 0 and key[k - 1] != '-' and key[k - 1] != '_' and !std.ascii.isUpper(key[k - 1])) try out.append(arena, '_');
            try out.append(arena, std.ascii.toLower(c));
        } else try out.append(arena, c);
    }
    return out.items;
}
