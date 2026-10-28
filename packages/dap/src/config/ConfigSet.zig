//! The workspace's launch configurations (E07.F06.S01.T02):
//! `.zigguro/launch.zon` first, then `.vscode/launch.json` (read only),
//! with their compounds and inputs. VS Code types map to zigguro's
//! adapters (`type_map.zig`); a configuration whose type maps to nothing,
//! whose name is already taken, or that sits in an untrusted workspace is
//! listed disabled with the reason. Problems with the files are
//! `errors` (with a line and column when the file does not parse).
//!
//! `fromSources` builds a set from texts already read, `loadAll` reads
//! the two files, and `Cache` reloads after `fileChanged` reports one of
//! them. `saveZon` writes the set as launch.zon text for a reviewable
//! edit ("Convert to launch.zon").

const ConfigSet = @This();
const std = @import("std");
const LaunchConfig = @import("LaunchConfig.zig");
const launch_zon = @import("launch_zon.zig");
const launch_json = @import("launch_json.zig");
const type_map = @import("type_map.zig");
const builtin_adapters = @import("../adapters/builtin_adapters.zig");
const TaskList = @import("../tasks/TaskList.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const WorkspaceView = TaskList.WorkspaceView;
pub const untrusted_reason = TaskList.untrusted_reason;

/// The files whose change reloads the set.
pub const watched = [_][]const u8{ launch_zon.path, launch_json.path };

/// A problem with one of the files.
pub const ConfigError = struct {
    /// Workspace-relative file.
    file: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
    message: []const u8,
};

/// Several configurations started together.
pub const Compound = struct {
    name: []const u8,
    configurations: []const []const u8,
    pre_launch_task: ?[]const u8 = null,
    /// Stopping one session stops them all.
    stop_all: bool = false,
    origin_path: ?[]const u8 = null,
};

/// A value asked for when `${input:id}` is substituted.
pub const InputDef = struct {
    pub const Kind = enum { promptString, pickString, command };

    id: []const u8,
    type: Kind,
    description: ?[]const u8 = null,
    default: ?[]const u8 = null,
    /// pickString's choices.
    options: []const []const u8 = &.{},
    password: bool = false,
    /// The command of a `command` input.
    command: ?[]const u8 = null,
    args: ?Value = null,
};

arena: std.heap.ArenaAllocator,
configs: []LaunchConfig = &.{},
compounds: []const Compound = &.{},
inputs: []const InputDef = &.{},
errors: []const ConfigError = &.{},

/// What the readers fill (`launch_zon.append`, `launch_json.append`).
pub const Builder = struct {
    arena: Allocator,
    configs: std.ArrayList(LaunchConfig) = .empty,
    compounds: std.ArrayList(Compound) = .empty,
    inputs: std.ArrayList(InputDef) = .empty,
    errors: std.ArrayList(ConfigError) = .empty,

    pub fn add(b: *Builder, c: LaunchConfig) Allocator.Error!void {
        try b.configs.append(b.arena, c);
    }

    pub fn err(b: *Builder, file: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try b.errors.append(b.arena, .{ .file = file, .message = try std.fmt.allocPrint(b.arena, fmt, args) });
    }

    pub fn errorAt(b: *Builder, file: []const u8, line: u32, column: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try b.errors.append(b.arena, .{ .file = file, .line = line, .column = column, .message = try std.fmt.allocPrint(b.arena, fmt, args) });
    }
};

pub const Inputs = struct {
    launch_zon: ?[:0]const u8 = null,
    launch_json: ?[]const u8 = null,
    os: std.Target.Os.Tag,
    trusted: bool,
};

pub fn fromSources(gpa: Allocator, in: Inputs) Allocator.Error!ConfigSet {
    var set: ConfigSet = .{ .arena = .init(gpa) };
    errdefer set.arena.deinit();
    const a = set.arena.allocator();
    var b: Builder = .{ .arena = a };
    // Configurations may point into the texts, so the set keeps copies.
    if (in.launch_zon) |src| try launch_zon.append(&b, try a.dupeZ(u8, src), in.os);
    if (in.launch_json) |src| try launch_json.append(&b, try a.dupe(u8, src), in.os);

    var seen: std.StringHashMapUnmanaged(LaunchConfig.Source) = .empty;
    for (b.configs.items) |*c| {
        // Types: VS Code's names map to the adapters; launch.zon names
        // an adapter (or alias) directly.
        const mapped = try type_map.map(a, c.type, c.args);
        if (mapped.adapter) |t| {
            c.type = t;
        } else if (builtin_adapters.find(c.type)) |d| {
            c.type = d.type;
        } else disable(c, mapped.reason orelse "no adapter");

        const gop = try seen.getOrPut(a, c.name);
        if (gop.found_existing) {
            const file = c.origin_path orelse "";
            try b.err(file, "configuration \"{s}\" has the name of one in {s}, which is the one used", .{ c.name, sourceFile(gop.value_ptr.*) });
            disable(c, "another configuration has this name");
        } else gop.value_ptr.* = c.source;

        if (!in.trusted) {
            c.enabled = false;
            c.disabled_reason = untrusted_reason;
        }
    }
    for (b.compounds.items) |cp| {
        if (cp.configurations.len == 0) try b.err(cp.origin_path orelse "", "compound \"{s}\" lists no configurations", .{cp.name});
        for (cp.configurations) |n| {
            if (!seen.contains(n)) try b.err(cp.origin_path orelse "", "compound \"{s}\": no configuration named \"{s}\"", .{ cp.name, n });
        }
    }
    set.configs = b.configs.items;
    set.compounds = b.compounds.items;
    set.inputs = b.inputs.items;
    set.errors = b.errors.items;
    return set;
}

fn disable(c: *LaunchConfig, reason: []const u8) void {
    if (!c.enabled) return;
    c.enabled = false;
    c.disabled_reason = reason;
}

fn sourceFile(s: LaunchConfig.Source) []const u8 {
    return switch (s) {
        .zon => launch_zon.path,
        .vscode => launch_json.path,
        .auto => "the generated configurations",
    };
}

/// Reads the launch files under `ws.root`.
pub fn loadAll(gpa: Allocator, io: Io, ws: WorkspaceView, os: std.Target.Os.Tag) !ConfigSet {
    const zon = try readFile(gpa, io, ws.root, launch_zon.path);
    defer if (zon) |s| gpa.free(s);
    const json = try readFile(gpa, io, ws.root, launch_json.path);
    defer if (json) |s| gpa.free(s);
    return fromSources(gpa, .{ .launch_zon = zon, .launch_json = json, .os = os, .trusted = ws.trusted });
}

fn readFile(gpa: Allocator, io: Io, root: []const u8, rel: []const u8) !?[:0]u8 {
    var dir = Io.Dir.cwd().openDir(io, root, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer dir.close(io);
    return dir.readFileAllocOptions(io, rel, gpa, .limited(4 << 20), .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

pub fn deinit(s: *ConfigSet) void {
    s.arena.deinit();
    s.* = undefined;
}

pub fn find(s: *const ConfigSet, name: []const u8) ?*const LaunchConfig {
    for (s.configs) |*c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

pub fn findCompound(s: *const ConfigSet, name: []const u8) ?*const Compound {
    for (s.compounds) |*c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

pub fn findInput(s: *const ConfigSet, id: []const u8) ?*const InputDef {
    for (s.inputs) |*in| if (std.mem.eql(u8, in.id, id)) return in;
    return null;
}

/// The set as launch.zon text (owned by `gpa`); see `launch_zon.save`.
pub fn saveZon(s: *const ConfigSet, gpa: Allocator) Allocator.Error![]u8 {
    return launch_zon.save(gpa, s);
}

/// The last set, reloaded on demand after `fileChanged` reports a change
/// to a watched file (the E08 watch pipeline calls it).
pub const Cache = struct {
    gpa: Allocator,
    ws: WorkspaceView,
    os: std.Target.Os.Tag,
    set: ?*ConfigSet = null,
    /// Sets replaced by a reload, kept until `deinit`: a session start on
    /// another thread may still be reading one.
    retired: std.ArrayList(*ConfigSet) = .empty,
    dirty: bool = true,

    pub fn init(gpa: Allocator, ws: WorkspaceView, os: std.Target.Os.Tag) Cache {
        return .{ .gpa = gpa, .ws = ws, .os = os };
    }

    pub fn deinit(c: *Cache) void {
        if (c.set) |s| c.free(s);
        for (c.retired.items) |s| c.free(s);
        c.retired.deinit(c.gpa);
        c.* = undefined;
    }

    fn free(c: *Cache, s: *ConfigSet) void {
        s.deinit();
        c.gpa.destroy(s);
    }

    /// The current set, reloaded first when a watched file changed. A
    /// reload returns a new pointer; the old set stays valid until
    /// `deinit`.
    pub fn get(c: *Cache, io: Io) !*const ConfigSet {
        if (c.dirty or c.set == null) {
            try c.retired.ensureUnusedCapacity(c.gpa, 1);
            const fresh = try c.gpa.create(ConfigSet);
            errdefer c.gpa.destroy(fresh);
            fresh.* = try loadAll(c.gpa, io, c.ws, c.os);
            if (c.set) |old| c.retired.appendAssumeCapacity(old);
            c.set = fresh;
            c.dirty = false;
        }
        return c.set.?;
    }

    pub fn setTrusted(c: *Cache, trusted: bool) void {
        if (c.ws.trusted == trusted) return;
        c.ws.trusted = trusted;
        c.dirty = true;
    }

    /// A file changed (absolute, or relative to the workspace root).
    /// Returns whether it is one the set depends on.
    pub fn fileChanged(c: *Cache, path: []const u8) bool {
        var rel = path;
        if (std.mem.startsWith(u8, rel, c.ws.root)) rel = std.mem.trimStart(u8, rel[c.ws.root.len..], "/\\");
        for (watched) |w| {
            if (rel.len != w.len) continue;
            for (rel, w) |x, y| {
                if ((if (x == '\\') '/' else x) != y) break;
            } else {
                c.dirty = true;
                return true;
            }
        }
        return false;
    }
};

// Value helpers shared by the two readers.

pub fn object(v: ?Value) ?ObjectMap {
    return switch (v orelse return null) {
        .object => |o| o,
        else => null,
    };
}

/// An array's items; an empty object (ZON's `.{}`) is an empty array.
pub fn items(v: ?Value) []const Value {
    return switch (v orelse return &.{}) {
        .array => |arr| arr.items,
        else => &.{},
    };
}

pub fn string(v: ?Value) ?[]const u8 {
    return switch (v orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn boolean(v: ?Value) ?bool {
    return switch (v orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

pub fn request(v: ?Value) ?LaunchConfig.Request {
    return std.meta.stringToEnum(LaunchConfig.Request, string(v) orelse return null);
}

/// Strings, or objects with a `name` (VS Code compounds' `{ name, folder }`).
pub fn stringList(a: Allocator, v: ?Value) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (items(v)) |it| switch (it) {
        .string => |s| try out.append(a, s),
        .object => |o| if (string(o.get("name"))) |s| try out.append(a, s),
        else => {},
    };
    return out.items;
}

pub fn presentation(o: ObjectMap) LaunchConfig.Presentation {
    return .{
        .hidden = boolean(o.get("hidden")) orelse false,
        .group = string(o.get("group")),
        .order = if (o.get("order")) |v| (if (v == .integer) v.integer else null) else null,
    };
}

/// `base` with `over`'s fields on top (an OS override object). `args`
/// and `env` objects merge key by key; `type` cannot be overridden.
pub fn overrideFields(b: *Builder, file: []const u8, base: ObjectMap, over: ObjectMap) Allocator.Error!ObjectMap {
    var out = try base.clone(b.arena);
    var it = over.iterator();
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key_ptr.*, "type")) {
            try b.err(file, "\"{s}\": the type cannot be changed per OS", .{string(base.get("name")) orelse "?"});
            continue;
        }
        try mergeField(b.arena, &out, kv.key_ptr.*, kv.value_ptr.*);
    }
    return out;
}

fn mergeField(a: Allocator, into: *ObjectMap, key: []const u8, v: Value) Allocator.Error!void {
    const deep = std.mem.eql(u8, key, "args") or std.mem.eql(u8, key, "env");
    if (deep and v == .object) if (into.get(key)) |old| if (old == .object) {
        var merged = try old.object.clone(a);
        var it = v.object.iterator();
        while (it.next()) |kv| try mergeField(a, &merged, kv.key_ptr.*, kv.value_ptr.*);
        try into.put(a, key, .{ .object = merged });
        return;
    };
    try into.put(a, key, v);
}

/// An `inputs` entry (the same fields in both files).
pub fn input(b: *Builder, file: []const u8, o: ObjectMap) Allocator.Error!?InputDef {
    const id = string(o.get("id")) orelse {
        try b.err(file, "an input has no id", .{});
        return null;
    };
    const kind = std.meta.stringToEnum(InputDef.Kind, string(o.get("type")) orelse "") orelse {
        try b.err(file, "input \"{s}\": type must be promptString, pickString or command", .{id});
        return null;
    };
    var opts: std.ArrayList([]const u8) = .empty;
    for (items(o.get("options"))) |it| switch (it) {
        .string => |s| try opts.append(b.arena, s),
        // `{ label, value }`: the value is what is substituted.
        .object => |m| if (string(m.get("value"))) |s| try opts.append(b.arena, s),
        else => {},
    };
    const in: InputDef = .{
        .id = id,
        .type = kind,
        .description = string(o.get("description")),
        .default = string(o.get("default")),
        .options = opts.items,
        .password = boolean(o.get("password")) orelse false,
        .command = string(o.get("command")),
        .args = o.get("args"),
    };
    if (kind == .pickString and in.options.len == 0) try b.err(file, "input \"{s}\": pickString needs options", .{id});
    if (kind == .command and in.command == null) try b.err(file, "input \"{s}\": a command input needs a command", .{id});
    return in;
}
