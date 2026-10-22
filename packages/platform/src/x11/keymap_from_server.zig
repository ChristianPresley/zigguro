//! The server's compiled XKB keymap → `xkb.Keymap` (E01.F05.S02.T02).
//! X11 has no keymap text to parse: `XkbGetMap` sends key types, keysyms,
//! the modifier map and virtual modifier bindings as binary, and
//! `XkbGetNames` sends key and virtual modifier names. The result is the
//! same model the Wayland seat builds from text, so resolution, modifier
//! masks and compose behave alike on both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xkb = @import("../xkb/keymap.zig");

const le = std.builtin.Endian.little;

/// Errors for replies that do not hold what their headers say.
pub const Error = error{Malformed} || Allocator.Error;

const Reader = struct {
    b: []const u8,
    pos: usize,

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.pos + n > r.b.len) return error.Malformed;
        defer r.pos += n;
        return r.b[r.pos..][0..n];
    }
    fn byte(r: *Reader) Error!u8 {
        return (try r.take(1))[0];
    }
    fn u16_(r: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try r.take(2))[0..2], le);
    }
    fn u32_(r: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try r.take(4))[0..4], le);
    }
    fn alignTo4(r: *Reader) void {
        r.pos = std.mem.alignForward(usize, r.pos, 4);
    }
};

fn u16At(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], le);
}
fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], le);
}

/// Up to 16 virtual modifier name atoms, in bit order.
pub const VmodAtoms = struct {
    buf: [16]u32 = undefined,
    len: usize = 0,

    /// The atoms.
    pub fn slice(a: *const VmodAtoms) []const u32 {
        return a.buf[0..a.len];
    }
};

/// The virtual modifier name atoms in a GetNames reply, one per set bit
/// of its `virtualMods`, in bit order.
pub fn vmodNameAtoms(names: []const u8) Error!VmodAtoms {
    var r = try namesReader(names);
    const vmods = u16At(names, 16);
    var out: VmodAtoms = .{};
    if (u32At(names, 8) & which_vmods == 0) return out;
    for (0..16) |i| if (vmods & (@as(u16, 1) << @intCast(i)) != 0) {
        out.buf[out.len] = try r.u32_();
        out.len += 1;
    };
    return out;
}

const which_keys: u32 = 1 << 9;
const which_vmods: u32 = 1 << 11;

/// A reader positioned at the virtual modifier names of a GetNames
/// reply, past the parts that come first.
fn namesReader(names: []const u8) Error!Reader {
    if (names.len < 32) return error.Malformed;
    const which = u32At(names, 8);
    var r: Reader = .{ .b = names, .pos = 32 };
    // Keycodes, Geometry, Symbols, PhysSymbols, Types, Compat: one atom
    // each.
    for (0..6) |i| if (which & (@as(u32, 1) << @intCast(i)) != 0) {
        _ = try r.take(4);
    };
    const n_types = names[14];
    if (which & (1 << 6) != 0) _ = try r.take(@as(usize, n_types) * 4);
    if (which & (1 << 7) != 0) {
        _ = try r.take(n_types);
        r.alignTo4();
        _ = try r.take(@as(usize, u16At(names, 26)) * 4);
    }
    if (which & (1 << 8) != 0) _ = try r.take(@as(usize, @popCount(u32At(names, 20))) * 4);
    return r;
}

/// Builds the shared keymap model from a GetMap reply (key types, key
/// syms, modifier map, virtual mods, virtual mod map), a GetNames reply
/// (key names, virtual mod names) and the strings of its virtual modifier
/// atoms (`vmodNameAtoms` order).
pub fn keymapFromXkbGetMap(gpa: Allocator, map: []const u8, names: []const u8, vmod_names: []const []const u8) Error!xkb.Keymap {
    if (map.len < 40 or names.len < 32) return error.Malformed;
    var km: xkb.Keymap = .{ .arena = .init(gpa) };
    errdefer km.arena.deinit();
    const a = km.arena.allocator();

    const min_kc = map[10];
    const max_kc = map[11];
    if (max_kc < min_kc) return error.Malformed;
    const present = u16At(map, 12);
    km.min_keycode = min_kc;
    km.keys = try a.alloc(xkb.Key, @as(usize, max_kc) - min_kc + 1);
    @memset(km.keys, .{});

    var r: Reader = .{ .b = map, .pos = 40 };

    // Key types.
    if (present & 1 != 0) {
        if (map[14] != 0) return error.Malformed;
        const n_types = map[15];
        const types = try a.alloc(xkb.KeyType, n_types);
        for (types) |*t| {
            const mask = try r.byte();
            _ = try r.take(3); // realMods, virtualMods
            const num_levels = try r.byte();
            const n_entries = try r.byte();
            const has_preserve = try r.byte() != 0;
            _ = try r.byte();
            const entries = try a.alloc(xkb.TypeEntry, n_entries);
            var n_active: usize = 0;
            var active: [256]bool = undefined;
            for (entries, 0..) |*e, i| {
                active[i] = try r.byte() != 0;
                const emask = try r.byte();
                const level = try r.byte();
                _ = try r.take(5); // realMods, virtualMods, pad
                e.* = .{ .mods = emask, .level = level, .preserve = 0 };
            }
            if (has_preserve) for (entries) |*e| {
                e.preserve = try r.byte();
                _ = try r.take(3);
            };
            // Entries whose virtual modifiers are unbound do not match.
            for (entries, 0..) |e, i| if (active[i]) {
                entries[n_active] = e;
                n_active += 1;
            };
            t.* = .{ .name = "", .mods = mask, .entries = entries[0..n_active], .num_levels = num_levels };
        }
        km.types = types;
    }

    // Key symbols.
    if (present & 2 != 0) {
        const first = map[17];
        const n_keys = map[20];
        for (0..n_keys) |i| {
            var kt: [4]u8 = undefined;
            @memcpy(&kt, try r.take(4));
            const n_groups: usize = @min((try r.byte()) & 0x0f, 4);
            const width = try r.byte();
            const n_syms = try r.u16_();
            const raw = try r.take(@as(usize, n_syms) * 4);
            const kc = @as(usize, first) + i;
            if (kc < min_kc or kc > max_kc) return error.Malformed;
            if (n_groups == 0 or n_syms == 0) continue;
            if (n_syms < n_groups * width) return error.Malformed;
            const syms = try a.alloc(u32, n_syms);
            for (syms, 0..) |*s, j| s.* = u32At(raw, j * 4);
            const groups = try a.alloc(xkb.Group, n_groups);
            for (groups, 0..) |*g, gi| {
                if (kt[gi] >= km.types.len) return error.Malformed;
                g.* = .{ .type = kt[gi], .syms = syms[gi * width ..][0..width] };
            }
            km.keys[kc - min_kc].groups = groups;
        }
    }

    // Key actions and behaviors (not asked for; skipped if present).
    if (present & (1 << 4) != 0) {
        _ = try r.take(map[24]);
        r.alignTo4();
        _ = try r.take(@as(usize, u16At(map, 22)) * 8);
    }
    if (present & (1 << 5) != 0) _ = try r.take(@as(usize, map[27]) * 4);

    // Virtual modifier bindings, one byte per bit of `virtualMods`.
    var vmod_masks: [16]u8 = @splat(0);
    if (present & (1 << 6) != 0) {
        const vmods = u16At(map, 38);
        for (0..16) |i| if (vmods & (@as(u16, 1) << @intCast(i)) != 0) {
            vmod_masks[i] = try r.byte();
        };
        r.alignTo4();
    }

    // Explicit components (skipped if present).
    if (present & (1 << 3) != 0) {
        _ = try r.take(@as(usize, map[30]) * 2);
        r.alignTo4();
    }

    // Modifier map.
    if (present & (1 << 2) != 0) {
        for (0..map[33]) |_| {
            const kc = try r.byte();
            const mods = try r.byte();
            if (kc >= min_kc and kc <= max_kc) km.keys[kc - min_kc].modmap = mods;
        }
        r.alignTo4();
    }

    // Virtual modifier map.
    if (present & (1 << 7) != 0) {
        for (0..map[36]) |_| {
            const kc = try r.byte();
            _ = try r.byte();
            const vm = try r.u16_();
            if (kc >= min_kc and kc <= max_kc) km.keys[kc - min_kc].vmodmap = vm;
        }
    }

    // Names.
    const which = u32At(names, 8);
    var nr = try namesReader(names);
    const name_vmods: u16 = if (which & which_vmods != 0) u16At(names, 16) else 0;
    var vn: std.ArrayList([]const u8) = .empty;
    var vm: std.ArrayList(u8) = .empty;
    var rank: usize = 0;
    for (0..16) |i| if (name_vmods & (@as(u16, 1) << @intCast(i)) != 0) {
        _ = try nr.take(4);
        const n = if (rank < vmod_names.len) vmod_names[rank] else "";
        rank += 1;
        if (n.len == 0) continue;
        try vn.append(a, try a.dupe(u8, n));
        try vm.append(a, vmod_masks[i]);
    };
    // GroupNames come between the virtual modifier names and key names.
    if (which & (1 << 12) != 0) _ = try nr.take(@as(usize, @popCount(names[15])) * 4);
    km.vmod_names = vn.items;
    km.vmod_masks = vm.items;

    if (which & which_keys != 0) {
        const first = names[18];
        for (0..names[19]) |i| {
            const raw = try nr.take(4);
            const kc = @as(usize, first) + i;
            if (kc < min_kc or kc > max_kc) continue;
            const len = std.mem.indexOfScalar(u8, raw, 0) orelse 4;
            if (len == 0) continue;
            km.keys[kc - min_kc].name = try std.fmt.allocPrint(a, "<{s}>", .{raw[0..len]});
        }
    }
    // Keys with symbols but no name still resolve.
    for (km.keys, 0..) |*k, i| if (k.name.len == 0 and k.groups.len > 0) {
        k.name = try std.fmt.allocPrint(a, "<I{d}>", .{i + min_kc});
    };
    return km;
}

const testing = std.testing;
const Masks = @import("../wayland/seat.zig").Masks;

/// The fixture: GetMap and GetNames replies captured from Xvfb (us),
/// then the virtual modifier names.
const Fixture = struct {
    map: []const u8,
    names: []const u8,
    vmods: [16][]const u8,
    n_vmods: usize,

    fn load() Fixture {
        const b = @embedFile("testdata/xkb_us.bin");
        var f: Fixture = undefined;
        var p: usize = 0;
        const ml = u32At(b, p);
        f.map = b[p + 4 ..][0..ml];
        p += 4 + ml;
        const nl = u32At(b, p);
        f.names = b[p + 4 ..][0..nl];
        p += 4 + nl;
        f.n_vmods = b[p];
        p += 1;
        for (0..f.n_vmods) |i| {
            const l = b[p];
            f.vmods[i] = b[p + 1 ..][0..l];
            p += 1 + l;
        }
        return f;
    }
};

test "XkbGetMap reply → Keymap (us, captured from Xvfb)" {
    const f = Fixture.load();
    const atoms = try vmodNameAtoms(f.names);
    try testing.expectEqual(f.n_vmods, atoms.len);
    var km = try keymapFromXkbGetMap(testing.allocator, f.map, f.names, f.vmods[0..f.n_vmods]);
    defer km.deinit(testing.allocator);

    try testing.expectEqualStrings("<AC01>", km.keyName(38).?);
    try testing.expectEqualStrings("<AE01>", km.keyName(10).?);
    const shift: xkb.ModState = .{ .depressed = 1 };
    // <AC01> → a, with Shift → A, with Caps Lock → A.
    try testing.expectEqual(@as(u32, 'a'), km.resolve(38, .{}, 0).keysym);
    try testing.expectEqual(@as(u32, 'A'), km.resolve(38, shift, 0).keysym);
    try testing.expectEqual(@as(u32, 'A'), km.resolve(38, .{ .locked = 2 }, 0).keysym);
    try testing.expectEqual(@as(u32, '!'), km.resolve(10, shift, 0).keysym);
    // Caps Lock does not shift digits; NumLock picks keypad digits.
    try testing.expectEqual(@as(u32, '1'), km.resolve(10, .{ .locked = 2 }, 0).keysym);
    try testing.expectEqual(@as(u32, 0xffb7), km.resolve(79, .{ .locked = 1 << 4 }, 0).keysym); // KP_7
    try testing.expectEqual(@as(u32, 0xff95), km.resolve(79, .{}, 0).keysym); // KP_Home
    try testing.expectEqual(@as(u32, 0xff0d), km.resolve(36, .{}, 1).keysym); // Return; groups wrap

    // Virtual modifiers resolve to the usual real modifiers.
    try testing.expectEqual(@as(u32, 1 << 3), km.vmodMask("Alt"));
    try testing.expectEqual(@as(u32, 1 << 4), km.vmodMask("NumLock"));
    try testing.expectEqual(@as(u32, 1 << 6), Masks.of(&km).super);
    // Modifier map: Shift_L is on Shift.
    try testing.expectEqual(@as(u8, 1), km.key(50).?.modmap);
}

test "truncated replies are rejected" {
    const f = Fixture.load();
    try testing.expectError(error.Malformed, keymapFromXkbGetMap(testing.allocator, f.map[0 .. f.map.len / 2], f.names, f.vmods[0..f.n_vmods]));
    try testing.expectError(error.Malformed, keymapFromXkbGetMap(testing.allocator, f.map, f.names[0..40], f.vmods[0..f.n_vmods]));
    try testing.expectError(error.Malformed, keymapFromXkbGetMap(testing.allocator, f.map[0..20], f.names, &.{}));
}

/// Encodes `km` the way a server sends it: a GetMap reply and a
/// GetNames reply. Test-only.
fn encodeReplies(gpa: Allocator, km: *const xkb.Keymap) !struct { map: []u8, names: []u8 } {
    var m: std.ArrayList(u8) = .empty;
    errdefer m.deinit(gpa);
    try m.appendNTimes(gpa, 0, 40);
    for (km.types) |t| {
        try m.appendSlice(gpa, &.{ @truncate(t.mods), @truncate(t.mods), 0, 0, t.num_levels, @intCast(t.entries.len), 1, 0 });
        for (t.entries) |e| try m.appendSlice(gpa, &.{ 1, @truncate(e.mods), e.level, @truncate(e.mods), 0, 0, 0, 0 });
        for (t.entries) |e| try m.appendSlice(gpa, &.{ @truncate(e.preserve), @truncate(e.preserve), 0, 0 });
    }
    var n_modmap: u8 = 0;
    var n_vmodmap: u8 = 0;
    for (km.keys) |k| {
        var width: usize = 1;
        for (k.groups) |g| width = @max(width, g.syms.len);
        var kt: [4]u8 = @splat(0);
        for (k.groups, 0..) |g, i| kt[i] = @intCast(g.type);
        try m.appendSlice(gpa, &kt);
        try m.appendSlice(gpa, &.{ @intCast(k.groups.len), @intCast(width) });
        var b2: [2]u8 = undefined;
        std.mem.writeInt(u16, &b2, @intCast(k.groups.len * width), le);
        try m.appendSlice(gpa, &b2);
        for (k.groups) |g| for (0..width) |l| {
            var b4: [4]u8 = undefined;
            std.mem.writeInt(u32, &b4, if (l < g.syms.len) g.syms[l] else 0, le);
            try m.appendSlice(gpa, &b4);
        };
        if (k.modmap != 0) n_modmap += 1;
        if (k.vmodmap != 0) n_vmodmap += 1;
    }
    for (km.vmod_masks) |v| try m.append(gpa, v);
    while (m.items.len % 4 != 0) try m.append(gpa, 0);
    for (km.keys, 0..) |k, i| if (k.modmap != 0) try m.appendSlice(gpa, &.{ @intCast(i + km.min_keycode), k.modmap });
    while (m.items.len % 4 != 0) try m.append(gpa, 0);
    for (km.keys, 0..) |k, i| if (k.vmodmap != 0) {
        var b2: [2]u8 = undefined;
        std.mem.writeInt(u16, &b2, k.vmodmap, le);
        try m.appendSlice(gpa, &.{ @intCast(i + km.min_keycode), 0, b2[0], b2[1] });
    };
    const h = m.items;
    h[0] = 1;
    std.mem.writeInt(u32, h[4..8], @intCast((h.len - 32) / 4), le);
    h[10] = @intCast(km.min_keycode);
    h[11] = @intCast(km.min_keycode + km.keys.len - 1);
    std.mem.writeInt(u16, h[12..14], 1 | 2 | 4 | 64 | 128, le);
    h[15] = @intCast(km.types.len);
    h[17] = @intCast(km.min_keycode);
    h[20] = @intCast(km.keys.len);
    h[33] = n_modmap;
    h[36] = n_vmodmap;
    std.mem.writeInt(u16, h[38..40], @intCast((@as(u32, 1) << @intCast(km.vmod_masks.len)) - 1), le);

    var n: std.ArrayList(u8) = .empty;
    errdefer n.deinit(gpa);
    try n.appendNTimes(gpa, 0, 32);
    for (km.vmod_names, 0..) |_, i| {
        var b4: [4]u8 = undefined;
        std.mem.writeInt(u32, &b4, @intCast(i + 1), le);
        try n.appendSlice(gpa, &b4);
    }
    for (km.keys) |k| {
        var nm: [4]u8 = @splat(0);
        const inner = if (k.name.len >= 2) k.name[1 .. k.name.len - 1] else "";
        @memcpy(nm[0..@min(4, inner.len)], inner[0..@min(4, inner.len)]);
        try n.appendSlice(gpa, &nm);
    }
    const nh = n.items;
    nh[0] = 1;
    std.mem.writeInt(u32, nh[4..8], @intCast((nh.len - 32) / 4), le);
    std.mem.writeInt(u32, nh[8..12], which_keys | which_vmods, le);
    std.mem.writeInt(u16, nh[16..18], @intCast((@as(u32, 1) << @intCast(km.vmod_names.len)) - 1), le);
    nh[18] = @intCast(km.min_keycode);
    nh[19] = @intCast(km.keys.len);
    return .{ .map = try m.toOwnedSlice(gpa), .names = try n.toOwnedSlice(gpa) };
}

test "two groups (us,ru): server replies resolve like the keymap text" {
    const gpa = testing.allocator;
    var text = try xkb.Keymap.parse(gpa, @embedFile("../xkb/testdata/ru_us_2groups.xkb"));
    defer text.deinit(gpa);
    const r = try encodeReplies(gpa, &text);
    defer gpa.free(r.map);
    defer gpa.free(r.names);
    var km = try keymapFromXkbGetMap(gpa, r.map, r.names, text.vmod_names);
    defer km.deinit(gpa);

    // <AC01>: a/A in group 1, Cyrillic_ef/EF in group 2.
    try testing.expectEqual(@as(u32, 'a'), km.resolve(38, .{}, 0).keysym);
    try testing.expectEqual(@as(u32, 0x6c6), km.resolve(38, .{}, 1).keysym);
    try testing.expectEqual(@as(u32, 0x6e6), km.resolve(38, .{ .depressed = 1 }, 1).keysym);
    // Every key, group and real-modifier combination agrees.
    var kc: u32 = text.min_keycode;
    while (kc < text.min_keycode + text.keys.len) : (kc += 1) {
        for (0..4) |g| for (0..256) |mods| {
            const st: xkb.ModState = .{ .depressed = @intCast(mods & 0xed), .locked = @intCast(mods & 0x12) };
            const want = text.resolve(kc, st, @intCast(g));
            const got = km.resolve(kc, st, @intCast(g));
            try testing.expectEqual(want.keysym, got.keysym);
            try testing.expectEqual(want.level, got.level);
        };
    }
    try testing.expectEqual(Masks.of(&text), Masks.of(&km));
}
