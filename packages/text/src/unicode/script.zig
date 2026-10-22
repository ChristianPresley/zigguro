//! Script runs for shaping: Script plus Script_Extensions, with Common and
//! Inherited characters joining the surrounding run and paired brackets
//! sharing the script of their opener (the ICU/HarfBuzz approach).

const std = @import("std");
const p = @import("props.zig");
const decode = @import("decode.zig");
const Script = p.Script;

const script_count = @typeInfo(Script).@"enum".fields.len;

/// A set of scripts.
const Set = struct {
    bits: [4]u64 = @splat(0),

    fn of(list: []const Script) Set {
        var s: Set = .{};
        for (list) |x| s.add(x);
        return s;
    }
    fn add(s: *Set, x: Script) void {
        const i = @intFromEnum(x);
        s.bits[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
    }
    fn has(s: Set, x: Script) bool {
        const i = @intFromEnum(x);
        return s.bits[i >> 6] >> @intCast(i & 63) & 1 != 0;
    }
    fn meet(a: Set, b: Set) Set {
        var out: Set = .{};
        for (&out.bits, a.bits, b.bits) |*o, x, y| o.* = x & y;
        return out;
    }
    fn isEmpty(s: Set) bool {
        for (s.bits) |w| if (w != 0) return false;
        return true;
    }
    fn first(s: Set) Script {
        for (s.bits, 0..) |w, i| if (w != 0) return @enumFromInt(i * 64 + @ctz(w));
        return .Zyyy;
    }
};

comptime {
    std.debug.assert(script_count <= 256);
}

const latn = Set.of(&.{.Latn});

fn isAsciiBracket(c: u8) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}' => true,
        else => false,
    };
}

/// One run of text in a single script.
pub const Run = struct { start: u32, end: u32, script: Script };

/// True for characters that take the script of their neighbours: Common
/// and Inherited with no narrower Script_Extensions.
fn isNeutral(cp: u21) bool {
    const s = p.props(cp).script;
    if (s != .Zyyy and s != .Zinh and s != .Zzzz) return false;
    const ext = p.scriptExtensions(cp);
    return ext.len == 1 and (ext[0] == .Zyyy or ext[0] == .Zinh or ext[0] == .Zzzz);
}

/// Splits UTF-8 text into script runs.
pub const ScriptRunIterator = struct {
    text: []const u8,
    pos: usize = 0,
    /// Open brackets: the closing code point and the script set of the run
    /// at the opener.
    stack: [32]struct { close: u21, set: Set, start: u32 } = undefined,
    depth: u8 = 0,

    /// Iterates `text` from the start.
    pub fn init(text: []const u8) ScriptRunIterator {
        return .{ .text = text };
    }

    /// The next run, or null at the end.
    pub fn next(it: *ScriptRunIterator) ?Run {
        const text = it.text;
        if (it.pos >= text.len) return null;
        const start = it.pos;
        var set: Set = .{};
        var determined = false;
        // The props script of the run's first non-neutral character.
        var primary: Script = .Zyyy;
        var i = start;
        while (i < text.len) {
            const c0 = text[i];
            // ASCII letters are Latin with no other extensions; other ASCII
            // is Common (brackets go the slow way for the stack).
            if (c0 < 0x80 and std.ascii.isAlphabetic(c0)) {
                if (!determined) {
                    set = latn;
                    determined = true;
                    primary = .Latn;
                    for (it.stack[0..it.depth]) |*e| if (e.start >= start and e.set.isEmpty()) {
                        e.set = set;
                    };
                } else if (!set.has(.Latn)) {
                    it.pos = i;
                    return .{ .start = @intCast(start), .end = @intCast(i), .script = pick(set, primary) };
                } else set = latn;
                i += 1;
                continue;
            }
            if (c0 < 0x80 and !isAsciiBracket(c0)) {
                i += 1;
                continue;
            }
            const u = decode.at(text, i);
            const cp = u.cp;
            if (isNeutral(cp)) {
                const pr = p.props(cp);
                if (pr.bpt == .o) {
                    if (p.pairedBracket(cp)) |close| {
                        if (it.depth == it.stack.len) {
                            std.mem.copyForwards(@TypeOf(it.stack[0]), it.stack[0 .. it.stack.len - 1], it.stack[1..]);
                            it.depth -= 1;
                        }
                        it.stack[it.depth] = .{ .close = close, .set = set, .start = @intCast(i) };
                        it.depth += 1;
                    }
                } else if (pr.bpt == .c) {
                    // Pop to the matching opener; a closer whose opener was
                    // in another script ends this run so it joins that one.
                    var d = it.depth;
                    while (d > 0) : (d -= 1) if (it.stack[d - 1].close == cp or (cp == 0x232A and it.stack[d - 1].close == 0x3009)) break;
                    if (d > 0) {
                        const opener = it.stack[d - 1];
                        it.depth = d - 1;
                        if (determined and !opener.set.isEmpty() and opener.start < start and Set.meet(opener.set, set).isEmpty()) {
                            it.pos = i;
                            return .{ .start = @intCast(start), .end = @intCast(i), .script = pick(set, primary) };
                        }
                    }
                }
                i += u.len;
                continue;
            }
            const ext = Set.of(p.scriptExtensions(cp));
            if (!determined) {
                set = ext;
                determined = true;
                primary = p.props(cp).script;
                // Brackets opened in the leading neutral part adopt it.
                for (it.stack[0..it.depth]) |*e| if (e.start >= start and e.set.isEmpty()) {
                    e.set = set;
                };
            } else {
                const m = Set.meet(set, ext);
                if (m.isEmpty()) {
                    it.pos = i;
                    return .{ .start = @intCast(start), .end = @intCast(i), .script = pick(set, primary) };
                }
                set = m;
            }
            i += u.len;
        }
        it.pos = text.len;
        return .{ .start = @intCast(start), .end = @intCast(text.len), .script = if (determined) pick(set, primary) else .Zyyy };
    }

    fn pick(set: Set, primary: Script) Script {
        if (set.has(primary)) return primary;
        return set.first();
    }
};

test "script runs: latin, arabic and common" {
    var it = ScriptRunIterator.init("abc \u{627}\u{628} 12");
    const r1 = it.next().?;
    try std.testing.expectEqual(Script.Latn, r1.script);
    try std.testing.expectEqual(@as(u32, 4), r1.end);
    const r2 = it.next().?;
    try std.testing.expectEqual(Script.Arab, r2.script);
    try std.testing.expectEqual(@as(u32, 11), r2.end);
    try std.testing.expect(it.next() == null);
}

test "script runs: extensions intersect" {
    // Devanagari danda between Bengali letters stays Bengali.
    var it = ScriptRunIterator.init("\u{995}\u{964}\u{996}");
    const r = it.next().?;
    try std.testing.expectEqual(Script.Beng, r.script);
    try std.testing.expectEqual(@as(u32, 9), r.end);
    try std.testing.expect(it.next() == null);
}

test "script runs: brackets share script" {
    // The closing paren goes with the Latin run that opened it.
    var it = ScriptRunIterator.init("a(\u{3b1})b");
    const r1 = it.next().?;
    try std.testing.expectEqual(Script.Latn, r1.script);
    try std.testing.expectEqual(@as(u32, 2), r1.end);
    const r2 = it.next().?;
    try std.testing.expectEqual(Script.Grek, r2.script);
    try std.testing.expectEqual(@as(u32, 4), r2.end);
    const r3 = it.next().?;
    try std.testing.expectEqual(Script.Latn, r3.script);
    try std.testing.expectEqual(@as(u32, 6), r3.end);
}

test "script runs: leading common adopts and all-common is Zyyy" {
    var it = ScriptRunIterator.init("123 abc");
    const r = it.next().?;
    try std.testing.expectEqual(Script.Latn, r.script);
    try std.testing.expectEqual(@as(u32, 7), r.end);
    var it2 = ScriptRunIterator.init("1 + 2");
    try std.testing.expectEqual(Script.Zyyy, it2.next().?.script);
}
