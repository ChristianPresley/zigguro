//! The input steps of `.vtt` scripts: `@key`, `@mouse`, `@paste` and
//! `@focus` build events from their words and run them through the input
//! encoders with the terminal's current modes; `@expect-input` checks the
//! bytes they produced. See `testdata/conformance/README.md`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("../term/Terminal.zig");
const input = @import("../input.zig");
const keytables = input.keytables;
const vtt = @import("vtt.zig");

pub const Error = error{ BadKey, BadMouse, BadString };

/// Parses `@key` words: `NAME [MOD...] [press|repeat|release] [text="..."]
/// [shifted=C] [base=C]`. A letter or digit names its key; other names are
/// `Key` tags (`up`, `f5`, `kp_1`, `left_shift`). Without `text=`, a text
/// key with no Ctrl, Alt or Super types its US-layout character (shifted).
pub fn parseKey(arena: Allocator, words: []const []const u8) Error!input.KeyInput {
    if (words.len == 0) return error.BadKey;
    var k: input.KeyInput = .{ .key = keyByName(words[0]) orelse return error.BadKey };
    var text: ?[]const u8 = null;
    for (words[1..]) |w| {
        if (std.mem.startsWith(u8, w, "text=")) {
            text = vtt.unquote(arena, w["text=".len..]) catch return error.BadString;
        } else if (std.mem.startsWith(u8, w, "shifted=")) {
            k.shifted_cp = oneCodepoint(w["shifted=".len..]) orelse return error.BadKey;
        } else if (std.mem.startsWith(u8, w, "base=")) {
            k.base_layout_cp = oneCodepoint(w["base=".len..]) orelse return error.BadKey;
        } else if (std.meta.stringToEnum(input.Action, w)) |a| {
            k.action = a;
        } else if (!setMod(&k.mods, w)) return error.BadKey;
    }
    k.text = text orelse autoText(arena, k) catch return error.BadKey;
    return k;
}

fn keyByName(name: []const u8) ?input.Key {
    if (name.len == 1) switch (name[0]) {
        'a'...'z' => return @enumFromInt(@intFromEnum(input.Key.key_a) + (name[0] - 'a')),
        '1'...'9' => return @enumFromInt(@intFromEnum(input.Key.digit_1) + (name[0] - '1')),
        '0' => return .digit_0,
        else => {},
    };
    return std.meta.stringToEnum(input.Key, name);
}

fn oneCodepoint(s: []const u8) ?u21 {
    const n = std.unicode.utf8ByteSequenceLength(if (s.len > 0) s[0] else return null) catch return null;
    if (n != s.len) return null;
    return std.unicode.utf8Decode(s) catch null;
}

fn setMod(m: *input.Mods, w: []const u8) bool {
    inline for (.{ "shift", "ctrl", "alt", "super", "alt_gr", "caps_lock", "num_lock" }) |name| {
        if (std.mem.eql(u8, w, name)) {
            @field(m, name) = true;
            return true;
        }
    }
    return false;
}

const shift_pairs = "1!2@3#4$5%6^7&8*9(0)-_=+[{]}\\|;:'\",<.>/?`~";

fn autoText(arena: Allocator, k: input.KeyInput) ![]const u8 {
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return "";
    var cp = keytables.usCodepoint(k.key);
    if (cp == 0) return "";
    if (k.mods.shift or k.mods.caps_lock) {
        if (cp >= 'a' and cp <= 'z') cp -= 32 else if (k.mods.shift) {
            var i: usize = 0;
            while (i < shift_pairs.len) : (i += 2) if (shift_pairs[i] == cp) {
                cp = shift_pairs[i + 1];
                break;
            };
        }
    }
    const out = try arena.alloc(u8, 4);
    const n = std.unicode.utf8Encode(cp, out) catch unreachable;
    return out[0..n];
}

/// Parses `@mouse` words: `press|release|motion|wheel BUTTON ROW,COL
/// [MOD...] [px=X,Y] [held=BUTTON...]`. Buttons are `left`, `middle`,
/// `right`, `none` (motion without a button), `up`, `down`, `wheel_left`,
/// `wheel_right`, `b8`-`b11`.
pub fn parseMouse(words: []const []const u8) Error!input.mouse.MouseInput {
    if (words.len < 3) return error.BadMouse;
    const Kind = @FieldType(input.mouse.MouseInput, "kind");
    const kind = std.meta.stringToEnum(Kind, words[0]) orelse return error.BadMouse;
    const button = buttonByName(words[1]) orelse return error.BadMouse;
    const rc = pair(words[2], ',') orelse return error.BadMouse;
    if (rc[0] == 0 or rc[1] == 0) return error.BadMouse;
    var ev: input.mouse.MouseInput = .{ .kind = kind, .button = button, .cell = .{ @intCast(rc[1] - 1), @intCast(rc[0] - 1) } };
    for (words[3..]) |w| {
        if (std.mem.startsWith(u8, w, "px=")) {
            const p = pair(w[3..], ',') orelse return error.BadMouse;
            ev.px = .{ p[0], p[1] };
        } else if (std.mem.startsWith(u8, w, "held=")) {
            const b = buttonByName(w[5..]) orelse return error.BadMouse;
            if (b > 2) return error.BadMouse;
            ev.buttons_down |= @as(u8, 1) << @intCast(b);
        } else if (!setMod(&ev.mods, w)) return error.BadMouse;
    }
    if (kind == .motion and button != 3) ev.buttons_down |= if (button <= 2) @as(u8, 1) << @intCast(button) else 0;
    return ev;
}

fn buttonByName(name: []const u8) ?u8 {
    const names = [_]struct { []const u8, u8 }{
        .{ "left", 0 }, .{ "middle", 1 }, .{ "right", 2 },       .{ "none", 3 },
        .{ "up", 64 },  .{ "down", 65 },  .{ "wheel_left", 66 }, .{ "wheel_right", 67 },
        .{ "b8", 128 }, .{ "b9", 129 },   .{ "b10", 130 },       .{ "b11", 131 },
    };
    for (names) |n| if (std.mem.eql(u8, n[0], name)) return n[1];
    return null;
}

fn pair(s: []const u8, sep: u8) ?[2]u32 {
    const i = std.mem.indexOfScalar(u8, s, sep) orelse return null;
    const a = std.fmt.parseInt(u32, s[0..i], 10) catch return null;
    const b = std.fmt.parseInt(u32, s[i + 1 ..], 10) catch return null;
    return .{ a, b };
}

/// Runs an input step, appending the encoded bytes to `out`. Errors name a
/// malformed step.
pub fn run(gpa: Allocator, t: *const Terminal, step: vtt.Step, out: *std.ArrayList(u8)) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const st = t.encoderState();
    switch (step) {
        .key => |words| {
            var buf: [64]u8 = undefined;
            try out.appendSlice(gpa, input.encodeKey(&st, try parseKey(arena, words), &buf));
        },
        .mouse => |words| {
            var buf: [32]u8 = undefined;
            const ev = try parseMouse(words);
            if (ev.kind == .wheel and st.mouse == .none) {
                var sbuf: [64]u8 = undefined;
                try out.appendSlice(gpa, input.mouse.altScroll(&st, ev.button == 64, 1, &sbuf));
            } else try out.appendSlice(gpa, input.encodeMouse(&st, ev, &buf));
        },
        .paste => |text| {
            var enc: std.ArrayList(u8) = .empty;
            defer enc.deinit(gpa);
            const verdict = try input.encodePaste(&st, text, .{ .confirm_multiline = false }, &enc, gpa);
            if (verdict == .send) try out.appendSlice(gpa, enc.items);
        },
        .focus => |focused| try out.appendSlice(gpa, input.encodeFocus(&st, focused)),
        else => unreachable,
    }
}

test "parseKey names and defaults" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const k = try parseKey(a, &.{ "a", "shift" });
    try std.testing.expectEqual(input.Key.key_a, k.key);
    try std.testing.expectEqualStrings("A", k.text);
    const c = try parseKey(a, &.{ "1", "ctrl", "release" });
    try std.testing.expectEqual(input.Key.digit_1, c.key);
    try std.testing.expectEqualStrings("", c.text);
    try std.testing.expectEqual(.release, c.action);
    try std.testing.expectEqualStrings("é", (try parseKey(a, &.{ "e", "text=\"\\u{e9}\"" })).text);
    try std.testing.expectError(error.BadKey, parseKey(a, &.{"nosuchkey"}));
    try std.testing.expectError(error.BadKey, parseKey(a, &.{ "a", "hyper" }));
}

test "parseMouse positions and buttons" {
    const ev = try parseMouse(&.{ "motion", "left", "3,5", "shift" });
    try std.testing.expectEqual([2]u16{ 4, 2 }, ev.cell);
    try std.testing.expectEqual(@as(u8, 1), ev.buttons_down);
    try std.testing.expect(ev.mods.shift);
    try std.testing.expectError(error.BadMouse, parseMouse(&.{ "press", "left", "0,1" }));
}
