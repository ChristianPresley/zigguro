//! The terminal mode table: every ANSI and DEC private mode we know, with its
//! default and DECRQM reporting class. `ModeId` and the lookup tables are
//! generated from `mode_defs` at comptime, so the table is the single source
//! of truth for set/reset, DECRQM, XTSAVE/XTRESTORE and DECRQSS.

const std = @import("std");

/// Which namespace a mode number lives in.
pub const Kind = enum { ansi, dec };

/// How DECRQM reports a mode.
pub const Report = enum { normal, perm_set, perm_reset };

/// One mode definition.
pub const ModeDef = struct {
    name: [:0]const u8,
    value: u16,
    kind: Kind,
    default: bool = false,
    report: Report = .normal,
};

/// Every supported mode.
pub const mode_defs = [_]ModeDef{
    .{ .name = "insert", .value = 4, .kind = .ansi },
    .{ .name = "linefeed", .value = 20, .kind = .ansi },
    .{ .name = "cursor_keys", .value = 1, .kind = .dec },
    .{ .name = "column_132", .value = 3, .kind = .dec },
    .{ .name = "reverse_video", .value = 5, .kind = .dec },
    .{ .name = "origin", .value = 6, .kind = .dec },
    .{ .name = "autowrap", .value = 7, .kind = .dec, .default = true },
    .{ .name = "autorepeat", .value = 8, .kind = .dec, .default = true, .report = .perm_set },
    .{ .name = "mouse_x10", .value = 9, .kind = .dec },
    .{ .name = "cursor_blink", .value = 12, .kind = .dec },
    .{ .name = "cursor_visible", .value = 25, .kind = .dec, .default = true },
    .{ .name = "allow_column_132", .value = 40, .kind = .dec },
    .{ .name = "reverse_wrap", .value = 45, .kind = .dec },
    .{ .name = "alt_screen_legacy", .value = 47, .kind = .dec },
    .{ .name = "keypad_numeric", .value = 66, .kind = .dec },
    .{ .name = "backarrow_bs", .value = 67, .kind = .dec },
    .{ .name = "left_right_margins", .value = 69, .kind = .dec },
    .{ .name = "sixel_display", .value = 80, .kind = .dec },
    .{ .name = "mouse_normal", .value = 1000, .kind = .dec },
    .{ .name = "mouse_button", .value = 1002, .kind = .dec },
    .{ .name = "mouse_any", .value = 1003, .kind = .dec },
    .{ .name = "focus_events", .value = 1004, .kind = .dec },
    .{ .name = "mouse_utf8", .value = 1005, .kind = .dec },
    .{ .name = "mouse_sgr", .value = 1006, .kind = .dec },
    .{ .name = "alternate_scroll", .value = 1007, .kind = .dec },
    .{ .name = "mouse_urxvt", .value = 1015, .kind = .dec },
    .{ .name = "mouse_sgr_pixels", .value = 1016, .kind = .dec },
    .{ .name = "num_lock", .value = 1035, .kind = .dec },
    .{ .name = "meta_sends_escape", .value = 1036, .kind = .dec, .default = true },
    .{ .name = "alt_sends_escape", .value = 1039, .kind = .dec },
    .{ .name = "alt_screen", .value = 1047, .kind = .dec },
    .{ .name = "save_cursor", .value = 1048, .kind = .dec },
    .{ .name = "alt_screen_save", .value = 1049, .kind = .dec },
    .{ .name = "bracketed_paste", .value = 2004, .kind = .dec },
    .{ .name = "synchronized_output", .value = 2026, .kind = .dec },
    .{ .name = "grapheme_cluster", .value = 2027, .kind = .dec },
    .{ .name = "color_scheme_reports", .value = 2031, .kind = .dec, .report = .perm_reset },
    .{ .name = "in_band_resize", .value = 2048, .kind = .dec },
    .{ .name = "win32_input", .value = 9001, .kind = .dec },
    .{ .name = "kitty_paste_events", .value = 5522, .kind = .dec, .report = .perm_reset },
};

/// A mode, by name.
pub const ModeId = blk: {
    var names: [mode_defs.len][]const u8 = undefined;
    var values: [mode_defs.len]u16 = undefined;
    for (mode_defs, 0..) |d, i| {
        names[i] = d.name;
        values[i] = i;
    }
    break :blk @Enum(u16, .exhaustive, &names, &values);
};

/// The definition of `id`.
pub fn def(id: ModeId) ModeDef {
    return mode_defs[@intFromEnum(id)];
}

const Bits = std.StaticBitSet(mode_defs.len);

/// The current and XTSAVE'd values of every mode.
pub const Modes = struct {
    bits: Bits,
    saved: Bits,

    /// All modes at their defaults.
    pub const initial: Modes = blk: {
        var b = Bits.initEmpty();
        for (mode_defs, 0..) |d, i| if (d.default) b.set(i);
        break :blk .{ .bits = b, .saved = b };
    };

    /// Whether `id` is set.
    pub inline fn get(m: *const Modes, id: ModeId) bool {
        return m.bits.isSet(@intFromEnum(id));
    }

    /// Sets `id` (permanent modes never change).
    pub inline fn set(m: *Modes, id: ModeId, on: bool) void {
        if (def(id).report != .normal) return;
        m.bits.setValue(@intFromEnum(id), on);
    }

    /// XTSAVE of one mode.
    pub fn save(m: *Modes, id: ModeId) void {
        m.saved.setValue(@intFromEnum(id), m.get(id));
    }

    /// The XTSAVE'd value of `id`.
    pub fn savedValue(m: *const Modes, id: ModeId) bool {
        return m.saved.isSet(@intFromEnum(id));
    }

    /// The mode with number `value` in namespace `kind`.
    pub fn lookup(kind: Kind, value: u16) ?ModeId {
        inline for (mode_defs, 0..) |d, i| {
            if (d.kind == kind and d.value == value) return @enumFromInt(i);
        }
        return null;
    }

    /// The DECRQM Ps for a mode number: 0 unknown, 1 set, 2 reset,
    /// 3 permanently set, 4 permanently reset.
    pub fn reportValue(m: *const Modes, kind: Kind, value: u16) u8 {
        const id = lookup(kind, value) orelse return 0;
        return switch (def(id).report) {
            .perm_set => 3,
            .perm_reset => 4,
            .normal => if (m.get(id)) 1 else 2,
        };
    }
};

test "lookup and defaults" {
    const m = Modes.initial;
    try std.testing.expect(m.get(.autowrap));
    try std.testing.expect(!m.get(.origin));
    try std.testing.expectEqual(ModeId.alt_screen_save, Modes.lookup(.dec, 1049).?);
    try std.testing.expectEqual(ModeId.insert, Modes.lookup(.ansi, 4).?);
    try std.testing.expect(Modes.lookup(.ansi, 1049) == null);
}

test "modes: DECRQM for every def returns the right Ps; unknown → 0" {
    var m = Modes.initial;
    for (mode_defs, 0..) |d, i| {
        const id: ModeId = @enumFromInt(i);
        const want: u8 = switch (d.report) {
            .perm_set => 3,
            .perm_reset => 4,
            .normal => if (d.default) 1 else 2,
        };
        try std.testing.expectEqual(want, m.reportValue(d.kind, d.value));
        m.set(id, !d.default);
        if (d.report == .normal) try std.testing.expectEqual(@as(u8, if (d.default) 2 else 1), m.reportValue(d.kind, d.value));
    }
    try std.testing.expectEqual(@as(u8, 0), m.reportValue(.dec, 31337));
}

test "XTSAVE/XTRESTORE round trip" {
    var m = Modes.initial;
    m.set(.mouse_sgr, true);
    m.save(.mouse_sgr);
    m.set(.mouse_sgr, false);
    try std.testing.expect(m.savedValue(.mouse_sgr));
}
