//! Keymap presets: the default VS Code-style keymap and the JetBrains and
//! Sublime Text presets, shipped as ZON data, plus the Vim/Emacs mode layer
//! selection. `keyboard.preset` picks the base; the VS Code keymap is always
//! loaded first and the chosen preset applies on top of it (both in the
//! `preset` layer), so presets only list what differs.

const std = @import("std");
const keymap = @import("keymap.zig");
const store = @import("../store.zig");

/// A preset (setting `keyboard.preset`).
pub const Preset = enum { vscode, jetbrains, sublime, none };

/// The ZON source of one preset file (`none` has no file).
pub fn presetSource(p: Preset) ?[:0]const u8 {
    return switch (p) {
        .vscode => @embedFile("presets/vscode.zon"),
        .jetbrains => @embedFile("presets/jetbrains.zon"),
        .sublime => @embedFile("presets/sublime.zon"),
        .none => null,
    };
}

const vscode_src: [:0]const u8 = @embedFile("presets/vscode.zon");
const layers_vscode = [_][:0]const u8{vscode_src};
const layers_jetbrains = [_][:0]const u8{ vscode_src, @embedFile("presets/jetbrains.zon") };
const layers_sublime = [_][:0]const u8{ vscode_src, @embedFile("presets/sublime.zon") };

/// The files that make up preset `p`, in load order (all `Layer.preset`).
pub fn presetLayers(p: Preset) []const [:0]const u8 {
    return switch (p) {
        .vscode => &layers_vscode,
        .jetbrains => &layers_jetbrains,
        .sublime => &layers_sublime,
        .none => &.{},
    };
}

/// One onboarding choice ("Which editor are you coming from?").
pub const Choice = struct {
    label: []const u8,
    description: []const u8,
    preset: Preset,
    /// Also enable a mode layer (E05).
    mode: ?Mode = null,
};

/// Editor mode layers provided by E05.
pub const Mode = enum { vim, emacs };

/// The onboarding choices, for the E04/E17 first-run flow.
pub fn choices() []const Choice {
    return &.{
        .{ .label = "VS Code", .description = "VS Code default shortcuts.", .preset = .vscode },
        .{ .label = "JetBrains", .description = "IntelliJ IDEA default keymap: Shift Shift, Ctrl+Shift+A, Alt+Enter.", .preset = .jetbrains },
        .{ .label = "Sublime Text", .description = "Sublime Text shortcuts; the agent pane moves to Mod+Alt+L.", .preset = .sublime },
        .{ .label = "Vim", .description = "VS Code shortcuts plus Vim modal editing.", .preset = .vscode, .mode = .vim },
        .{ .label = "Emacs", .description = "VS Code shortcuts plus Emacs editing keys.", .preset = .vscode, .mode = .emacs },
    };
}

/// The preset selected in `snap` (default `vscode`).
pub fn selected(snap: *const store.Snapshot) Preset {
    const v = snap.getByKey("keyboard.preset", .{}) orelse return .vscode;
    const t = switch (v) {
        .string, .enum_lit => |s| s,
        else => return .vscode,
    };
    return std.meta.stringToEnum(Preset, t) orelse .vscode;
}

/// The enabled mode layer in `snap`, if any. Vim wins if both are set (the
/// settings UI keeps them exclusive).
pub fn selectedMode(snap: *const store.Snapshot) ?Mode {
    if (flag(snap, "keyboard.vim.enabled")) return .vim;
    if (flag(snap, "keyboard.emacs.enabled")) return .emacs;
    return null;
}

fn flag(snap: *const store.Snapshot, key: []const u8) bool {
    const v = snap.getByKey(key, .{}) orelse return false;
    return v == .bool and v.bool;
}

/// Bindings generated from `keyboard.vim.passthroughKeys`: each key keeps
/// its default command outside insert mode. Returned as ZON source for a
/// `mode_layer` input; `default_cmds` maps a key spec to its command.
pub fn vimPassthroughSource(arena: std.mem.Allocator, keys: []const []const u8, default_cmd: *const fn (key: []const u8) ?[]const u8) ![:0]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    w.writeAll(".{\n") catch return error.OutOfMemory;
    for (keys) |k| {
        const cmd = default_cmd(k) orelse continue;
        w.print("    .{{ .key = \"{f}\", .command = \"{f}\", .when = \"vim.mode != insert\" }},\n", .{ std.zig.fmtString(k), std.zig.fmtString(cmd) }) catch return error.OutOfMemory;
    }
    w.writeAll("}\n") catch return error.OutOfMemory;
    return aw.toOwnedSliceSentinel(0) catch error.OutOfMemory;
}
