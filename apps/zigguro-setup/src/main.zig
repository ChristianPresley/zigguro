//! zigguro-setup.exe (E17.F02.S01.T03): the per-user Windows installer.
//! With an embedded payload it installs or upgrades; the helper copy in
//! `app\` (no payload) uninstalls and applies updates. See args.zig for
//! the command line and exit codes. Progress and errors go to
//! `%TEMP%\zigguro-setup.log`, appended in every mode, and those of
//! `--apply` also to `<state>\update\apply.log`.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zg_install = @import("zg_install");
const zg_config = @import("zg_config");
const zg_crash = @import("zg_crash");
const zg_update = @import("zg_update");
const apply = @import("apply.zig");
const args_mod = @import("args.zig");
const install = @import("install.zig");
const payload = @import("payload.zig");
const ui = @import("ui.zig");
const uninstall = @import("uninstall.zig");
const win = @import("win.zig");
const Exit = args_mod.Exit;
const instance = zg_install.win.instance;

// Size: the installer is ReleaseSmall and carries no stack-trace printer.
pub const panic = if (builtin.mode == .ReleaseSmall) std.debug.simple_panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options: std.Options = .{ .enable_segfault_handler = builtin.mode != .ReleaseSmall };

pub fn main(init: std.process.Init) u8 {
    return @intFromEnum(run(init));
}

fn run(init: std.process.Init) Exit {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var log_buf: [1024]u8 = undefined;
    var log = Log.openTemp(io, init.environ_map, &log_buf);
    defer log.close(io);

    const argz = init.minimal.args.toSlice(arena) catch return .io_failure;
    const argv = arena.alloc([]const u8, argz.len) catch return .io_failure;
    for (argz, argv) |z, *o| o.* = z;
    const cmd = args_mod.parse(if (argv.len > 0) argv[1..] else argv) catch |err| {
        log.line("bad arguments: {t}", .{err});
        return .bad_arguments;
    };
    return switch (cmd) {
        .install => |i| runInstall(gpa, io, arena, init.environ_map, i, &log),
        .uninstall => |u| if (u.stage2) uninstallStage2(gpa, io, arena, init.environ_map, u, &log) else uninstallStage1(io, arena, init.environ_map, u, &log),
        .apply => |a| runApply(gpa, io, arena, init.minimal.environ, a, &log),
    };
}

fn runInstall(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, a: args_mod.Install, log: *Log) Exit {
    if (!payload.has_payload) {
        log.line("this setup has no payload; it only uninstalls and applies updates", .{});
        if (!a.silent) ui.message(.failure, "This copy of zigguro setup cannot install. Download the installer from the zigguro website.");
        return .bad_arguments;
    }
    const single = instance.hold(instance.setup_mutex);
    defer single.release();
    if (!single.first) {
        log.line("another setup is running", .{});
        return .cancelled;
    }

    const root = (install.resolveRoot(arena, env, a.dir) catch return .io_failure) orelse fallback: {
        const programs = zg_install.win.known_folders.knownFolderPath(arena, .user_program_files) catch {
            log.line("no install directory: LOCALAPPDATA is unset", .{});
            return .io_failure;
        };
        break :fallback std.fs.path.join(arena, &.{ programs, "zigguro" }) catch return .io_failure;
    };

    while (instance.exists(instance.app_mutex)) {
        log.line("zigguro is running", .{});
        if (a.silent) return .app_running;
        if (!ui.retry("zigguro is running. Close it to continue.")) return .cancelled;
    }

    const plan: install.Plan = .{ .root = root, .opts = a.opts, .version = payload.version, .target = payload.target, .silent = a.silent };
    var cancel: std.atomic.Value(bool) = .init(false);
    const t0 = Io.Clock.awake.now(io);
    const out = install.run(gpa, io, plan, payload.bytes, .{}, &cancel, .windows, log.writer()) catch |err| {
        log.line("install failed: {t}", .{err});
        const code: Exit = switch (err) {
            error.Cancelled => .cancelled,
            error.PayloadCorrupt => .payload_corrupt,
            error.NoSpace, error.InstallFailed, error.OutOfMemory => .io_failure,
        };
        if (!a.silent) ui.message(.failure, switch (err) {
            error.Cancelled => "Setup was cancelled.",
            error.PayloadCorrupt => "This installer is damaged. Download it again.",
            error.NoSpace => "There is not enough free disk space to install zigguro.",
            error.InstallFailed, error.OutOfMemory => "zigguro could not be installed. Details are in %TEMP%\\zigguro-setup.log.",
        });
        return code;
    };
    defer if (out.previous_version) |v| gpa.free(v);
    const ms = t0.durationTo(Io.Clock.awake.now(io)).toMilliseconds();
    log.line("done in {d} ms{s}", .{ ms, if (out.upgraded) " (upgrade)" else "" });

    if (!a.silent and a.launch) launch(io, arena, root, &.{}, log);
    return .ok;
}

/// Tells the relaunched app that the helper ran but `app\` did not change.
const update_skipped = "--update-skipped";

/// The update helper: waits for the app to exit, swaps in the staged
/// version (or rolls back), then relaunches the app.
fn runApply(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, environ: std.process.Environ, a: args_mod.Apply, temp_log: *Log) Exit {
    var state_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const state = zg_crash.paths.stateDir(environ, &state_buf);
    var log_buf: [1024]u8 = undefined;
    var own_log: ?Log = if (state) |s| open: {
        const dir = std.fs.path.join(arena, &.{ s, zg_update.boot_health.dir_name }) catch break :open null;
        Io.Dir.cwd().createDirPath(io, dir) catch break :open null;
        const path = std.fs.path.join(arena, &.{ dir, "apply.log" }) catch break :open null;
        const l = Log.open(io, path, &log_buf);
        break :open if (l.file != null) l else null;
    } else null;
    defer if (own_log) |*l| l.close(io);
    const log = if (own_log) |*l| l else temp_log;
    const mode: apply.Mode = if (a.rollback) .rollback else .apply;
    log.line("{t}: {s}, waiting for process {d}", .{ mode, a.root, a.wait_pid });

    if (!win.waitForExit(a.wait_pid, 30_000)) {
        log.line("process {d} did not exit", .{a.wait_pid});
        return .app_running;
    }
    var extra: std.ArrayList([]const u8) = .empty;
    if (a.relaunch) |tail| {
        const parts = zg_install.win.cmdline.split(arena, tail) catch |err| {
            log.line("--relaunch: {t}", .{err});
            return .bad_arguments;
        };
        extra.appendSlice(arena, parts) catch return .io_failure;
    }
    // Another window still runs from `app\`: the update waits for the
    // next start.
    if (instance.exists(instance.app_mutex)) {
        log.line("zigguro is still running; nothing applied", .{});
        extra.append(arena, update_skipped) catch return .io_failure;
        if (a.relaunch != null) launch(io, arena, a.root, extra.items, log);
        return .app_running;
    }

    var root = Io.Dir.cwd().openDir(io, a.root, .{}) catch |err| {
        log.line("open {s}: {t}", .{ a.root, err });
        return .io_failure;
    };
    defer root.close(io);
    const now: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const plan: apply.Plan = .{ .mode = mode, .state_path = state, .crash_report = a.crash_report };
    var code: Exit = .ok;
    // The app hands over again unless it sees one of these flags.
    var flag: []const []const u8 = &.{update_skipped};
    if (apply.run(gpa, arena, io, root, plan, .windows, now, log.writer())) |r| {
        if (r.changed()) flag = arena.dupe([]const u8, &.{ switch (mode) {
            .apply => "--updated-from",
            .rollback => "--rolled-back-from",
        }, r.from }) catch return .io_failure;
        log.line("done: {s} -> {s}", .{ r.from, r.to });
    } else |err| {
        log.line("{t} failed: {t}", .{ mode, err });
        code = .io_failure;
    }
    extra.appendSlice(arena, flag) catch return .io_failure;
    // Relaunch whatever `app\` holds now, even after a failure.
    if (a.relaunch != null) launch(io, arena, a.root, extra.items, log);
    return code;
}

/// Uninstall, first stage: copy this helper to %TEMP% and start the copy,
/// which can then delete `<root>\app\` (this exe included).
fn uninstallStage1(io: Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, u: args_mod.Uninstall, log: *Log) Exit {
    if (builtin.os.tag != .windows) {
        log.line("uninstall is for Windows installs", .{});
        return .bad_arguments;
    }
    const self = std.process.executablePathAlloc(io, arena) catch return .io_failure;
    const root = u.root orelse uninstall.rootFromExeDir(std.fs.path.dirname(self) orelse "") orelse {
        log.line("{s} is not inside an install's app folder; pass --root", .{self});
        return .bad_arguments;
    };
    if (!uninstall.looksInstalled(io, root)) {
        log.line("{s} holds no install", .{root});
        if (!u.silent) ui.message(.failure, "zigguro is not installed here.");
        return .bad_arguments;
    }
    const tmp = env.get("TEMP") orelse env.get("TMP") orelse return .io_failure;
    var rnd: [4]u8 = undefined;
    io.random(&rnd);
    const copy = std.fmt.allocPrint(arena, "{s}\\{s}{x}.exe", .{ tmp, uninstall.temp_prefix, &rnd }) catch return .io_failure;
    Io.Dir.copyFileAbsolute(self, copy, io, .{}) catch |err| {
        log.line("copy {s} to {s}: {t}", .{ self, copy, err });
        return .io_failure;
    };
    var argv: std.ArrayList([]const u8) = .empty;
    const pid = std.fmt.allocPrint(arena, "{d}", .{win.currentPid()}) catch return .io_failure;
    argv.appendSlice(arena, &.{ copy, "--uninstall", "--stage2", "--root", root, "--parent-pid", pid }) catch return .io_failure;
    if (u.silent) argv.append(arena, "--silent") catch return .io_failure;
    if (u.remove_user_data) argv.append(arena, "--remove-user-data") catch return .io_failure;
    _ = std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        log.line("start {s}: {t}", .{ copy, err });
        return .io_failure;
    };
    log.line("uninstall: handed over to {s}", .{copy});
    return .ok;
}

/// Uninstall, second stage (the temporary copy).
fn uninstallStage2(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, u: args_mod.Uninstall, log: *Log) Exit {
    defer scheduleSelfDelete(io, arena, env, log);
    const root = u.root orelse return .bad_arguments;
    if (u.parent_pid) |pid| if (!win.waitForExit(pid, 10_000)) log.line("first stage {d} still running", .{pid});

    var remove_data = u.remove_user_data;
    if (!u.silent) {
        const q = std.fmt.allocPrint(arena, "Uninstall zigguro from {s}?", .{root}) catch return .io_failure;
        if (!ui.confirm(q)) return .cancelled;
        remove_data = ui.confirm("Also delete your zigguro settings and data?");
    }
    while (instance.exists(instance.app_mutex)) {
        log.line("zigguro is running", .{});
        if (u.silent) return .app_running;
        if (!ui.retry("zigguro is running. Close it to continue.")) return .cancelled;
    }

    var plan: uninstall.Plan = .{ .root = root };
    if (remove_data) {
        if (zg_config.paths.resolve(arena, env, .{})) |paths| {
            const d = uninstall.dataDirs(arena, paths) catch return .io_failure;
            plan.data_dirs = d.dirs;
            plan.empty_parents = d.parents;
        } else |err| log.line("user directories: {t}", .{err});
    }
    var shortcuts: std.ArrayList([]const u8) = .empty;
    inline for (.{ zg_install.win.known_folders.Folder.programs, zg_install.win.known_folders.Folder.desktop }) |f| {
        if (zg_install.win.known_folders.knownFolderPath(arena, f)) |dir| {
            shortcuts.append(arena, std.fs.path.join(arena, &.{ dir, zg_install.win.shortcut_name }) catch return .io_failure) catch return .io_failure;
        } else |_| {}
    }
    plan.shortcut_paths = shortcuts.items;

    var backend: zg_install.win.reg.Windows = .{ .gpa = gpa };
    uninstall.run(gpa, io, plan, backend.backend(), log.writer()) catch |err| {
        log.line("uninstall failed: {t}", .{err});
        if (!u.silent) ui.message(.failure, "zigguro could not be removed completely. Details are in %TEMP%\\zigguro-setup.log.");
        return switch (err) {
            error.NotInstalled => .bad_arguments,
            error.DeleteFailed, error.OutOfMemory => .io_failure,
        };
    };
    zg_install.win.path_env.notifyAssocChanged();
    zg_install.win.path_env.broadcastEnvironmentChange();
    if (!u.silent) ui.message(.info, "zigguro was uninstalled.");
    return .ok;
}

/// Has `cmd` delete this temporary copy once it has exited. Only for the
/// copy stage 1 made.
fn scheduleSelfDelete(io: Io, arena: std.mem.Allocator, env: *const std.process.Environ.Map, log: *Log) void {
    if (builtin.os.tag != .windows) return;
    const self = std.process.executablePathAlloc(io, arena) catch return;
    if (!std.mem.startsWith(u8, std.fs.path.basename(self), uninstall.temp_prefix)) return;
    const script = std.fmt.allocPrint(arena, "{s}.cmd", .{self[0 .. self.len - ".exe".len]}) catch return;
    var buf: [2048]u8 = undefined;
    const text = uninstall.cleanupScript(&buf, self) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = text }) catch |err| {
        log.line("write {s}: {t}", .{ script, err });
        return;
    };
    const cmd = env.get("ComSpec") orelse "cmd.exe";
    _ = std.process.spawn(io, .{ .argv = &.{ cmd, "/d", "/c", script }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true }) catch |err| {
        log.line("start {s}: {t}", .{ script, err });
    };
}

/// Starts `<root>\app\zigguro.exe args...` without waiting for it.
fn launch(io: Io, arena: std.mem.Allocator, root: []const u8, args: []const []const u8, log: *Log) void {
    const exe = std.fs.path.join(arena, &.{ root, "app", zg_install.win.registry.exe_name }) catch return;
    const argv = std.mem.concat(arena, []const u8, &.{ &.{exe}, args }) catch return;
    _ = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        log.line("launch {s}: {t}", .{ exe, err });
    };
}

/// A log file, appended; silently absent when it cannot be opened.
const Log = struct {
    file: ?Io.File,
    w: Io.File.Writer = undefined,

    /// `%TEMP%\zigguro-setup.log`.
    fn openTemp(io: Io, env: *const std.process.Environ.Map, buf: []u8) Log {
        const tmp = env.get("TEMP") orelse env.get("TMP") orelse env.get("TMPDIR") orelse return .{ .file = null };
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{c}zigguro-setup.log", .{ tmp, std.fs.path.sep }) catch return .{ .file = null };
        return open(io, path, buf);
    }

    fn open(io: Io, path: []const u8, buf: []u8) Log {
        const f = Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return .{ .file = null };
        var l: Log = .{ .file = f };
        l.w = f.writer(io, buf);
        const end = f.length(io) catch 0;
        l.w.seekTo(end) catch {};
        return l;
    }

    fn writer(l: *Log) ?*Io.Writer {
        return if (l.file != null) &l.w.interface else null;
    }

    fn line(l: *Log, comptime fmt: []const u8, args: anytype) void {
        const w = l.writer() orelse return;
        w.print(fmt ++ "\n", args) catch {};
        w.flush() catch {};
    }

    fn close(l: *Log, io: Io) void {
        if (l.file) |f| f.close(io);
    }
};

test {
    _ = apply;
    _ = args_mod;
    _ = install;
    _ = @import("zipcheck.zig");
    _ = uninstall;
}
