//! zigguro: the GUI application (composition root). It handles `--version`
//! (through zg_release, before the runtime starts), then opens the welcome
//! window through `zg_gui.Host` on the detected platform backend (Wayland,
//! then X11, on Linux; `ZG_PLATFORM` forces one).
//!
//! `zigguro FILE` opens FILE in the editor workbench instead (a missing
//! file starts empty and is created on save); `zigguro FOLDER` opens the
//! workbench on FOLDER with the Explorer. With no path an interactive run
//! opens the last folder (or the working folder); `--welcome` shows the
//! welcome window; `--terminal` opens the
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
//! `--trace=<path>` (with `--trace-format=perfetto|chrome`) records a
//! performance trace until exit; `ZG_TRACE=startup` records startup to the
//! first frame + 2 s (see `tracing.zig`). `--hud` opens the performance
//! HUD (Ctrl+Alt+Shift+H, `perf.hud.toggle`). `--mem-report[=now]` and
//! `--mem-report-exit` print the memory report (`perf.memory.report`).
//! `--startup-report` prints the startup phases once the first frame is
//! interactive (`startup/report.zig`).
//!
//! `--bench-scenario=latency` runs the typing-latency benchmark
//! (`bench/latency.zig`, `zig build bench-latency`) and exits;
//! `--bench-scenario=<name>` runs a macro scenario (`bench/runner.zig`,
//! `zig build bench-scenarios`).
//!
//! Text is drawn with system fonts through `zg_gui.FontText` (see
//! `fonts.zig`), or with placeholder boxes when no font file is found.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_install = @import("zg_install");
const zg_release = @import("zg_release");
const zg_crash = @import("zg_crash");
const zg_update = @import("zg_update");
const zg_platform = @import("zg_platform");
const zg_gui = @import("zg_gui");
const zg_vulkan = @import("zg_vulkan");
const Welcome = @import("welcome.zig").Welcome;
const Workbench = @import("workbench.zig").Workbench;
const tracing_mod = @import("tracing.zig");
const Tracing = tracing_mod.Tracing;
const fonts = @import("fonts.zig");
const early_update = @import("startup/early_update_check.zig");
const install_kind = @import("startup/install_kind.zig");
const StartupReport = @import("startup/report.zig").StartupReport;
const zg_perf = @import("zg_perf");
const bench_latency = @import("bench/latency.zig");
const bench_runner = @import("bench/runner.zig");

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
    // Startup phase marks (E14.F05.S01.T01; docs/perf/startup.md).
    zg_perf.startup.mark(.main_entered);
    // Before any runtime init: no allocator, no worker threads.
    if (zg_release.cli.handleVersionFlag(min, &zg_release.current, "zigguro")) return 0;
    installCrashHandler(min, "zigguro");
    // Windows: setup waits while this named mutex exists (E17.F02.S01.T03).
    const running = zg_install.win.instance.hold(zg_install.win.instance.app_mutex);
    defer running.release();

    var rt: zg_core.Runtime = undefined;
    try rt.init(min, .{});
    defer _ = rt.deinit();
    zg_perf.startup.global().install(rt.io);
    zg_perf.startup.mark(.runtime_ready);
    // Before GPU and window init: apply a staged update or roll back one
    // that cannot start (may re-execute the process).
    var boot = early_update.run(&rt, min, running.first);
    defer boot.deinit(rt.io);

    var buf: [256]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), rt.io, &buf);
    const w = &out.interface;

    var env = try min.environ.createMap(rt.gpa);
    defer env.deinit();
    var kind_arena: std.heap.ArenaAllocator = .init(rt.gpa);
    defer kind_arena.deinit();
    const kind = try install_kind.resolve(kind_arena.allocator(), rt.io, &env, min.environ);
    if (hasFlag(min, rt.gpa, "--self-check")) {
        try install_kind.write(kind, w);
        try w.flush();
        return 0;
    }
    try install_kind.usePortableTmp(rt.io, kind, &env);
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
    // `--trace=`, `--trace-format=`, `ZG_TRACE` and the perf.trace.*
    // commands (E14.F02.S01.T02).
    var tracing: Tracing = undefined;
    tracing.init(rt.gpa, rt.io, &env);
    defer tracing.deinit();
    tracing.app = &app;
    const trace_req = traceRequest(min, &kind_arena, &env);
    if (trace_req) |r| tracing.applyRequest(r);
    var mono: zg_gui.paint.text.MonoText = .{};
    const font_files = fonts.load(rt.gpa, rt.io, &env);
    defer if (font_files) |f| f.deinit(rt.gpa);
    const font_text: ?*zg_gui.paint.FontText = if (font_files) |f| zg_gui.paint.FontText.create(rt.gpa, .{ .ui = f.ui, .mono = f.mono }) catch null else null;
    defer if (font_text) |ft| ft.destroy();
    const text_sys = if (font_text) |ft| ft.system() else mono.system();
    zg_perf.startup.mark(.fonts_ready);
    var welcome: Welcome = .{ .version = zg_release.current.version_string };
    if (try benchScenario(min, &rt, &env, &app, &tracing, text_sys, font_text, backend, w)) |code| return code;
    const path_arg = pathArg(min, rt.gpa);
    defer if (path_arg) |p| rt.gpa.free(p);
    const want_terminal = hasFlag(min, rt.gpa, "--terminal");
    const want_agent = hasFlag(min, rt.gpa, "--agent");
    const want_review = hasFlag(min, rt.gpa, "--review");
    // `--hud` opens the performance HUD (perf.hud.toggle) at start.
    const want_hud = hasFlag(min, rt.gpa, "--hud");
    // `--mem-report[=now]` prints the memory report once idle (or at
    // once); `--mem-report-exit` then exits (E14.F04.S01.T02).
    const mem_now = hasFlag(min, rt.gpa, "--mem-report=now");
    const mem_exit = hasFlag(min, rt.gpa, "--mem-report-exit");
    const want_mem = mem_now or mem_exit or hasFlag(min, rt.gpa, "--mem-report");
    const frames_arg = framesArg(min, rt.gpa);
    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state_dir = zg_crash.paths.stateDirAt(rt.io, min.environ, &state_buf);
    // `--startup-report` prints the startup report once the first frame
    // is interactive; interactive runs (not --frames or headless ones)
    // record it in startup.json.
    // `--startup-report-json=PATH` and `--exit-after-startup` serve
    // zigguro-bench-startup (E14.F05.S01.T03).
    const startup_json = prefixArg(min, rt.gpa, "--startup-report-json=");
    defer if (startup_json) |p| rt.gpa.free(p);
    const bench_run = startup_json != null;
    var startup_report: StartupReport = .{
        .gpa = rt.gpa,
        .io = rt.io,
        .print = hasFlag(min, rt.gpa, "--startup-report"),
        .state_dir = if (frames_arg == null and backend != .headless and !bench_run) state_dir else null,
        .json_path = startup_json,
        .exit_after = hasFlag(min, rt.gpa, "--exit-after-startup"),
        .refresh_ns = if (tracing.timeline) |tl| &tl.refresh_ns else null,
    };
    const inject_key = hasFlag(min, rt.gpa, "--bench-inject-key-after-first-frame");
    defer startup_report.deinit();
    startup_report.arm();
    // `zigguro DIR` opens the folder; with no path, interactive runs open
    // the last folder (or the working folder). `--welcome` shows the
    // welcome window instead.
    var file_arg: ?[]const u8 = path_arg;
    var folder_mode = false;
    if (path_arg) |p| if (isFolder(rt.io, p)) {
        std.process.setCurrentPath(rt.io, p) catch |e| std.log.err("cannot open folder {s}: {t}", .{ p, e });
        file_arg = null;
        folder_mode = true;
    };
    if (path_arg == null and frames_arg == null and !hasFlag(min, rt.gpa, "--welcome")) {
        if (state_dir) |sd| restoreLastFolder(rt.gpa, rt.io, sd);
        folder_mode = true;
    }
    const use_wb = file_arg != null or folder_mode or want_terminal or want_agent or want_review;
    if (use_wb and frames_arg == null) if (state_dir) |sd| saveLastFolder(rt.gpa, rt.io, sd);
    var wb: Workbench = undefined;
    if (use_wb) {
        try wb.init(&rt, &env, file_arg);
        // settings.json and keybindings.json in the config folder.
        const cp = kind.paths;
        wb.useSettings(if (cp) |p| p.userSettings() else null, if (cp) |p| p.userKeybindings() else null) catch |e|
            std.log.err("settings: {t}", .{e});
        zg_perf.startup.mark(.config_loaded);
        tracing.registerCommands(wb.reg) catch |e| std.log.err("trace commands: {t}", .{e});
    }
    defer if (use_wb) wb.deinit();
    const root: zg_gui.AnyView = if (use_wb) .of(&wb) else .of(&welcome);

    if (backend != .headless) native: {
        const platform = zg_platform.init(rt.gpa, rt.io, .{ .environ_map = &env }) catch |err| {
            try w.print("zigguro {s}: no {t} display ({t}); falling back to the headless platform\n", .{ zg_release.current.version_string, backend, err });
            try w.flush();
            break :native;
        };
        defer platform.deinit();
        zg_perf.startup.mark(.platform_ready);
        // Screen readers on Linux reach the app through AT-SPI2 on the
        // session bus.
        var bus_buf: [256]u8 = undefined;
        const session_bus: ?[]const u8 = if (builtin.os.tag == .linux) zg_platform.portal.desktop.sessionAddress(&bus_buf, &env) else null;
        var host = zg_gui.Host.init(rt.gpa, rt.io, &app, platform, text_sys, .{
            .fonts = font_text,
            .a11y = .{ .session_address = session_bus, .version = zg_release.current.version_string },
            .timeline = tracing.timeline,
        });
        defer host.deinit();
        // Interactive sessions get the working folder's saved layout back
        // (runs with --frames are reproducible: they neither read nor
        // write it).
        var size: zg_gui.core.geom.Size = .{ .w = 1280, .h = 800 };
        if (use_wb and frames_arg == null) {
            if (state_dir) |state| {
                wb.enableUndoFiles(state);
                if (wb.loadLayout(state)) |s| size = fitOnScreen(s, platform);
                zg_perf.startup.mark(.session_restored);
            }
        }
        const hw = try host.open(.{ .title = "zigguro", .size = size, .root = root });
        zg_perf.startup.mark(.window_created);
        tracing.hud_win = hw.win;
        defer tracing.detachWindow();
        if (want_hud) tracing.toggleHud() catch {};
        if (trace_req) |r| if (r.startup) tracing.armStartupStop();
        if (use_wb) try wb.attach(hw.win);
        if (use_wb) wb.enableFloating(host.windowOpener());
        zg_perf.startup.mark(.workbench_built);
        if (want_terminal and !wb.panelShown("terminal")) try wb.toggleTerminal();
        if (want_agent and !wb.panelShown("agent")) try wb.toggleAgent();
        if (want_review and !wb.panelShown("review")) try wb.toggleReview();
        defer if (use_wb) wb.detach();
        if (want_mem) tracing.armMemReport(mem_now, mem_exit);
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
        startup_report.finishNow();
        try w.print("zigguro {s}: rendered {d} frame(s) on the {t} platform\n", .{ zg_release.current.version_string, drawn, backend });
        try w.flush();
        return 0;
    }

    const frames = frames_arg orelse 3;
    const hl = try zg_platform.headless.Headless.init(rt.gpa, rt.io, .{});
    defer hl.deinit();
    zg_perf.startup.mark(.platform_ready);
    var host = zg_gui.Host.init(rt.gpa, rt.io, &app, hl.platform(), text_sys, .{ .fonts = font_text, .timeline = tracing.timeline });
    defer host.deinit();
    const hw = try host.open(.{ .title = "zigguro", .size = .{ .w = 960, .h = 600 }, .root = root });
    zg_perf.startup.mark(.window_created);
    tracing.hud_win = hw.win;
    defer tracing.detachWindow();
    if (want_hud) tracing.toggleHud() catch {};
    if (use_wb) try wb.attach(hw.win);
    zg_perf.startup.mark(.workbench_built);
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
        // The bench's interactive check: one key right after the first
        // frame, handled by the next pump.
        if (i == 0 and inject_key) {
            for ([_]zg_platform.keys.KeyAction{ .press, .release }) |action|
                hl.inject(.{ .key = .{ .win = hw.id, .ev = .{ .key = .f24, .keysym = 0, .codepoint = 0, .mods = .{}, .action = action, .text = .empty, .native_scancode = 0, .time_ns = hl.clock_ns } } }) catch {};
        }
        hw.win.themeChanged(false); // force a full repaint next frame
    }
    _ = host.flush(5 * std.time.ns_per_s);
    try w.print("zigguro {s}: rendered {d} frame(s) on the headless platform\n", .{ zg_release.current.version_string, drawn });
    if (want_mem) tracing.writeMemReport(w) catch |e| std.log.err("memory report: {t}", .{e});
    try w.flush();
    startup_report.finishNow();
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

/// Runs `--bench-scenario=<name>` when asked (`latency` has its own
/// harness): returns the exit code.
fn benchScenario(
    min: std.process.Init.Minimal,
    rt: *zg_core.Runtime,
    env: *std.process.Environ.Map,
    app: *zg_gui.App,
    tracing: *Tracing,
    text_sys: zg_gui.paint.text.TextSystem,
    font_text: ?*zg_gui.paint.FontText,
    backend: zg_platform.platform.Backend,
    w: *std.Io.Writer,
) !?u8 {
    var arena: std.heap.ArenaAllocator = .init(rt.gpa);
    defer arena.deinit();
    var args: std.ArrayList([]const u8) = .empty;
    var it = try min.args.iterateAllocator(arena.allocator());
    while (it.next()) |a| try args.append(arena.allocator(), try arena.allocator().dupe(u8, a));
    if (bench_runner.Options.parse(args.items)) |opts| {
        // Absolute: the idle scenario changes the working folder.
        const cwd = try std.process.currentPathAlloc(rt.io, arena.allocator());
        const corpus_root = try std.fs.path.resolve(arena.allocator(), &.{ cwd, opts.corpus_root orelse try bench_runner.defaultCorpusRoot(arena.allocator(), env) });
        var d: bench_runner.Driver = .{ .gpa = rt.gpa, .io = rt.io, .rt = rt, .env = env, .app = app, .text_sys = text_sys, .fonts = font_text, .timeline = tracing.timeline, .quick = opts.quick, .corpus_root = corpus_root };
        const code = try bench_runner.run(&d, opts, w);
        try w.flush();
        return code;
    }
    if (!bench_latency.requested(args.items)) return null;
    const opts = bench_latency.Options.parse(args.items);
    const tl = tracing.timeline orelse return error.NoFrameTimeline;
    const corpus = opts.corpus orelse try bench_latency.defaultCorpus(arena.allocator(), env, opts.file_lines);
    try bench_latency.writeCorpus(rt.io, corpus, opts.file_lines);
    var wb: Workbench = undefined;
    try wb.init(rt, env, corpus);
    defer wb.deinit();
    const o = try bench_latency.run(.{ .gpa = rt.gpa, .io = rt.io, .app = app, .wb = &wb, .text_sys = text_sys, .fonts = font_text, .timeline = tl, .env = env, .backend = backend }, opts);
    try bench_latency.writeResults(rt.io, o, opts, w);
    try w.flush();
    return if (o.ok()) 0 else 1;
}

/// Runs until the window closes. In a managed install the version counts
/// as healthy 30 s after the window opened, or at a clean quit.
/// A saved window size, shrunk to the primary monitor's work area: the
/// layout may come from a larger screen or a smaller scale, and a window
/// larger than its output cannot be moved or resized back.
fn fitOnScreen(s: zg_gui.core.geom.Size, platform: zg_platform.Platform) zg_gui.core.geom.Size {
    var mons: [8]zg_platform.types.MonitorInfo = undefined;
    const n = @min(platform.monitors(&mons), mons.len);
    if (n == 0) return s;
    var m = &mons[0];
    for (mons[0..n]) |*x| if (x.primary) {
        m = x;
    };
    const scale = if (m.scale.factor > 0) m.scale.factor else 1;
    const area = if (m.work_px.w > 0 and m.work_px.h > 0) m.work_px else m.rect_px;
    if (area.w == 0 or area.h == 0) return s;
    return .{
        .w = @min(s.w, @as(f32, @floatFromInt(area.w)) / scale),
        .h = @min(s.h, @as(f32, @floatFromInt(area.h)) / scale),
    };
}

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

/// The trace the command line or `ZG_TRACE` asks for (strings in `arena`).
fn traceRequest(min: std.process.Init.Minimal, arena: *std.heap.ArenaAllocator, env: *const std.process.Environ.Map) ?tracing_mod.Request {
    var args: std.ArrayList([]const u8) = .empty;
    var it = min.args.iterateAllocator(arena.allocator()) catch return null;
    while (it.next()) |a| args.append(arena.allocator(), arena.allocator().dupe(u8, a) catch return null) catch return null;
    return tracing_mod.parseRequest(args.items, env.get("ZG_TRACE"));
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

/// The value of `--name=value` (`prefix` includes the `=`).
fn prefixArg(min: std.process.Init.Minimal, gpa: std.mem.Allocator, prefix: []const u8) ?[]u8 {
    var it = min.args.iterateAllocator(gpa) catch return null;
    defer it.deinit();
    while (it.next()) |a| {
        if (std.mem.startsWith(u8, a, prefix)) return gpa.dupe(u8, a[prefix.len..]) catch null;
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
        if (early_update.flags.match(a)) |m| {
            if (m.value) _ = it.next();
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

/// Whether `p` is a folder.
fn isFolder(io: std.Io, p: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

/// Where the last opened folder is remembered.
const last_folder_file = "last-folder";

/// Makes the folder the last session opened the working folder (when it
/// still exists).
fn restoreLastFolder(gpa: std.mem.Allocator, io: std.Io, state: []const u8) void {
    const f = std.fs.path.join(gpa, &.{ state, last_folder_file }) catch return;
    defer gpa.free(f);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, f, gpa, .limited(std.fs.max_path_bytes)) catch return;
    defer gpa.free(bytes);
    const dir = std.mem.trim(u8, bytes, " \r\n");
    if (dir.len > 0 and isFolder(io, dir)) std.process.setCurrentPath(io, dir) catch {};
}

/// Remembers the working folder for the next start without a path.
fn saveLastFolder(gpa: std.mem.Allocator, io: std.Io, state: []const u8) void {
    const cwd = std.process.currentPathAlloc(io, gpa) catch return;
    defer gpa.free(cwd);
    std.Io.Dir.cwd().createDirPath(io, state) catch return;
    const f = std.fs.path.join(gpa, &.{ state, last_folder_file }) catch return;
    defer gpa.free(f);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = f, .data = cwd }) catch {};
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

/// Crash reports go to `<state>/crashes` (E17.F05), inside
/// `zigguro-data` for a portable install; `install` copies the paths. A failure here only means no reports.
fn installCrashHandler(min: std.process.Init.Minimal, product: []const u8) void {
    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    var crash_buf: [std.fs.max_path_bytes]u8 = undefined;
    // Before the runtime exists: the one stat for portable mode runs on
    // std's single-threaded Io.
    const state = zg_crash.paths.stateDirAt(std.Io.Threaded.global_single_threaded.io(), min.environ, &state_buf) orelse return;
    const crashes = zg_crash.paths.crashDir(state, &crash_buf) orelse return;
    zg_crash.install(.{ .crash_dir = crashes, .state_dir = state, .product = product }) catch {};
}
