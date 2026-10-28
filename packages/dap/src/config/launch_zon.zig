//! `.zigguro/launch.zon`, zigguro's own debug configurations
//! (E07.F06.S01.T02):
//!
//!     .{
//!         .version = 1,
//!         .configurations = .{
//!             .{
//!                 .name = "Debug app",
//!                 .type = "lldb-dap",
//!                 .request = .launch,
//!                 .args = .{ .program = "${workspaceFolder}/zig-out/bin/app" },
//!                 .pre_launch_task = "zig build",
//!                 .windows = .{ .args = .{ .program = "${workspaceFolder}/zig-out/bin/app.exe" } },
//!             },
//!         },
//!         .compounds = .{ .{ .name = "Both", .configurations = .{ "a", "b" }, .stop_all = true } },
//!         .inputs = .{ .{ .id = "pid", .type = .promptString, .description = "Process id" } },
//!     }
//!
//! `args` is the adapter's own object and is read as written (any ZON
//! value), through `zon_dynamic`. `windows`, `linux` and `macos` objects
//! override a configuration's fields on that OS (`args` merges key by
//! key; `type` cannot be overridden).

const std = @import("std");
const ConfigSet = @import("ConfigSet.zig");
const LaunchConfig = @import("LaunchConfig.zig");
const zon_dynamic = @import("zon_dynamic.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;
const Builder = ConfigSet.Builder;

pub const path = ".zigguro/launch.zon";

fn osKey(os: std.Target.Os.Tag) ?[]const u8 {
    return switch (os) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => null,
    };
}

/// Adds the contents of `src` to `b`.
pub fn append(b: *Builder, src: [:0]const u8, os: std.Target.Os.Tag) Allocator.Error!void {
    const a = b.arena;
    var zerr: zon_dynamic.ZonError = undefined;
    const root = (try zon_dynamic.parse(a, src, &zerr)) orelse
        return b.errorAt(path, zerr.line, zerr.column, "{s}", .{zerr.message});
    const top = ConfigSet.object(root) orelse return b.err(path, "expected a struct at the top level", .{});
    if (top.get("version")) |v| if (v != .integer or v.integer != 1) try b.err(path, "version must be 1", .{});
    const os_key = osKey(os);

    for (ConfigSet.items(top.get("configurations")), 0..) |cv, i| {
        var o = ConfigSet.object(cv) orelse {
            try b.err(path, "configuration {d} is not a struct", .{i + 1});
            continue;
        };
        if (os_key) |k| if (ConfigSet.object(o.get(k))) |over| {
            o = try ConfigSet.overrideFields(b, path, o, over);
        };
        const name = ConfigSet.string(o.get("name")) orelse {
            try b.err(path, "configuration {d} has no .name", .{i + 1});
            continue;
        };
        const type_name = ConfigSet.string(o.get("type")) orelse {
            try b.err(path, "\"{s}\" has no .type", .{name});
            continue;
        };
        const request = ConfigSet.request(o.get("request")) orelse {
            try b.err(path, "\"{s}\": .request must be .launch or .attach", .{name});
            continue;
        };
        var args: ObjectMap = .empty;
        if (o.get("args")) |av| switch (av) {
            .object => |m| args = m,
            else => try b.err(path, "\"{s}\": .args must be a struct", .{name}),
        };
        var pres: ?LaunchConfig.Presentation = null;
        if (ConfigSet.object(o.get("presentation"))) |p| pres = ConfigSet.presentation(p);
        try b.add(.{
            .name = name,
            .type = type_name,
            .request = request,
            .args = args,
            .pre_launch_task = ConfigSet.string(o.get("pre_launch_task")),
            .post_debug_task = ConfigSet.string(o.get("post_debug_task")),
            .presentation = pres,
            .source = .zon,
            .origin_path = path,
        });
    }
    for (ConfigSet.items(top.get("compounds")), 0..) |cv, i| {
        const o = ConfigSet.object(cv) orelse {
            try b.err(path, "compound {d} is not a struct", .{i + 1});
            continue;
        };
        const name = ConfigSet.string(o.get("name")) orelse {
            try b.err(path, "compound {d} has no .name", .{i + 1});
            continue;
        };
        try b.compounds.append(a, .{
            .name = name,
            .configurations = try ConfigSet.stringList(a, o.get("configurations")),
            .pre_launch_task = ConfigSet.string(o.get("pre_launch_task")),
            .stop_all = ConfigSet.boolean(o.get("stop_all")) orelse false,
            .origin_path = path,
        });
    }
    for (ConfigSet.items(top.get("inputs")), 0..) |iv, i| {
        const o = ConfigSet.object(iv) orelse {
            try b.err(path, "input {d} is not a struct", .{i + 1});
            continue;
        };
        if (try ConfigSet.input(b, path, o)) |in| try b.inputs.append(a, in);
    }
}

/// `set`'s configurations, compounds and inputs as launch.zon text, for
/// a reviewable edit (never written here). Generated configurations'
/// tasks are not part of it.
pub fn save(gpa: Allocator, set: *const ConfigSet) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var top: ObjectMap = .empty;
    try top.put(a, "version", .{ .integer = 1 });
    var cfgs: std.json.Array = .init(a);
    for (set.configs) |c| {
        if (c.source == .auto) continue;
        var o: ObjectMap = .empty;
        try o.put(a, "name", .{ .string = c.name });
        try o.put(a, "type", .{ .string = c.type });
        try o.put(a, "request", .{ .string = @tagName(c.request) });
        try o.put(a, "args", .{ .object = c.args });
        if (c.pre_launch_task) |t| try o.put(a, "pre_launch_task", .{ .string = t });
        if (c.post_debug_task) |t| try o.put(a, "post_debug_task", .{ .string = t });
        if (c.presentation) |p| {
            var po: ObjectMap = .empty;
            if (p.hidden) try po.put(a, "hidden", .{ .bool = true });
            if (p.group) |g| try po.put(a, "group", .{ .string = g });
            if (p.order) |n| try po.put(a, "order", .{ .integer = n });
            try o.put(a, "presentation", .{ .object = po });
        }
        try cfgs.append(.{ .object = o });
    }
    try top.put(a, "configurations", .{ .array = cfgs });
    if (set.compounds.len > 0) {
        var cs: std.json.Array = .init(a);
        for (set.compounds) |c| {
            var o: ObjectMap = .empty;
            try o.put(a, "name", .{ .string = c.name });
            var names: std.json.Array = .init(a);
            for (c.configurations) |n| try names.append(.{ .string = n });
            try o.put(a, "configurations", .{ .array = names });
            if (c.pre_launch_task) |t| try o.put(a, "pre_launch_task", .{ .string = t });
            if (c.stop_all) try o.put(a, "stop_all", .{ .bool = true });
            try cs.append(.{ .object = o });
        }
        try top.put(a, "compounds", .{ .array = cs });
    }
    if (set.inputs.len > 0) {
        var ins: std.json.Array = .init(a);
        for (set.inputs) |in| {
            var o: ObjectMap = .empty;
            try o.put(a, "id", .{ .string = in.id });
            try o.put(a, "type", .{ .string = @tagName(in.type) });
            if (in.description) |d| try o.put(a, "description", .{ .string = d });
            if (in.default) |d| try o.put(a, "default", .{ .string = d });
            if (in.options.len > 0) {
                var opts: std.json.Array = .init(a);
                for (in.options) |x| try opts.append(.{ .string = x });
                try o.put(a, "options", .{ .array = opts });
            }
            if (in.password) try o.put(a, "password", .{ .bool = true });
            if (in.command) |c| try o.put(a, "command", .{ .string = c });
            if (in.args) |v| try o.put(a, "args", v);
            try ins.append(.{ .object = o });
        }
        try top.put(a, "inputs", .{ .array = ins });
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    zon_dynamic.write(&out.writer, .{ .object = top }, 0, &.{ "request", "type" }) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}
