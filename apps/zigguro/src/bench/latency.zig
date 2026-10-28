//! `bench-latency` (E14.F03.S02.T02): types into a 100 k-line file in the
//! real workbench and reports key-to-photon percentiles with a segment
//! breakdown as E00 bench JSON (`zg_perf.frame.latency_report`).
//!
//! `zigguro --bench-scenario=latency` runs it in the app process. Options:
//! `--bench-out=PATH` (the JSON; default stdout only), `--bench-keys=N`
//! (1000), `--bench-warmup=N` (50), `--bench-interval-ms=N` (150; `--burst`
//! is 10 ms to measure coalescing), `--bench-lines=N` (100 000),
//! `--bench-injection=auto|os|ring` and `--bench-corpus=PATH` (the
//! generated file; default in the temp folder).
//!
//! - `os` opens a real window and types through uinput (Linux) or
//!   `SendInput` (Windows), waiting the interval after each key so every
//!   key gets its own frame (Typometer's synchronous mode).
//! - `ring` runs on the headless platform and queues key events there with
//!   no waiting, one frame per key; presentation times are estimated
//!   (submit + one refresh), and the result is `latency.ring_to_photon`.
//! - `auto` tries `os` and falls back to `ring`.
//! - `external` opens a real window with the latency probe square and
//!   only collects: the photodiode rig is the keyboard (section 3 of
//!   docs/perf/latency.md). It stops after `--bench-keys` key frames or
//!   when the window closes.
//!
//! The caret starts at line 50 000, column 10. A run fails (exit code 1)
//! when nothing was measured, the text did not change, or more than 5 % of
//! the frames were estimated on a backend that claims presentation
//! feedback.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_platform = @import("zg_platform");
const zg_gui = @import("zg_gui");
const zg_perf = @import("zg_perf");
const Workbench = @import("../workbench.zig").Workbench;
const keys = @import("keys.zig");
const injector = @import("injector.zig");
const zg_perf_ui = @import("zg_perf_ui");

const report_mod = zg_perf.frame.latency_report;
const clock_contract = zg_perf.frame.clock_contract;
const FrameTimeline = zg_perf.frame.FrameTimeline;
pub const Report = report_mod.Report;

pub const Injection = enum { auto, os, ring, external };

pub const Options = struct {
    keys: u32 = 1000,
    interval_ms: u32 = 150,
    warmup_keys: u32 = 50,
    file_lines: u32 = 100_000,
    injection: Injection = .auto,
    out_path: ?[]const u8 = null,
    corpus: ?[]const u8 = null,

    /// Reads the `--bench-*` options from `args` (slices into `args`).
    pub fn parse(args: []const []const u8) Options {
        var o: Options = .{};
        for (args) |a| {
            if (value(a, "--bench-keys=")) |v| o.keys = std.fmt.parseInt(u32, v, 10) catch o.keys;
            if (value(a, "--bench-warmup=")) |v| o.warmup_keys = std.fmt.parseInt(u32, v, 10) catch o.warmup_keys;
            if (value(a, "--bench-interval-ms=")) |v| o.interval_ms = std.fmt.parseInt(u32, v, 10) catch o.interval_ms;
            if (value(a, "--bench-lines=")) |v| o.file_lines = std.fmt.parseInt(u32, v, 10) catch o.file_lines;
            if (value(a, "--bench-injection=")) |v| o.injection = std.meta.stringToEnum(Injection, v) orelse o.injection;
            if (value(a, "--bench-out=")) |v| o.out_path = v;
            if (value(a, "--bench-corpus=")) |v| o.corpus = v;
            if (std.mem.eql(u8, a, "--burst")) o.interval_ms = 10;
        }
        return o;
    }

    fn value(a: []const u8, comptime prefix: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, a, prefix)) a[prefix.len..] else null;
    }
};

/// Whether `args` asks for this scenario.
pub fn requested(args: []const []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, "--bench-scenario=latency")) return true;
    return false;
}

/// Where the caret starts.
pub const start_line = 50_000;
pub const start_col = 10;

/// Writes the corpus: `lines` lines of Zig-like code, the same every run
/// (stand-in for corpusgen's `lines-100k` profile, E14.F06.S01.T01).
pub fn writeCorpus(io: std.Io, path: []const u8, lines: u32) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    var i: u32 = 0;
    while (i < lines) : (i += 1) {
        switch (i % 16) {
            0 => try w.print("pub fn step{d}(ctx: *Context, input: []const u8) !u64 {{\n", .{i / 16}),
            14 => try w.print("    return acc{d} +% @as(u64, input.len);\n", .{i % 7}),
            15 => try w.writeAll("}\n"),
            else => try w.print("    const acc{d} = ctx.table[{d}] *% 0x9e3779b9 + {d}; // line {d}\n", .{ i % 7, i % 251, i, i + 1 }),
        }
    }
    try w.flush();
}

/// The default corpus path in the temp folder (owned).
pub fn defaultCorpus(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, lines: u32) ![]u8 {
    const tmp = env.get("TMPDIR") orelse env.get("TEMP") orelse env.get("TMP") orelse (if (builtin.os.tag == .windows) "." else "/tmp");
    var name: [48]u8 = undefined;
    return std.fs.path.join(gpa, &.{ tmp, try std.fmt.bufPrint(&name, "zigguro-bench-lines-{d}.zig", .{lines}) });
}

/// What the scenario runs on.
pub const Ctx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *zg_gui.App,
    /// Initialized on the corpus, not attached.
    wb: *Workbench,
    text_sys: zg_gui.paint.text.TextSystem,
    fonts: ?*zg_gui.paint.FontText = null,
    timeline: *FrameTimeline,
    env: *const std.process.Environ.Map,
    /// The backend to use for `os` injection.
    backend: zg_platform.platform.Backend,
};

/// A run's outcome.
pub const Outcome = struct {
    report: Report,
    /// The document's length changed.
    typed: bool,

    pub fn ok(o: Outcome) bool {
        return o.typed and o.report.frames > 0 and o.report.estimatedGateOk();
    }
};

/// Runs the scenario: `os` injection when asked or available, else
/// `ring`.
pub fn run(c: Ctx, opts: Options) !Outcome {
    var col: report_mod.Collector = .{ .warmup = opts.warmup_keys };
    c.timeline.sink = col.sink();
    defer c.timeline.sink = null;
    if (opts.injection != .ring and c.backend != .headless) {
        if (runOs(c, opts, &col)) |o| return o else |e| {
            if (opts.injection == .os or opts.injection == .external) return e;
            std.log.warn("bench-latency: OS injection unavailable ({t}); using ring mode", .{e});
            if (e == error.AccessDenied and builtin.os.tag == .linux)
                std.log.warn("bench-latency: allow /dev/uinput with a udev rule: {s}", .{@import("inject_uinput.zig").udev_rule});
            col = .{ .warmup = opts.warmup_keys };
        }
    }
    return runRing(c, opts, &col);
}

fn backendOf(b: zg_platform.platform.Backend) clock_contract.Backend {
    return std.meta.stringToEnum(clock_contract.Backend, @tagName(b)) orelse .headless;
}

/// The profile of `backend`, with the presentation time marked estimated
/// when the window never sent plausible feedback.
fn profileOf(backend: zg_platform.platform.Backend, hw: *const zg_gui.host.HostWindow) clock_contract.BackendLatencyProfile {
    var p = clock_contract.profileFor(backendOf(backend), .{});
    if (!hw.feedback.expectFeedback()) p.present_time = .{ .resolution_ns = 1000, .accuracy = .unavailable, .note = "no plausible presentation feedback: submit + one refresh period" };
    return p;
}

fn runRing(c: Ctx, opts: Options, col: *report_mod.Collector) !Outcome {
    const hl = try zg_platform.headless.Headless.init(c.gpa, c.io, .{});
    defer hl.deinit();
    var host = zg_gui.Host.init(c.gpa, c.io, c.app, hl.platform(), c.text_sys, .{ .fonts = c.fonts, .timeline = c.timeline, .render_thread = false });
    defer host.deinit();
    const hw = try host.open(.{ .title = "zigguro bench-latency", .size = .{ .w = 1280, .h = 800 }, .root = .of(c.wb) });
    try c.wb.attach(hw.win);
    defer c.wb.detach();
    c.wb.gotoLine(start_line, start_col);
    for (0..4) |_| try frame(&host, hl);
    const len0 = c.wb.doc.len();
    var i: u32 = 0;
    while (i < opts.keys) : (i += 1) {
        const k = keys.keyFor(keys.sequence(i));
        var ev: zg_platform.event.KeyEvent = .{ .key = k.key, .keysym = k.keysym, .codepoint = if (k.text.len == 1) k.text[0] else 0, .mods = .{}, .action = .press, .text = .{ .len = @intCast(k.text.len) }, .native_scancode = k.evdev, .time_ns = 0 };
        try hl.injectPayload(.{ .key = .{ .win = hw.id, .ev = ev } }, k.text);
        ev.action = .release;
        ev.text = .empty;
        try hl.inject(.{ .key = .{ .win = hw.id, .ev = ev } });
        try frame(&host, hl);
    }
    for (0..4) |_| try frame(&host, hl);
    return .{ .report = col.report(.ring, c.timeline.refresh_ns, profileOf(.headless, hw)), .typed = c.wb.doc.len() != len0 };
}

/// One headless frame.
fn frame(host: *zg_gui.Host, hl: *zg_platform.headless.Headless) !void {
    _ = try host.pump();
    try hl.tick(hl.opts.refresh_ns);
    _ = try host.pump();
}

fn runOs(c: Ctx, opts: Options, col: *report_mod.Collector) !Outcome {
    const platform = try zg_platform.initBackend(c.gpa, c.io, c.backend, .{ .environ_map = @constCast(c.env) });
    defer platform.deinit();
    var host = zg_gui.Host.init(c.gpa, c.io, c.app, platform, c.text_sys, .{ .fonts = c.fonts, .timeline = c.timeline });
    defer host.deinit();
    const hw = try host.open(.{ .title = "zigguro bench-latency", .size = .{ .w = 1280, .h = 800 }, .root = .of(c.wb) });
    try c.wb.attach(hw.win);
    defer c.wb.detach();
    c.wb.gotoLine(start_line, start_col);
    const len0 = c.wb.doc.len();
    if (opts.injection == .external) {
        // The rig types and times the probe square; collect until enough
        // key frames arrived or the window closes.
        const probe = try zg_perf_ui.Probe.init(c.gpa, .{});
        defer probe.destroy();
        probe.setVisible(hw.win, true);
        defer probe.setVisible(hw.win, false);
        while (col.seen < opts.keys and host.windows.items.len > 0) try pumpFor(&host, platform, c.io, 100 * std.time.ns_per_ms);
    } else {
        const inj = try injector.osInjector(c.gpa, c.io);
        defer inj.deinit();
        // Let the window map, take focus and settle.
        try pumpFor(&host, platform, c.io, 500 * std.time.ns_per_ms);
        var i: u32 = 0;
        while (i < opts.keys and host.windows.items.len > 0) : (i += 1) {
            try inj.keyTap(keys.sequence(i));
            try pumpFor(&host, platform, c.io, @as(u64, opts.interval_ms) * std.time.ns_per_ms);
        }
    }
    // The last frames' presentation feedback.
    try pumpFor(&host, platform, c.io, 300 * std.time.ns_per_ms);
    if (c.wb.doc.len() == len0) return error.KeysNotDelivered;
    return .{ .report = col.report(if (opts.injection == .external) .external else .os, c.timeline.refresh_ns, profileOf(c.backend, hw)), .typed = true };
}

/// Pumps events and frames for `ns`.
fn pumpFor(host: *zg_gui.Host, platform: zg_platform.Platform, io: std.Io, ns: u64) !void {
    const deadline = zg_core.time.nowNs(io) + ns;
    while (host.windows.items.len > 0) {
        _ = try host.pump();
        if (zg_core.time.nowNs(io) >= deadline) return;
        platform.waitEvents(deadline);
    }
}

/// Writes the JSON to `opts.out_path` (when set) and the summary to `w`.
pub fn writeResults(io: std.Io, o: Outcome, opts: Options, w: *std.Io.Writer) !void {
    try o.report.writeSummary(w);
    if (!o.typed) try w.writeAll("bench-latency: FAILED: the keys did not change the text\n");
    if (!o.report.estimatedGateOk()) try w.print("bench-latency: FAILED: {d} of {d} frames estimated on a backend that claims presentation feedback\n", .{ o.report.estimated_frames, o.report.frames });
    const path = opts.out_path orelse return;
    if (std.fs.path.dirname(path)) |d| std.Io.Dir.cwd().createDirPath(io, d) catch {};
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    try o.report.writeJson(&fw.interface, .{});
    try fw.interface.flush();
    try w.print("bench-latency: wrote {s}\n", .{path});
}

test "bench latency ring mode runs 100 keys" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const corpus = try std.fs.path.join(gpa, &.{ root, "lines.zig" });
    defer gpa.free(corpus);
    try writeCorpus(io, corpus, 60_000);

    var app = zg_gui.App.init(gpa);
    defer app.deinit();
    app.attachRuntime(&rt);
    var wb: Workbench = undefined;
    try wb.init(&rt, &env, corpus);
    defer wb.deinit();
    var tl = try FrameTimeline.init(gpa, 1024);
    defer tl.deinit();
    var mono: zg_gui.paint.text.MonoText = .{};
    const opts: Options = .{ .keys = 100, .warmup_keys = 10, .injection = .ring };
    const o = try run(.{ .gpa = gpa, .io = io, .app = &app, .wb = &wb, .text_sys = mono.system(), .timeline = &tl, .env = &env, .backend = .headless }, opts);
    try std.testing.expect(o.typed);
    try std.testing.expect(o.ok());
    // Every key after the warm-up got its own frame; Backspace (keys 64..71)
    // counts too.
    try std.testing.expectEqual(@as(u32, 90), o.report.frames);
    try std.testing.expectEqual(o.report.frames, o.report.estimated_frames);
    try std.testing.expectEqual(report_mod.Injection.ring, o.report.injection);
    try std.testing.expect(o.report.key_to_photon.p50_ns > 0);
    try std.testing.expect(o.report.key_to_photon.p99_ns >= o.report.key_to_photon.p50_ns);
    // The caret moved from line 50 000 by the typed text.
    try std.testing.expectEqual(@as(u64, start_line), wb.view.lineOf(wb.view.primarySel().head));

    var out: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    const json = try std.fs.path.join(gpa, &.{ root, "out", "latency.json" });
    defer gpa.free(json);
    var o2 = opts;
    o2.out_path = json;
    try writeResults(io, o, o2, &w);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, json, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("latency.ring_to_photon", parsed.value.object.get("results").?.array.items[0].object.get("name").?.string);
}

test "bench latency options" {
    const o = Options.parse(&.{ "--bench-scenario=latency", "--bench-keys=200", "--bench-injection=ring", "--bench-out=x.json", "--burst" });
    try std.testing.expectEqual(@as(u32, 200), o.keys);
    try std.testing.expectEqual(Injection.ring, o.injection);
    try std.testing.expectEqualStrings("x.json", o.out_path.?);
    try std.testing.expectEqual(@as(u32, 10), o.interval_ms);
    try std.testing.expect(requested(&.{ "zigguro", "--bench-scenario=latency" }));
    try std.testing.expect(!requested(&.{"zigguro"}));
}
