//! zigguro-setup.exe (E17.F02.S01.T03): the per-user Windows installer.
//! With an embedded payload it installs or upgrades; the helper copy in
//! `app\` (no payload) uninstalls and applies updates. See args.zig for
//! the command line and exit codes. Progress and errors go to
//! `%TEMP%\zigguro-setup.log`, appended in every mode.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const zg_install = @import("zg_install");
const args_mod = @import("args.zig");
const install = @import("install.zig");
const payload = @import("payload.zig");
const ui = @import("ui.zig");
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
    var log = Log.open(io, init.environ_map, &log_buf);
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
        .uninstall, .apply => {
            log.line("{t}: not available in this build", .{cmd});
            return .bad_arguments;
        },
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

    if (!a.silent and a.launch) launch(io, arena, root, log);
    return .ok;
}

/// Starts `<root>\app\zigguro.exe` without waiting for it.
fn launch(io: Io, arena: std.mem.Allocator, root: []const u8, log: *Log) void {
    const exe = std.fs.path.join(arena, &.{ root, "app", zg_install.win.registry.exe_name }) catch return;
    _ = std.process.spawn(io, .{ .argv = &.{exe}, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        log.line("launch {s}: {t}", .{ exe, err });
    };
}

/// `%TEMP%\zigguro-setup.log`, appended; silently absent when it cannot
/// be opened.
const Log = struct {
    file: ?Io.File,
    w: Io.File.Writer = undefined,

    fn open(io: Io, env: *const std.process.Environ.Map, buf: []u8) Log {
        const tmp = env.get("TEMP") orelse env.get("TMP") orelse env.get("TMPDIR") orelse return .{ .file = null };
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}{c}zigguro-setup.log", .{ tmp, std.fs.path.sep }) catch return .{ .file = null };
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
    _ = args_mod;
    _ = install;
    _ = @import("zipcheck.zig");
}
