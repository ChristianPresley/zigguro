//! ZLS support around the manager (E07.F01.S03.T02): answers the `zls`
//! configuration section (initialization options and
//! `workspace/configuration`) from the settings, and while doing so on the
//! start-up worker finds the Zig toolchain, the ZLS version, the user's
//! `zls.json` and whether the build has a `check` step. The UI asks it for
//! a pairing warning once per session, for the server details lines and
//! whether to offer adding a `check` step.

const ZlsSupport = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Manager = @import("../Manager.zig");
const zls = @import("../registry/zls.zig");

const Server = Manager.Server;
const log = std.log.scoped(.zls);

gpa: Allocator,
io: Io,
env: ?*const std.process.Environ.Map,
mutex: Io.Mutex = .init,
/// The settings (in `settings_arena`).
settings: zls.Settings = .{},
settings_arena: std.heap.ArenaAllocator,
/// What the probes found (in `probe_arena`).
probe_arena: std.heap.ArenaAllocator,
zig: ?zls.ZigToolchain = null,
/// The `zig_path` `zig` was probed for ("" for PATH); null: not yet.
zig_probed: ?[]const u8 = null,
zls_version: ?std.SemanticVersion = null,
zls_config_file: ?[]const u8 = null,
zls_probed: bool = false,
roots: std.ArrayList(Root) = .empty,
/// The pairing warning was given.
warned: bool = false,

const Root = struct {
    path: []const u8,
    stamp: [2]?Io.Timestamp,
    has_check: ?bool,
};

pub fn init(gpa: Allocator, io: Io, env: ?*const std.process.Environ.Map) ZlsSupport {
    return .{ .gpa = gpa, .io = io, .env = env, .settings_arena = .init(gpa), .probe_arena = .init(gpa) };
}

pub fn deinit(z: *ZlsSupport) void {
    z.roots.deinit(z.gpa);
    z.settings_arena.deinit();
    z.probe_arena.deinit();
}

/// The hook for `Manager.config_provider`.
pub fn provider(z: *ZlsSupport) Manager.ConfigProvider {
    return .{ .ctx = z, .get = get };
}

/// Takes new settings (copied). True when they differ from the last ones,
/// so the servers should pull them again (`Manager.settingsChanged`).
pub fn setSettings(z: *ZlsSupport, s: zls.Settings) !bool {
    var next: std.heap.ArenaAllocator = .init(z.gpa);
    errdefer next.deinit();
    const a = next.allocator();
    const opts = try a.alloc(zls.Option, s.zls.len);
    for (s.zls, opts) |o, *out| out.* = .{ .name = try a.dupe(u8, o.name), .value = try cloneValue(a, o.value) };
    const copy: zls.Settings = .{ .zig_path = if (s.zig_path) |p| try a.dupe(u8, p) else null, .zls = opts };

    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    const changed = !try settingsEql(z.gpa, z.settings, copy);
    if (!changed) {
        next.deinit();
        return false;
    }
    z.settings_arena.deinit();
    z.settings_arena = next;
    z.settings = copy;
    return true;
}

fn get(ctx: *anyopaque, s: *Server, arena: Allocator) std.json.Value {
    const z: *ZlsSupport = @ptrCast(@alignCast(ctx));
    if (!isZls(s)) return .null;
    z.probe(s);
    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    const tc: ?*const zls.ZigToolchain = if (z.zig) |*t| t else null;
    // The settings arena goes away on the next `setSettings`: copy.
    const v = zls.configSection(arena, &z.settings, tc) catch return .null;
    return cloneValue(arena, v) catch .null;
}

pub fn isZls(s: *const Server) bool {
    const sec = s.def.settings_section orelse return false;
    return std.mem.eql(u8, sec, "zls");
}

/// Runs the probes `s` still needs. Worker.
fn probe(z: *ZlsSupport, s: *Server) void {
    var tmp: std.heap.ArenaAllocator = .init(z.gpa);
    defer tmp.deinit();
    const t = tmp.allocator();
    // The `zig.path` to probe for, or null when probed already.
    const want_zig: ?[]const u8 = blk: {
        z.mutex.lockUncancelable(z.io);
        defer z.mutex.unlock(z.io);
        const p = z.settings.zig_path orelse "";
        if (z.zig_probed) |done| if (std.mem.eql(u8, done, p)) break :blk null;
        break :blk t.dupe(u8, p) catch return;
    };
    var zig: ?zls.ZigToolchain = null;
    if (want_zig) |p| {
        zig = zls.detectZig(t, z.io, if (p.len > 0) p else "zig", z.env);
        if (zig == null) log.info("no Zig toolchain found ({s})", .{if (p.len > 0) p else "PATH"});
    }
    var zls_version: ?std.SemanticVersion = null;
    var config_file: ?[]const u8 = null;
    const probe_zls = !z.zlsProbed() and s.exe.len > 0;
    if (probe_zls) {
        if (zls.probeZlsVersion(t, z.io, s.exe, z.env)) |ver| zls_version = ver;
        config_file = zls.zlsConfigFile(t, z.io, s.exe, z.env);
    }
    const zig_exe = if (zig) |x| x.exe_path else if (z.cachedZigExe(t)) |e| e else null;
    var has_check: ?bool = null;
    var stamp: [2]?Io.Timestamp = .{ null, null };
    const root_due = s.root.len > 0 and zig_exe != null and z.rootStale(s.root, &stamp);
    if (root_due) if (zls.listBuildSteps(t, z.io, zig_exe.?, s.root, z.env)) |steps| {
        has_check = zls.hasStep(steps, "check");
    };

    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    const a = z.probe_arena.allocator();
    if (want_zig) |p| {
        z.zig_probed = a.dupe(u8, p) catch return;
        z.zig = if (zig) |x| dupeToolchain(a, x) catch null else null;
    }
    if (probe_zls) {
        z.zls_probed = true;
        if (zls_version) |ver| z.zls_version = dupeVersion(a, ver) catch null;
        if (config_file) |f| z.zls_config_file = a.dupe(u8, f) catch null;
    }
    if (root_due and has_check != null) z.setRoot(s.root, stamp, has_check) catch {};
}

fn zlsProbed(z: *ZlsSupport) bool {
    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    return z.zls_probed;
}

fn cachedZigExe(z: *ZlsSupport, a: Allocator) ?[]const u8 {
    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    const tc = z.zig orelse return null;
    return a.dupe(u8, tc.exe_path) catch null;
}

/// Whether `root`'s steps must be listed again (`build.zig` or
/// `build.zig.zon` changed); `stamp` gets the current times.
fn rootStale(z: *ZlsSupport, root: []const u8, stamp: *[2]?Io.Timestamp) bool {
    var dir = Io.Dir.cwd().openDir(z.io, root, .{}) catch return false;
    defer dir.close(z.io);
    for ([_][]const u8{ "build.zig", "build.zig.zon" }, 0..) |f, i| {
        stamp[i] = if (dir.statFile(z.io, f, .{})) |st| st.mtime else |_| null;
    }
    if (stamp[0] == null) return false;
    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    for (z.roots.items) |r| if (std.mem.eql(u8, r.path, root)) return !std.meta.eql(r.stamp, stamp.*);
    return true;
}

fn setRoot(z: *ZlsSupport, root: []const u8, stamp: [2]?Io.Timestamp, has_check: ?bool) !void {
    for (z.roots.items) |*r| if (std.mem.eql(u8, r.path, root)) {
        r.stamp = stamp;
        r.has_check = has_check;
        return;
    };
    try z.roots.append(z.gpa, .{ .path = try z.probe_arena.allocator().dupe(u8, root), .stamp = stamp, .has_check = has_check });
}

fn hasCheck(z: *ZlsSupport, root: []const u8) ?bool {
    for (z.roots.items) |r| if (std.mem.eql(u8, r.path, root)) return r.has_check;
    return null;
}

/// Whether `s`'s build is known to lack a `check` step.
pub fn needsCheckStep(z: *ZlsSupport, s: *const Server) bool {
    if (!isZls(s)) return false;
    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    return z.hasCheck(s.root) == false;
}

/// Forgets `root`'s steps (its build changed by our hand).
pub fn forgetRoot(z: *ZlsSupport, root: []const u8) void {
    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    for (z.roots.items, 0..) |r, i| if (std.mem.eql(u8, r.path, root)) {
        _ = z.roots.swapRemove(i);
        return;
    };
}

/// The once-per-session pairing warning for running server `s`, if its
/// ZLS does not match the Zig toolchain. UI thread.
pub fn takePairingWarning(z: *ZlsSupport, s: *const Server, buf: []u8) ?[]const u8 {
    if (z.warned or !isZls(s) or s.status != .running) return null;
    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    const tc = z.zig orelse return null;
    const ver: std.SemanticVersion = blk: {
        if (s.client) |c| if (c.serverInfo()) |si| if (si.version) |text| {
            if (zls.parseVersion(text)) |x| break :blk x else |_| {}
        };
        break :blk z.zls_version orelse return null;
    };
    const msg = zls.pairingWarning(buf, tc.version, ver) orelse return null;
    z.warned = true;
    return msg;
}

/// Extra lines of `s`'s details report: the toolchain, `zls.json`,
/// build-on-save.
pub fn writeDetails(z: *ZlsSupport, s: *const Server, w: *Io.Writer) Io.Writer.Error!void {
    if (!isZls(s)) return;
    z.mutex.lockUncancelable(z.io);
    defer z.mutex.unlock(z.io);
    if (z.zig) |tc| {
        try w.print("Zig: {f} ({s})\n", .{ tc.version, tc.exe_path });
    } else if (z.zig_probed != null) try w.writeAll("Zig: not found (set zig.path)\n");
    if (z.zls_config_file) |f| try w.print("ZLS config file: {s} (its settings may override the editor's)\n", .{f});
    const user_set = for (z.settings.zls) |o| {
        if (std.mem.eql(u8, o.name, "enable_build_on_save")) break o.value == .bool and o.value.bool;
    } else null;
    if (user_set) |on| {
        try w.print("Build-on-save: {s} (zig.zls.enable_build_on_save)\n", .{if (on) "on" else "off"});
    } else if (z.hasCheck(s.root)) |has| {
        try w.writeAll(if (has) "Build-on-save: on (check step)\n" else "Build-on-save: off (no check step; Add a check step from the server menu)\n");
    }
}

fn dupeToolchain(a: Allocator, t: zls.ZigToolchain) !zls.ZigToolchain {
    return .{ .exe_path = try a.dupe(u8, t.exe_path), .version = try dupeVersion(a, t.version), .lib_dir = if (t.lib_dir) |d| try a.dupe(u8, d) else null };
}

fn dupeVersion(a: Allocator, v: std.SemanticVersion) !std.SemanticVersion {
    var out = v;
    if (v.pre) |p| out.pre = try a.dupe(u8, p);
    if (v.build) |b| out.build = try a.dupe(u8, b);
    return out;
}

fn settingsEql(gpa: Allocator, a: zls.Settings, b: zls.Settings) !bool {
    const ja = try std.json.Stringify.valueAlloc(gpa, a, .{});
    defer gpa.free(ja);
    const jb = try std.json.Stringify.valueAlloc(gpa, b, .{});
    defer gpa.free(jb);
    return std.mem.eql(u8, ja, jb);
}

pub fn cloneValue(a: Allocator, v: std.json.Value) Allocator.Error!std.json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = try std.json.Array.initCapacity(a, arr.items.len);
            for (arr.items) |x| out.appendAssumeCapacity(try cloneValue(a, x));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: std.json.ObjectMap = .empty;
            var it = obj.iterator();
            while (it.next()) |e| try out.put(a, try a.dupe(u8, e.key_ptr.*), try cloneValue(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
    };
}
