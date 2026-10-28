//! One debug configuration (E07.F06.S01.T02): what to debug and with
//! which adapter, from `.zigguro/launch.zon`, `.vscode/launch.json` or
//! generated for a Zig project (`zig_autoconfig.zig`). `args` is the
//! adapter's own launch or attach object, before `${...}` substitution
//! (done when the session starts, so `${file}` is the editor of that
//! moment).

const std = @import("std");

pub const Request = enum { launch, attach };

pub const Source = enum { zon, vscode, auto };

/// Where the configuration shows in the picker.
pub const Presentation = struct {
    hidden: bool = false,
    group: ?[]const u8 = null,
    order: ?i64 = null,
};

/// A task a generated configuration needs before it starts (the
/// runtime adds it to the task list under `label`).
pub const GeneratedTask = struct {
    label: []const u8,
    command: []const u8,
    args: []const []const u8,
    cwd: ?[]const u8 = null,
};

name: []const u8,
/// The adapter type (`AdapterDef.type` or an alias).
type: []const u8,
request: Request,
args: std.json.ObjectMap,
pre_launch_task: ?[]const u8 = null,
post_debug_task: ?[]const u8 = null,
presentation: ?Presentation = null,
source: Source,
origin_path: ?[]const u8 = null,
enabled: bool = true,
disabled_reason: ?[]const u8 = null,
/// For generated configurations: the pre-launch task they define.
generated_task: ?GeneratedTask = null,

/// The string value of `args[key]`, if it is one.
pub fn argString(c: *const @This(), key: []const u8) ?[]const u8 {
    const v = c.args.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
