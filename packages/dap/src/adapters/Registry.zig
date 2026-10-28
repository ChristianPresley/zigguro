//! The debug adapter registry (E07.F06.S01.T04): the built-in adapter
//! definitions plus the user's settings, and resolving an adapter to the
//! argv that starts it. Lookup is by `type` or alias. Resolving searches
//! PATH (zg_lsp's shared search, PATHEXT on Windows), runs the version
//! probe once (2 s deadline) when the adapter has a minimum version, and
//! caches the outcome per type until `rescan`. Settings the app passes in:
//! `debug.adapters.debugpy.python`, `debug.adapters.jsDebug.path`,
//! `debug.adapters.codelldb.command` and per-type command overrides
//! (`debug.adapters.<type>.command`); overrides from workspace settings
//! are ignored in an untrusted workspace.

const Registry = @This();
const std = @import("std");
const builtin = @import("builtin");
const zg_lsp = @import("zg_lsp");
const builtins = @import("builtin_adapters.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const executables = zg_lsp.client.executables;

pub const AdapterDef = builtins.AdapterDef;
pub const TransportKind = builtins.TransportKind;

/// A command set in settings for one adapter type.
pub const Override = struct {
    type: []const u8,
    command: []const []const u8,
    /// From the workspace's settings (ignored when untrusted).
    from_workspace: bool = false,
};

pub const Options = struct {
    os: std.Target.Os.Tag = builtin.os.tag,
    /// `debug.adapters.debugpy.python` (default "python", "py" on
    /// Windows when "python" is missing).
    python: ?[]const u8 = null,
    /// `debug.adapters.jsDebug.path`: the unpacked js-debug folder.
    js_debug_path: ?[]const u8 = null,
    /// `debug.adapters.codelldb.command`.
    codelldb_command: ?[]const []const u8 = null,
    overrides: []const Override = &.{},
    trusted: bool = true,
    probe_timeout: Io.Duration = .fromSeconds(2),
};

/// A startable adapter.
pub const Resolved = struct {
    def: *const AdapterDef,
    /// argv[0] found on disk; `{port}` left for TCP adapters (`withPort`).
    argv: []const []const u8,
    version: ?std.SemanticVersion = null,
    /// The probe's first line, when it ran.
    version_text: ?[]const u8 = null,
};

/// Why an adapter can or cannot start.
pub const Status = union(enum) {
    ok: Resolved,
    /// Not on PATH (or the configured path does not exist).
    missing: []const u8,
    /// Older than `min_version`.
    too_old: struct { found: std.SemanticVersion, min: std.SemanticVersion, text: []const u8 },
    /// Needs a setting first (js-debug, CodeLLDB).
    needs_setting: []const u8,

    /// A one-line explanation for a notice or the picker.
    pub fn message(s: Status, a: Allocator, def: *const AdapterDef) Allocator.Error![]const u8 {
        return switch (s) {
            .ok => |r| if (r.version_text) |t| std.fmt.allocPrint(a, "{s}: {s}", .{ def.label, t }) else a.dupe(u8, def.label),
            .missing => |exe| std.fmt.allocPrint(a, "{s} not found ({s}). {s}", .{ def.label, exe, def.install_hint }),
            .too_old => |o| std.fmt.allocPrint(a, "{s} {d}.{d} is too old: version {d}.{d} or later is needed. {s}", .{ def.label, o.found.major, o.found.minor, o.min.major, o.min.minor, def.install_hint }),
            .needs_setting => |key| std.fmt.allocPrint(a, "{s} needs the setting {s}. {s}", .{ def.label, key, def.install_hint }),
        };
    }
};

gpa: Allocator,
arena: std.heap.ArenaAllocator,
opts: Options,
/// The definitions with settings applied (commands replaced), in
/// built-in order.
defs: []AdapterDef,
cache: std.StringHashMapUnmanaged(Status) = .empty,
cache_arena: std.heap.ArenaAllocator,
/// Probe output per executable path, kept across `rescan` (an upgrade
/// in place needs `forgetVersions`).
versions: std.StringHashMapUnmanaged([]const u8) = .empty,
versions_arena: std.heap.ArenaAllocator,

pub fn init(gpa: Allocator, opts: Options) Allocator.Error!Registry {
    var r: Registry = .{ .gpa = gpa, .arena = .init(gpa), .opts = opts, .defs = &.{}, .cache_arena = .init(gpa), .versions_arena = .init(gpa) };
    errdefer r.arena.deinit();
    const a = r.arena.allocator();
    r.opts.python = if (opts.python) |p| try a.dupe(u8, p) else null;
    r.opts.js_debug_path = if (opts.js_debug_path) |p| try a.dupe(u8, p) else null;
    r.opts.codelldb_command = if (opts.codelldb_command) |c| try dupeArgv(a, c) else null;
    r.opts.overrides = &.{};
    r.defs = try a.dupe(AdapterDef, &builtins.defs);
    for (r.defs) |*d| {
        if (std.mem.eql(u8, d.type, "codelldb")) if (r.opts.codelldb_command) |c| {
            d.command = c;
        };
        // The last override for a type wins; workspace ones only when
        // trusted.
        for (opts.overrides) |o| {
            if (o.from_workspace and !opts.trusted) continue;
            if (!std.mem.eql(u8, o.type, d.type)) continue;
            if (o.command.len == 0) continue;
            d.command = try dupeArgv(a, o.command);
            d.auto_discover = true;
            d.required_setting = null;
        }
    }
    return r;
}

pub fn deinit(r: *Registry) void {
    r.cache.deinit(r.gpa);
    r.cache_arena.deinit();
    r.versions.deinit(r.gpa);
    r.versions_arena.deinit();
    r.arena.deinit();
}

fn dupeArgv(a: Allocator, argv: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, argv.len);
    for (out, argv) |*o, s| o.* = try a.dupe(u8, s);
    return out;
}

/// The definition for a configuration's `type` (or alias).
pub fn get(r: *const Registry, type_name: []const u8) ?*const AdapterDef {
    for (r.defs) |*d| {
        if (std.mem.eql(u8, d.type, type_name)) return d;
        for (d.aliases) |al| if (std.mem.eql(u8, al, type_name)) return d;
    }
    return null;
}

/// Forgets every resolution (PATH or settings changed, "Rescan"); the
/// probed versions stay.
pub fn rescan(r: *Registry) void {
    r.cache.clearRetainingCapacity();
    _ = r.cache_arena.reset(.retain_capacity);
}

/// Forgets the probed versions too (an adapter was upgraded in place).
pub fn forgetVersions(r: *Registry) void {
    r.rescan();
    r.versions.clearRetainingCapacity();
    _ = r.versions_arena.reset(.retain_capacity);
}

/// `exe`'s version line, probed once per path.
fn versionOf(r: *Registry, io: Io, def: *const AdapterDef, exe: []const u8, env: *const std.process.Environ.Map) Allocator.Error![]const u8 {
    if (r.versions.get(exe)) |hit| return hit;
    const a = r.versions_arena.allocator();
    var probe: std.ArrayList([]const u8) = .empty;
    try probe.append(a, exe);
    try probe.appendSlice(a, def.version_args);
    const text = (try executables.probeFirstLine(io, a, probe.items, env, r.opts.probe_timeout)) orelse "";
    try r.versions.put(r.gpa, try a.dupe(u8, exe), text);
    return text;
}

/// Whether `def` can start, and how. Searches PATH and probes the
/// version on first use; cached. Worker only (file system, processes).
pub fn resolve(r: *Registry, io: Io, def: *const AdapterDef, env: *const std.process.Environ.Map) Allocator.Error!Status {
    if (r.cache.get(def.type)) |hit| return hit;
    const st = try r.resolveUncached(io, def, env);
    try r.cache.put(r.gpa, def.type, st);
    return st;
}

fn resolveUncached(r: *Registry, io: Io, def: *const AdapterDef, env: *const std.process.Environ.Map) Allocator.Error!Status {
    const a = r.cache_arena.allocator();
    if (def.required_setting) |key| {
        const set = if (std.mem.eql(u8, def.type, "js-debug")) r.opts.js_debug_path != null else def.command.len > 0;
        if (!set) return .{ .needs_setting = key };
    }
    if (def.command.len == 0) return .{ .needs_setting = def.required_setting orelse "a command" };
    // Placeholders other than {port}.
    var argv = try a.alloc([]const u8, def.command.len);
    for (def.command, 0..) |arg, i| {
        argv[i] = arg;
        if (std.mem.eql(u8, arg, "{python}")) {
            argv[i] = r.opts.python orelse "python";
        } else if (std.mem.indexOf(u8, arg, "{path}") != null) {
            argv[i] = try std.mem.replaceOwned(u8, a, arg, "{path}", r.opts.js_debug_path orelse "");
        }
    }
    var exe = try executables.find(io, a, r.opts.os, argv[0], env);
    // Windows' launcher stands in for a missing "python".
    if (exe == null and r.opts.os == .windows and r.opts.python == null and std.mem.eql(u8, argv[0], "python"))
        exe = try executables.find(io, a, r.opts.os, "py", env);
    argv[0] = exe orelse return .{ .missing = argv[0] };
    // A script the command needs (js-debug's server) must exist too.
    for (argv[1..]) |arg| if (std.mem.endsWith(u8, arg, ".js")) {
        Io.Dir.cwd().access(io, arg, .{}) catch return .{ .missing = arg };
    };
    var res: Resolved = .{ .def = def, .argv = argv };
    if (def.min_version) |min| {
        const text = try r.versionOf(io, def, argv[0], env);
        res.version_text = if (text.len > 0) text else null;
        if (executables.parseVersion(text)) |v| {
            res.version = v;
            if (v.order(min) == .lt) return .{ .too_old = .{ .found = v, .min = min, .text = text } };
        }
    }
    return .{ .ok = res };
}

/// `argv` with `{port}` replaced (TCP adapters). Allocated in `a`.
pub fn withPort(a: Allocator, argv: []const []const u8, port: u16) Allocator.Error![]const []const u8 {
    var buf: [8]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{d}", .{port}) catch unreachable;
    const out = try a.alloc([]const u8, argv.len);
    for (out, argv) |*o, s| o.* = if (std.mem.indexOf(u8, s, "{port}") != null) try std.mem.replaceOwned(u8, a, s, "{port}", p) else s;
    return out;
}

/// Runs the adapter's `normalize` hook on `args` (allocations in `a`).
pub fn normalizeArgs(def: *const AdapterDef, a: Allocator, request: @import("../config/LaunchConfig.zig").Request, args: *std.json.ObjectMap) !void {
    if (def.normalize) |f| try f(a, request, args);
}

/// The first of `preference` that resolves to `.ok`.
pub fn firstAvailable(r: *Registry, io: Io, env: *const std.process.Environ.Map, preference: []const []const u8) Allocator.Error!?*const AdapterDef {
    for (preference) |t| {
        const d = r.get(t) orelse continue;
        if (!d.auto_discover and d.required_setting != null and d.command.len == 0) continue;
        if ((try r.resolve(io, d, env)) == .ok) return d;
    }
    return null;
}
