//! The install flow (E17.F02.S01.T03), free of UI and of the real
//! registry so it runs on every OS in tests:
//!
//! 1. Check free space (three times the payload) on the install volume.
//! 2. Write the payload to `<root>\staged.download\` and stage it with
//!    `zg_update.stage`: extract, check `BUILDINFO.zon` against the
//!    expected version and target, move its top directory to `staged\`.
//! 3. Swap it in with `zg_update.swap.applyStaged`, which recovers an
//!    interrupted earlier swap first; an existing `app\` becomes
//!    `app.prev\`.
//! 4. A fresh install integrates (registry, PATH, shortcuts) and writes
//!    the receipt; an upgrade keeps the receipt's actions and updates its
//!    version and the Apps & features entry.
//!
//! Cancelling before the swap leaves any existing install untouched.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_install = @import("zg_install");
const zg_update = @import("zg_update");
const zg_release = @import("zg_release");
const registry = zg_install.win.registry;
const names = zg_update.layout.names;
const zipcheck = @import("zipcheck.zig");

pub const Plan = struct {
    /// Absolute install root.
    root: []const u8,
    opts: zg_install.InstallOptions,
    version: []const u8,
    target: []const u8,
    silent: bool,
};

/// Progress from the worker. `permille` runs 0..1000.
pub const Progress = struct {
    ctx: ?*anyopaque = null,
    report: *const fn (ctx: ?*anyopaque, permille: u16, label: []const u8) void = noReport,

    fn noReport(_: ?*anyopaque, _: u16, _: []const u8) void {}
};

/// The desktop integration: `zg_install.win` on Windows, an in-memory
/// registry in tests.
pub const Integration = struct {
    ctx: ?*anyopaque = null,
    integrate: *const fn (ctx: ?*anyopaque, gpa: Allocator, io: Io, rc: registry.Context, opts: zg_install.InstallOptions, rb: *zg_install.ReceiptBuilder) anyerror!void,
    update_version: *const fn (ctx: ?*anyopaque, gpa: Allocator, app_id: []const u8, version: []const u8, size_kib: u32) anyerror!void,

    /// The real one; `error.Unsupported` off Windows.
    pub const windows: Integration = .{ .integrate = realIntegrate, .update_version = realUpdateVersion };

    fn realIntegrate(_: ?*anyopaque, gpa: Allocator, io: Io, rc: registry.Context, opts: zg_install.InstallOptions, rb: *zg_install.ReceiptBuilder) anyerror!void {
        try zg_install.win.integrate(gpa, io, rc, opts, rb);
    }

    fn realUpdateVersion(_: ?*anyopaque, gpa: Allocator, app_id: []const u8, version: []const u8, size_kib: u32) anyerror!void {
        if (@import("builtin").os.tag != .windows) return error.Unsupported;
        var backend: zg_install.win.reg.Windows = .{ .gpa = gpa };
        try registry.updateDisplayVersion(backend.backend(), app_id, version, size_kib);
    }
};

pub const InstallError = error{
    Cancelled,
    /// Not enough free space on the install volume.
    NoSpace,
    /// The embedded zip is damaged or is not the expected build.
    PayloadCorrupt,
    /// A file system or registry step failed; see the log.
    InstallFailed,
    OutOfMemory,
};

pub const Outcome = struct {
    /// An earlier version was replaced (now in `app.prev\`).
    upgraded: bool,
    /// The version the upgrade replaced, if known.
    previous_version: ?[]const u8 = null,
};

/// Where the payload is written before staging.
const payload_name = "setup-payload.zip";

/// The install root: `dir`, else `%LOCALAPPDATA%\Programs\zigguro`. Null
/// when neither is known (the caller then asks the shell for
/// `FOLDERID_UserProgramFiles`).
pub fn resolveRoot(arena: Allocator, env: *const std.process.Environ.Map, dir: ?[]const u8) Allocator.Error!?[]const u8 {
    if (dir) |d| return try arena.dupe(u8, std.mem.trimEnd(u8, d, "\\/"));
    const local = env.get("LOCALAPPDATA") orelse return null;
    if (local.len == 0) return null;
    return try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, local, "\\"), "\\Programs\\zigguro" });
}

/// `YYYYMMDD` (UTC) for `unix`.
pub fn installDate(buf: *[8]u8, unix: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(unix, 0)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}", .{ yd.year, md.month.numeric(), @as(u32, md.day_index) + 1 }) catch unreachable;
}

/// Installs `payload` into `plan.root`. `cancel` is honoured until the
/// swap starts.
pub fn run(
    gpa: Allocator,
    io: Io,
    plan: Plan,
    payload: []const u8,
    progress: Progress,
    cancel: *const std.atomic.Value(bool),
    integration: Integration,
    log: ?*Io.Writer,
) InstallError!Outcome {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const L = struct {
        fn line(w: ?*Io.Writer, comptime fmt: []const u8, args: anytype) void {
            const out = w orelse return;
            out.print(fmt ++ "\n", args) catch {};
            out.flush() catch {};
        }
    };
    const now = Io.Clock.real.now(io).toSeconds();

    progress.report(progress.ctx, 0, "Preparing");
    L.line(log, "install {s} ({s}) into {s}", .{ plan.version, plan.target, plan.root });
    Io.Dir.cwd().createDirPath(io, plan.root) catch |err| {
        L.line(log, "create {s}: {t}", .{ plan.root, err });
        return error.InstallFailed;
    };
    var root = Io.Dir.cwd().openDir(io, plan.root, .{ .iterate = true }) catch |err| {
        L.line(log, "open {s}: {t}", .{ plan.root, err });
        return error.InstallFailed;
    };
    defer root.close(io);

    if (!zg_update.disk.enoughFor(zg_update.disk.freeBytes(arena, plan.root), payload.len)) {
        L.line(log, "not enough free space for {d} bytes x3", .{payload.len});
        return error.NoSpace;
    }
    if (cancel.load(.acquire)) return error.Cancelled;

    // 2. Stage.
    progress.report(progress.ctx, 100, "Extracting");
    // The payload goes next to the install, so the extracted tree moves
    // into place with same-volume renames.
    const sub = std.fs.path.join(arena, &.{ names.download, payload_name }) catch return error.OutOfMemory;
    root.createDirPath(io, names.download) catch |err| {
        L.line(log, "create {s}: {t}", .{ names.download, err });
        return error.InstallFailed;
    };
    root.writeFile(io, .{ .sub_path = sub, .data = payload }) catch |err| {
        L.line(log, "write payload: {t}", .{err});
        return error.InstallFailed;
    };
    verifyPayload(io, root, sub) catch |err| {
        L.line(log, "payload check: {t}", .{err});
        root.deleteFile(io, sub) catch {};
        return if (corrupt(err)) error.PayloadCorrupt else error.InstallFailed;
    };
    if (cancel.load(.acquire)) {
        root.deleteFile(io, sub) catch {};
        return error.Cancelled;
    }
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &sha, .{});
    zg_update.stage.stage(arena, io, root, payload_name, .{ .version = plan.version, .target = plan.target, .sha256 = sha, .serial = 0, .now_unix = now }) catch |err| {
        L.line(log, "stage: {t}", .{err});
        root.deleteFile(io, sub) catch {};
        return if (corrupt(err)) error.PayloadCorrupt else error.InstallFailed;
    };
    root.deleteDir(io, names.download) catch {};
    if (cancel.load(.acquire)) {
        discardStaged(io, root);
        return error.Cancelled;
    }

    // 3. Swap.
    progress.report(progress.ctx, 600, "Installing");
    const old = zg_install.Receipt.load(arena, io, root) catch null;
    // `statFile`, not `access`: Zig 0.16's Windows `access` misses
    // directories under Wine.
    const had_app = if (root.statFile(io, names.app, .{})) |_| true else |_| false;
    _ = zg_update.swap.applyStaged(arena, io, root, if (old) |r| r.version else "", now) catch |err| {
        L.line(log, "swap: {t}", .{err});
        return error.InstallFailed;
    };
    const size_kib = dirSizeKib(io, root, names.app);

    // 4. Integrate and write the receipt.
    progress.report(progress.ctx, 800, "Registering");
    const p = zg_release.product;
    var receipt: zg_install.Receipt = undefined;
    if (old) |r| {
        integration.update_version(integration.ctx, gpa, p.app_id, plan.version, size_kib) catch |err| L.line(log, "update DisplayVersion: {t}", .{err});
        receipt = r;
        receipt.version = plan.version;
    } else {
        var date_buf: [8]u8 = undefined;
        var rb: zg_install.ReceiptBuilder = .{ .arena = arena };
        const rc: registry.Context = .{ .root = plan.root, .version = plan.version, .install_date = installDate(&date_buf, now), .estimated_size_kib = size_kib };
        integration.integrate(integration.ctx, gpa, io, rc, plan.opts, &rb) catch |err| {
            // Keep what was done in the receipt so uninstall can undo it.
            L.line(log, "integrate: {t}", .{err});
            writeReceipt(gpa, io, root, .{ .app_id = p.app_id, .version = plan.version, .root = plan.root, .installed_at_unix = now, .options = plan.opts, .actions = rb.actions.items }, log);
            return error.InstallFailed;
        };
        receipt = .{ .app_id = p.app_id, .version = plan.version, .root = plan.root, .installed_at_unix = now, .options = plan.opts, .actions = rb.actions.items };
    }
    writeReceipt(gpa, io, root, receipt, log);
    progress.report(progress.ctx, 1000, "Done");
    L.line(log, "installed {s}{s}", .{ plan.version, if (had_app) " (upgrade)" else "" });
    return .{ .upgraded = had_app, .previous_version = if (old) |r| gpa.dupe(u8, r.version) catch null else null };
}

fn verifyPayload(io: Io, root: Io.Dir, sub: []const u8) !void {
    const f = try root.openFile(io, sub, .{});
    defer f.close(io);
    try zipcheck.verify(io, f);
}

fn writeReceipt(gpa: Allocator, io: Io, root: Io.Dir, r: zg_install.Receipt, log: ?*Io.Writer) void {
    r.store(gpa, io, root) catch |err| if (log) |w| {
        w.print("write receipt: {t}\n", .{err}) catch {};
        w.flush() catch {};
    };
}

/// True for errors that mean the payload itself is bad.
fn corrupt(err: anyerror) bool {
    inline for (@typeInfo(zg_update.stage.Error).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return true;
    }
    const n = @errorName(err);
    return std.mem.startsWith(u8, n, "Zip") or std.mem.eql(u8, n, "EndOfStream") or std.mem.eql(u8, n, "BadCrc") or std.mem.eql(u8, n, "ReadFailed");
}

/// Removes a staged payload (after a cancel or a failed update).
pub fn discardStaged(io: Io, root: Io.Dir) void {
    root.deleteFile(io, names.staged_zon) catch {};
    root.deleteTree(io, names.staged) catch {};
}

/// The size of `sub` in KiB (Apps & features "EstimatedSize").
pub fn dirSizeKib(io: Io, root: Io.Dir, sub: []const u8) u32 {
    var dir = root.openDir(io, sub, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    var walker = dir.walk(fba.allocator()) catch return 0;
    defer walker.deinit();
    var total: u64 = 0;
    while (walker.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const st = e.dir.statFile(io, e.basename, .{}) catch continue;
        total += st.size;
    }
    return @intCast(@min(total / 1024, std.math.maxInt(u32)));
}

const testing = std.testing;

/// Tests: an integration on an in-memory registry.
pub const MemoryIntegration = struct {
    reg: zg_install.win.reg.Memory,
    integrated: usize = 0,

    pub fn integration(m: *MemoryIntegration) Integration {
        return .{ .ctx = m, .integrate = integrate, .update_version = updateVersion };
    }

    fn integrate(ctx: ?*anyopaque, gpa: Allocator, _: Io, rc: registry.Context, opts: zg_install.InstallOptions, rb: *zg_install.ReceiptBuilder) anyerror!void {
        const m: *MemoryIntegration = @ptrCast(@alignCast(ctx.?));
        m.integrated += 1;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try registry.integrateRegistry(m.reg.backend(), arena.allocator(), rc, opts, rb);
    }

    fn updateVersion(ctx: ?*anyopaque, _: Allocator, app_id: []const u8, version: []const u8, size_kib: u32) anyerror!void {
        const m: *MemoryIntegration = @ptrCast(@alignCast(ctx.?));
        try registry.updateDisplayVersion(m.reg.backend(), app_id, version, size_kib);
    }
};

/// Tests: a release-shaped zip: `<top>/BUILDINFO.zon` and `<top>/zigguro.exe`.
pub fn testZip(gpa: Allocator, version: []const u8, exe: []const u8) ![]u8 {
    const top = try std.fmt.allocPrint(gpa, "zigguro-{s}-x86_64-windows", .{version});
    defer gpa.free(top);
    const info = try std.fmt.allocPrint(gpa, ".{{ .version = \"{s}\", .target = \"x86_64-windows\" }}\n", .{version});
    defer gpa.free(info);
    const p1 = try std.fmt.allocPrint(gpa, "{s}/BUILDINFO.zon", .{top});
    defer gpa.free(p1);
    const p2 = try std.fmt.allocPrint(gpa, "{s}/zigguro.exe", .{top});
    defer gpa.free(p2);
    return zipcheck.testZip(gpa, &.{ .{ p1, info }, .{ p2, exe } }, .store);
}

/// Tests: a non-ASCII install root inside `tmp`.
pub fn tmpRoot(a: Allocator, tmp: *testing.TmpDir) ![]const u8 {
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    return std.fs.path.join(a, &.{ dir, "zïggürø" });
}

test "install: plan resolution from env map" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expect(try resolveRoot(a, &env, null) == null);
    try env.put("LOCALAPPDATA", "C:\\Users\\zïg\\AppData\\Local\\");
    try testing.expectEqualStrings("C:\\Users\\zïg\\AppData\\Local\\Programs\\zigguro", (try resolveRoot(a, &env, null)).?);
    try testing.expectEqualStrings("D:\\Tools\\zg", (try resolveRoot(a, &env, "D:\\Tools\\zg\\")).?);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("20261022", installDate(&buf, 1_793_000_000 - 4 * 86400));
}

test "install: fresh install flattens the top dir, integrates and writes the receipt" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = try tmpRoot(arena.allocator(), &tmp);
    const zip = try testZip(gpa, "0.5.0+gabc", "MZ v5");
    defer gpa.free(zip);
    var mem: MemoryIntegration = .{ .reg = .init(gpa) };
    defer mem.reg.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    const plan: Plan = .{ .root = root, .opts = .{}, .version = "0.5.0+gabc", .target = "x86_64-windows", .silent = true };
    const out = try run(gpa, testing.io, plan, zip, .{}, &cancel, mem.integration(), null);
    try testing.expect(!out.upgraded and out.previous_version == null);
    try testing.expectEqual(@as(usize, 1), mem.integrated);

    var rd = try tmp.dir.openDir(testing.io, "zïggürø", .{});
    defer rd.close(testing.io);
    const exe = try rd.readFileAlloc(testing.io, "app/zigguro.exe", arena.allocator(), .limited(64));
    try testing.expectEqualStrings("MZ v5", exe);
    _ = try rd.statFile(testing.io, "app/BUILDINFO.zon", .{});
    try testing.expectError(error.FileNotFound, rd.statFile(testing.io, names.staged, .{}));
    try testing.expectError(error.FileNotFound, rd.statFile(testing.io, names.download, .{}));
    const r = try zg_install.Receipt.load(arena.allocator(), testing.io, rd);
    try testing.expectEqualStrings("0.5.0+gabc", r.version);
    try testing.expectEqualStrings(root, r.root);
    try testing.expect(r.actions.len > 5);
    const path_key = zg_install.win.path_env;
    const path = (try mem.reg.backend().getValue(arena.allocator(), path_key.key, path_key.value_name)).?;
    try testing.expect(std.mem.endsWith(u8, path.expand_sz, "\\app"));
}

test "install: upgrade keeps app.prev, the receipt's actions, and updates versions" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmpRoot(a, &tmp);
    var mem: MemoryIntegration = .{ .reg = .init(gpa) };
    defer mem.reg.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    inline for (.{ "0.5.0", "0.6.0" }, .{ "MZ v5", "MZ v6" }) |v, body| {
        const zip = try testZip(gpa, v, body);
        defer gpa.free(zip);
        const out = try run(gpa, testing.io, .{ .root = root, .opts = .{}, .version = v, .target = "x86_64-windows", .silent = true }, zip, .{}, &cancel, mem.integration(), null);
        defer if (out.previous_version) |pv| gpa.free(pv);
        try testing.expectEqual(comptime std.mem.eql(u8, v, "0.6.0"), out.upgraded);
        if (out.upgraded) try testing.expectEqualStrings("0.5.0", out.previous_version.?);
    }
    try testing.expectEqual(@as(usize, 1), mem.integrated);
    var rd = try tmp.dir.openDir(testing.io, "zïggürø", .{});
    defer rd.close(testing.io);
    try testing.expectEqualStrings("MZ v6", try rd.readFileAlloc(testing.io, "app/zigguro.exe", a, .limited(64)));
    try testing.expectEqualStrings("MZ v5", try rd.readFileAlloc(testing.io, "app.prev/zigguro.exe", a, .limited(64)));
    const r = try zg_install.Receipt.load(a, testing.io, rd);
    try testing.expectEqualStrings("0.6.0", r.version);
    try testing.expect(r.actions.len > 5);
    const un = registry.uninstall_root ++ "dev.zigguro.zigguro";
    try testing.expectEqualStrings("0.6.0", (try mem.reg.backend().getValue(a, un, "DisplayVersion")).?.sz);
}

test "install: corrupt or mismatched payload, cancel before the swap" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = try tmpRoot(arena.allocator(), &tmp);
    var mem: MemoryIntegration = .{ .reg = .init(gpa) };
    defer mem.reg.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    const plan: Plan = .{ .root = root, .opts = .{}, .version = "0.5.0", .target = "x86_64-windows", .silent = true };
    try testing.expectError(error.PayloadCorrupt, run(gpa, testing.io, plan, "PK\x03\x04 not a zip", .{}, &cancel, mem.integration(), null));
    const zip = try testZip(gpa, "0.4.0", "MZ");
    defer gpa.free(zip);
    try testing.expectError(error.PayloadCorrupt, run(gpa, testing.io, plan, zip, .{}, &cancel, mem.integration(), null));
    // A damaged byte in the stored data fails the CRC.
    const good = try testZip(gpa, "0.5.0", "MZ payload");
    defer gpa.free(good);
    const bad = try gpa.dupe(u8, good);
    defer gpa.free(bad);
    bad[std.mem.indexOf(u8, bad, "MZ payload").?] = 'X';
    try testing.expectError(error.PayloadCorrupt, run(gpa, testing.io, plan, bad, .{}, &cancel, mem.integration(), null));

    cancel.store(true, .release);
    try testing.expectError(error.Cancelled, run(gpa, testing.io, plan, good, .{}, &cancel, mem.integration(), null));
    var rd = try tmp.dir.openDir(testing.io, "zïggürø", .{});
    defer rd.close(testing.io);
    try testing.expectError(error.FileNotFound, rd.statFile(testing.io, names.app, .{}));
    try testing.expectError(error.FileNotFound, rd.statFile(testing.io, names.staged, .{}));
    try testing.expectEqual(@as(usize, 0), mem.integrated);
}
