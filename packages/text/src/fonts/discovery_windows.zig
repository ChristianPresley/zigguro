//! Windows font discovery without DirectWrite or COM: the font files
//! registered under `Software\Microsoft\Windows NT\CurrentVersion\Fonts`
//! in HKLM and HKCU (read through win_registry.zig), the system font
//! directory `%WINDIR%\Fonts` and the per-user one
//! `%LOCALAPPDATA%\Microsoft\Windows\Fonts` (Windows 10 1803+). Files
//! present in those directories but not registered are found too; the
//! registry adds the files registered elsewhere.
//!
//! Registry value names (`"Segoe UI (TrueType)"`) are hints only: the
//! family a file holds comes from its `name` table when the database
//! scans it. The generic-family aliases come from `windowsDefaults`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const discovery = @import("discovery.zig");
const fallback = @import("fallback.zig");
const reg = @import("win_registry.zig");

pub const Discovery = discovery.Discovery;
pub const OsDefaults = fallback.OsDefaults;
pub const NameValue = reg.NameValue;

pub const fonts_subkey = "Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts";

/// Windows' default families (overridable in settings, E15).
pub const windows_defaults: OsDefaults = .{
    .ui = &.{ "Segoe UI Variable Text", "Segoe UI" },
    .mono = &.{ "Cascadia Mono", "Cascadia Code", "Consolas" },
    .serif = &.{ "Cambria", "Times New Roman" },
    .emoji = &.{"Segoe UI Emoji"},
    .per_script = &.{
        .{ .script = .Hani, .han = .sc, .families = &.{ "Microsoft YaHei UI", "Microsoft YaHei", "SimSun" } },
        .{ .script = .Hani, .han = .tc, .families = &.{ "Microsoft JhengHei UI", "Microsoft JhengHei", "MingLiU" } },
        .{ .script = .Hani, .han = .ja, .families = &.{ "Yu Gothic UI", "Meiryo", "MS Gothic" } },
        .{ .script = .Hani, .han = .ko, .families = &.{ "Malgun Gothic", "Gulim" } },
        .{ .script = .Arab, .families = &.{"Segoe UI"} },
        .{ .script = .Hebr, .families = &.{"Segoe UI"} },
        .{ .script = .Armn, .families = &.{"Segoe UI"} },
        .{ .script = .Geor, .families = &.{"Segoe UI"} },
        .{ .script = .Deva, .families = &.{"Nirmala UI"} },
        .{ .script = .Beng, .families = &.{"Nirmala UI"} },
        .{ .script = .Guru, .families = &.{"Nirmala UI"} },
        .{ .script = .Gujr, .families = &.{"Nirmala UI"} },
        .{ .script = .Orya, .families = &.{"Nirmala UI"} },
        .{ .script = .Taml, .families = &.{"Nirmala UI"} },
        .{ .script = .Telu, .families = &.{"Nirmala UI"} },
        .{ .script = .Knda, .families = &.{"Nirmala UI"} },
        .{ .script = .Mlym, .families = &.{"Nirmala UI"} },
        .{ .script = .Sinh, .families = &.{"Nirmala UI"} },
        .{ .script = .Olck, .families = &.{"Nirmala UI"} },
        .{ .script = .Thai, .families = &.{"Leelawadee UI"} },
        .{ .script = .Laoo, .families = &.{"Leelawadee UI"} },
        .{ .script = .Khmr, .families = &.{"Leelawadee UI"} },
        .{ .script = .Mymr, .families = &.{"Myanmar Text"} },
        .{ .script = .Tibt, .families = &.{"Microsoft Himalaya"} },
        .{ .script = .Mong, .families = &.{"Mongolian Baiti"} },
        .{ .script = .Ethi, .families = &.{"Ebrima"} },
        .{ .script = .Nkoo, .families = &.{"Ebrima"} },
        .{ .script = .Tfng, .families = &.{"Ebrima"} },
        .{ .script = .Vaii, .families = &.{"Ebrima"} },
        .{ .script = .Cher, .families = &.{"Gadugi"} },
        .{ .script = .Zyyy, .families = &.{ "Segoe UI Symbol", "Segoe UI" } },
        .{ .script = .Copt, .families = &.{"Segoe UI Historic"} },
        .{ .script = .Egyp, .families = &.{"Segoe UI Historic"} },
        .{ .script = .Goth, .families = &.{"Segoe UI Historic"} },
        .{ .script = .Ital, .families = &.{"Segoe UI Historic"} },
        .{ .script = .Linb, .families = &.{"Segoe UI Historic"} },
        .{ .script = .Ogam, .families = &.{"Segoe UI Historic"} },
        .{ .script = .Phnx, .families = &.{"Segoe UI Historic"} },
        .{ .script = .Runr, .families = &.{"Segoe UI Historic"} },
        .{ .script = .Xsux, .families = &.{"Segoe UI Historic"} },
    },
};

pub fn windowsDefaults() OsDefaults {
    return windows_defaults;
}

/// Reads the registry and directories of this machine (on another OS
/// the registry read fails with error.Unsupported).
pub fn discoverWindows(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !Discovery {
    var values: std.ArrayList(NameValue) = .empty;
    defer reg.freeValues(gpa, &values);
    try reg.enumStringValues(gpa, .hklm, fonts_subkey, &values);
    try reg.enumStringValues(gpa, .hkcu, fonts_subkey, &values);
    return assemble(gpa, io, env, values.items, windows_defaults);
}

/// Builds the discovery from registry values (HKLM first): the font
/// directories that exist, the registered font files outside them (not
/// checked here: `listFiles` stats them anyway and skips missing ones),
/// and aliases from `defaults`. Platform-independent, so the
/// path logic is tested everywhere.
pub fn assemble(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, values: []const NameValue, defaults: OsDefaults) !Discovery {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const fonts_dir = try systemFontsDir(arena, env);
    var candidates: std.ArrayList([]const u8) = .empty;
    try candidates.append(arena, fonts_dir);
    if (nonEmpty(env.get("LOCALAPPDATA"))) |l|
        try candidates.append(arena, try std.fs.path.join(arena, &.{ l, "Microsoft", "Windows", "Fonts" }));
    var dirs: std.ArrayList([]const u8) = .empty;
    for (candidates.items) |d| {
        if (!isDir(io, d)) continue;
        for (dirs.items) |o| {
            if (pathEql(o, d)) break;
        } else try dirs.append(arena, d);
    }

    var files: std.ArrayList([]const u8) = .empty;
    for (values) |v| {
        const data = if (v.kind == .expand_sz) try expandEnv(arena, v.value, env) else v.value;
        const p = try resolveFontPath(arena, data, fonts_dir);
        if (!discovery.isFontFile(p)) continue;
        const parent = std.fs.path.dirname(p) orelse continue;
        const listed = for (dirs.items) |d| {
            if (pathEql(d, parent)) break true;
        } else false;
        if (listed) continue;
        const dup = for (files.items) |o| {
            if (pathEql(o, p)) break true;
        } else false;
        if (dup) continue;
        // `p` may still point into `values`, which the caller frees.
        try files.append(arena, try arena.dupe(u8, p));
    }

    return .{
        .dirs = dirs.items,
        .files = files.items,
        .aliases = try defaultAliases(arena, defaults),
        .arena = arena_state.state,
    };
}

/// `%SystemRoot%\Fonts` (else `%WINDIR%`, else `C:\Windows`).
pub fn systemFontsDir(arena: Allocator, env: *const std.process.Environ.Map) Allocator.Error![]const u8 {
    const root = nonEmpty(env.get("SystemRoot")) orelse nonEmpty(env.get("WINDIR")) orelse "C:\\Windows";
    return std.fs.path.join(arena, &.{ root, "Fonts" });
}

/// Registry data: an absolute path as is, a file name against the
/// system font directory.
pub fn resolveFontPath(arena: Allocator, data: []const u8, fonts_dir: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(data)) return data;
    return std.fs.path.join(arena, &.{ fonts_dir, data });
}

/// Expands `%NAME%` references from `env` as ExpandEnvironmentStrings
/// does: unknown names and a lone `%` stay as written.
pub fn expandEnv(arena: Allocator, s: []const u8, env: *const std.process.Environ.Map) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '%')) |end| {
                const name = s[i + 1 .. end];
                if (name.len > 0) if (env.get(name)) |v| {
                    try out.appendSlice(arena, v);
                    i = end + 1;
                    continue;
                };
                // Not a variable: keep the `%` and rescan from the
                // closing one, which may open the next reference.
                try out.appendSlice(arena, s[i..end]);
                i = end;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}

/// The family hint of a registry value name: `"Segoe UI (TrueType)"` →
/// `"Segoe UI"` (also ` (OpenType)`, any case).
pub fn stripSuffix(name: []const u8) []const u8 {
    for ([_][]const u8{ " (TrueType)", " (OpenType)" }) |suffix| {
        if (name.len >= suffix.len and std.ascii.eqlIgnoreCase(name[name.len - suffix.len ..], suffix))
            return name[0 .. name.len - suffix.len];
    }
    return name;
}

/// Aliases for the CSS generic families from an OS default table:
/// `system-ui` and `sans-serif` prefer the UI families.
pub fn defaultAliases(arena: Allocator, d: OsDefaults) Allocator.Error![]const discovery.Alias {
    return arena.dupe(discovery.Alias, &.{
        .{ .family = "sans-serif", .prefer = d.ui },
        .{ .family = "system-ui", .prefer = d.ui },
        .{ .family = "monospace", .prefer = d.mono },
        .{ .family = "serif", .prefer = d.serif },
        .{ .family = "emoji", .prefer = d.emoji },
    });
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

fn isDir(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

/// Path equality as the OS compares: case-insensitive on Windows.
fn pathEql(a: []const u8, b: []const u8) bool {
    const x = std.mem.trimEnd(u8, a, "\\/");
    const y = std.mem.trimEnd(u8, b, "\\/");
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(x, y);
    return std.mem.eql(u8, x, y);
}
