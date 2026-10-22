//! Finds the UI and code fonts for `zg_gui.FontText`. `ZG_FONT_UI` and
//! `ZG_FONT_MONO` name font files directly; otherwise well-known system
//! paths are tried (Linux distributions, then Windows). Until E03's font
//! registry (E03.F07) lands there is no fontconfig-style discovery. When
//! only one font is found it serves both slots; when none is, the app
//! falls back to the built-in monospace boxes.

const std = @import("std");
const builtin = @import("builtin");

const ui_paths = if (builtin.os.tag == .windows) [_][]const u8{
    "C:\\Windows\\Fonts\\segoeui.ttf",
    "C:\\Windows\\Fonts\\arial.ttf",
} else [_][]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
    "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/LiberationSans-Regular.ttf",
};

const mono_paths = if (builtin.os.tag == .windows) [_][]const u8{
    "C:\\Windows\\Fonts\\consola.ttf",
    "C:\\Windows\\Fonts\\cour.ttf",
} else [_][]const u8{
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/google-noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/liberation-mono/LiberationMono-Regular.ttf",
    "/usr/share/fonts/TTF/LiberationMono-Regular.ttf",
};

/// Font file contents, owned.
pub const Loaded = struct {
    ui: []u8,
    mono: []u8,

    /// Frees both (once when they are the same bytes).
    pub fn deinit(l: Loaded, gpa: std.mem.Allocator) void {
        gpa.free(l.ui);
        if (l.mono.ptr != l.ui.ptr) gpa.free(l.mono);
    }
};

fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch null;
}

fn first(gpa: std.mem.Allocator, io: std.Io, override: ?[]const u8, paths: []const []const u8) ?[]u8 {
    if (override) |p| if (read(gpa, io, p)) |b| return b;
    for (paths) |p| if (read(gpa, io, p)) |b| return b;
    return null;
}

/// The UI and mono fonts, or null when no font file is found.
pub fn load(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?Loaded {
    const ui = first(gpa, io, env.get("ZG_FONT_UI"), &ui_paths);
    const mono = first(gpa, io, env.get("ZG_FONT_MONO"), &mono_paths);
    if (ui) |u| return .{ .ui = u, .mono = mono orelse u };
    if (mono) |m| return .{ .ui = m, .mono = m };
    return null;
}
