//! Read-only import of `.vscode/launch.json` (version 0.2.0, JSONC) for
//! E07.F06.S01.T02. The file is never written back.
//!
//! - Every key of a configuration that is not one of VS Code's own
//!   (`name`, `type`, `request`, `preLaunchTask`, `postDebugTask`,
//!   `presentation`, `windows`, `linux`, `osx`, `internalConsoleOptions`,
//!   `debugServer`) is the adapter's and goes to `args` as written.
//! - The `windows`/`linux`/`osx` objects override the configuration's
//!   fields on that OS (`env` merges key by key; `type` cannot change).
//! - `compounds` name configurations as strings or `{ name, folder }`.
//! - `${...}` is left as written; it is substituted when a session starts.

const std = @import("std");
const ConfigSet = @import("ConfigSet.zig");
const jsonc = @import("../tasks/sources/jsonc.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Builder = ConfigSet.Builder;

pub const path = ".vscode/launch.json";

const reserved = std.StaticStringMap(void).initComptime(.{
    .{"name"},                   .{"type"},          .{"request"},
    .{"preLaunchTask"},          .{"postDebugTask"}, .{"presentation"},
    .{"windows"},                .{"linux"},         .{"osx"},
    .{"internalConsoleOptions"}, .{"debugServer"},
});

fn osKey(os: std.Target.Os.Tag) ?[]const u8 {
    return switch (os) {
        .windows => "windows",
        .linux => "linux",
        .macos => "osx",
        else => null,
    };
}

/// Adds the contents of `src` (kept alive by the caller) to `b`.
pub fn append(b: *Builder, src: []const u8, os: std.Target.Os.Tag) Allocator.Error!void {
    const a = b.arena;
    const text = jsonc.stripJsonc(a, src) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnterminatedComment => return b.err(path, "unterminated /* comment", .{}),
    };
    var scanner: std.json.Scanner = .initCompleteInput(a, text);
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    const root = std.json.parseFromTokenSourceLeaky(Value, a, &scanner, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return b.errorAt(path, @intCast(diag.getLine()), @intCast(diag.getColumn()), "not valid JSON ({s})", .{@errorName(e)}),
    };
    const top = ConfigSet.object(root) orelse return b.err(path, "expected an object at the top level", .{});
    if (ConfigSet.string(top.get("version"))) |v| {
        if (!std.mem.eql(u8, v, "0.2.0")) try b.err(path, "version \"{s}\" is not supported (expected \"0.2.0\"); reading it as 0.2.0", .{v});
    }
    const os_key = osKey(os);

    for (ConfigSet.items(top.get("configurations")), 0..) |cv, i| {
        var o = ConfigSet.object(cv) orelse {
            try b.err(path, "configuration {d} is not an object", .{i + 1});
            continue;
        };
        if (os_key) |k| if (ConfigSet.object(o.get(k))) |over| {
            o = try ConfigSet.overrideFields(b, path, o, over);
        };
        const name = ConfigSet.string(o.get("name")) orelse {
            try b.err(path, "configuration {d} has no name", .{i + 1});
            continue;
        };
        const type_name = ConfigSet.string(o.get("type")) orelse {
            try b.err(path, "\"{s}\" has no type", .{name});
            continue;
        };
        const request = ConfigSet.request(o.get("request")) orelse {
            try b.err(path, "\"{s}\": request must be \"launch\" or \"attach\"", .{name});
            continue;
        };
        var args: ObjectMap = .empty;
        var it = o.iterator();
        while (it.next()) |kv| {
            if (reserved.has(kv.key_ptr.*)) continue;
            try args.put(a, kv.key_ptr.*, kv.value_ptr.*);
        }
        try b.add(.{
            .name = name,
            .type = type_name,
            .request = request,
            .args = args,
            .pre_launch_task = ConfigSet.string(o.get("preLaunchTask")),
            .post_debug_task = ConfigSet.string(o.get("postDebugTask")),
            .presentation = if (ConfigSet.object(o.get("presentation"))) |p| ConfigSet.presentation(p) else null,
            .source = .vscode,
            .origin_path = path,
        });
    }
    for (ConfigSet.items(top.get("compounds")), 0..) |cv, i| {
        const o = ConfigSet.object(cv) orelse {
            try b.err(path, "compound {d} is not an object", .{i + 1});
            continue;
        };
        const name = ConfigSet.string(o.get("name")) orelse {
            try b.err(path, "compound {d} has no name", .{i + 1});
            continue;
        };
        try b.compounds.append(a, .{
            .name = name,
            .configurations = try ConfigSet.stringList(a, o.get("configurations")),
            .pre_launch_task = ConfigSet.string(o.get("preLaunchTask")),
            .stop_all = ConfigSet.boolean(o.get("stopAll")) orelse false,
            .origin_path = path,
        });
    }
    for (ConfigSet.items(top.get("inputs")), 0..) |iv, i| {
        const o = ConfigSet.object(iv) orelse {
            try b.err(path, "input {d} is not an object", .{i + 1});
            continue;
        };
        if (try ConfigSet.input(b, path, o)) |in| try b.inputs.append(a, in);
    }
}
