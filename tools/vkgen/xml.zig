//! A small zero-copy XML pull parser for the registry files we vendor
//! (vk.xml). Every slice in an event points into the input; `Parser.next`
//! never allocates. Entities are decoded on demand (`RawText.decode`,
//! `decodeValue`).
//!
//! Supported: elements, attributes in either quote style, self-closing
//! tags, mixed content (text events keep their order and whitespace),
//! comments, processing instructions, CDATA (text with `cdata = true`) and a
//! skipped `<!DOCTYPE>`. No DTD processing and no namespaces.

const std = @import("std");

/// Parse errors.
pub const Error = error{
    UnexpectedEof,
    InvalidName,
    UnterminatedTag,
    MismatchedEndTag,
    InvalidEntity,
    InvalidCharRef,
    AttributeSyntax,
    DuplicateAttribute,
    TooDeep,
};

/// Deepest element nesting accepted.
pub const max_depth = 64;

/// One parse event.
pub const Event = union(enum) {
    /// `<name attrs>` or `<name attrs/>`. A self-closing element produces no
    /// `end` event.
    start: Start,
    /// `</name>`.
    end: []const u8,
    /// Character data, undecoded.
    text: RawText,
    /// `<!-- ... -->` contents.
    comment: []const u8,
    /// `<? ... ?>` contents.
    pi: []const u8,
    eof,

    /// A start tag.
    pub const Start = struct {
        name: []const u8,
        attrs: AttrIter,
        self_closing: bool,
    };
};

/// Undecoded character data.
pub const RawText = struct {
    raw: []const u8,
    /// From a CDATA section: `raw` is literal and must not be decoded.
    cdata: bool = false,

    /// Appends the decoded text to `out`.
    pub fn decode(self: RawText, out: *std.ArrayList(u8), gpa: std.mem.Allocator) (Error || error{OutOfMemory})!void {
        if (self.cdata) return out.appendSlice(gpa, self.raw);
        return decodeValue(self.raw, out, gpa);
    }

    /// True if the text is only XML whitespace.
    pub fn isWhitespace(self: RawText) bool {
        for (self.raw) |c| if (!isSpace(c)) return false;
        return true;
    }
};

/// One attribute; `raw_value` is undecoded (see `decodeValue`).
pub const Attr = struct { name: []const u8, raw_value: []const u8 };

/// Iterates the attributes of a start tag. The tag was validated when it
/// was parsed, so iteration cannot fail.
pub const AttrIter = struct {
    src: []const u8,
    pos: usize = 0,

    /// The next attribute, or null.
    pub fn next(self: *AttrIter) ?Attr {
        const s = self.src;
        var i = self.pos;
        while (i < s.len and isSpace(s[i])) i += 1;
        if (i >= s.len or !isNameStart(s[i])) {
            self.pos = s.len;
            return null;
        }
        const n0 = i;
        while (i < s.len and isNameChar(s[i])) i += 1;
        const name = s[n0..i];
        while (s[i] != '=') i += 1;
        i += 1;
        while (isSpace(s[i])) i += 1;
        const q = s[i];
        const v0 = i + 1;
        const v1 = std.mem.indexOfScalarPos(u8, s, v0, q).?;
        self.pos = v1 + 1;
        return .{ .name = name, .raw_value = s[v0..v1] };
    }

    /// The raw value of attribute `name`, or null.
    pub fn get(self: AttrIter, name: []const u8) ?[]const u8 {
        var it = self;
        it.pos = 0;
        while (it.next()) |a| if (std.mem.eql(u8, a.name, name)) return a.raw_value;
        return null;
    }
};

/// The pull parser.
pub const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    stack: [max_depth][]const u8 = undefined,
    depth: u32 = 0,
    last_self_closing: bool = false,
    /// Byte offset of the last error, for `location`.
    err_pos: ?usize = null,

    /// A parser over `src`, which must outlive every event.
    pub fn init(src: []const u8) Parser {
        return .{ .src = src };
    }

    /// Current element depth (0 outside the root element).
    pub fn currentDepth(self: *const Parser) u32 {
        return self.depth;
    }

    /// The next event.
    pub fn next(self: *Parser) Error!Event {
        self.last_self_closing = false;
        const s = self.src;
        while (true) {
            if (self.pos >= s.len) {
                if (self.depth > 0) return self.fail(self.pos, error.UnexpectedEof);
                return .eof;
            }
            if (s[self.pos] != '<') {
                const end = std.mem.indexOfScalarPos(u8, s, self.pos, '<') orelse s.len;
                const t = s[self.pos..end];
                self.pos = end;
                return .{ .text = .{ .raw = t } };
            }
            const rest = s[self.pos..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                const end = std.mem.indexOfPos(u8, s, self.pos + 4, "-->") orelse return self.fail(self.pos, error.UnexpectedEof);
                const c = s[self.pos + 4 .. end];
                self.pos = end + 3;
                return .{ .comment = c };
            }
            if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, s, self.pos + 9, "]]>") orelse return self.fail(self.pos, error.UnexpectedEof);
                const c = s[self.pos + 9 .. end];
                self.pos = end + 3;
                return .{ .text = .{ .raw = c, .cdata = true } };
            }
            if (std.mem.startsWith(u8, rest, "<!")) {
                try self.skipDecl();
                continue;
            }
            if (std.mem.startsWith(u8, rest, "<?")) {
                const end = std.mem.indexOfPos(u8, s, self.pos + 2, "?>") orelse return self.fail(self.pos, error.UnexpectedEof);
                const c = s[self.pos + 2 .. end];
                self.pos = end + 2;
                return .{ .pi = c };
            }
            if (std.mem.startsWith(u8, rest, "</")) return self.endTag();
            return self.startTag();
        }
    }

    /// Skips the rest of the element whose `start` was just returned
    /// (nothing for a self-closing element).
    pub fn skipElement(self: *Parser) Error!void {
        if (self.last_self_closing) {
            self.last_self_closing = false;
            return;
        }
        if (self.depth == 0) return;
        const target = self.depth - 1;
        while (true) {
            switch (try self.next()) {
                .end => if (self.depth == target) return,
                .eof => return self.fail(self.pos, error.UnexpectedEof),
                else => {},
            }
        }
    }

    /// 1-based line and column of the last error (or the current position).
    pub fn location(self: *const Parser) struct { line: u32, col: u32 } {
        const at = @min(self.err_pos orelse self.pos, self.src.len);
        var line: u32 = 1;
        var col: u32 = 1;
        for (self.src[0..at]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else col += 1;
        }
        return .{ .line = line, .col = col };
    }

    fn fail(self: *Parser, at: usize, err: Error) Error {
        self.err_pos = at;
        return err;
    }

    fn skipDecl(self: *Parser) Error!void {
        // <!DOCTYPE ...> with an optional [internal subset].
        const s = self.src;
        var i = self.pos + 2;
        var brackets: u32 = 0;
        var quote: u8 = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (quote != 0) {
                if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '[' => brackets += 1,
                ']' => brackets -|= 1,
                '>' => if (brackets == 0) {
                    self.pos = i + 1;
                    return;
                },
                else => {},
            }
        }
        return self.fail(self.pos, error.UnexpectedEof);
    }

    fn parseName(self: *Parser, i: *usize) Error![]const u8 {
        const s = self.src;
        if (i.* >= s.len) return self.fail(i.*, error.UnexpectedEof);
        if (!isNameStart(s[i.*])) return self.fail(i.*, error.InvalidName);
        const n0 = i.*;
        while (i.* < s.len and isNameChar(s[i.*])) i.* += 1;
        return s[n0..i.*];
    }

    fn endTag(self: *Parser) Error!Event {
        const s = self.src;
        const at = self.pos;
        var i = self.pos + 2;
        const name = try self.parseName(&i);
        while (i < s.len and isSpace(s[i])) i += 1;
        if (i >= s.len) return self.fail(at, error.UnexpectedEof);
        if (s[i] != '>') return self.fail(i, error.UnterminatedTag);
        if (self.depth == 0 or !std.mem.eql(u8, self.stack[self.depth - 1], name)) return self.fail(at, error.MismatchedEndTag);
        self.depth -= 1;
        self.pos = i + 1;
        return .{ .end = name };
    }

    fn startTag(self: *Parser) Error!Event {
        const s = self.src;
        const at = self.pos;
        var i = self.pos + 1;
        const name = try self.parseName(&i);
        const a0 = i;
        var self_closing = false;
        while (true) {
            const had_space = i < s.len and isSpace(s[i]);
            while (i < s.len and isSpace(s[i])) i += 1;
            if (i >= s.len) return self.fail(at, error.UnexpectedEof);
            if (s[i] == '>') break;
            if (s[i] == '/') {
                if (i + 1 >= s.len) return self.fail(at, error.UnexpectedEof);
                if (s[i + 1] != '>') return self.fail(i, error.UnterminatedTag);
                self_closing = true;
                break;
            }
            if (!had_space) return self.fail(i, error.AttributeSyntax);
            const an0 = i;
            const an = try self.parseName(&i);
            while (i < s.len and isSpace(s[i])) i += 1;
            if (i >= s.len) return self.fail(at, error.UnexpectedEof);
            if (s[i] != '=') return self.fail(i, error.AttributeSyntax);
            i += 1;
            while (i < s.len and isSpace(s[i])) i += 1;
            if (i >= s.len) return self.fail(at, error.UnexpectedEof);
            const q = s[i];
            if (q != '"' and q != '\'') return self.fail(i, error.AttributeSyntax);
            const v1 = std.mem.indexOfScalarPos(u8, s, i + 1, q) orelse return self.fail(at, error.UnterminatedTag);
            if (std.mem.indexOfScalar(u8, s[i + 1 .. v1], '<') != null) return self.fail(i, error.AttributeSyntax);
            // Duplicate check over the attributes before this one.
            var prev: AttrIter = .{ .src = s[a0..an0] };
            while (prev.next()) |p| if (std.mem.eql(u8, p.name, an)) return self.fail(an0, error.DuplicateAttribute);
            i = v1 + 1;
        }
        const attrs: AttrIter = .{ .src = s[a0..i] };
        self.pos = i + @as(usize, if (self_closing) 2 else 1);
        if (self_closing) {
            self.last_self_closing = true;
        } else {
            if (self.depth >= max_depth) return self.fail(at, error.TooDeep);
            self.stack[self.depth] = name;
            self.depth += 1;
        }
        return .{ .start = .{ .name = name, .attrs = attrs, .self_closing = self_closing } };
    }
};

/// Appends `raw` with entity and character references decoded.
pub fn decodeValue(raw: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) (Error || error{OutOfMemory})!void {
    var i: usize = 0;
    while (i < raw.len) {
        const amp = std.mem.indexOfScalarPos(u8, raw, i, '&') orelse {
            try out.appendSlice(gpa, raw[i..]);
            return;
        };
        try out.appendSlice(gpa, raw[i..amp]);
        const semi = std.mem.indexOfScalarPos(u8, raw, amp, ';') orelse return error.InvalidEntity;
        const ent = raw[amp + 1 .. semi];
        if (ent.len > 0 and ent[0] == '#') {
            const cp: u21 = blk: {
                const v = if (ent.len > 1 and ent[1] == 'x')
                    std.fmt.parseInt(u32, ent[2..], 16)
                else
                    std.fmt.parseInt(u32, ent[1..], 10);
                const n = v catch return error.InvalidCharRef;
                if (n == 0 or n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF)) return error.InvalidCharRef;
                break :blk @intCast(n);
            };
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidCharRef;
            try out.appendSlice(gpa, buf[0..len]);
        } else {
            const map = [_]struct { []const u8, u8 }{ .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' } };
            for (map) |m| {
                if (std.mem.eql(u8, ent, m[0])) {
                    try out.append(gpa, m[1]);
                    break;
                }
            } else return error.InvalidEntity;
        }
        i = semi + 1;
    }
}

/// True if `raw` contains no references, so it can be used undecoded.
pub fn isPlain(raw: []const u8) bool {
    return std.mem.indexOfScalar(u8, raw, '&') == null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == ':' or c >= 0x80;
}

fn isNameChar(c: u8) bool {
    return isNameStart(c) or std.ascii.isDigit(c) or c == '.' or c == '-';
}

test {
    _ = @import("xml_test.zig");
}
