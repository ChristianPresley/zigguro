//! A fast decoder for `textDocument/completion` results (E07.F03.S01.T02):
//! a server's list can be megabytes (every symbol in scope, each with
//! documentation), and std.json's tokenizer alone takes about as long as
//! the whole decode budget. This reads the JSON directly into the
//! protocol types: one pass, no token stream, strings borrowed from the
//! input unless they have escapes.
//!
//! It handles every field of `CompletionItem` and `CompletionList`; the
//! list's `itemDefaults` and `applyKind` (one each) go through std.json.
//! Unknown fields are skipped. Anything else it does not expect (a
//! number where a string goes, a fraction in a position, a markup kind
//! it does not know) is `error.Unsupported`, and the caller parses with
//! std.json instead, which accepts or rejects it as before: so do
//! duplicate fields, raw control characters in strings, lone surrogate
//! escapes and invalid UTF-8. The one leniency: the syntax inside an
//! unknown field's value is only bracket-matched, not checked.

const std = @import("std");
const protocol = @import("../gen/protocol.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Error = error{ Unsupported, OutOfMemory };

/// Parses `bytes` (a response's `result`) as std.json would into
/// `?TextDocumentCompletionResult`. Strings without escapes borrow from
/// `bytes`, so it must outlive the result (both live in the response's
/// arena in the client).
pub fn parse(a: Allocator, bytes: []const u8) Error!?protocol.TextDocumentCompletionResult {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Unsupported;
    var p: P = .{ .s = bytes, .a = a };
    if (p.isNull()) {
        try p.end();
        return null;
    }
    p.ws();
    const r: protocol.TextDocumentCompletionResult = switch (p.peek()) {
        '[' => .{ .completion_item_array = try p.items() },
        '{' => .{ .completion_list = try p.list() },
        else => return error.Unsupported,
    };
    try p.end();
    return r;
}

const ListKey = enum { isIncomplete, itemDefaults, applyKind, items };
const ItemKey = enum { label, labelDetails, kind, tags, detail, documentation, deprecated, preselect, sortText, filterText, insertText, insertTextFormat, insertTextMode, textEdit, textEditText, additionalTextEdits, commitCharacters, command, data };

const P = struct {
    s: []const u8,
    i: usize = 0,
    a: Allocator,

    fn ws(p: *P) void {
        while (p.i < p.s.len) : (p.i += 1) switch (p.s[p.i]) {
            ' ', '\t', '\n', '\r' => {},
            else => return,
        };
    }

    fn peek(p: *P) u8 {
        return if (p.i < p.s.len) p.s[p.i] else 0;
    }

    fn eat(p: *P, c: u8) bool {
        p.ws();
        if (p.peek() != c) return false;
        p.i += 1;
        return true;
    }

    fn expect(p: *P, c: u8) Error!void {
        if (!p.eat(c)) return error.Unsupported;
    }

    fn end(p: *P) Error!void {
        p.ws();
        if (p.i != p.s.len) return error.Unsupported;
    }

    fn literal(p: *P, word: []const u8) bool {
        p.ws();
        if (!std.mem.startsWith(u8, p.s[p.i..], word)) return false;
        p.i += word.len;
        return true;
    }

    fn isNull(p: *P) bool {
        return p.literal("null");
    }

    /// The next key of an object (after `{`), or null at its end.
    fn key(p: *P, n: *usize) Error!?[]const u8 {
        p.ws();
        if (p.peek() == '}') {
            p.i += 1;
            return null;
        }
        if (n.* > 0) {
            if (p.peek() != ',') return error.Unsupported;
            p.i += 1;
        }
        n.* += 1;
        const k = try p.str();
        // Compact JSON: the colon follows at once.
        if (p.peek() == ':') p.i += 1 else try p.expect(':');
        return k;
    }

    /// Whether another array element follows (after `[`).
    fn more(p: *P, n: *usize) Error!bool {
        if (p.eat(']')) return false;
        if (n.* > 0) try p.expect(',');
        n.* += 1;
        return true;
    }

    fn str(p: *P) Error![]const u8 {
        try p.expect('"');
        const start = p.i;
        var j = start;
        // Strings are runs of plain bytes: find the first quote,
        // backslash or control character a vector at a time.
        const V = @Vector(16, u8);
        while (true) {
            if (j + 16 <= p.s.len) {
                const v: V = p.s[j..][0..16].*;
                const stop = (v == @as(V, @splat('"'))) | (v == @as(V, @splat('\\'))) | (v < @as(V, @splat(0x20)));
                const mask: u16 = @bitCast(stop);
                if (mask == 0) {
                    j += 16;
                    continue;
                }
                j += @ctz(mask);
            } else {
                while (j < p.s.len and p.s[j] != '"' and p.s[j] != '\\' and p.s[j] >= 0x20) j += 1;
                if (j == p.s.len) return error.Unsupported;
            }
            switch (p.s[j]) {
                '"' => {
                    p.i = j + 1;
                    return p.s[start..j];
                },
                '\\' => return p.escaped(start, j),
                else => return error.Unsupported,
            }
        }
    }

    /// The rest of a string with escapes, from `j` (at a backslash).
    fn escaped(p: *P, start: usize, first: usize) Error![]const u8 {
        var out: std.ArrayList(u8) = try .initCapacity(p.a, first - start + 16);
        out.appendSliceAssumeCapacity(p.s[start..first]);
        var j = first;
        while (j < p.s.len) {
            const c = p.s[j];
            if (c == '"') {
                p.i = j + 1;
                return out.items;
            }
            if (c < 0x20) return error.Unsupported;
            if (c != '\\') {
                try out.append(p.a, c);
                j += 1;
                continue;
            }
            if (j + 1 >= p.s.len) return error.Unsupported;
            const e = p.s[j + 1];
            j += 2;
            switch (e) {
                '"', '\\', '/' => try out.append(p.a, e),
                'b' => try out.append(p.a, 8),
                'f' => try out.append(p.a, 12),
                'n' => try out.append(p.a, '\n'),
                'r' => try out.append(p.a, '\r'),
                't' => try out.append(p.a, '\t'),
                'u' => {
                    var cp: u21 = try hex4(p.s, j);
                    j += 4;
                    if (cp >= 0xD800 and cp < 0xDC00) {
                        // A high surrogate wants its low half.
                        if (j + 6 <= p.s.len and p.s[j] == '\\' and p.s[j + 1] == 'u') {
                            const lo = try hex4(p.s, j + 2);
                            if (lo >= 0xDC00 and lo < 0xE000) {
                                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                                j += 6;
                            } else return error.Unsupported;
                        } else return error.Unsupported;
                    } else if (cp >= 0xDC00 and cp < 0xE000) return error.Unsupported;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.Unsupported;
                    try out.appendSlice(p.a, buf[0..n]);
                },
                else => return error.Unsupported,
            }
        }
        return error.Unsupported;
    }

    fn optStr(p: *P) Error!?[]const u8 {
        if (p.isNull()) return null;
        return try p.str();
    }

    fn uint(p: *P) Error!u32 {
        p.ws();
        const start = p.i;
        var v: u64 = 0;
        while (p.i < p.s.len and p.s[p.i] >= '0' and p.s[p.i] <= '9') : (p.i += 1) {
            v = v * 10 + (p.s[p.i] - '0');
            if (v > std.math.maxInt(u32)) return error.Unsupported;
        }
        if (p.i == start or (p.s[start] == '0' and p.i - start > 1)) return error.Unsupported;
        switch (p.peek()) {
            '.', 'e', 'E' => return error.Unsupported,
            else => {},
        }
        return @intCast(v);
    }

    fn optEnum(p: *P, comptime E: type) Error!?E {
        if (p.isNull()) return null;
        return @enumFromInt(try p.uint());
    }

    fn optBool(p: *P) Error!?bool {
        if (p.isNull()) return null;
        if (p.literal("true")) return true;
        if (p.literal("false")) return false;
        return error.Unsupported;
    }

    /// Skips one value; returns its bytes.
    fn skip(p: *P) Error![]const u8 {
        p.ws();
        const start = p.i;
        switch (p.peek()) {
            '"' => _ = try p.str(),
            '{', '[' => {
                var depth: usize = 0;
                while (p.i < p.s.len) {
                    switch (p.s[p.i]) {
                        '"' => {
                            _ = try p.str();
                            continue;
                        },
                        '{', '[' => depth += 1,
                        '}', ']' => {
                            depth -= 1;
                            if (depth == 0) {
                                p.i += 1;
                                return p.s[start..p.i];
                            }
                        },
                        else => {},
                    }
                    p.i += 1;
                }
                return error.Unsupported;
            },
            else => {
                while (p.i < p.s.len) : (p.i += 1) switch (p.s[p.i]) {
                    ',', '}', ']', ' ', '\t', '\n', '\r' => break,
                    else => {},
                };
                if (p.i == start) return error.Unsupported;
            },
        }
        return p.s[start..p.i];
    }

    /// Any value, as std.json's dynamic `Value`.
    fn value(p: *P) Error!Value {
        p.ws();
        switch (p.peek()) {
            '"' => return .{ .string = try p.str() },
            '{' => {
                p.i += 1;
                var m: std.json.ObjectMap = .empty;
                var n: usize = 0;
                while (try p.key(&n)) |k| {
                    const gop = try m.getOrPut(p.a, k);
                    if (gop.found_existing) return error.Unsupported;
                    gop.value_ptr.* = try p.value();
                }
                return .{ .object = m };
            },
            '[' => {
                p.i += 1;
                var arr: std.json.Array = .init(p.a);
                var n: usize = 0;
                while (try p.more(&n)) try arr.append(try p.value());
                return .{ .array = arr };
            },
            else => {
                if (p.isNull()) return .null;
                if (p.literal("true")) return .{ .bool = true };
                if (p.literal("false")) return .{ .bool = false };
                const t = try p.skip();
                if (!isNumber(t)) return error.Unsupported;
                return Value.parseFromNumberSlice(t);
            },
        }
    }

    fn position(p: *P) Error!protocol.Position {
        try p.expect('{');
        var pos: protocol.Position = .{ .line = 0, .character = 0 };
        var seen: u2 = 0;
        var n: usize = 0;
        while (try p.key(&n)) |k| {
            if (std.mem.eql(u8, k, "line")) {
                if (seen & 1 != 0) return error.Unsupported;
                pos.line = try p.uint();
                seen |= 1;
            } else if (std.mem.eql(u8, k, "character")) {
                if (seen & 2 != 0) return error.Unsupported;
                pos.character = try p.uint();
                seen |= 2;
            } else _ = try p.skip();
        }
        if (seen != 3) return error.Unsupported;
        return pos;
    }

    fn range(p: *P) Error!protocol.Range {
        try p.expect('{');
        var start: ?protocol.Position = null;
        var end_: ?protocol.Position = null;
        var n: usize = 0;
        while (try p.key(&n)) |k| {
            if (std.mem.eql(u8, k, "start")) {
                start = try p.position();
            } else if (std.mem.eql(u8, k, "end")) {
                end_ = try p.position();
            } else _ = try p.skip();
        }
        return .{ .start = start orelse return error.Unsupported, .end = end_ orelse return error.Unsupported };
    }

    fn textEdit(p: *P) Error!protocol.TextEdit {
        try p.expect('{');
        var r: ?protocol.Range = null;
        var text: ?[]const u8 = null;
        var n: usize = 0;
        while (try p.key(&n)) |k| {
            if (std.mem.eql(u8, k, "range")) {
                r = try p.range();
            } else if (std.mem.eql(u8, k, "newText")) {
                text = try p.str();
            } else _ = try p.skip();
        }
        return .{ .range = r orelse return error.Unsupported, .newText = text orelse return error.Unsupported };
    }

    fn itemEdit(p: *P) Error!protocol.CompletionItemTextEdit {
        try p.expect('{');
        var r: ?protocol.Range = null;
        var ins: ?protocol.Range = null;
        var rep: ?protocol.Range = null;
        var text: ?[]const u8 = null;
        var n: usize = 0;
        while (try p.key(&n)) |k| {
            if (std.mem.eql(u8, k, "range")) {
                r = try p.range();
            } else if (std.mem.eql(u8, k, "insert")) {
                ins = try p.range();
            } else if (std.mem.eql(u8, k, "replace")) {
                rep = try p.range();
            } else if (std.mem.eql(u8, k, "newText")) {
                text = try p.str();
            } else _ = try p.skip();
        }
        const t = text orelse return error.Unsupported;
        if (r) |x| {
            if (ins != null or rep != null) return error.Unsupported;
            return .{ .text_edit = .{ .range = x, .newText = t } };
        }
        return .{ .insert_replace_edit = .{ .newText = t, .insert = ins orelse return error.Unsupported, .replace = rep orelse return error.Unsupported } };
    }

    fn documentation(p: *P) Error!protocol.CompletionItemDocumentation {
        p.ws();
        if (p.peek() == '"') return .{ .string = try p.str() };
        try p.expect('{');
        var kind: ?protocol.MarkupKind = null;
        var val: ?[]const u8 = null;
        var n: usize = 0;
        while (try p.key(&n)) |k| {
            if (std.mem.eql(u8, k, "kind")) {
                const s = try p.str();
                kind = if (std.mem.eql(u8, s, "markdown")) .Markdown else if (std.mem.eql(u8, s, "plaintext")) .PlainText else return error.Unsupported;
            } else if (std.mem.eql(u8, k, "value")) {
                val = try p.str();
            } else _ = try p.skip();
        }
        return .{ .markup_content = .{ .kind = kind orelse return error.Unsupported, .value = val orelse return error.Unsupported } };
    }

    fn labelDetails(p: *P) Error!protocol.CompletionItemLabelDetails {
        try p.expect('{');
        var d: protocol.CompletionItemLabelDetails = .{};
        var n: usize = 0;
        while (try p.key(&n)) |k| {
            if (std.mem.eql(u8, k, "detail")) {
                d.detail = try p.optStr();
            } else if (std.mem.eql(u8, k, "description")) {
                d.description = try p.optStr();
            } else _ = try p.skip();
        }
        return d;
    }

    fn command(p: *P) Error!protocol.Command {
        try p.expect('{');
        var title: ?[]const u8 = null;
        var cmd: ?[]const u8 = null;
        var c: protocol.Command = .{ .title = "", .command = "" };
        var n: usize = 0;
        while (try p.key(&n)) |k| {
            if (std.mem.eql(u8, k, "title")) {
                title = try p.str();
            } else if (std.mem.eql(u8, k, "command")) {
                cmd = try p.str();
            } else if (std.mem.eql(u8, k, "tooltip")) {
                c.tooltip = try p.optStr();
            } else if (std.mem.eql(u8, k, "arguments")) {
                if (p.isNull()) continue;
                try p.expect('[');
                var args: std.ArrayList(Value) = .empty;
                var m: usize = 0;
                while (try p.more(&m)) try args.append(p.a, try p.value());
                c.arguments = args.items;
            } else _ = try p.skip();
        }
        c.title = title orelse return error.Unsupported;
        c.command = cmd orelse return error.Unsupported;
        return c;
    }

    /// Decodes into `it` (items are big: no copy).
    fn item(p: *P, it: *protocol.CompletionItem) Error!void {
        try p.expect('{');
        var label: ?[]const u8 = null;
        it.* = .{ .label = "" };
        var seen: std.EnumSet(ItemKey) = .{};
        var n: usize = 0;
        while (try p.key(&n)) |k| {
            const which = std.meta.stringToEnum(ItemKey, k) orelse {
                _ = try p.skip();
                continue;
            };
            if (seen.contains(which)) return error.Unsupported;
            seen.insert(which);
            switch (which) {
                .label => label = try p.str(),
                .labelDetails => it.labelDetails = if (p.isNull()) null else try p.labelDetails(),
                .kind => it.kind = try p.optEnum(protocol.CompletionItemKind),
                .tags => {
                    if (p.isNull()) continue;
                    try p.expect('[');
                    var tags: std.ArrayList(protocol.CompletionItemTag) = .empty;
                    var m: usize = 0;
                    while (try p.more(&m)) try tags.append(p.a, @enumFromInt(try p.uint()));
                    it.tags = tags.items;
                },
                .detail => it.detail = try p.optStr(),
                .documentation => it.documentation = if (p.isNull()) null else try p.documentation(),
                .deprecated => it.deprecated = try p.optBool(),
                .preselect => it.preselect = try p.optBool(),
                .sortText => it.sortText = try p.optStr(),
                .filterText => it.filterText = try p.optStr(),
                .insertText => it.insertText = try p.optStr(),
                .insertTextFormat => it.insertTextFormat = try p.optEnum(protocol.InsertTextFormat),
                .insertTextMode => it.insertTextMode = try p.optEnum(protocol.InsertTextMode),
                .textEdit => it.textEdit = if (p.isNull()) null else try p.itemEdit(),
                .textEditText => it.textEditText = try p.optStr(),
                .additionalTextEdits => {
                    if (p.isNull()) continue;
                    try p.expect('[');
                    var edits: std.ArrayList(protocol.TextEdit) = .empty;
                    var m: usize = 0;
                    while (try p.more(&m)) try edits.append(p.a, try p.textEdit());
                    it.additionalTextEdits = edits.items;
                },
                .commitCharacters => {
                    if (p.isNull()) continue;
                    try p.expect('[');
                    var cs: std.ArrayList([]const u8) = .empty;
                    var m: usize = 0;
                    while (try p.more(&m)) try cs.append(p.a, try p.str());
                    it.commitCharacters = cs.items;
                },
                .command => it.command = if (p.isNull()) null else try p.command(),
                .data => it.data = if (p.isNull()) null else try p.value(),
            }
        }
        it.label = label orelse return error.Unsupported;
    }

    fn items(p: *P) Error![]const protocol.CompletionItem {
        try p.expect('[');
        // About one item per 200 bytes in real lists.
        var out: std.ArrayList(protocol.CompletionItem) = try .initCapacity(p.a, @min((p.s.len - p.i) / 200 + 1, 1 << 16));
        var n: usize = 0;
        while (try p.more(&n)) try p.item(try out.addOne(p.a));
        return out.items;
    }

    fn list(p: *P) Error!protocol.CompletionList {
        try p.expect('{');
        var incomplete: ?bool = null;
        var its: ?[]const protocol.CompletionItem = null;
        var l: protocol.CompletionList = .{ .isIncomplete = false, .items = &.{} };
        var seen: std.EnumSet(ListKey) = .{};
        var n: usize = 0;
        while (try p.key(&n)) |k| {
            const which = std.meta.stringToEnum(ListKey, k) orelse {
                _ = try p.skip();
                continue;
            };
            if (seen.contains(which)) return error.Unsupported;
            seen.insert(which);
            switch (which) {
                .isIncomplete => incomplete = (try p.optBool()) orelse return error.Unsupported,
                .items => its = try p.items(),
                .itemDefaults => l.itemDefaults = try p.sub(protocol.CompletionItemDefaults),
                .applyKind => l.applyKind = try p.sub(protocol.CompletionItemApplyKinds),
            }
        }
        l.isIncomplete = incomplete orelse return error.Unsupported;
        l.items = its orelse return error.Unsupported;
        return l;
    }

    /// A rare, small object through std.json.
    fn sub(p: *P, comptime T: type) Error!?T {
        if (p.isNull()) return null;
        const bytes = try p.skip();
        return std.json.parseFromSliceLeaky(T, p.a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Unsupported,
        };
    }
};

fn hex4(s: []const u8, j: usize) Error!u21 {
    if (j + 4 > s.len) return error.Unsupported;
    return std.fmt.parseInt(u16, s[j..][0..4], 16) catch error.Unsupported;
}

/// Whether `t` is a JSON number.
fn isNumber(t: []const u8) bool {
    var i: usize = 0;
    if (i < t.len and t[i] == '-') i += 1;
    if (i >= t.len) return false;
    if (t[i] == '0') {
        i += 1;
    } else if (t[i] >= '1' and t[i] <= '9') {
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    } else return false;
    if (i < t.len and t[i] == '.') {
        i += 1;
        const d = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        if (i == d) return false;
    }
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        i += 1;
        if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
        const d = i;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
        if (i == d) return false;
    }
    return i == t.len;
}
