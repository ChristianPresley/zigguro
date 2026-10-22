//! HTML (WHATWG tokenization, simplified): data, tags and attributes,
//! comments, doctypes, CDATA, character references, and the raw-text
//! elements. `<script>` (no type, or a JavaScript type) injects JavaScript
//! and `<style>` injects CSS until `</script` / `</style` (any case), which
//! `injection_end` finds before the guest sees the line, so a `</script`
//! inside a JS string still ends the script, as in browsers. `textarea`
//! and `title` are RCDATA; a `<script>` with another type is raw text.
//!
//! State: `mode` bits 0-3 are the tokenizer state, bits 4-6 the special
//! element of the tag being read, bit 7 "this script is not JavaScript",
//! bit 8 "this is an end tag" and bit 9 "the attribute being read is
//! `type`".

const std = @import("std");
const language = @import("../language.zig");
const scanner_mod = @import("../lex/scanner.zig");
const LexState = @import("../lex/state.zig").LexState;
const HighlightId = @import("../highlight_names.zig").HighlightId;

const Scanner = scanner_mod.Scanner;
const TokenSink = scanner_mod.TokenSink;
const atomic = scanner_mod.Token.atomic_bit;

/// Token kinds.
pub const Kind = struct {
    pub const ws: u16 = 1;
    pub const text: u16 = 2;
    pub const comment: u16 = 3;
    pub const punct: u16 = 4 | atomic;
    pub const tag: u16 = 5 | atomic;
    pub const attribute: u16 = 6 | atomic;
    pub const equals: u16 = 7 | atomic;
    pub const value: u16 = 8;
    pub const entity: u16 = 9 | atomic;
    pub const doctype: u16 = 10;
    pub const cdata: u16 = 11;
    pub const raw: u16 = 12;
    pub const invalid: u16 = 13;
};

/// Tokenizer states (`mode` bits 0-3).
pub const State = struct {
    pub const data: u16 = 0;
    /// Inside a start or end tag, after its name.
    pub const tag: u16 = 1;
    pub const comment: u16 = 2;
    /// `textarea` / `title` text, up to the matching end tag.
    pub const rcdata: u16 = 3;
    /// A non-JavaScript `<script>`'s text, up to `</script`.
    pub const raw_script: u16 = 4;
    pub const cdata: u16 = 5;
    pub const attr_dq: u16 = 6;
    pub const attr_sq: u16 = 7;
    /// JavaScript runs as a guest until `</script`.
    pub const script: u16 = 8;
    /// CSS runs as a guest until `</style`.
    pub const style: u16 = 9;
    /// `<!…>` or `<?…>` continuing on the next line.
    pub const declaration: u16 = 10;
    pub const mask: u16 = 0xf;
};

/// Special elements (`mode` bits 4-6).
pub const Element = struct {
    pub const other: u16 = 0;
    pub const script: u16 = 1;
    pub const style: u16 = 2;
    pub const textarea: u16 = 3;
    pub const title: u16 = 4;
    pub const shift: u4 = 4;
    pub const mask: u16 = 0x70;
};

pub const Bits = struct {
    pub const not_js: u16 = 0x80;
    pub const end_tag: u16 = 0x100;
    pub const type_attr: u16 = 0x200;
};

fn isSpaceB(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r' or b == '\n' or b == 0x0c;
}

fn isTagName(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '-' or b == ':' or b == '_' or b == '.' or b >= 0x80;
}

fn isAttrName(b: u8) bool {
    return !isSpaceB(b) and b != '/' and b != '>' and b != '=' and b != '"' and b != '\'' and b != '<';
}

fn elementOf(name: []const u8) u16 {
    if (std.ascii.eqlIgnoreCase(name, "script")) return Element.script;
    if (std.ascii.eqlIgnoreCase(name, "style")) return Element.style;
    if (std.ascii.eqlIgnoreCase(name, "textarea")) return Element.textarea;
    if (std.ascii.eqlIgnoreCase(name, "title")) return Element.title;
    return Element.other;
}

fn endTagOf(el: u16) []const u8 {
    return switch (el) {
        Element.script => "</script",
        Element.style => "</style",
        Element.textarea => "</textarea",
        else => "</title",
    };
}

/// Whether a `<script type=…>` value is JavaScript.
fn isJsType(v_in: []const u8) bool {
    const v = std.mem.trim(u8, v_in, " \t");
    const js_types = [_][]const u8{ "", "module", "text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript", "text/jsx", "text/babel" };
    for (js_types) |t| if (std.ascii.eqlIgnoreCase(v, t)) return true;
    return false;
}

/// The first `needle` (an end-tag opener such as `</script`) at or after
/// `from`, in any case.
fn findTag(line: []const u8, from: usize, needle: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, line, i, '<')) |p| {
        if (std.ascii.startsWithIgnoreCase(line[p..], needle)) return p;
        i = p + 1;
    }
    return null;
}

fn setState(st: *LexState, s: u16) void {
    st.mode = (st.mode & ~State.mask) | s;
}

fn state(st: *const LexState) u16 {
    return st.mode & State.mask;
}

fn element(st: *const LexState) u16 {
    return (st.mode & Element.mask) >> Element.shift;
}

const Lexer = struct {
    st: *LexState,
    s: *Scanner,
    out: *TokenSink,

    fn emit(l: *Lexer, start: u32, kind: u16, hl: HighlightId) void {
        l.s.emit(l.out, start, kind, hl);
    }

    /// Scans to `end` (or the line end) as one token of `kind`; returns
    /// whether `end` was found (and consumed).
    fn until(l: *Lexer, end: []const u8, kind: u16, hl: HighlightId) bool {
        const s = l.s;
        const start = s.pos;
        const found = std.mem.indexOfPos(u8, s.line, s.pos, end);
        s.pos = if (found) |e| @intCast(e + end.len) else @intCast(s.line.len);
        if (s.pos > start) l.emit(start, kind, hl);
        return found != null;
    }

    /// A character reference at `&`, or plain text.
    fn entity(l: *Lexer, text_kind: u16, text_hl: HighlightId) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        var e: usize = start + 1;
        if (e < line.len and line[e] == '#') e += 1;
        while (e < line.len and e < start + 32 and std.ascii.isAlphanumeric(line[e])) e += 1;
        if (e > start + 1 and e < line.len and line[e] == ';') {
            s.pos = @intCast(e + 1);
            l.emit(start, Kind.entity, .string_escape);
        } else {
            s.advance();
            l.emit(start, text_kind, text_hl);
        }
    }

    fn data(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        switch (line[start]) {
            '<' => {
                const rest = line[start..];
                if (std.mem.startsWith(u8, rest, "<!--")) {
                    s.advanceBy(4);
                    l.emit(start, Kind.comment, .comment);
                    if (!l.until("-->", Kind.comment, .comment)) setState(l.st, State.comment);
                } else if (std.mem.startsWith(u8, rest, "<![CDATA[")) {
                    s.advanceBy(9);
                    l.emit(start, Kind.cdata, .string_special);
                    if (!l.until("]]>", Kind.cdata, .string_special)) setState(l.st, State.cdata);
                } else if (std.mem.startsWith(u8, rest, "<!") or std.mem.startsWith(u8, rest, "<?")) {
                    s.advanceBy(2);
                    l.emit(start, Kind.doctype, .keyword);
                    if (!l.until(">", Kind.doctype, .keyword)) setState(l.st, State.declaration);
                } else if (rest.len > 2 and rest[1] == '/' and std.ascii.isAlphabetic(rest[2])) {
                    s.advanceBy(2);
                    l.emit(start, Kind.punct, .punctuation);
                    l.tagName(true);
                } else if (rest.len > 1 and std.ascii.isAlphabetic(rest[1])) {
                    s.advance();
                    l.emit(start, Kind.punct, .punctuation);
                    l.tagName(false);
                } else {
                    s.advance();
                    l.emit(start, Kind.text, .none);
                }
            },
            '&' => l.entity(Kind.text, .none),
            else => {
                s.pos = @intCast(std.mem.indexOfAnyPos(u8, line, start + 1, "<&") orelse line.len);
                l.emit(start, Kind.text, .none);
            },
        }
    }

    fn tagName(l: *Lexer, end_tag: bool) void {
        const s = l.s;
        const start = s.pos;
        _ = s.eatWhile(isTagName);
        l.emit(start, Kind.tag, .tag);
        const el = elementOf(s.line[start..s.pos]);
        l.st.mode = State.tag | el << Element.shift | (if (end_tag) Bits.end_tag else 0);
    }

    /// The tag's closing `>`: what follows depends on the element.
    fn tagEnd(l: *Lexer) void {
        const st = l.st;
        const el = element(st);
        const end_tag = st.mode & Bits.end_tag != 0;
        const not_js = st.mode & Bits.not_js != 0;
        if (end_tag) {
            st.mode = State.data;
            return;
        }
        switch (el) {
            Element.script => if (not_js) {
                st.mode = State.raw_script | el << Element.shift;
            } else {
                st.mode = State.script | el << Element.shift;
                if (!st.push(.javascript)) st.mode = State.raw_script | el << Element.shift;
            },
            Element.style => {
                st.mode = State.style | el << Element.shift;
                if (!st.push(.css)) st.mode = State.raw_script | el << Element.shift;
            },
            Element.textarea, Element.title => st.mode = State.rcdata | el << Element.shift,
            else => st.mode = State.data,
        }
    }

    /// Inside a tag: attributes up to `>` or `/>`.
    fn tag(l: *Lexer) void {
        const s = l.s;
        const line = s.line;
        const start = s.pos;
        const c = line[start];
        if (isSpaceB(c)) {
            _ = s.eatWhile(isSpaceB);
            l.emit(start, Kind.ws, .none);
            return;
        }
        switch (c) {
            '>' => {
                s.advance();
                l.emit(start, Kind.punct, .punctuation);
                l.tagEnd();
            },
            '/' => if (s.peekAt(1) == '>') {
                s.advanceBy(2);
                l.emit(start, Kind.punct, .punctuation);
                l.st.mode = State.data;
            } else {
                s.advance();
                l.emit(start, Kind.invalid, .invalid);
            },
            '=' => {
                s.advance();
                l.emit(start, Kind.equals, .operator);
                const ws = s.pos;
                if (s.eatWhile(isSpaceB) > 0) l.emit(ws, Kind.ws, .none);
                if (s.atEnd()) return;
                const q = s.peek().?;
                const v = s.pos;
                if (q == '"' or q == '\'') {
                    s.advance();
                    const close = std.mem.indexOfScalarPos(u8, line, s.pos, q);
                    s.pos = if (close) |e| @intCast(e + 1) else @intCast(line.len);
                    l.emit(v, Kind.value, .string);
                    if (close) |e| {
                        l.checkType(line[v + 1 .. e]);
                    } else setState(l.st, if (q == '"') State.attr_dq else State.attr_sq);
                } else if (q != '>') {
                    _ = s.eatWhile(struct {
                        fn f(b: u8) bool {
                            return !isSpaceB(b) and b != '>';
                        }
                    }.f);
                    l.emit(v, Kind.value, .string);
                    l.checkType(line[v..s.pos]);
                }
            },
            else => if (isAttrName(c)) {
                _ = s.eatWhile(isAttrName);
                l.emit(start, Kind.attribute, .attribute);
                if (std.ascii.eqlIgnoreCase(line[start..s.pos], "type")) l.st.mode |= Bits.type_attr else l.st.mode &= ~Bits.type_attr;
            } else {
                s.advance();
                l.emit(start, Kind.invalid, .invalid);
            },
        }
    }

    fn checkType(l: *Lexer, v: []const u8) void {
        if (l.st.mode & Bits.type_attr == 0) return;
        l.st.mode &= ~Bits.type_attr;
        if (element(l.st) == Element.script and !isJsType(v)) l.st.mode |= Bits.not_js;
    }

    /// Text up to the element's end tag (left for `data` to lex).
    fn rawUntilEnd(l: *Lexer, kind: u16, hl: HighlightId, entities: bool) void {
        const s = l.s;
        const line = s.line;
        const end = findTag(line, s.pos, endTagOf(element(l.st)));
        const stop = end orelse line.len;
        while (s.pos < stop) {
            const start = s.pos;
            if (entities and line[start] == '&') {
                l.entity(kind, hl);
                continue;
            }
            s.pos = @intCast(if (entities) std.mem.indexOfScalarPos(u8, line[0..stop], start + 1, '&') orelse stop else stop);
            l.emit(start, kind, hl);
        }
        if (end != null) l.st.mode = State.data;
    }

    fn lexLine(st: *LexState, s_in: *Scanner, out: *TokenSink) void {
        var sc = s_in.*;
        defer s_in.* = sc;
        var l: Lexer = .{ .st = st, .s = &sc, .out = out };
        const depth = st.stack_len;
        while (sc.pos < sc.line.len) {
            switch (state(st)) {
                State.data => l.data(),
                State.tag => l.tag(),
                State.comment => if (l.until("-->", Kind.comment, .comment)) setState(st, State.data),
                State.cdata => if (l.until("]]>", Kind.cdata, .string_special)) setState(st, State.data),
                State.declaration => if (l.until(">", Kind.doctype, .keyword)) setState(st, State.data),
                State.attr_dq, State.attr_sq => {
                    const q: u8 = if (state(st) == State.attr_dq) '"' else '\'';
                    if (l.until(&.{q}, Kind.value, .string)) setState(st, State.tag);
                },
                State.rcdata => l.rawUntilEnd(Kind.text, .none, true),
                // A guest that could not start, or the host resuming at the
                // end tag after its guest.
                State.raw_script, State.script, State.style => l.rawUntilEnd(Kind.raw, .none, false),
                else => setState(st, State.data),
            }
            // A guest started: the framework hands it the rest of the line.
            if (st.stack_len != depth) return;
        }
    }
};

fn lexLine(st: *LexState, s: *Scanner, out: *TokenSink) void {
    Lexer.lexLine(st, s, out);
}

/// Where a running `<script>` / `<style>` guest ends on `line`.
fn injectionEnd(host_mode: u16, line: []const u8, from: u32) ?u32 {
    const tag_name: []const u8 = switch (host_mode & State.mask) {
        State.script => "</script",
        State.style => "</style",
        else => return null,
    };
    const e = findTag(line, from, tag_name) orelse return null;
    return @intCast(e);
}

fn resync(line: []const u8) bool {
    // A tag at column 0.
    return line.len > 1 and line[0] == '<' and (std.ascii.isAlphabetic(line[1]) or line[1] == '/' or line[1] == '!');
}

/// HTML.
pub const html_language: language.Language = .{
    .id = .html,
    .name = "html",
    .aliases = &.{ "htm", "xhtml" },
    .extensions = &.{ ".html", ".htm", ".xhtml" },
    .lexer = .{ .lexLineFn = lexLine },
    .injection_end = injectionEnd,
    .resync = resync,
    .decl_keywords = &.{},
    .edit_rules = .{
        .block_comment = .{ .open = "<!--", .close = "-->" },
        .auto_close = &.{
            .{ .open = "\"", .close = "\"" },
            .{ .open = "'", .close = "'" },
            .{ .open = "<!--", .close = " -->" },
        },
        .surround = &.{
            .{ .open = "\"", .close = "\"" },
            .{ .open = "'", .close = "'" },
            .{ .open = "(", .close = ")" },
            .{ .open = "[", .close = "]" },
            .{ .open = "{", .close = "}" },
            .{ .open = "<", .close = ">" },
        },
        .tag_pairs = true,
        .insert_spaces = true,
    },
    .brackets = &.{},
    .word_chars = &.{'-'},
};
