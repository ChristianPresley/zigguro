//! Key resolution: (keycode, modifier state, group) to (keysym, level,
//! consumed modifiers), following xkbcommon's rules. The group wraps per
//! key; the key type picks the level by an exact match of the active
//! modifiers it looks at; Lock uppercases the keysym when the type does
//! not consume it.

const std = @import("std");
const keymap = @import("keymap.zig");
const keysyms = @import("keysyms.zig");

const lock_mask: u32 = 1 << 1;

/// See `Keymap.resolve`.
pub fn resolve(km: *const keymap.Keymap, keycode: u32, mods: keymap.ModState, group: u32) keymap.Resolved {
    const none: keymap.Resolved = .{ .keysym = 0, .level = 0, .consumed = 0 };
    const k = km.key(keycode) orelse return none;
    if (k.groups.len == 0) return none;
    const g = k.groups[group % k.groups.len];
    const t = km.types[g.type];
    const active = mods.depressed | mods.latched | mods.locked;
    const mask = active & t.mods;
    var level: u8 = 0;
    var preserve: u32 = 0;
    for (t.entries) |e| if (e.mods == mask) {
        level = e.level;
        preserve = e.preserve;
        break;
    };
    const consumed = t.mods & ~preserve;
    var ks: u32 = if (level < g.syms.len) g.syms[level] else 0;
    if (active & lock_mask != 0 and consumed & lock_mask == 0) ks = keysyms.toUpper(ks);
    return .{ .keysym = ks, .level = level, .consumed = consumed };
}
