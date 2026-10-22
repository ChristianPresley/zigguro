//! The very-early update step (E17.F04.S02.T01/T02), after the runtime
//! starts and before any GPU or window init: a driver crash is the
//! likeliest failure of a new version, so the rollback decision must
//! come first.
//!
//! In a managed install (`<root>/app/zigguro`) it:
//! 1. finishes or undoes an interrupted swap and applies a staged
//!    update, then re-executes `app/` with `--updated-from <old>`;
//! 2. rolls back a pending version that failed to start twice or crashed
//!    while pending, then re-executes `app/` with `--rolled-back-from <v>`;
//! 3. records this start in `boot.zon` and sets the `boot_pending` crash
//!    annotation while the version is not yet healthy.
//!
//! On Windows the running executable lives inside `app/`, so for steps 1
//! and 2 it hands over to the setup helper instead: it copies the
//! zigguro-setup.exe of the version that will run next (`staged/` for an
//! update, `app.prev/` for a rollback, else `app/`) to `helper/`, starts
//! it with `--apply` and exits; the helper waits for this process to end,
//! swaps or rolls back and relaunches `app/` with the same flags as on
//! Linux, or with `--update-skipped` when nothing changed. Only the first
//! instance hands over, and never right after a handover.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const zg_crash = @import("zg_crash");
const zg_install = @import("zg_install");
const zg_release = @import("zg_release");
const zg_update = @import("zg_update");

const Io = std.Io;
const boot_health = zg_update.boot_health;
const swap = zg_update.swap;

/// What the rest of startup needs: the health tracker of a managed
/// install, or null.
pub const Boot = struct {
    arena: std.heap.ArenaAllocator,
    state_dir: ?Io.Dir = null,
    health: ?boot_health.BootHealth = null,

    pub fn deinit(b: *Boot, io: Io) void {
        if (b.state_dir) |*d| d.close(io);
        b.arena.deinit();
    }
};

/// Flags the update steps add to the app's command line.
pub const flags = struct {
    pub const updated_from = "--updated-from";
    pub const rolled_back_from = "--rolled-back-from";
    /// Windows: the helper ran but `app/` did not change.
    pub const update_skipped = "--update-skipped";

    /// Whether `a` is one of the flags; `value` when it takes one.
    pub fn match(a: []const u8) ?struct { value: bool } {
        if (std.mem.eql(u8, a, updated_from) or std.mem.eql(u8, a, rolled_back_from)) return .{ .value = true };
        if (std.mem.eql(u8, a, update_skipped)) return .{ .value = false };
        return null;
    }
};

/// Runs the early step. Does not return when it re-executes `app/` or
/// hands over to the Windows helper. `first_instance`: no other zigguro
/// process holds the app mutex.
pub fn run(rt: *zg_core.Runtime, min: std.process.Init.Minimal, first_instance: bool) Boot {
    var boot: Boot = .{ .arena = .init(rt.gpa) };
    runInner(rt.io, min, first_instance, &boot) catch |err| std.log.scoped(.update).warn("early update check: {t}", .{err});
    return boot;
}

fn runInner(io: Io, min: std.process.Init.Minimal, first_instance: bool, boot: *Boot) !void {
    const arena = boot.arena.allocator();
    const version = zg_release.current.version_string;
    const exe_path = try std.process.executablePathAlloc(io, arena);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return;
    const layout = zg_update.layout.detectInstall(io, exe_dir, builtin.os.tag, zg_release.current.distro);
    if (!layout.kind.managed()) return;

    var state_buf: [std.fs.max_path_bytes]u8 = undefined;
    const state_path = zg_crash.paths.stateDirAt(io, min.environ, &state_buf) orelse return;
    try Io.Dir.cwd().createDirPath(io, state_path);
    const state_dir = try Io.Dir.cwd().openDir(io, state_path, .{});
    boot.state_dir = state_dir;
    var root = try Io.Dir.cwd().openDir(io, layout.root, .{});
    defer root.close(io);

    var args: std.ArrayList([]const u8) = .empty;
    var it = try min.args.iterateAllocator(arena);
    while (it.next()) |a| try args.append(arena, try arena.dupe(u8, a));
    const updated_from = flagValue(args.items, flags.updated_from) != null;

    if (builtin.os.tag == .linux) {
        // 1. Swap in a staged update (recovering an interrupted one first).
        const outcome = try swap.applyStaged(arena, io, root, version, nowUnix(io));
        if (outcome == .applied or outcome == .recovered_forward) {
            try reexec(io, arena, layout.root, exe_path, args.items, "--updated-from", version);
        }
        // 2. Roll back a version that cannot start.
        const has_prev = exists(io, root, swap.prev);
        if (boot_health.early(io, state_dir, version, has_prev) == .rollback_now) {
            const prev_version = readPrevVersion(arena, io, root) orelse "previous";
            try boot_health.rollbackNow(arena, io, root, state_path, .{
                .from_version = version,
                .to_version = prev_version,
                .crash_report = newestCrashReport(arena, io, state_path),
            });
            try reexec(io, arena, layout.root, exe_path, args.items, "--rolled-back-from", version);
        }
    } else if (builtin.os.tag == .windows and first_instance) {
        const handed_over = for (args.items) |a| {
            if (flags.match(a) != null) break true;
        } else false;
        // 1. A staged update, or a swap that never finished.
        if (!handed_over and (zg_update.stage.readStaged(arena, io, root) != null or exists(io, root, zg_update.layout.names.journal))) {
            try handOver(io, arena, layout.root, root, args.items, .{});
        }
        // 2. A version that cannot start.
        if (boot_health.early(io, state_dir, version, exists(io, root, swap.prev)) == .rollback_now) {
            try handOver(io, arena, layout.root, root, args.items, .{ .rollback = true, .crash_report = newestCrashReport(arena, io, state_path) });
        }
    }

    // 3. Count this start.
    if (try boot_health.markAttempt(io, state_dir, version, updated_from, nowUnix(io))) {
        zg_crash.annotations.set("boot_pending", "1");
    }
    boot.health = .{ .io = io, .state_dir = state_dir, .version = version };
}

const Handover = struct {
    rollback: bool = false,
    crash_report: ?[]const u8 = null,
};

/// Windows: starts `<root>\helper\zigguro-setup.exe --apply` and exits
/// this process, which the helper waits for.
fn handOver(io: Io, arena: std.mem.Allocator, root_path: []const u8, root: Io.Dir, args: []const []const u8, h: Handover) !noreturn {
    const names = zg_update.layout.names;
    const setup = zg_install.win.registry.setup_name;
    // The next version's helper knows that version's layout.
    const sources: []const []const u8 = if (h.rollback) &.{ swap.prev, names.app } else &.{ names.staged, names.app };
    const from = for (sources) |dir| {
        const p = try std.fs.path.join(arena, &.{ dir, setup });
        if (exists(io, root, p)) break p;
    } else return error.NoSetupHelper;
    try root.createDirPath(io, helper_dir);
    const helper_rel = try std.fs.path.join(arena, &.{ helper_dir, setup });
    try root.copyFile(from, root, helper_rel, io, .{});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ try std.fs.path.join(arena, &.{ root_path, helper_rel }), "--apply", "--root", root_path, "--wait-pid", try std.fmt.allocPrint(arena, "{d}", .{currentPid()}) });
    if (h.rollback) try argv.append(arena, "--rollback");
    if (h.crash_report) |c| try argv.appendSlice(arena, &.{ "--crash-report", c });
    try argv.appendSlice(arena, &.{ "--relaunch", try zg_install.win.cmdline.join(arena, try userArgs(arena, args)) });
    _ = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    std.log.scoped(.update).info("handed over to {s}", .{argv.items[0]});
    std.process.exit(0);
}

/// Where the app puts the helper it hands over to.
pub const helper_dir = "helper";

fn currentPid() u32 {
    if (builtin.os.tag != .windows) return 0;
    return std.os.windows.GetCurrentProcessId();
}

/// `args` without the program name and the update flags.
fn userArgs(arena: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (flags.match(args[i])) |m| {
            if (m.value) i += 1;
            continue;
        }
        try out.append(arena, args[i]);
    }
    return out.items;
}

/// Replaces this process with `<root>/app/<exe name>`, passing the
/// original arguments (minus earlier update flags) plus `flag value`.
fn reexec(io: Io, arena: std.mem.Allocator, root: []const u8, exe_path: []const u8, args: []const []const u8, flag: []const u8, value: []const u8) !noreturn {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, try std.fs.path.join(arena, &.{ root, zg_update.layout.names.app, std.fs.path.basename(exe_path) }));
    try argv.appendSlice(arena, try userArgs(arena, args));
    try argv.appendSlice(arena, &.{ flag, value });
    const err = std.process.replace(io, .{ .argv = argv.items });
    return err;
}

fn flagValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |a, i| if (std.mem.eql(u8, a, name) and i + 1 < args.len) return args[i + 1];
    return null;
}

fn exists(io: Io, dir: Io.Dir, name: []const u8) bool {
    _ = dir.statFile(io, name, .{}) catch return false;
    return true;
}

fn nowUnix(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

/// The version in `app.prev/BUILDINFO.zon`, if readable.
fn readPrevVersion(arena: std.mem.Allocator, io: Io, root: Io.Dir) ?[]const u8 {
    const text = root.readFileAlloc(io, swap.prev ++ "/BUILDINFO.zon", arena, .limited(16 * 1024)) catch return null;
    const key = ".version = \"";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return null];
}

/// The newest `.zgcrash` report in `<state>/crashes`, if any.
fn newestCrashReport(arena: std.mem.Allocator, io: Io, state_path: []const u8) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const crash_path = zg_crash.paths.crashDir(state_path, &buf) orelse return null;
    var dir = Io.Dir.cwd().openDir(io, crash_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var best: ?[]const u8 = null;
    var best_ns: i96 = 0;
    var dit = dir.iterate();
    while (dit.next(io) catch null) |e| {
        if (!std.mem.endsWith(u8, e.name, ".zgcrash")) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        if (best == null or st.mtime.nanoseconds > best_ns) {
            best_ns = st.mtime.nanoseconds;
            best = std.fs.path.join(arena, &.{ crash_path, e.name }) catch continue;
        }
    }
    return best;
}

test "early_update_check: user arguments drop the update flags" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const args = [_][]const u8{ "zigguro", "--updated-from", "0.4.0", "x.zig", "--update-skipped", "--rolled-back-from", "0.5.0", "--new-window" };
    const out = try userArgs(arena.allocator(), &args);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("x.zig", out[0]);
    try std.testing.expectEqualStrings("--new-window", out[1]);
}

test "early_update_check: flag values" {
    const args = [_][]const u8{ "zigguro", "--updated-from", "0.4.0", "x.zig" };
    try std.testing.expectEqualStrings("0.4.0", flagValue(&args, "--updated-from").?);
    try std.testing.expect(flagValue(&args, "--rolled-back-from") == null);
}
