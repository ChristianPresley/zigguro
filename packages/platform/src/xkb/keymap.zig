//! A compiled keymap: keys by keycode with their groups, types and levels,
//! the virtual-to-real modifier mapping, and repeat flags. `parse` runs the
//! parser and then resolves what a server-sent keymap leaves implicit:
//! aliases, virtual modifiers (from `interpret` statements and the modmap),
//! inactive type entries and automatic key types.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const keysyms = @import("keysyms.zig");
const resolve_mod = @import("resolve.zig");

/// Errors from `Keymap.parse`.
pub const ParseError = parser.Error;

/// The modifier state as `wl_keyboard.modifiers` reports it: real-mod masks.
pub const ModState = struct { depressed: u32 = 0, latched: u32 = 0, locked: u32 = 0 };

/// The result of resolving a key press.
pub const Resolved = struct {
    /// The keysym, or 0 for none.
    keysym: u32,
    /// The 0-based shift level.
    level: u8,
    /// The real modifiers the key type used to choose the level.
    consumed: u32,
};

/// One `map[...]` entry of a key type, with modifiers resolved to real
/// masks.
pub const TypeEntry = struct { mods: u32, level: u8, preserve: u32 };

/// A key type.
pub const KeyType = struct {
    name: []const u8,
    /// The real modifiers the type looks at.
    mods: u32,
    entries: []const TypeEntry,
    num_levels: u8,
};

/// One group of a key.
pub const Group = struct {
    /// Index into `Keymap.types`.
    type: u16,
    /// Keysyms by level; missing levels are 0.
    syms: []const u32,
};

/// A key.
pub const Key = struct {
    /// The key name with brackets, e.g. `<AE01>`.
    name: []const u8 = "",
    groups: []const Group = &.{},
    repeats: bool = true,
    /// Real modifiers from `modifier_map`.
    modmap: u8 = 0,
    /// Virtual modifiers the key sets.
    vmodmap: u16 = 0,
};

/// Most keycodes one keymap may span.
pub const max_keycode_span = 1 << 16;

/// A compiled keymap. All memory belongs to its arena.
pub const Keymap = struct {
    arena: std.heap.ArenaAllocator,
    /// The keycode of `keys[0]`.
    min_keycode: u32 = 0,
    keys: []Key = &.{},
    types: []KeyType = &.{},
    vmod_names: []const []const u8 = &.{},
    /// Real-mod mask of each virtual modifier.
    vmod_masks: []u8 = &.{},

    /// Parses keymap text (NUL-terminated per the protocol; a missing NUL
    /// is fine).
    pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!Keymap {
        return parseDiag(gpa, text, null);
    }

    /// `parse`, filling `diag` with the line, column and reason of a
    /// syntax error.
    pub fn parseDiag(gpa: std.mem.Allocator, text: []const u8, diag: ?*parser.Diagnostic) ParseError!Keymap {
        var km: Keymap = .{ .arena = .init(gpa) };
        errdefer km.arena.deinit();
        const a = km.arena.allocator();
        const tree = try parser.parse(a, text, diag);
        try compile(&km, a, &tree);
        return km;
    }

    /// Frees the keymap. `gpa` must be the allocator given to `parse`.
    pub fn deinit(self: *Keymap, gpa: std.mem.Allocator) void {
        _ = gpa;
        self.arena.deinit();
        self.* = undefined;
    }

    /// The key at `keycode`, if the keymap defines it.
    pub fn key(self: *const Keymap, keycode: u32) ?*const Key {
        if (keycode < self.min_keycode) return null;
        const i = keycode - self.min_keycode;
        if (i >= self.keys.len) return null;
        const k = &self.keys[i];
        return if (k.name.len == 0) null else k;
    }

    /// The name of `keycode`, e.g. `<AE01>`.
    pub fn keyName(self: *const Keymap, keycode: u32) ?[]const u8 {
        return if (self.key(keycode)) |k| k.name else null;
    }

    /// Resolves `keycode` under `mods` in `group` (wrapped per key).
    pub fn resolve(self: *const Keymap, keycode: u32, mods: ModState, group: u32) Resolved {
        return resolve_mod.resolve(self, keycode, mods, group);
    }

    /// The index of a real modifier: "Shift", "Lock", "Control", "Mod1"
    /// to "Mod5".
    pub fn modIndex(self: *const Keymap, name: []const u8) ?u5 {
        _ = self;
        for (ast.real_mod_names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return @intCast(i);
        return null;
    }

    /// The real-mod mask a virtual modifier maps to, e.g. "NumLock" ->
    /// Mod2. Real modifier names give their own bit; unknown names give 0.
    pub fn vmodMask(self: *const Keymap, vmod: []const u8) u32 {
        if (self.modIndex(vmod)) |i| return @as(u32, 1) << i;
        for (self.vmod_names, self.vmod_masks) |n, m| if (std.ascii.eqlIgnoreCase(n, vmod)) return m;
        return 0;
    }

    fn realMods(self: *const Keymap, m: ast.Mods) u32 {
        return realModsOf(self, m);
    }

    /// Whether holding `keycode` should repeat.
    pub fn repeats(self: *const Keymap, keycode: u32) bool {
        return if (self.key(keycode)) |k| k.repeats else false;
    }
};

const match_order = [_]ast.Match{ .exactly, .all_of, .none_of, .any_of, .any_of_or_none };

fn predicateMatches(it: ast.Interpret, modmap: u8) bool {
    return switch (it.match) {
        .none_of => it.mods & modmap == 0,
        .any_of_or_none => modmap == 0 or it.mods & modmap != 0,
        .any_of => it.mods & modmap != 0,
        .all_of => it.mods & modmap == it.mods,
        .exactly => it.mods == modmap,
    };
}

/// The first interpret for `sym` on a key with `modmap`, in xkbcommon's
/// priority: keysym-specific before `Any`, then by predicate strictness.
fn findInterpret(sorted: []const ast.Interpret, sym: u32, level: usize, modmap: u8) ?ast.Interpret {
    for (sorted) |it| {
        if (it.keysym) |s| if (s != sym) continue;
        const mods: u8 = if (it.level_one_only and level != 0) 0 else modmap;
        if (predicateMatches(it, mods)) return it;
    }
    return null;
}

fn sortInterprets(a: std.mem.Allocator, in: []const ast.Interpret) ![]ast.Interpret {
    var out: std.ArrayList(ast.Interpret) = try .initCapacity(a, in.len);
    for ([_]bool{ true, false }) |specific| for (match_order) |m| for (in) |it| {
        if ((it.keysym != null) == specific and it.match == m) out.appendAssumeCapacity(it);
    };
    return out.items;
}

fn compile(km: *Keymap, a: std.mem.Allocator, tree: *const ast.Ast) ParseError!void {
    // Keycodes and aliases.
    var codes: std.StringHashMapUnmanaged(u32) = .empty;
    var lo: u32 = std.math.maxInt(u32);
    var hi: u32 = 0;
    for (tree.keycodes.items) |kc| {
        const gop = try codes.getOrPut(a, kc.name);
        if (!gop.found_existing) gop.value_ptr.* = kc.code;
        lo = @min(lo, kc.code);
        hi = @max(hi, kc.code);
    }
    if (tree.keycodes.items.len > 0) {
        if (hi - lo >= max_keycode_span) return error.TooLarge;
        km.min_keycode = lo;
        km.keys = try a.alloc(Key, hi - lo + 1);
        @memset(km.keys, .{});
        for (tree.keycodes.items) |kc| {
            const k = &km.keys[kc.code - lo];
            if (k.name.len == 0) k.name = kc.name;
        }
    }
    for (tree.aliases.items) |al| {
        if (codes.contains(al.alias)) continue;
        if (codes.get(al.real)) |c| try codes.put(a, al.alias, c);
    }

    // Raw key definitions by keycode.
    const raw = try a.alloc(?*const ast.Key, km.keys.len);
    @memset(raw, null);
    for (tree.keys.items) |*k| {
        const c = codes.get(k.name) orelse continue;
        raw[c - km.min_keycode] = k;
    }

    // modifier_map.
    for (tree.modmap.items) |m| {
        const bit = @as(u8, 1) << m.real_index;
        switch (m.target) {
            .keyname => |n| if (codes.get(n)) |c| {
                km.keys[c - km.min_keycode].modmap |= bit;
            },
            .keysym => |s| if (s != 0) if (keyWithSym(raw, s)) |i| {
                km.keys[i].modmap |= bit;
            },
        }
    }

    // Virtual modifiers: explicit values, then interprets and the modmap.
    const nv = tree.vmods.items.len;
    km.vmod_names = blk: {
        const names = try a.alloc([]const u8, nv);
        for (tree.vmods.items, names) |v, *n| n.* = v.name;
        break :blk names;
    };
    km.vmod_masks = try a.alloc(u8, nv);
    for (tree.vmods.items, km.vmod_masks) |v, *m| m.* = v.explicit orelse 0;
    const sorted = try sortInterprets(a, tree.interprets.items);
    for (km.keys, raw) |*k, r| {
        const def = r orelse continue;
        var vmodmap: u16 = 0;
        var repeat: ?bool = null;
        for (def.groups, 0..) |g, gi| for (g.syms, 0..) |s, level| {
            const it = findInterpret(sorted, s, level, k.modmap) orelse continue;
            if ((gi == 0 and level == 0) or !it.level_one_only) {
                if (it.vmod) |v| vmodmap |= @as(u16, 1) << @intCast(v);
            }
            if (gi == 0 and level == 0) repeat = it.repeat;
        };
        k.vmodmap = def.vmods orelse vmodmap;
        k.repeats = def.repeat orelse (repeat orelse true);
    }
    for (km.keys) |k| {
        var bits = k.vmodmap;
        while (bits != 0) : (bits &= bits - 1) {
            const v = @ctz(bits);
            if (v < nv) km.vmod_masks[v] |= k.modmap;
        }
    }

    // Types with real masks.
    var types: std.ArrayList(KeyType) = .empty;
    for (tree.types.items) |t| {
        const tmods = km.realMods(t.mods);
        var entries: std.ArrayList(TypeEntry) = .empty;
        for (t.entries) |e| {
            const m = km.realMods(e.mods);
            // An entry whose modifiers are all unbound never matches.
            if (!e.mods.isEmpty() and m == 0) continue;
            const mask = m & tmods;
            if (findTypeEntry(entries.items, mask) != null) continue;
            try entries.append(a, .{ .mods = mask, .level = e.level, .preserve = km.realMods(e.preserve) & mask });
        }
        try types.append(a, .{ .name = t.name, .mods = tmods, .entries = entries.items, .num_levels = t.num_levels });
    }
    if (findType(types.items, "ONE_LEVEL") == null) try types.append(a, .{ .name = "ONE_LEVEL", .mods = 0, .entries = &.{}, .num_levels = 1 });
    km.types = types.items;

    // Groups with their types.
    for (km.keys, raw) |*k, r| {
        const def = r orelse continue;
        const groups = try a.alloc(Group, def.groups.len);
        for (def.groups, groups) |g, *out| {
            const name = g.type_name orelse automaticType(g.syms);
            out.* = .{
                .type = findType(km.types, name) orelse findType(km.types, automaticType(g.syms)) orelse findType(km.types, "ONE_LEVEL").?,
                .syms = g.syms,
            };
        }
        k.groups = groups;
    }
}

fn findTypeEntry(entries: []const TypeEntry, mask: u32) ?usize {
    for (entries, 0..) |e, i| if (e.mods == mask) return i;
    return null;
}

fn findType(types: []const KeyType, name: []const u8) ?u16 {
    for (types, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) return @intCast(i);
    return null;
}

/// The key with the lowest keycode that has `sym` in any group or level.
fn keyWithSym(raw: []const ?*const ast.Key, sym: u32) ?usize {
    for (raw, 0..) |r, i| {
        const def = r orelse continue;
        for (def.groups) |g| for (g.syms) |s| if (s == sym) return i;
    }
    return null;
}

/// xkbcommon's choice of type for a group without one.
fn automaticType(syms: []const u32) []const u8 {
    const s = struct {
        fn at(x: []const u32, i: usize) u32 {
            return if (i < x.len) x[i] else 0;
        }
    };
    const w = syms.len;
    if (w <= 1) return "ONE_LEVEL";
    const s0 = s.at(syms, 0);
    const s1 = s.at(syms, 1);
    if (w == 2) {
        if (keysyms.isLower(s0) and keysyms.isUpper(s1)) return "ALPHABETIC";
        if (keysyms.isKeypad(s0) or keysyms.isKeypad(s1)) return "KEYPAD";
        return "TWO_LEVEL";
    }
    if (keysyms.isLower(s0) and keysyms.isUpper(s1)) {
        if (keysyms.isLower(s.at(syms, 2)) and keysyms.isUpper(s.at(syms, 3))) return "FOUR_LEVEL_ALPHABETIC";
        return "FOUR_LEVEL_SEMIALPHABETIC";
    }
    if (keysyms.isKeypad(s0) or keysyms.isKeypad(s1)) return "FOUR_LEVEL_KEYPAD";
    return "FOUR_LEVEL";
}

fn realModsOf(km: *const Keymap, m: ast.Mods) u32 {
    var mask: u32 = m.real;
    var bits = m.virtual;
    while (bits != 0) : (bits &= bits - 1) {
        const v = @ctz(bits);
        if (v < km.vmod_masks.len) mask |= km.vmod_masks[v];
    }
    return mask;
}

const testing = std.testing;

fn ks(name: []const u8) u32 {
    return keysyms.keysymFromName(name).?;
}

const shift: u32 = 1 << 0;
const lock: u32 = 1 << 1;
const mod2: u32 = 1 << 4;
const mod5: u32 = 1 << 7;

test "us: <AC01> + Lock -> A, Shift -> A, plain -> a" {
    var km = try Keymap.parse(testing.allocator, @embedFile("testdata/us.xkb"));
    defer km.deinit(testing.allocator);
    const ac01 = 38;
    try testing.expectEqualStrings("<AC01>", km.keyName(ac01).?);
    try testing.expectEqual(ks("a"), km.resolve(ac01, .{}, 0).keysym);
    try testing.expectEqual(ks("A"), km.resolve(ac01, .{ .locked = lock }, 0).keysym);
    try testing.expectEqual(ks("A"), km.resolve(ac01, .{ .depressed = shift }, 0).keysym);
    // Digits are TWO_LEVEL: Lock does not apply.
    try testing.expectEqual(ks("1"), km.resolve(10, .{ .locked = lock }, 0).keysym);
    try testing.expectEqual(ks("exclam"), km.resolve(10, .{ .depressed = shift }, 0).keysym);
    try testing.expectEqual(shift, km.resolve(10, .{ .depressed = shift }, 0).consumed);
}

test "de: <AD01> with LevelThree -> at, Shift+LevelThree -> Greek_OMEGA" {
    var km = try Keymap.parse(testing.allocator, @embedFile("testdata/de.xkb"));
    defer km.deinit(testing.allocator);
    try testing.expectEqual(mod5, km.vmodMask("LevelThree"));
    const ad01 = 24;
    try testing.expectEqual(ks("q"), km.resolve(ad01, .{}, 0).keysym);
    const at = km.resolve(ad01, .{ .depressed = mod5 }, 0);
    try testing.expectEqual(ks("at"), at.keysym);
    try testing.expectEqual(2, at.level);
    try testing.expectEqual(ks("Greek_OMEGA"), km.resolve(ad01, .{ .depressed = mod5 | shift }, 0).keysym);
    // <AD06> is z on QWERTZ.
    try testing.expectEqual(ks("z"), km.resolve(29, .{}, 0).keysym);
}

test "NumLock vmod mapped to Mod2; keypad keys with NumLock" {
    var km = try Keymap.parse(testing.allocator, @embedFile("testdata/us.xkb"));
    defer km.deinit(testing.allocator);
    try testing.expectEqual(mod2, km.vmodMask("NumLock"));
    try testing.expectEqual(1 << 3, km.vmodMask("Alt"));
    try testing.expectEqual(0, km.vmodMask("NoSuchMod"));
    try testing.expectEqual(4, km.modIndex("Mod2").?);
    const kp7 = 79;
    try testing.expectEqualStrings("<KP7>", km.keyName(kp7).?);
    try testing.expectEqual(ks("KP_Home"), km.resolve(kp7, .{}, 0).keysym);
    try testing.expectEqual(ks("KP_7"), km.resolve(kp7, .{ .locked = mod2 }, 0).keysym);
    try testing.expectEqual(ks("KP_Home"), km.resolve(kp7, .{ .locked = mod2, .depressed = shift }, 0).keysym);
}

test "ru group 2 <AC01> -> Cyrillic_ef; groups wrap" {
    var km = try Keymap.parse(testing.allocator, @embedFile("testdata/ru_us_2groups.xkb"));
    defer km.deinit(testing.allocator);
    try testing.expectEqual(ks("a"), km.resolve(38, .{}, 0).keysym);
    try testing.expectEqual(ks("Cyrillic_ef"), km.resolve(38, .{}, 1).keysym);
    try testing.expectEqual(ks("Cyrillic_EF"), km.resolve(38, .{ .locked = lock }, 1).keysym);
    try testing.expectEqual(ks("a"), km.resolve(38, .{}, 2).keysym);
    // A one-group key stays on its group.
    try testing.expectEqual(ks("Escape"), km.resolve(9, .{}, 1).keysym);
}

test "fr and jp parse; repeat flags; unknown keycodes" {
    var fr = try Keymap.parse(testing.allocator, @embedFile("testdata/fr.xkb"));
    defer fr.deinit(testing.allocator);
    try testing.expectEqual(ks("a"), fr.resolve(24, .{}, 0).keysym); // AZERTY
    try testing.expectEqual(ks("ampersand"), fr.resolve(10, .{}, 0).keysym);
    var jp = try Keymap.parse(testing.allocator, @embedFile("testdata/jp.xkb"));
    defer jp.deinit(testing.allocator);
    try testing.expectEqual(ks("a"), jp.resolve(38, .{}, 0).keysym);
    try testing.expect(jp.repeats(38));
    try testing.expect(!jp.repeats(50)); // Shift_L
    try testing.expectEqual(null, jp.keyName(3));
    try testing.expectEqual(0, jp.resolve(3, .{}, 0).keysym);
}

test "fuzz: xkb keymap parse never crashes" {
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            const base = @embedFile("testdata/us.xkb");
            var buf: [base.len]u8 = base.*;
            // Overwrite a random window of the fixture with random bytes.
            var patch: [64]u8 = undefined;
            const n = sm.slice(&patch);
            if (n < 4) return;
            const at = std.mem.readInt(u32, patch[0..4], .little) % base.len;
            const len = @min(n - 4, base.len - at);
            @memcpy(buf[at..][0..len], patch[4..][0..len]);
            var km = Keymap.parse(testing.allocator, &buf) catch return;
            km.deinit(testing.allocator);
        }
    }.one, .{});
}
