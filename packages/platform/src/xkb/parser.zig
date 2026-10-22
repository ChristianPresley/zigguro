//! Recursive-descent parser for server-sent XKB keymaps (text format V1):
//! `xkb_keymap { xkb_keycodes {...}; xkb_types {...}; xkb_compat {...};
//! xkb_symbols {...}; xkb_geometry {...}; };`. It keeps what resolution
//! needs (see `ast.zig`), skips actions, indicators and geometry, and
//! rejects `include`, which a resolved keymap never contains.

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const keysyms = @import("keysyms.zig");
const Token = lexer.Token;
const Tag = lexer.Tag;

const log = std.log.scoped(.xkb);

/// Parse errors. `Syntax` details are in the `Diagnostic`.
pub const Error = error{ OutOfMemory, Syntax, TooLarge, IncludeUnsupported };

/// Longest keymap text accepted.
pub const max_input = 1 << 20;
/// Deepest bracket nesting accepted.
pub const max_depth = 32;

/// Where and why parsing failed.
pub const Diagnostic = struct {
    line: u32 = 0,
    col: u32 = 0,
    message: []const u8 = "",
};

/// Parses `text`, allocating the result in `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8, diag: ?*Diagnostic) Error!ast.Ast {
    if (text.len > max_input) return error.TooLarge;
    var p: Parser = .{ .lx = .init(text), .arena = arena, .diag = diag };
    try p.advance();
    try p.keymap();
    if (p.unknown_keysyms > 0) log.debug("{d} unknown keysym names mapped to NoSymbol", .{p.unknown_keysyms});
    return p.out;
}

const Parser = struct {
    lx: lexer.Lexer,
    tok: Token = undefined,
    arena: std.mem.Allocator,
    diag: ?*Diagnostic,
    out: ast.Ast = .{},
    default_level_one_only: bool = false,
    default_repeat: bool = false,
    unknown_keysyms: usize = 0,

    fn advance(p: *Parser) Error!void {
        p.tok = p.lx.next() catch {
            if (p.diag) |d| d.* = .{ .line = p.lx.err_line, .col = p.lx.err_col, .message = "invalid token" };
            return error.Syntax;
        };
    }

    fn fail(p: *Parser, msg: []const u8) Error {
        if (p.diag) |d| d.* = .{ .line = p.tok.line, .col = p.tok.col, .message = msg };
        return error.Syntax;
    }

    fn expect(p: *Parser, tag: Tag, msg: []const u8) Error!Token {
        if (p.tok.tag != tag) return p.fail(msg);
        const t = p.tok;
        try p.advance();
        return t;
    }

    fn accept(p: *Parser, tag: Tag) Error!bool {
        if (p.tok.tag != tag) return false;
        try p.advance();
        return true;
    }

    fn is(p: *const Parser, name: []const u8) bool {
        return p.tok.tag == .ident and std.ascii.eqlIgnoreCase(p.tok.text, name);
    }

    fn keymap(p: *Parser) Error!void {
        while (p.tok.tag == .ident and !p.is("xkb_keymap")) try p.advance();
        if (!p.is("xkb_keymap")) return p.fail("expected xkb_keymap");
        try p.advance();
        _ = try p.accept(.string);
        _ = try p.expect(.lbrace, "expected '{' after xkb_keymap");
        while (p.tok.tag != .rbrace) {
            if (p.tok.tag == .eof) return p.fail("unterminated xkb_keymap");
            try p.section();
        }
        try p.advance();
        _ = try p.accept(.semi);
        if (p.tok.tag != .eof) return p.fail("text after the keymap");
    }

    fn section(p: *Parser) Error!void {
        const Kind = enum { keycodes, types, compat, symbols, geometry };
        var kind: ?Kind = null;
        while (p.tok.tag == .ident) {
            kind = if (p.is("xkb_keycodes")) .keycodes else if (p.is("xkb_types")) .types else if (p.is("xkb_compatibility") or p.is("xkb_compat") or p.is("xkb_compatibility_map")) .compat else if (p.is("xkb_symbols")) .symbols else if (p.is("xkb_geometry")) .geometry else null;
            try p.advance();
            if (kind != null) break;
        }
        const k = kind orelse return p.fail("expected a section");
        _ = try p.accept(.string);
        if (p.tok.tag != .lbrace) return p.fail("expected '{' to open the section");
        if (k == .geometry) {
            try p.skipBalanced();
            _ = try p.accept(.semi);
            return;
        }
        try p.advance();
        while (p.tok.tag != .rbrace) {
            if (p.tok.tag == .eof) return p.fail("unterminated section");
            if (try p.mergeMode()) continue;
            switch (k) {
                .keycodes => try p.keycodeStmt(),
                .types => try p.typesStmt(),
                .compat => try p.compatStmt(),
                .symbols => try p.symbolsStmt(),
                .geometry => unreachable,
            }
        }
        try p.advance();
        _ = try p.accept(.semi);
    }

    /// Handles `include "..."` (unsupported) and merge-mode prefixes.
    fn mergeMode(p: *Parser) Error!bool {
        if (p.is("include")) {
            log.info("keymap uses include at {d}:{d}; only resolved keymaps are supported", .{ p.tok.line, p.tok.col });
            if (p.diag) |d| d.* = .{ .line = p.tok.line, .col = p.tok.col, .message = "include is not supported" };
            return error.IncludeUnsupported;
        }
        if (p.is("augment") or p.is("override") or p.is("replace") or p.is("alternate")) {
            try p.advance();
            if (p.tok.tag == .string) {
                if (p.diag) |d| d.* = .{ .line = p.tok.line, .col = p.tok.col, .message = "include is not supported" };
                return error.IncludeUnsupported;
            }
            return true;
        }
        return false;
    }

    /// Skips one bracketed group starting at the current opening token.
    fn skipBalanced(p: *Parser) Error!void {
        var depth: usize = 0;
        while (true) {
            switch (p.tok.tag) {
                .lbrace, .lbracket, .lparen => {
                    depth += 1;
                    if (depth > max_depth) return p.fail("nesting too deep");
                },
                .rbrace, .rbracket, .rparen => {
                    if (depth == 0) return p.fail("unbalanced bracket");
                    depth -= 1;
                    if (depth == 0) {
                        try p.advance();
                        return;
                    }
                },
                .eof => return p.fail("unterminated block"),
                else => {},
            }
            try p.advance();
        }
    }

    /// Skips to just past the `;` that ends this statement, or to a `}`
    /// closing the enclosing block.
    fn skipStatement(p: *Parser) Error!void {
        while (true) switch (p.tok.tag) {
            .semi => return p.advance(),
            .rbrace => return,
            .eof => return p.fail("unexpected end of input"),
            .lbrace, .lbracket, .lparen => try p.skipBalanced(),
            .rbracket, .rparen => return p.fail("unbalanced bracket"),
            else => try p.advance(),
        };
    }

    /// Skips one comma-separated item inside a key body.
    fn skipItem(p: *Parser) Error!void {
        while (true) switch (p.tok.tag) {
            .comma, .rbrace => return,
            .eof => return p.fail("unexpected end of input"),
            .lbrace, .lbracket, .lparen => try p.skipBalanced(),
            .semi, .rbracket, .rparen => return p.fail("unexpected token in key"),
            else => try p.advance(),
        };
    }

    fn endStmt(p: *Parser) Error!void {
        _ = try p.expect(.semi, "expected ';'");
    }

    // xkb_keycodes

    fn keycodeStmt(p: *Parser) Error!void {
        if (p.tok.tag == .keyname) {
            const name = p.tok.text;
            try p.advance();
            _ = try p.expect(.equals, "expected '=' after key name");
            const code = try p.int(u32);
            try p.out.keycodes.append(p.arena, .{ .name = name, .code = code });
            return p.endStmt();
        }
        if (p.is("alias")) {
            try p.advance();
            const a = (try p.expect(.keyname, "expected key name")).text;
            _ = try p.expect(.equals, "expected '='");
            const r = (try p.expect(.keyname, "expected key name")).text;
            try p.out.aliases.append(p.arena, .{ .alias = a, .real = r });
            return p.endStmt();
        }
        return p.skipStatement();
    }

    fn int(p: *Parser, comptime T: type) Error!T {
        const t = try p.expect(.int, "expected a number");
        return parseInt(T, t.text) orelse p.fail("number out of range");
    }

    // Modifiers

    fn vmodIndex(p: *Parser, name: []const u8) Error!u8 {
        for (p.out.vmods.items, 0..) |v, i| if (std.ascii.eqlIgnoreCase(v.name, name)) return @intCast(i);
        if (p.out.vmods.items.len >= ast.max_vmods) return p.fail("too many virtual modifiers");
        try p.out.vmods.append(p.arena, .{ .name = name });
        return @intCast(p.out.vmods.items.len - 1);
    }

    fn modTerm(p: *Parser) Error!ast.Mods {
        if (p.tok.tag == .int) {
            const v = try p.int(u32);
            return .{ .real = @truncate(v) };
        }
        if (p.tok.tag != .ident) return p.fail("expected a modifier");
        const name = p.tok.text;
        try p.advance();
        for (ast.real_mod_names, 0..) |m, i| if (std.ascii.eqlIgnoreCase(m, name)) return .{ .real = @as(u8, 1) << @intCast(i) };
        if (std.ascii.eqlIgnoreCase(name, "none")) return .{};
        if (std.ascii.eqlIgnoreCase(name, "all")) return .{ .real = 0xff, .virtual = 0xffff };
        return .{ .virtual = @as(u16, 1) << @intCast(try p.vmodIndex(name)) };
    }

    fn mods(p: *Parser) Error!ast.Mods {
        var m = try p.modTerm();
        while (try p.accept(.plus)) m = m.with(try p.modTerm());
        return m;
    }

    fn vmodDecl(p: *Parser) Error!void {
        try p.advance();
        while (true) {
            const name = (try p.expect(.ident, "expected a modifier name")).text;
            const idx = try p.vmodIndex(name);
            if (try p.accept(.equals)) p.out.vmods.items[idx].explicit = (try p.mods()).real;
            if (!try p.accept(.comma)) break;
        }
        return p.endStmt();
    }

    // xkb_types

    fn typesStmt(p: *Parser) Error!void {
        if (p.is("virtual_modifiers")) return p.vmodDecl();
        if (p.is("type")) {
            try p.advance();
            if (p.tok.tag == .dot) return p.skipStatement();
            const name = (try p.expect(.string, "expected a type name")).text;
            _ = try p.expect(.lbrace, "expected '{'");
            var t: ast.KeyType = .{ .name = name };
            var entries: std.ArrayList(ast.TypeEntry) = .empty;
            var max_level: u8 = 0;
            while (p.tok.tag != .rbrace) {
                if (p.tok.tag == .eof) return p.fail("unterminated type");
                if (p.is("modifiers")) {
                    try p.advance();
                    _ = try p.expect(.equals, "expected '='");
                    t.mods = try p.mods();
                    try p.endStmt();
                } else if (p.is("map")) {
                    try p.advance();
                    _ = try p.expect(.lbracket, "expected '['");
                    const m = try p.mods();
                    _ = try p.expect(.rbracket, "expected ']'");
                    _ = try p.expect(.equals, "expected '='");
                    const lv = try p.level();
                    max_level = @max(max_level, lv);
                    if (findEntry(entries.items, m)) |e| e.level = lv else try entries.append(p.arena, .{ .mods = m, .level = lv });
                    try p.endStmt();
                } else if (p.is("preserve")) {
                    try p.advance();
                    _ = try p.expect(.lbracket, "expected '['");
                    const m = try p.mods();
                    _ = try p.expect(.rbracket, "expected ']'");
                    _ = try p.expect(.equals, "expected '='");
                    const keep = try p.mods();
                    if (findEntry(entries.items, m)) |e| e.preserve = keep else try entries.append(p.arena, .{ .mods = m, .level = 0, .preserve = keep });
                    try p.endStmt();
                } else if (p.is("level_name") or p.is("levelname")) {
                    try p.advance();
                    _ = try p.expect(.lbracket, "expected '['");
                    max_level = @max(max_level, try p.level());
                    _ = try p.expect(.rbracket, "expected ']'");
                    try p.skipStatement();
                } else try p.skipStatement();
            }
            try p.advance();
            _ = try p.accept(.semi);
            t.entries = entries.items;
            t.num_levels = max_level + 1;
            try p.out.types.append(p.arena, t);
            return;
        }
        return p.skipStatement();
    }

    fn findEntry(entries: []ast.TypeEntry, m: ast.Mods) ?*ast.TypeEntry {
        for (entries) |*e| if (e.mods.real == m.real and e.mods.virtual == m.virtual) return e;
        return null;
    }

    /// `LevelN` or `N`, returned 0-based.
    fn level(p: *Parser) Error!u8 {
        const n: u32 = if (p.tok.tag == .int) try p.int(u32) else blk: {
            const t = try p.expect(.ident, "expected a level");
            if (t.text.len < 6 or !std.ascii.eqlIgnoreCase(t.text[0..5], "level")) return p.fail("expected a level");
            break :blk parseInt(u32, t.text[5..]) orelse return p.fail("bad level");
        };
        if (n < 1 or n > 255) return p.fail("level out of range");
        return @intCast(n - 1);
    }

    /// `GroupN` or `N`, returned 0-based.
    fn group(p: *Parser) Error!u8 {
        const n: u32 = if (p.tok.tag == .int) try p.int(u32) else blk: {
            const t = try p.expect(.ident, "expected a group");
            if (t.text.len < 6 or !std.ascii.eqlIgnoreCase(t.text[0..5], "group")) return p.fail("expected a group");
            break :blk parseInt(u32, t.text[5..]) orelse return p.fail("bad group");
        };
        if (n < 1 or n > 32) return p.fail("group out of range");
        return @intCast(n - 1);
    }

    // xkb_compatibility

    fn compatStmt(p: *Parser) Error!void {
        if (p.is("virtual_modifiers")) return p.vmodDecl();
        if (p.is("interpret")) {
            try p.advance();
            if (try p.accept(.dot)) {
                const field = (try p.expect(.ident, "expected a field")).text;
                _ = try p.expect(.equals, "expected '='");
                if (std.ascii.eqlIgnoreCase(field, "useModMapMods")) {
                    p.default_level_one_only = try p.levelOneOnly();
                } else if (std.ascii.eqlIgnoreCase(field, "repeat")) {
                    p.default_repeat = try p.boolean();
                } else return p.skipStatement();
                return p.endStmt();
            }
            return p.interpret();
        }
        return p.skipStatement();
    }

    fn interpret(p: *Parser) Error!void {
        var it: ast.Interpret = .{ .keysym = null, .level_one_only = p.default_level_one_only, .repeat = p.default_repeat };
        if (p.is("any")) {
            try p.advance();
        } else it.keysym = try p.keysym();
        if (try p.accept(.plus)) {
            const pred: ?ast.Match = if (p.is("NoneOf")) .none_of else if (p.is("AnyOfOrNone")) .any_of_or_none else if (p.is("AnyOf")) .any_of else if (p.is("AllOf")) .all_of else if (p.is("Exactly")) .exactly else null;
            if (pred) |m| {
                try p.advance();
                _ = try p.expect(.lparen, "expected '('");
                it.mods = (try p.mods()).real;
                _ = try p.expect(.rparen, "expected ')'");
                it.match = m;
            } else {
                it.mods = (try p.mods()).real;
                it.match = .exactly;
            }
        }
        _ = try p.expect(.lbrace, "expected '{'");
        while (p.tok.tag != .rbrace) {
            if (p.tok.tag == .eof) return p.fail("unterminated interpret");
            if (p.is("virtualModifier") or p.is("virtualMod")) {
                try p.advance();
                _ = try p.expect(.equals, "expected '='");
                const name = (try p.expect(.ident, "expected a virtual modifier")).text;
                it.vmod = try p.vmodIndex(name);
                try p.endStmt();
            } else if (p.is("useModMapMods") or p.is("useModMap")) {
                try p.advance();
                _ = try p.expect(.equals, "expected '='");
                it.level_one_only = try p.levelOneOnly();
                try p.endStmt();
            } else if (p.is("repeat")) {
                try p.advance();
                _ = try p.expect(.equals, "expected '='");
                it.repeat = try p.boolean();
                try p.endStmt();
            } else try p.skipStatement();
        }
        try p.advance();
        _ = try p.accept(.semi);
        try p.out.interprets.append(p.arena, it);
    }

    fn levelOneOnly(p: *Parser) Error!bool {
        const t = try p.expect(.ident, "expected level1 or AnyLevel");
        if (std.ascii.eqlIgnoreCase(t.text, "level1") or std.ascii.eqlIgnoreCase(t.text, "levelone")) return true;
        if (std.ascii.eqlIgnoreCase(t.text, "anylevel") or std.ascii.eqlIgnoreCase(t.text, "any")) return false;
        return p.fail("expected level1 or AnyLevel");
    }

    fn boolean(p: *Parser) Error!bool {
        const t = try p.expect(.ident, "expected a boolean");
        for ([_][]const u8{ "true", "yes", "on" }) |w| if (std.ascii.eqlIgnoreCase(t.text, w)) return true;
        for ([_][]const u8{ "false", "no", "off" }) |w| if (std.ascii.eqlIgnoreCase(t.text, w)) return false;
        return p.fail("expected a boolean");
    }

    /// A keysym: a name, a digit 0-9 (that digit's keysym) or a number.
    fn keysym(p: *Parser) Error!u32 {
        switch (p.tok.tag) {
            .int => {
                const text = p.tok.text;
                try p.advance();
                if (text.len == 1) return text[0];
                return parseInt(u32, text) orelse p.fail("keysym out of range");
            },
            .ident => {
                const name = p.tok.text;
                try p.advance();
                if (keysyms.keysymFromName(name)) |v| return v;
                if (std.ascii.eqlIgnoreCase(name, "NoSymbol")) return 0;
                p.unknown_keysyms += 1;
                return 0;
            },
            else => return p.fail("expected a keysym"),
        }
    }

    // xkb_symbols

    fn symbolsStmt(p: *Parser) Error!void {
        if (p.is("virtual_modifiers")) return p.vmodDecl();
        if (p.is("key")) {
            try p.advance();
            if (p.tok.tag == .dot) return p.skipStatement();
            return p.key();
        }
        if (p.is("modifier_map") or p.is("modmap") or p.is("mod_map")) {
            try p.advance();
            const m = try p.mods();
            if (m.virtual != 0 or @popCount(m.real) != 1) return p.fail("modifier_map needs one real modifier");
            const idx: u3 = @intCast(@ctz(m.real));
            _ = try p.expect(.lbrace, "expected '{'");
            while (p.tok.tag != .rbrace) {
                const target: ast.ModMapTarget = if (p.tok.tag == .keyname) blk: {
                    const n = p.tok.text;
                    try p.advance();
                    break :blk .{ .keyname = n };
                } else .{ .keysym = try p.keysym() };
                try p.out.modmap.append(p.arena, .{ .real_index = idx, .target = target });
                if (!try p.accept(.comma)) break;
            }
            _ = try p.expect(.rbrace, "expected '}'");
            return p.endStmt();
        }
        return p.skipStatement();
    }

    fn key(p: *Parser) Error!void {
        var k: ast.Key = .{ .name = (try p.expect(.keyname, "expected key name")).text };
        _ = try p.expect(.lbrace, "expected '{'");
        var groups: std.ArrayList(ast.Group) = .empty;
        var all_type: ?[]const u8 = null;
        var bare: u8 = 0;
        while (p.tok.tag != .rbrace) {
            if (p.tok.tag == .eof) return p.fail("unterminated key");
            if (p.tok.tag == .lbracket) {
                const g = try groupSlot(p, &groups, bare);
                bare += 1;
                g.syms = try p.symList();
            } else if (p.is("type")) {
                try p.advance();
                if (try p.accept(.lbracket)) {
                    const gi = try p.group();
                    _ = try p.expect(.rbracket, "expected ']'");
                    _ = try p.expect(.equals, "expected '='");
                    (try groupSlot(p, &groups, gi)).type_name = (try p.expect(.string, "expected a type name")).text;
                } else {
                    _ = try p.expect(.equals, "expected '='");
                    all_type = (try p.expect(.string, "expected a type name")).text;
                }
            } else if (p.is("symbols")) {
                try p.advance();
                _ = try p.expect(.lbracket, "expected '['");
                const gi = try p.group();
                _ = try p.expect(.rbracket, "expected ']'");
                _ = try p.expect(.equals, "expected '='");
                (try groupSlot(p, &groups, gi)).syms = try p.symList();
            } else if (p.is("vmods") or p.is("virtualMods") or p.is("virtualModifiers")) {
                try p.advance();
                _ = try p.expect(.equals, "expected '='");
                k.vmods = (try p.mods()).virtual;
            } else if (p.is("repeat") or p.is("repeats") or p.is("repeating")) {
                try p.advance();
                _ = try p.expect(.equals, "expected '='");
                if (p.is("default")) try p.advance() else k.repeat = try p.boolean();
            } else try p.skipItem();
            if (!try p.accept(.comma)) break;
        }
        _ = try p.expect(.rbrace, "expected '}'");
        _ = try p.accept(.semi);
        if (all_type) |t| for (groups.items) |*g| {
            if (g.type_name == null) g.type_name = t;
        };
        k.groups = groups.items;
        try p.out.keys.append(p.arena, k);
    }

    fn groupSlot(p: *Parser, groups: *std.ArrayList(ast.Group), index: u8) Error!*ast.Group {
        if (index >= 32) return p.fail("too many groups");
        while (groups.items.len <= index) try groups.append(p.arena, .{});
        return &groups.items[index];
    }

    fn symList(p: *Parser) Error![]const u32 {
        _ = try p.expect(.lbracket, "expected '['");
        var syms: std.ArrayList(u32) = .empty;
        while (p.tok.tag != .rbracket) {
            if (try p.accept(.lbrace)) {
                // Several keysyms on one level: keep the first.
                var first: ?u32 = null;
                while (p.tok.tag != .rbrace) {
                    const s = try p.keysym();
                    if (first == null) first = s;
                    if (!try p.accept(.comma)) break;
                }
                _ = try p.expect(.rbrace, "expected '}'");
                try syms.append(p.arena, first orelse 0);
            } else try syms.append(p.arena, try p.keysym());
            if (syms.items.len > 255) return p.fail("too many levels");
            if (!try p.accept(.comma)) break;
        }
        _ = try p.expect(.rbracket, "expected ']'");
        return syms.items;
    }
};

fn parseInt(comptime T: type, text: []const u8) ?T {
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) return std.fmt.parseInt(T, text[2..], 16) catch null;
    return std.fmt.parseInt(T, text, 10) catch null;
}

const testing = std.testing;

test "parses a small keymap" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try parse(arena.allocator(),
        \\xkb_keymap {
        \\  xkb_keycodes "k" { minimum = 8; maximum = 255; <AE01> = 10; <LALT> = 64; alias <X> = <AE01>; indicator 1 = "Caps Lock"; };
        \\  xkb_types "t" {
        \\    virtual_modifiers NumLock, LevelThree;
        \\    type "TWO" { modifiers = Shift+NumLock; map[Shift] = Level2; preserve[Shift] = Shift; level_name[Level1] = "Base"; };
        \\  };
        \\  xkb_compat "c" {
        \\    interpret.useModMapMods = AnyLevel;
        \\    interpret Alt_L+AnyOf(all) { virtualModifier = Alt; action = SetMods(modifiers=modMapMods,clearLocks); };
        \\    interpret Any+Exactly(Lock) { action = LockMods(modifiers=Lock); };
        \\    indicator "Caps Lock" { modifiers = Lock; };
        \\  };
        \\  xkb_symbols "s" {
        \\    name[group1] = "US";
        \\    key <AE01> { type = "TWO", symbols[Group1] = [ 1, exclam ], symbols[Group2] = [ { a, b }, 0x41 ] };
        \\    key <LALT> { [ Alt_L, Meta_L ], vmods = Alt, repeat = No, actions[Group1] = [ SetMods(modifiers=Alt) ] };
        \\    modifier_map Mod1 { <LALT>, Meta_L };
        \\  };
        \\  xkb_geometry "g" { width = 1.5; shape "N" { { [ 18, 18 ] } }; };
        \\};
    ++ "\x00", null);
    try testing.expectEqual(2, a.keycodes.items.len);
    try testing.expectEqualStrings("<AE01>", a.keycodes.items[0].name);
    try testing.expectEqual(10, a.keycodes.items[0].code);
    try testing.expectEqualStrings("<X>", a.aliases.items[0].alias);
    try testing.expectEqual(3, a.vmods.items.len); // NumLock, LevelThree, Alt
    const t = a.types.items[0];
    try testing.expectEqual(0x01, t.mods.real);
    try testing.expectEqual(0x01, t.mods.virtual);
    try testing.expectEqual(1, t.entries[0].level);
    try testing.expectEqual(0x01, t.entries[0].preserve.real);
    try testing.expectEqual(2, t.num_levels);
    try testing.expectEqual(2, a.interprets.items.len);
    try testing.expectEqual(ast.Match.any_of, a.interprets.items[0].match);
    try testing.expectEqual(2, a.interprets.items[0].vmod.?);
    try testing.expectEqual(null, a.interprets.items[1].keysym);
    try testing.expectEqual(ast.Match.exactly, a.interprets.items[1].match);
    const k = a.keys.items[0];
    try testing.expectEqualStrings("TWO", k.groups[0].type_name.?);
    try testing.expectEqualSlices(u32, &.{ '1', '!' }, k.groups[0].syms);
    try testing.expectEqualSlices(u32, &.{ 'a', 0x41 }, k.groups[1].syms);
    const alt = a.keys.items[1];
    try testing.expectEqual(false, alt.repeat.?);
    try testing.expectEqual(0b100, alt.vmods.?);
    try testing.expectEqual(2, a.modmap.items.len);
    try testing.expectEqual(3, a.modmap.items[1].real_index);
}

test "include is rejected and syntax errors carry a position" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(error.IncludeUnsupported, parse(arena.allocator(), "xkb_keymap { xkb_symbols { include \"us\" }; };", &d));
    try testing.expectError(error.Syntax, parse(arena.allocator(), "xkb_keymap {\n  xkb_types { type \"A\" { map[Shift] = Level0; }; };\n};", &d));
    try testing.expectEqual(2, d.line);
    try testing.expectEqualStrings("level out of range", d.message);
    try testing.expectError(error.Syntax, parse(arena.allocator(), "xkb_keymap { xkb_symbols {", &d));
}
