//! Key specs: the textual key grammar of `keybindings.zon`, presets,
//! extensions and the `keybinding` setting type, plus matching candidates
//! for a key event on any keyboard layout. See `docs/keybindings.md`.
//!
//! ```
//! spec   := stroke (' ' stroke){0,3} | modtap ' ' modtap
//! stroke := (mod '+')* key
//! mod    := ctrl|control|shift|alt|option|opt|super|cmd|meta|win|mod|cmdorctrl
//! key    := letter | digit | punctuation | any single character  (logical)
//!         | enter|escape|esc|tab|space|backspace|delete|insert|home|end|pageup|pagedown
//!         | up|down|left|right|f1..f24|numpad0..9|numpad_add|...|contextmenu|capslock
//!         | '[' W3C code ']'                                        (physical)
//! modtap := shift|ctrl|alt|super   (bare, twice: a double tap, e.g. "shift shift")
//! ```

const std = @import("std");
const keys = @import("keys.zig");
const diag = @import("../diag.zig");

const Usage = keys.Usage;
const Mods = keys.Mods;
const Modifier = keys.Modifier;
const Diags = diag.Diags;

/// Platform conventions for `mod` and labels.
pub const Platform = enum {
    linux,
    windows,
    macos,

    /// The platform of `os`.
    pub fn of(os: std.Target.Os.Tag) Platform {
        return switch (os) {
            .windows => .windows,
            .macos => .macos,
            else => .linux,
        };
    }
};

/// One stroke.
pub const Stroke = struct {
    mods: Mods = .{},
    kind: Kind,
    /// Usage (physical), lowercase code point (logical) or `Modifier` (modtap).
    code: u21,

    /// Stroke kinds.
    pub const Kind = enum(u2) { physical, logical, modtap };

    /// Packs into a u32 (`mods:4 | kind:2 | code:21`) for hashing.
    pub fn pack(s: Stroke) u32 {
        return (@as(u32, @as(u4, @bitCast(s.mods))) << 23) | (@as(u32, @intFromEnum(s.kind)) << 21) | s.code;
    }

    /// Structural equality.
    pub fn eql(a: Stroke, b: Stroke) bool {
        return a.pack() == b.pack();
    }
};

/// Maximum strokes in a spec.
pub const max_strokes = 4;

/// A parsed spec.
pub const KeySpec = struct {
    strokes: [max_strokes]Stroke = undefined,
    len: u8 = 0,

    /// The strokes.
    pub fn slice(k: *const KeySpec) []const Stroke {
        return k.strokes[0..k.len];
    }

    /// Structural equality.
    pub fn eql(a: KeySpec, b: KeySpec) bool {
        if (a.len != b.len) return false;
        for (a.strokes[0..a.len], b.strokes[0..b.len]) |x, y| if (!x.eql(y)) return false;
        return true;
    }

    /// Whether this is a modifier double tap.
    pub fn isModTap(k: KeySpec) bool {
        return k.len == 2 and k.strokes[0].kind == .modtap;
    }
};

const named = std.StaticStringMap(Usage).initComptime(.{
    .{ "enter", 0x28 },           .{ "return", 0x28 },      .{ "escape", 0x29 },        .{ "esc", 0x29 },
    .{ "backspace", 0x2A },       .{ "tab", 0x2B },         .{ "space", 0x2C },         .{ "capslock", 0x39 },
    .{ "insert", 0x49 },          .{ "home", 0x4A },        .{ "pageup", 0x4B },        .{ "delete", 0x4C },
    .{ "end", 0x4D },             .{ "pagedown", 0x4E },    .{ "right", 0x4F },         .{ "left", 0x50 },
    .{ "down", 0x51 },            .{ "up", 0x52 },          .{ "numpad_divide", 0x54 }, .{ "numpad_multiply", 0x55 },
    .{ "numpad_subtract", 0x56 }, .{ "numpad_add", 0x57 },  .{ "numpad_enter", 0x58 },  .{ "numpad_decimal", 0x63 },
    .{ "contextmenu", 0x65 },     .{ "printscreen", 0x46 }, .{ "pause", 0x48 },         .{ "scrolllock", 0x47 },
});

fn namedKey(s: []const u8) ?Usage {
    if (named.get(s)) |u| return u;
    if (s.len >= 2 and s[0] == 'f') {
        const n = std.fmt.parseInt(u8, s[1..], 10) catch return null;
        if (n >= 1 and n <= 12) return 0x3A + @as(Usage, n) - 1;
        if (n >= 13 and n <= 24) return 0x68 + @as(Usage, n) - 13;
        return null;
    }
    if (std.mem.startsWith(u8, s, "numpad") and s.len == 7 and std.ascii.isDigit(s[6])) {
        const d = s[6] - '0';
        return if (d == 0) 0x62 else 0x59 + @as(Usage, d) - 1;
    }
    return null;
}

const fkey_names = blk: {
    var out: [24][]const u8 = undefined;
    for (&out, 1..) |*o, i| o.* = std.fmt.comptimePrint("f{d}", .{i});
    break :blk out;
};

fn namedName(u: Usage) ?[]const u8 {
    if (u >= 0x3A and u <= 0x45) return fkey_names[u - 0x3A];
    if (u >= 0x68 and u <= 0x73) return fkey_names[u - 0x68 + 12];
    for (named.keys(), named.values()) |k, v| {
        // Prefer the canonical spelling.
        if (v == u and !std.mem.eql(u8, k, "esc") and !std.mem.eql(u8, k, "return")) return k;
    }
    return null;
}

fn modifierWord(s: []const u8, plat: Platform) ?Modifier {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(s, "ctrl") or eq(s, "control")) return .ctrl;
    if (eq(s, "shift")) return .shift;
    if (eq(s, "alt") or eq(s, "option") or eq(s, "opt")) return .alt;
    if (eq(s, "super") or eq(s, "cmd") or eq(s, "meta") or eq(s, "win")) return .super;
    if (eq(s, "mod") or eq(s, "cmdorctrl")) return if (plat == .macos) .super else .ctrl;
    return null;
}

/// Parses `src` for `plat`. Errors go to `diags` with byte spans and return null.
pub fn parse(src: []const u8, plat: Platform, diags: *Diags) ?KeySpec {
    var spec: KeySpec = .{};
    const trimmed = std.mem.trim(u8, src, " ");
    if (trimmed.len == 0) {
        diags.add(.none, .err, "empty key spec", .{});
        return null;
    }
    const base: u32 = @intCast(std.mem.indexOf(u8, src, trimmed).?);
    var parts: [max_strokes + 1][]const u8 = undefined;
    var offs: [max_strokes + 1]u32 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    while (it.next()) |p| {
        if (n == parts.len) {
            diags.add(.{ .start = base, .end = base + @as(u32, @intCast(trimmed.len)) }, .err, "a key spec has at most {d} strokes", .{max_strokes});
            return null;
        }
        offs[n] = base + @as(u32, @intCast(it.index - p.len));
        parts[n] = p;
        n += 1;
    }
    if (n > max_strokes) {
        diags.add(.{ .start = base, .end = base + @as(u32, @intCast(trimmed.len)) }, .err, "a key spec has at most {d} strokes", .{max_strokes});
        return null;
    }
    // Modifier double tap: exactly two identical bare modifiers.
    if (n == 2) if (modifierWord(parts[0], plat)) |m0| if (modifierWord(parts[1], plat)) |m1| {
        if (m0 != m1) {
            diags.add(.{ .start = offs[0], .end = offs[1] + @as(u32, @intCast(parts[1].len)) }, .err, "a double tap repeats one modifier", .{});
            return null;
        }
        spec.strokes[0] = .{ .kind = .modtap, .code = @intFromEnum(m0) };
        spec.strokes[1] = spec.strokes[0];
        spec.len = 2;
        return spec;
    };
    for (parts[0..n], offs[0..n], 0..) |p, off, i| {
        spec.strokes[i] = parseStroke(p, off, plat, diags) orelse return null;
        if (spec.strokes[i].kind == .modtap) {
            diags.add(.{ .start = off, .end = off + @as(u32, @intCast(p.len)) }, .err, "a bare modifier is only allowed as a double tap (e.g. \"shift shift\")", .{});
            return null;
        }
    }
    spec.len = @intCast(n);
    return spec;
}

fn parseStroke(p: []const u8, off: u32, plat: Platform, diags: *Diags) ?Stroke {
    var mods: Mods = .{};
    var rest = p;
    var pos = off;
    while (true) {
        const plus = std.mem.indexOfScalar(u8, rest, '+') orelse break;
        if (plus == 0) break; // "+" as the key itself (e.g. "ctrl++")
        const word = rest[0..plus];
        const m = modifierWord(word, plat) orelse {
            diags.add(.{ .start = pos, .end = pos + @as(u32, @intCast(word.len)) }, .err, "unknown modifier '{s}'", .{word});
            return null;
        };
        if (mods.has(m)) {
            diags.add(.{ .start = pos, .end = pos + @as(u32, @intCast(word.len)) }, .err, "modifier '{s}' repeated", .{word});
            return null;
        }
        mods = mods.with(m);
        rest = rest[plus + 1 ..];
        pos += @intCast(plus + 1);
    }
    const span: diag.Span = .{ .start = pos, .end = pos + @as(u32, @intCast(rest.len)) };
    if (rest.len == 0) {
        diags.add(span, .err, "missing key after '+'", .{});
        return null;
    }
    if (rest[0] == '[' and rest.len > 1) {
        if (rest[rest.len - 1] != ']') {
            diags.add(span, .err, "unterminated physical key '{s}'", .{rest});
            return null;
        }
        const u = keys.fromName(rest[1 .. rest.len - 1]) orelse {
            diags.add(span, .err, "unknown physical key '{s}' (use a W3C code such as [KeyA])", .{rest});
            return null;
        };
        return .{ .mods = mods, .kind = .physical, .code = u };
    }
    var lower_buf: [32]u8 = undefined;
    if (rest.len <= lower_buf.len) {
        const low = std.ascii.lowerString(&lower_buf, rest);
        if (namedKey(low)) |u| return .{ .mods = mods, .kind = .physical, .code = u };
        if (mods.isEmpty() and modifierWord(low, plat) != null) return .{ .kind = .modtap, .code = @intFromEnum(modifierWord(low, plat).?) };
    }
    const view = std.unicode.Utf8View.init(rest) catch {
        diags.add(span, .err, "key is not valid UTF-8", .{});
        return null;
    };
    var cps = view.iterator();
    const c = cps.nextCodepoint().?;
    if (cps.nextCodepoint() != null) {
        diags.add(span, .err, "unknown key '{s}'", .{rest});
        return null;
    }
    return .{ .mods = mods, .kind = .logical, .code = keys.lower(c) };
}

/// Output style of `format`.
pub const Style = enum {
    /// Human label: "Ctrl+Shift+P" or "⌃⇧P" on macOS.
    label,
    /// Canonical config text: "ctrl+shift+p".
    config,
};

/// Writes `spec`. Labels for logical keys show the character; physical keys
/// show the layout character when `layout` knows one, else the code name.
pub fn format(spec: KeySpec, plat: Platform, style: Style, layout: ?*const keys.LayoutInfo, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (spec.isModTap()) {
        const m: Modifier = @enumFromInt(spec.strokes[0].code);
        const nm = modName(m, plat, style);
        return w.print("{s}{s}{s}", .{ nm, if (style == .label) ", " else " ", nm });
    }
    for (spec.slice(), 0..) |s, i| {
        if (i != 0) try w.writeAll(if (style == .label) ", " else " ");
        try formatStroke(s, plat, style, layout, w);
    }
}

fn modName(m: Modifier, plat: Platform, style: Style) []const u8 {
    if (style == .config) return @tagName(m);
    if (plat == .macos) return switch (m) {
        .ctrl => "⌃",
        .alt => "⌥",
        .shift => "⇧",
        .super => "⌘",
    };
    return switch (m) {
        .ctrl => "Ctrl",
        .alt => "Alt",
        .shift => "Shift",
        .super => if (plat == .windows) "Win" else "Super",
    };
}

fn formatStroke(s: Stroke, plat: Platform, style: Style, layout: ?*const keys.LayoutInfo, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const order: []const Modifier = if (style == .label and plat == .macos) &.{ .ctrl, .alt, .shift, .super } else &.{ .ctrl, .alt, .shift, .super };
    const sep: []const u8 = if (style == .label and plat == .macos) "" else "+";
    for (order) |m| if (s.mods.has(m)) try w.print("{s}{s}", .{ modName(m, plat, style), sep });
    switch (s.kind) {
        .modtap => try w.writeAll(modName(@enumFromInt(s.code), plat, style)),
        .logical => {
            const c: u21 = if (style == .label) upper(s.code) else s.code;
            if (style == .config and c == ' ') return w.writeAll("space");
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &buf) catch 0;
            try w.writeAll(buf[0..n]);
            if (style == .label) if (layout) |l| if (l.keyForChar(s.code) == null) try w.writeAll(" (US)");
        },
        .physical => {
            const u: Usage = @intCast(s.code);
            if (style == .config) {
                if (namedName(u)) |nm| return w.writeAll(nm);
                if (keys.name(u)) |nm| return w.print("[{s}]", .{nm});
                return w.print("[0x{x}]", .{u});
            }
            if (namedName(u)) |nm| return writeTitle(w, nm);
            if (layout) |l| if (l.baseChar(u)) |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(upper(c), &buf) catch 0;
                return w.writeAll(buf[0..n]);
            };
            try w.writeAll(keys.name(u) orelse "?");
        },
    }
}

fn writeTitle(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte(std.ascii.toUpper(s[0]));
    try w.writeAll(s[1..]);
}

fn upper(c: u21) u21 {
    if (c < 0x80) return std.ascii.toUpper(@intCast(c));
    if (c >= 0xE0 and c <= 0xFE and c != 0xF7) return c - 0x20;
    if (c >= 0x430 and c <= 0x44F) return c - 0x20;
    return c;
}

/// Dispatch mode (setting `keyboard.dispatch`).
pub const Dispatch = enum { auto, physical, logical };

/// The strokes an event may match, most specific first: physical, logical
/// (layout level-1 character), US fallback for non-Latin layouts, and the
/// produced character without Shift for shifted-symbol bindings. Releases
/// and AltGr chords produce none.
pub fn candidates(ev: keys.KeyInput, layout: *const keys.LayoutInfo, dispatch: Dispatch, out: *[4]Stroke) []Stroke {
    if (ev.action == .release) return out[0..0];
    var n: usize = 0;
    var mods = ev.mods.bindable();
    if (ev.mods.alt_gr) {
        // Typing through AltGr must never trigger Ctrl+Alt bindings.
        if (ev.usage != keys.alt_right) return out[0..0];
        mods.ctrl = false;
        mods.alt = false;
    }
    if (dispatch != .logical) {
        out[n] = .{ .mods = mods, .kind = .physical, .code = ev.usage };
        n += 1;
    }
    if (dispatch == .physical) return out[0..n];
    const base = layout.baseChar(ev.usage);
    if (base) |c| {
        out[n] = .{ .mods = mods, .kind = .logical, .code = c };
        n += 1;
    }
    if (!layout.isLatin() or (base != null and base.? >= 0x80)) if (keys.usChar(ev.usage)) |c| {
        if (base == null or base.? != c) {
            out[n] = .{ .mods = mods, .kind = .logical, .code = c };
            n += 1;
        }
    };
    if (ev.codepoint) |cp| if (mods.shift and n < out.len) {
        var m = mods;
        m.shift = false;
        const lc = keys.lower(cp);
        if (base == null or base.? != lc) {
            out[n] = .{ .mods = m, .kind = .logical, .code = cp };
            n += 1;
        }
    };
    return out[0..n];
}

const testing = std.testing;

fn roundTrip(src: []const u8, plat: Platform, want: []const u8) !void {
    var d = Diags.init(testing.allocator);
    defer d.deinit();
    const spec = parse(src, plat, &d) orelse {
        for (d.items()) |x| std.debug.print("'{s}': {s}\n", .{ src, x.message });
        return error.TestUnexpectedResult;
    };
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try format(spec, plat, .config, null, &w);
    try testing.expectEqualStrings(want, w.buffered());
    // Re-parse is stable.
    const again = parse(w.buffered(), plat, &d).?;
    try testing.expect(spec.eql(again));
}

test "keyspec: parse/format round trip" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "ctrl+shift+p", "ctrl+shift+p" },                     .{ "Ctrl+Shift+P", "ctrl+shift+p" },               .{ "control+a", "ctrl+a" },
        .{ "shift+alt+a", "alt+shift+a" },                       .{ "option+x", "alt+x" },                          .{ "cmd+s", "super+s" },
        .{ "win+e", "super+e" },                                 .{ "meta+k", "super+k" },                          .{ "ctrl+k ctrl+s", "ctrl+k ctrl+s" },
        .{ "ctrl+k s", "ctrl+k s" },                             .{ "g g", "g g" },                                 .{ "a b c d", "a b c d" },
        .{ "f1", "f1" },                                         .{ "F12", "f12" },                                 .{ "shift+f13", "shift+f13" },
        .{ "f24", "f24" },                                       .{ "enter", "enter" },                             .{ "return", "enter" },
        .{ "esc", "escape" },                                    .{ "escape", "escape" },                           .{ "tab", "tab" },
        .{ "shift+tab", "shift+tab" },                           .{ "space", "space" },                             .{ "ctrl+space", "ctrl+space" },
        .{ "backspace", "backspace" },                           .{ "delete", "delete" },                           .{ "insert", "insert" },
        .{ "home", "home" },                                     .{ "end", "end" },                                 .{ "pageup", "pageup" },
        .{ "pagedown", "pagedown" },                             .{ "up", "up" },                                   .{ "down", "down" },
        .{ "left", "left" },                                     .{ "right", "right" },                             .{ "alt+left", "alt+left" },
        .{ "numpad0", "[Numpad0]" },                             .{ "numpad5", "[Numpad5]" },                       .{ "numpad_add", "numpad_add" },
        .{ "numpad_subtract", "numpad_subtract" },               .{ "numpad_enter", "numpad_enter" },               .{ "contextmenu", "contextmenu" },
        .{ "capslock", "capslock" },                             .{ "ctrl+`", "ctrl+`" },                           .{ "ctrl+-", "ctrl+-" },
        .{ "ctrl+=", "ctrl+=" },                                 .{ "ctrl+[", "ctrl+[" },                           .{ "ctrl+]", "ctrl+]" },
        .{ "ctrl+\\", "ctrl+\\" },                               .{ "ctrl+;", "ctrl+;" },                           .{ "ctrl+'", "ctrl+'" },
        .{ "ctrl+,", "ctrl+," },                                 .{ "ctrl+.", "ctrl+." },                           .{ "ctrl+/", "ctrl+/" },
        .{ "ctrl+?", "ctrl+?" },                                 .{ "ctrl++", "ctrl++" },                           .{ "shift+1", "shift+1" },
        .{ "ctrl+0", "ctrl+0" },                                 .{ "[KeyA]", "[KeyA]" },                           .{ "ctrl+[Slash]", "ctrl+[Slash]" },
        .{ "[IntlBackslash]", "[IntlBackslash]" },               .{ "alt+[Digit1]", "alt+[Digit1]" },               .{ "[Enter]", "enter" },
        .{ "ctrl+alt+shift+super+x", "ctrl+alt+shift+super+x" }, .{ "shift shift", "shift shift" },                 .{ "ctrl ctrl", "ctrl ctrl" },
        .{ "alt alt", "alt alt" },
        .{ "ctrl+ü", "ctrl+ü" },
        .{ "ctrl+Ü", "ctrl+ü" },
        .{ "ctrl+ж", "ctrl+ж" },
        .{ "  ctrl+a  ", "ctrl+a" },                             .{ "ctrl+k ctrl+shift+s", "ctrl+k ctrl+shift+s" }, .{ "alt+f4", "alt+f4" },
        .{ "printscreen", "printscreen" },                       .{ "pause", "pause" },                             .{ "ctrl+shift+alt+f", "ctrl+alt+shift+f" },
        .{ "ctrl+k ctrl+0", "ctrl+k ctrl+0" },                   .{ "ctrl+k v", "ctrl+k v" },                       .{ "super+shift+[KeyZ]", "shift+super+[KeyZ]" },
        .{ "ctrl+numpad_divide", "ctrl+numpad_divide" },         .{ "shift+insert", "shift+insert" },               .{ "ctrl+pagedown", "ctrl+pagedown" },
    };
    try testing.expect(cases.len >= 80);
    for (cases) |c| for ([_]Platform{ .linux, .windows, .macos }) |p| try roundTrip(c[0], p, c[1]);
}

test "keyspec: mod mapping per platform" {
    var d = Diags.init(testing.allocator);
    defer d.deinit();
    try testing.expect(parse("mod+s", .linux, &d).?.strokes[0].mods.ctrl);
    try testing.expect(parse("cmdorctrl+s", .windows, &d).?.strokes[0].mods.ctrl);
    const mac = parse("mod+s", .macos, &d).?.strokes[0].mods;
    try testing.expect(mac.super and !mac.ctrl);
}

test "keyspec: errors with positions" {
    const cases = [_]struct { []const u8, u32, []const u8 }{
        .{ "hyper+a", 0, "unknown modifier" },
        .{ "ctrl+ctrl+a", 5, "repeated" },
        .{ "ctrl+", 5, "missing key" },
        .{ "ctrl+foo", 5, "unknown key" },
        .{ "a b c d e", 0, "at most" },
        .{ "[Nope]", 0, "unknown physical" },
        .{ "shift ctrl", 0, "double tap" },
        .{ "shift a", 0, "bare modifier" },
        .{ "", 0, "empty" },
    };
    for (cases) |c| {
        var d = Diags.init(testing.allocator);
        defer d.deinit();
        try testing.expect(parse(c[0], .linux, &d) == null);
        const first = d.items()[0];
        if (first.span.start != c[1] or std.mem.indexOf(u8, first.message, c[2]) == null) {
            std.debug.print("'{s}': got {d} '{s}'\n", .{ c[0], first.span.start, first.message });
            return error.TestUnexpectedResult;
        }
    }
}

test "keyspec: modtap" {
    var d = Diags.init(testing.allocator);
    defer d.deinit();
    const s = parse("shift shift", .linux, &d).?;
    try testing.expect(s.isModTap());
    try testing.expectEqual(@as(u21, @intFromEnum(Modifier.shift)), s.strokes[0].code);
}

fn labelOf(src: []const u8, plat: Platform, layout: ?*const keys.LayoutInfo) ![]const u8 {
    var d = Diags.init(testing.allocator);
    defer d.deinit();
    const spec = parse(src, plat, &d).?;
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.buf);
    try format(spec, plat, .label, layout, &w);
    return w.buffered();
}

test "labels: platform symbols and order" {
    try testing.expectEqualStrings("Ctrl+Shift+P", try labelOf("shift+ctrl+p", .linux, null));
    try testing.expectEqualStrings("⌃⌥⇧⌘P", try labelOf("cmd+shift+alt+ctrl+p", .macos, null));
    try testing.expectEqualStrings("⌘S", try labelOf("mod+s", .macos, null));
    try testing.expectEqualStrings("Ctrl+K, Ctrl+S", try labelOf("ctrl+k ctrl+s", .windows, null));
    try testing.expectEqualStrings("Win+E", try labelOf("win+e", .windows, null));
    try testing.expectEqualStrings("Shift, Shift", try labelOf("shift shift", .linux, null));
    try testing.expectEqualStrings("Pageup", try labelOf("pageup", .linux, null));
}

test "labels: unreachable char marked (US); physical shows layout char" {
    try testing.expectEqualStrings("Ctrl+` (US)", try labelOf("ctrl+`", .linux, &keys.fixtures.de));
    try testing.expectEqualStrings("Ctrl+Z", try labelOf("ctrl+z", .linux, &keys.fixtures.de));
    try testing.expectEqualStrings("Ctrl+Y", try labelOf("ctrl+[KeyZ]", .linux, &keys.fixtures.de));
    try testing.expectEqualStrings("Ctrl+KeyZ", try labelOf("ctrl+[KeyZ]", .linux, null));
}

fn matches(spec_src: []const u8, ev: keys.KeyInput, layout: *const keys.LayoutInfo) !bool {
    var d = Diags.init(testing.allocator);
    defer d.deinit();
    const spec = parse(spec_src, .linux, &d).?;
    var buf: [4]Stroke = undefined;
    for (candidates(ev, layout, .auto, &buf)) |c| if (c.eql(spec.strokes[0])) return true;
    return false;
}

test "layout: de QWERTZ ctrl+z by logical" {
    // On QWERTZ the Z character is on the physical KeyY.
    try testing.expect(try matches("ctrl+z", .{ .usage = 0x1C, .mods = .{ .ctrl = true } }, &keys.fixtures.de));
    try testing.expect(!try matches("ctrl+z", .{ .usage = 0x1D, .mods = .{ .ctrl = true } }, &keys.fixtures.de));
    try testing.expect(try matches("ctrl+[KeyZ]", .{ .usage = 0x1D, .mods = .{ .ctrl = true } }, &keys.fixtures.de));
}

test "layout: ru ctrl+c fallback" {
    try testing.expect(try matches("ctrl+c", .{ .usage = 0x06, .mods = .{ .ctrl = true } }, &keys.fixtures.ru));
    try testing.expect(try matches("ctrl+с", .{ .usage = 0x06, .mods = .{ .ctrl = true } }, &keys.fixtures.ru));
}

test "layout: fr AZERTY digits row ctrl+1 matches via physical" {
    try testing.expect(try matches("ctrl+[Digit1]", .{ .usage = 0x1E, .mods = .{ .ctrl = true } }, &keys.fixtures.fr_azerty));
    try testing.expect(try matches("ctrl+&", .{ .usage = 0x1E, .mods = .{ .ctrl = true } }, &keys.fixtures.fr_azerty));
    try testing.expect(try matches("ctrl+a", .{ .usage = 0x14, .mods = .{ .ctrl = true } }, &keys.fixtures.fr_azerty));
}

test "layout: dvorak logical" {
    try testing.expect(try matches("ctrl+s", .{ .usage = 0x33, .mods = .{ .ctrl = true } }, &keys.fixtures.dvorak));
    try testing.expect(!try matches("ctrl+s", .{ .usage = 0x16, .mods = .{ .ctrl = true } }, &keys.fixtures.dvorak));
}

test "layout: AltGr never matches ctrl+alt" {
    try testing.expect(!try matches("ctrl+alt+q", .{ .usage = 0x14, .mods = .{ .ctrl = true, .alt = true, .alt_gr = true }, .codepoint = '@' }, &keys.fixtures.de));
    try testing.expect(try matches("ctrl+alt+q", .{ .usage = 0x14, .mods = .{ .ctrl = true, .alt = true } }, &keys.fixtures.de));
}

test "layout: shifted symbol by produced character" {
    // On German, '?' is Shift+ß.
    try testing.expect(try matches("ctrl+?", .{ .usage = 0x2D, .mods = .{ .ctrl = true, .shift = true }, .codepoint = '?' }, &keys.fixtures.de));
    try testing.expect(!try matches("ctrl+?", .{ .usage = 0x2D, .mods = .{ .ctrl = true }, .codepoint = 0xDF }, &keys.fixtures.de));
}
