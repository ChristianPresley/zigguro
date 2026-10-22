//! macOS font discovery without CoreText: a scan of the standard font
//! directories, in priority order: `~/Library/Fonts` (from `HOME`),
//! `/Library/Fonts`, `/System/Library/Fonts`,
//! `/System/Library/Fonts/Supplemental` and `/Network/Library/Fonts`.
//! Only the directories that exist are kept. Fonts installed through
//! asset catalogs (downloadable system fonts) are not found.
//!
//! `.dfont` (resource-fork) suitcases are not read: `listFontFiles`
//! skips them with a debug log line. The generic-family aliases come
//! from `macosDefaults`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const discovery = @import("discovery.zig");
const fallback = @import("fallback.zig");
const windows = @import("discovery_windows.zig");

pub const Discovery = discovery.Discovery;
pub const OsDefaults = fallback.OsDefaults;

/// The system font directories, best first, after the user's.
pub const system_dirs = [_][]const u8{
    "/Library/Fonts",
    "/System/Library/Fonts",
    "/System/Library/Fonts/Supplemental",
    "/Network/Library/Fonts",
};

/// macOS' default families (overridable in settings, E15). SF Pro, SF
/// Mono and New York are the system fonts' family names when installed
/// as files; the second names are always present.
pub const macos_defaults: OsDefaults = .{
    .ui = &.{ "SF Pro", "SF Pro Text", "Helvetica Neue" },
    .mono = &.{ "SF Mono", "Menlo" },
    .serif = &.{ "New York", "Times" },
    .emoji = &.{"Apple Color Emoji"},
    .per_script = &.{
        .{ .script = .Hani, .han = .sc, .families = &.{ "PingFang SC", "Heiti SC" } },
        .{ .script = .Hani, .han = .tc, .families = &.{ "PingFang TC", "Heiti TC" } },
        .{ .script = .Hani, .han = .ja, .families = &.{ "Hiragino Sans", "Hiragino Kaku Gothic ProN" } },
        .{ .script = .Hani, .han = .ko, .families = &.{"Apple SD Gothic Neo"} },
        .{ .script = .Hang, .families = &.{"Apple SD Gothic Neo"} },
        .{ .script = .Arab, .families = &.{"Geeza Pro"} },
        .{ .script = .Hebr, .families = &.{ "Arial Hebrew", "Lucida Grande" } },
        .{ .script = .Deva, .families = &.{ "Kohinoor Devanagari", "Devanagari Sangam MN" } },
        .{ .script = .Beng, .families = &.{ "Kohinoor Bangla", "Bangla Sangam MN" } },
        .{ .script = .Guru, .families = &.{ "Gurmukhi MN", "Gurmukhi Sangam MN" } },
        .{ .script = .Gujr, .families = &.{ "Kohinoor Gujarati", "Gujarati Sangam MN" } },
        .{ .script = .Orya, .families = &.{"Oriya Sangam MN"} },
        .{ .script = .Taml, .families = &.{ "Tamil Sangam MN", "Tamil MN" } },
        .{ .script = .Telu, .families = &.{ "Kohinoor Telugu", "Telugu Sangam MN" } },
        .{ .script = .Knda, .families = &.{ "Kannada Sangam MN", "Kannada MN" } },
        .{ .script = .Mlym, .families = &.{ "Malayalam Sangam MN", "Malayalam MN" } },
        .{ .script = .Sinh, .families = &.{ "Sinhala Sangam MN", "Sinhala MN" } },
        .{ .script = .Thai, .families = &.{ "Thonburi", "Ayuthaya" } },
        .{ .script = .Laoo, .families = &.{ "Lao Sangam MN", "Lao MN" } },
        .{ .script = .Khmr, .families = &.{ "Khmer Sangam MN", "Khmer MN" } },
        .{ .script = .Mymr, .families = &.{ "Myanmar Sangam MN", "Myanmar MN" } },
        .{ .script = .Tibt, .families = &.{"Kailasa"} },
        .{ .script = .Ethi, .families = &.{"Kefa"} },
        .{ .script = .Armn, .families = &.{ "Mshtakan", "Helvetica Neue" } },
        .{ .script = .Geor, .families = &.{ "Helvetica Neue", "Lucida Grande" } },
        .{ .script = .Cher, .families = &.{"Plantagenet Cherokee"} },
        .{ .script = .Zyyy, .families = &.{ "Apple Symbols", "Menlo" } },
    },
};

pub fn macosDefaults() OsDefaults {
    return macos_defaults;
}

/// The font directories of this machine.
pub fn discoverMacos(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !Discovery {
    return assemble(gpa, io, env, "", macos_defaults);
}

/// Builds the discovery: the user's directory (when `HOME` is set) and
/// `system_dirs` under `root` (empty for the real file system), keeping
/// those that exist, and aliases from `defaults`. Platform-independent,
/// so it is tested everywhere over a fixture tree.
pub fn assemble(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, root: []const u8, defaults: OsDefaults) !Discovery {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var candidates: std.ArrayList([]const u8) = .empty;
    if (env.get("HOME")) |home| if (home.len > 0)
        try candidates.append(arena, try std.fs.path.join(arena, &.{ home, "Library", "Fonts" }));
    for (system_dirs) |d| try candidates.append(arena, try std.mem.concat(arena, u8, &.{ root, d }));

    var dirs: std.ArrayList([]const u8) = .empty;
    for (candidates.items) |d| {
        if (!isDir(io, d)) continue;
        for (dirs.items) |o| {
            if (std.mem.eql(u8, std.mem.trimEnd(u8, o, "/"), std.mem.trimEnd(u8, d, "/"))) break;
        } else try dirs.append(arena, d);
    }

    return .{
        .dirs = dirs.items,
        .aliases = try windows.defaultAliases(arena, defaults),
        .arena = arena_state.state,
    };
}

fn isDir(io: Io, p: []const u8) bool {
    const st = Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}
