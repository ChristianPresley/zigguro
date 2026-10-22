//! zigguro: the GUI application (composition root). It handles `--version`
//! (through zg_release, before the runtime starts), then opens the welcome
//! window through `zg_gui.Host` on the detected platform backend (Wayland,
//! then X11, on Linux; `ZG_PLATFORM` forces one).
//!
//! `--frames N` exits after N presented frames. With `ZG_PLATFORM=headless`,
//! or when no display can be reached, it renders `--frames N` frames
//! (default 3) on the headless platform and exits, which smoke-tests the
//! whole UI stack without a display.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_release = @import("zg_release");
const zg_crash = @import("zg_crash");
const zg_platform = @import("zg_platform");
const zg_gui = @import("zg_gui");
const Welcome = @import("welcome.zig").Welcome;

pub const std_options: std.Options = .{
    .logFn = zg_core.log.logFn,
    // Crash reports in every mode (std enables it only with runtime safety).
    .enable_segfault_handler = true,
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

    var buf: [256]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), rt.io, &buf);
    const w = &out.interface;

    var env = try min.environ.createMap(rt.gpa);
    defer env.deinit();
    const backend = zg_platform.detectBackend(&env);

    var app = zg_gui.App.init(rt.gpa);
    defer app.deinit();
    var mono: zg_gui.paint.text.MonoText = .{};
    var welcome: Welcome = .{ .version = zg_release.current.version_string };

    const frames_arg = framesArg(min, rt.gpa);
    if (backend != .headless) native: {
        const platform = zg_platform.init(rt.gpa, rt.io, .{ .environ_map = &env }) catch |err| {
            try w.print("zigguro {s}: no {t} display ({t}); falling back to the headless platform\n", .{ zg_release.current.version_string, backend, err });
            try w.flush();
            break :native;
        };
        defer platform.deinit();
        var host = zg_gui.Host.init(rt.gpa, rt.io, &app, platform, mono.system(), .{});
        defer host.deinit();
        const hw = try host.open(.{ .title = "zigguro", .size = .{ .w = 1280, .h = 800 }, .root = .of(&welcome) });
        // `--frames N` exits after N presented frames (smoke tests,
        // screenshots); otherwise run until the window closes.
        const frames = frames_arg orelse {
            try host.run();
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
    var host = zg_gui.Host.init(rt.gpa, rt.io, &app, hl.platform(), mono.system(), .{});
    defer host.deinit();
    const hw = try host.open(.{ .title = "zigguro", .size = .{ .w = 960, .h = 600 }, .root = .of(&welcome) });
    var drawn: u64 = 0;
    var i: u32 = 0;
    while (i < frames) : (i += 1) {
        _ = try host.pump();
        try hl.tick(hl.opts.refresh_ns);
        _ = try host.pump();
        drawn = hw.frames;
        hw.win.themeChanged(false); // force a full repaint next frame
    }
    try w.print("zigguro {s}: rendered {d} frame(s) on the headless platform\n", .{ zg_release.current.version_string, drawn });
    try w.flush();
    return 0;
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
