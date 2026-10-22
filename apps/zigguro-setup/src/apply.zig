//! `zigguro-setup --apply` (E17.F04.S02.T01/T02 on Windows): the swap
//! and the rollback that the running app cannot do itself, because its
//! own executable lives in `app\`. The app copies a helper to
//! `<root>\helper\`, starts it and exits; once the app's process is gone
//! the helper runs this, then relaunches `app\zigguro.exe`.
//!
//! - `apply`: `zg_update.swap.applyStaged` (recovering an interrupted swap
//!   first). When the swap fails part way, `swap.recover` repairs `app\`
//!   and whatever is left of the staged update is discarded, so the
//!   relaunched app does not hand over again.
//! - `rollback`: `boot_health.rollbackNow` (`app` → `app.failed`,
//!   `app.prev` → `app`, plus the skip list and the toast note) when the
//!   state directory is known, else a bare `swap.rollback`.
//!
//! When `app\` changed, the receipt's version and the Apps & features
//! entry follow. Free of UI and of the real registry, like install.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_install = @import("zg_install");
const zg_update = @import("zg_update");
const install = @import("install.zig");
const names = zg_update.layout.names;

pub const Mode = enum { apply, rollback };

pub const Plan = struct {
    mode: Mode,
    /// The app's state directory, for the rollback bookkeeping.
    state_path: ?[]const u8 = null,
    /// The crash report that triggered a rollback, for the toast.
    crash_report: ?[]const u8 = null,
};

pub const Result = struct {
    /// The version `app\` held before.
    from: []const u8,
    /// The version `app\` holds now.
    to: []const u8,

    pub fn changed(r: Result) bool {
        return !std.mem.eql(u8, r.from, r.to);
    }
};

pub const Error = error{
    /// Rollback without an `app.prev\`.
    NoPreviousVersion,
    /// The swap failed and `app\` could not be repaired.
    SwapFailed,
    OutOfMemory,
};

const unknown = "unknown";

/// Runs `plan` on the install at `root`. Strings go to `arena`.
pub fn run(gpa: Allocator, arena: Allocator, io: Io, root: Io.Dir, plan: Plan, integration: install.Integration, now_unix: i64, log: ?*Io.Writer) Error!Result {
    const old = zg_install.Receipt.load(arena, io, root) catch null;
    const from = buildVersion(arena, io, root, names.app) orelse if (old) |r| r.version else unknown;

    switch (plan.mode) {
        .apply => {
            if (zg_update.swap.applyStaged(arena, io, root, from, now_unix)) |outcome| {
                line(log, "swap: {t}", .{outcome});
            } else |err| {
                line(log, "swap: {t}", .{err});
                const repaired = zg_update.swap.recover(arena, io, root) catch |e| {
                    line(log, "recover: {t}", .{e});
                    return error.SwapFailed;
                };
                if (repaired) |o| line(log, "recover: {t}", .{o});
                // Never hand the same broken update back to the app.
                install.discardStaged(io, root);
            }
        },
        .rollback => {
            const prev_version = buildVersion(arena, io, root, names.prev) orelse unknown;
            if (plan.state_path) |state| {
                zg_update.boot_health.rollbackNow(arena, io, root, state, .{ .from_version = from, .to_version = prev_version, .crash_report = plan.crash_report }) catch |err| {
                    line(log, "rollback: {t}", .{err});
                    return if (err == error.NoPreviousVersion) error.NoPreviousVersion else error.SwapFailed;
                };
            } else zg_update.swap.rollback(io, root) catch |err| {
                line(log, "rollback: {t}", .{err});
                return if (err == error.NoPreviousVersion) error.NoPreviousVersion else error.SwapFailed;
            };
        },
    }

    if (root.statFile(io, names.app, .{})) |_| {} else |_| return error.SwapFailed;
    const to = buildVersion(arena, io, root, names.app) orelse unknown;
    const result: Result = .{ .from = from, .to = to };
    if (!result.changed()) return result;
    line(log, "{t}: {s} -> {s}", .{ plan.mode, from, to });

    if (old) |r| {
        const size_kib = install.dirSizeKib(io, root, names.app);
        integration.update_version(integration.ctx, gpa, r.app_id, to, size_kib) catch |err| line(log, "update DisplayVersion: {t}", .{err});
        var receipt = r;
        receipt.version = to;
        receipt.store(gpa, io, root) catch |err| line(log, "write receipt: {t}", .{err});
    }
    return result;
}

/// The `.version` in `<sub>\BUILDINFO.zon`, if readable.
pub fn buildVersion(arena: Allocator, io: Io, root: Io.Dir, comptime sub: []const u8) ?[]const u8 {
    const text = root.readFileAlloc(io, sub ++ "/BUILDINFO.zon", arena, .limited(16 * 1024)) catch return null;
    const key = ".version = \"";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return null];
}

fn line(log: ?*Io.Writer, comptime fmt: []const u8, args: anytype) void {
    const w = log orelse return;
    w.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
}

const testing = std.testing;

/// An installed 0.5.0 with a staged 0.6.0 (staged by hand: the
/// download pipeline has its own tests).
fn installWithStaged(gpa: Allocator, io: Io, root_path: []const u8, mem: *install.MemoryIntegration) !void {
    const zip = try install.testZip(gpa, "0.5.0", "MZ v5");
    defer gpa.free(zip);
    var cancel: std.atomic.Value(bool) = .init(false);
    const out = try install.run(gpa, io, .{ .root = root_path, .opts = .{}, .version = "0.5.0", .target = "x86_64-windows", .silent = true }, zip, .{}, &cancel, mem.integration(), null);
    if (out.previous_version) |v| gpa.free(v);
    var root = try Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);
    try root.createDirPath(io, names.staged);
    try root.writeFile(io, .{ .sub_path = names.staged ++ "/BUILDINFO.zon", .data = ".{ .version = \"0.6.0\", .target = \"x86_64-windows\" }\n" });
    try root.writeFile(io, .{ .sub_path = names.staged ++ "/zigguro.exe", .data = "MZ v6" });
    try root.writeFile(io, .{ .sub_path = names.staged_zon, .data = ".{ .version = \"0.6.0\", .sha256 = \"00\", .serial = 6, .staged_at = 1 }\n" });
}

test "apply: swaps the staged version in and updates receipt and registry" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root_path = try install.tmpRoot(a, &tmp);
    var mem: install.MemoryIntegration = .{ .reg = .init(gpa) };
    defer mem.reg.deinit();
    try installWithStaged(gpa, testing.io, root_path, &mem);

    var root = try Io.Dir.cwd().openDir(testing.io, root_path, .{});
    defer root.close(testing.io);
    const r = try run(gpa, a, testing.io, root, .{ .mode = .apply }, mem.integration(), 2, null);
    try testing.expectEqualStrings("0.5.0", r.from);
    try testing.expectEqualStrings("0.6.0", r.to);
    try testing.expectEqualStrings("MZ v6", try root.readFileAlloc(testing.io, "app/zigguro.exe", a, .limited(64)));
    try testing.expectEqualStrings("MZ v5", try root.readFileAlloc(testing.io, "app.prev/zigguro.exe", a, .limited(64)));
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, names.staged_zon, .{}));
    try testing.expectEqualStrings("0.6.0", (try zg_install.Receipt.load(a, testing.io, root)).version);
    const un = zg_install.win.registry.uninstall_root ++ "dev.zigguro.zigguro";
    try testing.expectEqualStrings("0.6.0", (try mem.reg.backend().getValue(a, un, "DisplayVersion")).?.sz);

    // Nothing staged: nothing changes.
    const again = try run(gpa, a, testing.io, root, .{ .mode = .apply }, mem.integration(), 3, null);
    try testing.expect(!again.changed());
}

test "apply: a swap that fails part way is repaired and the update discarded" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root_path = try install.tmpRoot(a, &tmp);
    var mem: install.MemoryIntegration = .{ .reg = .init(gpa) };
    defer mem.reg.deinit();
    var root_dir: ?Io.Dir = null;
    defer if (root_dir) |*d| d.close(testing.io);

    // Before anything moved: the old version stays, the update goes.
    try installWithStaged(gpa, testing.io, root_path, &mem);
    root_dir = try Io.Dir.cwd().openDir(testing.io, root_path, .{});
    const root = root_dir.?;
    zg_update.swap.test_failpoint = .after_begin;
    defer zg_update.swap.test_failpoint = null;
    const r = try run(gpa, a, testing.io, root, .{ .mode = .apply }, mem.integration(), 2, null);
    try testing.expect(!r.changed());
    try testing.expectEqualStrings("MZ v5", try root.readFileAlloc(testing.io, "app/zigguro.exe", a, .limited(64)));
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, names.staged, .{}));
    try testing.expectError(error.FileNotFound, root.statFile(testing.io, names.journal, .{}));

    // After `app` moved aside: the intact staged version is finished.
    try root.createDirPath(testing.io, names.staged);
    try root.writeFile(testing.io, .{ .sub_path = names.staged ++ "/BUILDINFO.zon", .data = ".{ .version = \"0.6.0\" }\n" });
    try root.writeFile(testing.io, .{ .sub_path = names.staged ++ "/zigguro.exe", .data = "MZ v6" });
    try root.writeFile(testing.io, .{ .sub_path = names.staged_zon, .data = ".{ .version = \"0.6.0\", .sha256 = \"00\", .serial = 6, .staged_at = 1 }\n" });
    zg_update.swap.test_failpoint = .after_app_to_prev;
    const fwd = try run(gpa, a, testing.io, root, .{ .mode = .apply }, mem.integration(), 3, null);
    try testing.expectEqualStrings("0.6.0", fwd.to);
    try testing.expectEqualStrings("MZ v6", try root.readFileAlloc(testing.io, "app/zigguro.exe", a, .limited(64)));
    try testing.expectEqualStrings("0.6.0", (try zg_install.Receipt.load(a, testing.io, root)).version);
}

test "apply: rollback restores app.prev and records it" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root_path = try install.tmpRoot(a, &tmp);
    var mem: install.MemoryIntegration = .{ .reg = .init(gpa) };
    defer mem.reg.deinit();
    try installWithStaged(gpa, testing.io, root_path, &mem);
    var root = try Io.Dir.cwd().openDir(testing.io, root_path, .{});
    defer root.close(testing.io);
    _ = try run(gpa, a, testing.io, root, .{ .mode = .apply }, mem.integration(), 2, null);

    try tmp.dir.createDirPath(testing.io, "state");
    const state = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(testing.io, ".", a), "state" });
    const r = try run(gpa, a, testing.io, root, .{ .mode = .rollback, .state_path = state, .crash_report = "C:\\crash.zgcrash" }, mem.integration(), 3, null);
    try testing.expectEqualStrings("0.6.0", r.from);
    try testing.expectEqualStrings("0.5.0", r.to);
    try testing.expectEqualStrings("MZ v5", try root.readFileAlloc(testing.io, "app/zigguro.exe", a, .limited(64)));
    try testing.expectEqualStrings("MZ v6", try root.readFileAlloc(testing.io, "app.failed/zigguro.exe", a, .limited(64)));
    try testing.expectEqualStrings("0.5.0", (try zg_install.Receipt.load(a, testing.io, root)).version);
    var sd = try tmp.dir.openDir(testing.io, "state", .{});
    defer sd.close(testing.io);
    const info = (try zg_update.boot_health.takeRollbackInfo(a, testing.io, sd)).?;
    try testing.expectEqualStrings("0.6.0", info.from_version);
    try testing.expectEqualStrings("C:\\crash.zgcrash", info.crash_report.?);

    // No app.prev left.
    try testing.expectError(error.NoPreviousVersion, run(gpa, a, testing.io, root, .{ .mode = .rollback }, mem.integration(), 4, null));
}
