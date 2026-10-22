//! What the parser extracts from a keymap, before `keymap.zig` resolves
//! names, virtual modifiers and key types. Strings are views into the
//! keymap text; slices live in the parse arena.

const std = @import("std");

/// The eight real modifiers, in mask bit order.
pub const real_mod_names = [_][]const u8{ "Shift", "Lock", "Control", "Mod1", "Mod2", "Mod3", "Mod4", "Mod5" };

/// Most virtual modifiers a keymap may declare.
pub const max_vmods = 16;

/// A modifier expression such as `Shift+LevelThree`, split into real mods
/// and virtual mods (bits index `Ast.vmods`).
pub const Mods = struct {
    real: u8 = 0,
    virtual: u16 = 0,

    /// Whether the expression names any modifier.
    pub fn isEmpty(m: Mods) bool {
        return m.real == 0 and m.virtual == 0;
    }

    /// Both expressions combined.
    pub fn with(a: Mods, b: Mods) Mods {
        return .{ .real = a.real | b.real, .virtual = a.virtual | b.virtual };
    }
};

/// `<NAME> = 10;`
pub const Keycode = struct { name: []const u8, code: u32 };

/// `alias <A> = <B>;`
pub const Alias = struct { alias: []const u8, real: []const u8 };

/// A declared virtual modifier, optionally with an explicit real mapping
/// (`virtual_modifiers NumLock = Mod2;`).
pub const VMod = struct { name: []const u8, explicit: ?u8 = null };

/// `map[Shift] = Level2;` and its `preserve[...]`.
pub const TypeEntry = struct { mods: Mods, level: u8, preserve: Mods = .{} };

/// `type "NAME" { ... };`
pub const KeyType = struct {
    name: []const u8,
    mods: Mods = .{},
    entries: []const TypeEntry = &.{},
    /// Highest level mentioned, 1-based.
    num_levels: u8 = 1,
};

/// How an `interpret` predicate compares its mods with a key's modmap.
pub const Match = enum { none_of, any_of_or_none, any_of, all_of, exactly };

/// `interpret Keysym+Pred(mods) { virtualModifier = X; useModMapMods = level1; };`
pub const Interpret = struct {
    /// Null for `Any`.
    keysym: ?u32,
    match: Match = .any_of_or_none,
    /// The predicate's mods (`all` sets every real mod).
    mods: u8 = 0xff,
    /// Index into `Ast.vmods`.
    vmod: ?u8 = null,
    level_one_only: bool = false,
    repeat: bool = false,
};

/// One group of a key: its type (null when implicit) and keysyms by level.
pub const Group = struct {
    type_name: ?[]const u8 = null,
    syms: []const u32 = &.{},
};

/// `key <NAME> { ... };`
pub const Key = struct {
    name: []const u8,
    groups: []const Group = &.{},
    /// Explicit `vmods = ...`, when given.
    vmods: ?u16 = null,
    /// Explicit `repeat = Yes|No`, when given.
    repeat: ?bool = null,
};

/// The target of a `modifier_map` entry.
pub const ModMapTarget = union(enum) { keyname: []const u8, keysym: u32 };

/// One entry of `modifier_map Mod1 { <LALT>, Alt_L };`
pub const ModMap = struct { real_index: u3, target: ModMapTarget };

/// Everything the parser keeps from a keymap.
pub const Ast = struct {
    keycodes: std.ArrayList(Keycode) = .empty,
    aliases: std.ArrayList(Alias) = .empty,
    vmods: std.ArrayList(VMod) = .empty,
    types: std.ArrayList(KeyType) = .empty,
    interprets: std.ArrayList(Interpret) = .empty,
    keys: std.ArrayList(Key) = .empty,
    modmap: std.ArrayList(ModMap) = .empty,
};
