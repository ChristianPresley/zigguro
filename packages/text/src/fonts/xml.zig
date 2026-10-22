//! A minimal XML tokenizer for fontconfig files: start/end/empty tags
//! with attributes, and text. No DTD processing: `<?...?>`, comments,
//! `<!DOCTYPE ...>` (internal subset included) and CDATA sections are
//! skipped. Text and attribute values are returned raw; `unescape`
//! decodes the predefined entities and character references.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{Malformed};

/// One attribute; `value` is raw (see `unescape`).
pub const Attr = struct { name: []const u8, value: []const u8 };

/// The attributes of a tag, parsed lazily.
pub const AttrIter = struct {
    src: []const u8,
    i: usize = 0,

    pub fn next(it: *AttrIter) Error!?Attr {
        skipSpace(it.src, &it.i);
        if (it.i >= it.src.len) return null;
        const n0 = it.i;
        while (it.i < it.src.len and isNameChar(it.src[it.i])) it.i += 1;
        if (it.i == n0) return error.Malformed;
        const name = it.src[n0..it.i];
        skipSpace(it.src, &it.i);
        if (it.i >= it.src.len or it.src[it.i] != '=') return error.Malformed;
        it.i += 1;
        skipSpace(it.src, &it.i);
        if (it.i >= it.src.len or (it.src[it.i] != '"' and it.src[it.i] != '\'')) return error.Malformed;
        const q = it.src[it.i];
        const v0 = it.i + 1;
        const v1 = std.mem.indexOfScalarPos(u8, it.src, v0, q) orelse return error.Malformed;
        it.i = v1 + 1;
        return .{ .name = name, .value = it.src[v0..v1] };
    }

    /// The raw value of attribute `name`, or null (also when malformed).
    pub fn get(it: AttrIter, name: []const u8) ?[]const u8 {
        var c = it;
        c.i = 0;
        while (c.next() catch return null) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

pub const Tag = struct { name: []const u8, attrs: AttrIter };

pub const Token = union(enum) {
    start: Tag,
    end: []const u8,
    /// Raw character data between tags (whitespace included).
    text: []const u8,
    empty: Tag,
};

pub const Tokenizer = struct {
    src: []const u8,
    i: usize = 0,

    pub fn init(src: []const u8) Tokenizer {
        return .{ .src = src };
    }

    pub fn next(t: *Tokenizer) Error!?Token {
        while (t.i < t.src.len) {
            const s = t.src;
            if (s[t.i] != '<') {
                const e = std.mem.indexOfScalarPos(u8, s, t.i, '<') orelse s.len;
                const text = s[t.i..e];
                t.i = e;
                return .{ .text = text };
            }
            const rest = s[t.i..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                t.i = try after(s, t.i + 4, "-->");
            } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                t.i = try after(s, t.i + 9, "]]>");
            } else if (std.mem.startsWith(u8, rest, "<?")) {
                t.i = try after(s, t.i + 2, "?>");
            } else if (std.mem.startsWith(u8, rest, "<!")) {
                t.i = try skipDecl(s, t.i + 2);
            } else if (std.mem.startsWith(u8, rest, "</")) {
                var j = t.i + 2;
                const n0 = j;
                while (j < s.len and isNameChar(s[j])) j += 1;
                if (j == n0) return error.Malformed;
                const name = s[n0..j];
                skipSpace(s, &j);
                if (j >= s.len or s[j] != '>') return error.Malformed;
                t.i = j + 1;
                return .{ .end = name };
            } else {
                var j = t.i + 1;
                const n0 = j;
                while (j < s.len and isNameChar(s[j])) j += 1;
                if (j == n0) return error.Malformed;
                const name = s[n0..j];
                // Find the closing '>' outside quotes.
                const a0 = j;
                var q: u8 = 0;
                while (j < s.len) : (j += 1) {
                    const c = s[j];
                    if (q != 0) {
                        if (c == q) q = 0;
                    } else if (c == '"' or c == '\'') {
                        q = c;
                    } else if (c == '>' or c == '<') break;
                }
                if (j >= s.len or s[j] != '>') return error.Malformed;
                const empty = j > a0 and s[j - 1] == '/';
                const attrs: AttrIter = .{ .src = s[a0..if (empty) j - 1 else j] };
                // Validate attributes now so consumers can rely on them.
                var check = attrs;
                while (try check.next()) |_| {}
                t.i = j + 1;
                const tag: Tag = .{ .name = name, .attrs = attrs };
                return if (empty) .{ .empty = tag } else .{ .start = tag };
            }
        }
        return null;
    }
};

fn after(s: []const u8, from: usize, term: []const u8) Error!usize {
    const e = std.mem.indexOfPos(u8, s, from, term) orelse return error.Malformed;
    return e + term.len;
}

/// Skips `<!DOCTYPE ...>` including a bracketed internal subset.
fn skipDecl(s: []const u8, from: usize) Error!usize {
    var j = from;
    var depth: usize = 0;
    var q: u8 = 0;
    while (j < s.len) : (j += 1) {
        const c = s[j];
        if (q != 0) {
            if (c == q) q = 0;
        } else switch (c) {
            '"', '\'' => q = c,
            '[' => depth += 1,
            ']' => depth -|= 1,
            '>' => if (depth == 0) return j + 1,
            else => {},
        }
    }
    return error.Malformed;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':' or c >= 0x80;
}

fn skipSpace(s: []const u8, i: *usize) void {
    while (i.* < s.len and std.ascii.isWhitespace(s[i.*])) i.* += 1;
}

/// `raw` with `&amp; &lt; &gt; &quot; &apos;` and `&#N;`/`&#xN;`
/// decoded. Unknown or unterminated references are malformed.
pub fn unescape(gpa: Allocator, raw: []const u8) (Error || Allocator.Error)![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, raw.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c != '&') {
            out.appendAssumeCapacity(c);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i + 1, ';') orelse return error.Malformed;
        const ent = raw[i + 1 .. semi];
        i = semi + 1;
        const named = [_]struct { []const u8, u8 }{ .{ "amp", '&' }, .{ "lt", '<' }, .{ "gt", '>' }, .{ "quot", '"' }, .{ "apos", '\'' } };
        const ch: u21 = for (named) |n| {
            if (std.mem.eql(u8, ent, n[0])) break n[1];
        } else blk: {
            if (ent.len < 2 or ent[0] != '#') return error.Malformed;
            const hex = ent[1] == 'x' or ent[1] == 'X';
            const digits = if (hex) ent[2..] else ent[1..];
            const v = std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch return error.Malformed;
            if (v == 0 or v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return error.Malformed;
            break :blk v;
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(ch, &buf) catch return error.Malformed;
        // A reference is never shorter than its encoding.
        out.appendSliceAssumeCapacity(buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}
