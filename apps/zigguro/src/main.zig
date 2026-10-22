//! zigguro: the GUI application (composition root). It handles `--version`
//! (through zg_release, before the runtime starts), then opens the welcome
//! window through `zg_gui.Host` on the detected platform backend (Wayland,
//! then X11, on Linux; `ZG_PLATFORM` forces one).
//!
//! `zigguro FILE` opens FILE in the editor workbench instead (a missing
//! file starts empty and is created on save); `--terminal` opens the
//! workbench with its terminal panel showing (Ctrl+` toggles it), and
//! `--agent` with the agent pane open (Ctrl+L toggles it); `--review`
//! opens it with the review queue showing.
//!
//! `--frames N` exits after N presented frames. With `ZG_PLATFORM=headless`,
//! or when no display can be reached, it renders `--frames N` frames
//! (default 3) on the headless platform and exits, which smoke-tests the
//! whole UI stack without a display; `--screenshot FILE` then writes the
//! last frame as a binary PPM.
//!
//! The renderer is chosen by `zg_vulkan.createRenderer`; `ZG_RENDERER=
//! vulkan|software|auto` overrides it, and `--doctor-gpu [--json]` prints
//! the GPU report (`zg doctor gpu`) and exits.
//!
//! Text is drawn with system fonts through `zg_gui.FontText` (see
//! `fonts.zig`), or with placeholder boxes when no font file is found.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_release = @import("zg_release");
const zg_crash = @import("zg_crash");
const zg_update = @import("zg_update");
const zg_platform = @import("zg_platform");
const zg_gui = @import("zg_gui");
const zg_vulkan = @import("zg_vulkan");
const Welcome = @import("welcome.zig").Welcome;
const Workbench = @import("workbench.zig").Workbench;
const fonts = @import("fonts.zig");
const early_update = @import("startup/early_update_check.zig");

pub const std_options: std.Options = .{
    .logFn = zg_core.log.logFn,
    // Crash reports in every mode (std enables it only with runtime safety).
    // std's Windows handler is a vectored one that would run before
    // zg_crash's unhandled-exception filter.
    .enable_segfault_handler = builtin.os.tag != .windows,
    .signal_stack_size = 256 * 1024,
};
pub const panic = std.debug.FullPanic(zg_core.report.panicHandler);
pub const debug = struct {
    pub const handleSegfault = zg_crash.handleSegfault;
};

pub fn main(min: std.process.Init.Minimal) !u8 {
    // Before any runtime init: no allocator, no worker threads.
    if (zg_release.cli.handleVersionFlag(min, &zg_release.current, "zigguro")) return 0;
    installCrashHandler(min, "zigguro");

    var rt: zg_core.Runtime = undefined;
    try rt.init(min, .{});
    defer _ = rt.deinit();
    // Before GPU and window init: apply a staged update or roll back one
    // that cannot start (may re-execute the process).
    var boot = early_update.run(&rt, min);
    defer boot.deinit(rt.io);

    var buf: [256]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), rt.io, &buf);
    const w = &out.interface;

    var env = try min.environ.createMap(rt.gpa);
    defer env.deinit();
    // `ZG_RENDERER`, `ZG_GPU`, `ZG_VK_*` for every renderer.
    zg_vulkan.setProcessEnv(.fromMap(&env));
    if (hasFlag(min, rt.gpa, "--doctor-gpu")) {
        try zg_vulkan.writeGpuReport(rt.gpa, rt.io, w, if (hasFlag(min, rt.gpa, "--json")) .json else .text);
        try w.flush();
        return 0;
    }
    const backend = zg_platform.detectBackend(&env);

    var app = zg_gui.App.init(rt.gpa);
    defer app.deinit();
    app.attachRuntime(&rt);
    var mono: zg_gui.paint.text.MonoText = .{};
    const font_files = fonts.load(rt.gpa, rt.io, &env);
    defer if (font_files) |f| f.deinit(rt.gpa);
    const font_text: ?*zg_gui.paint.FontText = if (font_files) |f| zg_gui.paint.FontText.create(rt.gpa, .{ .ui = f.ui, .mono = f.mono }) catch null else null;
    defer if (font_text) |ft| ft.destroy();
    const text_sys = if (font_text) |ft| ft.system() else mono.system();
    var welcome: Welcome = .{ .version = zg_release.current.version_string };
    const file_arg = pathArg(min, rt.gpa);
    defer if (file_arg) |p| rt.gpa.free(p);
    const want_terminal = hasFlag(min, rt.gpa, "--terminal");
    const want_agent = hasFlag(min, rt.gpa, "--agent");
    const want_review = hasFlag(min, rt.gpa, "--review");
    const use_wb = file_arg != null or want_terminal or want_agent or want_review;
    var wb: Workbench = undefined;
    if (use_wb) try wb.init(&rt, &env, file_arg);
    defer if (use_wb) wb.deinit();
    const root: zg_gui.AnyView = if (use_wb) .of(&wb) else .of(&welcome);

    const frames_arg = framesArg(min, rt.gpa);
    if (backend != .headless) native: {
        const platform = zg_platform.init(rt.gpa, rt.io, .{ .environ_map = &env }) catch |err| {
            try w.print("zigguro {s}: no {t} display ({t}); falling back to the headless platform\n", .{ zg_release.current.version_string, backend, err });
            try w.flush();
            break :native;
        };
        defer platform.deinit();
        var host = zg_gui.Host.init(rt.gpa, rt.io, &app, platform, text_sys, .{ .fonts = font_text });
        defer host.deinit();
        const hw = try host.open(.{ .title = "zigguro", .size = .{ .w = 1280, .h = 800 }, .root = root });
        if (use_wb) try wb.attach(hw.win);
        if (use_wb) wb.enableFloating(host.windowOpener());
        if (want_terminal) try wb.toggleTerminal();
        if (want_agent) try wb.toggleAgent();
        if (want_review) try wb.toggleReview();
        defer if (use_wb) wb.detach();
        // `--frames N` exits after N presented frames (smoke tests,
        // screenshots); otherwise run until the window closes.
        const frames = frames_arg orelse {
            try runInteractive(&rt, &host, &boot);
            return 0;
        };
        var seen: u64 = 0;
        while (host.windows.items.len > 0 and hw.frames < frames) {
            _ = try host.pump();
            if (host.windows.items.len == 0 or hw.frames >= frames) break;
            if (hw.frames != seen) {
                seen = hw.frames;
                hw.win.themeChanged(false); // force a full repaint next frame
                continue;
            }
            platform.waitEvents(null);
        }
        const drawn = if (host.windows.items.len > 0) hw.frames else seen;
        try w.print("zigguro {s}: rendered {d} frame(s) on the {t} platform\n", .{ zg_release.current.version_string, drawn, backend });
        try w.flush();
        return 0;
    }

    const frames = frames_arg orelse 3;
    const hl = try zg_platform.headless.Headless.init(rt.gpa, rt.io, .{});
    defer hl.deinit();
    var host = zg_gui.Host.init(rt.gpa, rt.io, &app, hl.platform(), text_sys, .{ .fonts = font_text });
    defer host.deinit();
    const hw = try host.open(.{ .title = "zigguro", .size = .{ .w = 960, .h = 600 }, .root = root });
    if (use_wb) try wb.attach(hw.win);
    if (want_terminal) try wb.toggleTerminal();
    if (want_agent) try wb.toggleAgent();
    if (want_review) try wb.toggleReview();
    defer if (use_wb) wb.detach();
    var drawn: u64 = 0;
    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        _ = try host.pump();
        try hl.tick(hl.opts.refresh_ns);
        _ = try host.pump();
        drawn = hw.frames;
        hw.win.themeChanged(false); // force a full repaint next frame
    }
    _ = host.flush(5 * std.time.ns_per_s);
    try w.print("zigguro {s}: rendered {d} frame(s) on the headless platform\n", .{ zg_release.current.version_string, drawn });
    if (stringArg(min, rt.gpa, "--screenshot")) |path| {
        defer rt.gpa.free(path);
        if (hl.lastFrame(hw.id)) |f| {
            try writePpm(rt.gpa, rt.io, path, f);
            try w.print("zigguro: wrote {s} ({d}x{d})\n", .{ path, f.width, f.height });
        }
    }
    try w.flush();
    return 0;
}

/// Runs until the window closes. In a managed install the version counts
/// as healthy 30 s after the window opened, or at a clean quit.
fn runInteractive(rt: *zg_core.Runtime, host: *zg_gui.Host, boot: *early_update.Boot) !void {
    const h = if (boot.health) |*h| h else return host.run();
    h.markFirstFrame(0);
    var timer = rt.io.concurrent(healthTimer, .{ rt.io, h }) catch null;
    try host.run();
    if (timer) |*t| t.cancel(rt.io) catch {};
    h.onCleanQuit();
}

fn healthTimer(io: std.Io, h: *zg_update.boot_health.BootHealth) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(zg_update.boot_health.healthy_after_ms), .awake);
    h.markHealthy();
}

/// The value after flag `name`, if given (owned).
fn stringArg(min: std.process.Init.Minimal, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    var it = min.args.iterateAllocator(gpa) catch return null;
    defer it.deinit();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, name)) return gpa.dupe(u8, it.next() orelse return null) catch null;
    }
    return null;
}

/// Whether flag `name` was given.
fn hasFlag(min: std.process.Init.Minimal, gpa: std.mem.Allocator, name: []const u8) bool {
    var it = min.args.iterateAllocator(gpa) catch return false;
    defer it.deinit();
    while (it.next()) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

/// The first argument that is not an option or an option's value.
fn pathArg(min: std.process.Init.Minimal, gpa: std.mem.Allocator) ?[]u8 {
    var it = min.args.iterateAllocator(gpa) catch return null;
    defer it.deinit();
    _ = it.next(); // the program
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--frames") or std.mem.eql(u8, a, "--screenshot")) {
            _ = it.next();
            continue;
        }
        if (std.mem.startsWith(u8, a, "-")) continue;
        return gpa.dupe(u8, a) catch null;
    }
    return null;
}

/// Writes an RGBA frame as a binary PPM (P6).
fn writePpm(gpa: std.mem.Allocator, io: std.Io, path: []const u8, f: anytype) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.print(gpa, "P6\n{d} {d}\n255\n", .{ f.width, f.height });
    for (0..f.height) |y| for (0..f.width) |x| {
        const o = y * f.stride + x * 4;
        try out.appendSlice(gpa, f.pixels[o..][0..3]);
    };
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// The value of `--frames N`, if given.
fn framesArg(min: std.process.Init.Minimal, gpa: std.mem.Allocator) ?u32 {
    var it = min.args.iterateAllocator(gpa) catch return null;
    defer it.deinit();
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--frames")) {
            const v = it.next() orelse return null;
            return std.fmt.parseInt(u32, v, 10) catch null;
        }
    }
    return null;
}

/// Crash reports go to `<state>/crashes` (E17.F05); `install` copies the
/// paths. A failure here only means no reports.
fn installCrashHandler(min: std.process.Init.Minimal, product: []const u8) void {
    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    var crash_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = zg_crash.paths.stateDir(min.environ, &state_buf) orelse return;
    const crashes = zg_crash.paths.crashDir(state, &crash_buf) orelse return;
    zg_crash.install(.{ .crash_dir = crashes, .state_dir = state, .product = product }) catch {};
}
