//! Keys as modal input handlers see them: a code point or a named key,
//! with modifiers. The GUI turns its key events into these; tests write
//! them in Vim notation (`d2w`, `<Esc>`, `<C-v>`, `<lt>`).

const std = @import("std");

/// Named keys, numbered above the Unicode range.
pub const Special = enum(u21) {
    esc = 0x11_0000,
    enter,
    tab,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    insert,
};

pub const Key = struct {
    /// A Unicode scalar value or a `Special`. With `ctrl`, letters are
    /// lower case.
    code: u21,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    /// A plain character.
    pub fn char(cp: u21) Key {
        return .{ .code = cp };
    }

    /// A named key.
    pub fn named(s: Special) Key {
        return .{ .code = @intFromEnum(s) };
    }

    /// Ctrl plus `cp`.
    pub fn ctrlOf(cp: u21) Key {
        return .{ .code = std.ascii.toLower(@intCast(cp)), .ctrl = true };
    }

    /// The character typed, if this is one without Ctrl or Alt.
    pub fn text(k: Key) ?u21 {
        if (k.ctrl or k.alt or k.code >= 0x11_0000) return null;
        return k.code;
    }

    /// Whether this is the named key `s` (any modifiers but Ctrl/Alt).
    pub fn is(k: Key, s: Special) bool {
        return k.code == @intFromEnum(s) and !k.ctrl and !k.alt;
    }

    /// Whether this is Ctrl plus the letter `c`.
    pub fn isCtrl(k: Key, c: u8) bool {
        return k.ctrl and !k.alt and k.code == c;
    }

    /// Escape, or the keys Vim and Emacs treat like it (`<C-[>`, `<C-c>`).
    pub fn isEscape(k: Key) bool {
        return k.is(.esc) or k.isCtrl('[') or k.isCtrl('c');
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.code == b.code and a.ctrl == b.ctrl and a.alt == b.alt and a.shift == b.shift;
    }
};

const names = [_]struct { []const u8, Special }{
    .{ "esc", .esc },     .{ "cr", .enter },       .{ "enter", .enter },        .{ "return", .enter },
    .{ "tab", .tab },     .{ "bs", .backspace },   .{ "del", .delete },         .{ "left", .left },
    .{ "right", .right }, .{ "up", .up },          .{ "down", .down },          .{ "home", .home },
    .{ "end", .end },     .{ "pageup", .page_up }, .{ "pagedown", .page_down }, .{ "insert", .insert },
};

pub const ParseError = error{ BadNotation, TooManyKeys };

/// Parses Vim key notation into `out`; returns the number of keys.
pub fn parse(notation: []const u8, out: []Key) ParseError!usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < notation.len) {
        if (n == out.len) return error.TooManyKeys;
        if (notation[i] == '<') if (std.mem.indexOfScalarPos(u8, notation, i + 1, '>')) |close| {
            if (parseNamed(notation[i + 1 .. close])) |k| {
                out[n] = k;
                n += 1;
                i = close + 1;
                continue;
            }
        };
        const len = std.unicode.utf8ByteSequenceLength(notation[i]) catch return error.BadNotation;
        if (i + len > notation.len) return error.BadNotation;
        out[n] = .char(std.unicode.utf8Decode(notation[i..][0..len]) catch return error.BadNotation);
        n += 1;
        i += len;
    }
    return n;
}

fn parseNamed(body: []const u8) ?Key {
    var k: Key = .{ .code = 0 };
    var rest = body;
    while (rest.len > 2 and rest[1] == '-') {
        switch (std.ascii.toLower(rest[0])) {
            'c' => k.ctrl = true,
            'm', 'a' => k.alt = true,
            's' => k.shift = true,
            else => return null,
        }
        rest = rest[2..];
    }
    if (std.ascii.eqlIgnoreCase(rest, "lt")) {
        k.code = '<';
    } else if (std.ascii.eqlIgnoreCase(rest, "space")) {
        k.code = ' ';
    } else if (std.ascii.eqlIgnoreCase(rest, "bar")) {
        k.code = '|';
    } else if (std.ascii.eqlIgnoreCase(rest, "bslash")) {
        k.code = '\\';
    } else if (rest.len == 1) {
        k.code = if (k.ctrl) std.ascii.toLower(rest[0]) else rest[0];
        if (k.ctrl and k.code == '[') return .named(.esc);
    } else {
        for (names) |e| if (std.ascii.eqlIgnoreCase(rest, e[0])) {
            k.code = @intFromEnum(e[1]);
            return k;
        };
        return null;
    }
    if (!k.ctrl and !k.alt and !k.shift and rest.len == 1) return null; // "<x>" is literal
    return k;
}

test "key: notation" {
    var buf: [16]Key = undefined;
    const n = try parse("d2w<Esc><C-v><lt>é<CR><C-R>", &buf);
    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expect(buf[0].eql(.char('d')));
    try std.testing.expect(buf[3].isEscape());
    try std.testing.expect(buf[4].isCtrl('v'));
    try std.testing.expectEqual(@as(?u21, '<'), buf[5].text());
    try std.testing.expectEqual(@as(?u21, 'é'), buf[6].text());
    try std.testing.expect(buf[7].is(.enter));
    try std.testing.expect(buf[8].isCtrl('r'));
    // An unknown name stays literal.
    try std.testing.expectEqual(@as(usize, 5), try parse("<foo>", &buf));
}
