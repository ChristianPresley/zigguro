//! The update pipeline (E17.F04.S01.T02): check the feed, decide with
//! `verify.decide`, download, stage, and report a `Status` the UI and
//! `zg update` read.
//!
//! `check` runs the whole pipeline synchronously (the CLI, tests);
//! `checkNow` runs it as a background task and `start` keeps the
//! automatic schedule (`schedule.zig`). Nothing here ever runs on the UI
//! thread. With `update.mode = none` or a disabling policy, the HTTP
//! client is never created.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_net = @import("zg_net");
const zg_release = @import("zg_release");
const verify = @import("verify.zig");
const state_mod = @import("state.zig");
const layout_mod = @import("layout.zig");
const fetch = @import("fetch.zig");
const download = @import("download.zig");
const stage = @import("stage.zig");
const schedule = @import("schedule.zig");
const disk = @import("disk.zig");

const names = layout_mod.names;

/// `update.mode`.
pub const Mode = enum { automatic, manual, none };

/// Why updates are off.
pub const DisabledReason = enum { setting, policy, distro, no_feed };

/// What is known about an offered update. Fixed-size, so a `Status` is a
/// plain value.
pub const Info = struct {
    version_buf: [64]u8 = undefined,
    version_len: u8 = 0,
    notes_buf: [256]u8 = undefined,
    notes_len: u16 = 0,
    summary_buf: [256]u8 = undefined,
    summary_len: u16 = 0,
    critical: bool = false,
    size: u64 = 0,

    pub fn version(i: *const Info) []const u8 {
        return i.version_buf[0..i.version_len];
    }
    pub fn notesUrl(i: *const Info) []const u8 {
        return i.notes_buf[0..i.notes_len];
    }
    pub fn summary(i: *const Info) []const u8 {
        return i.summary_buf[0..i.summary_len];
    }

    fn from(o: verify.Offer) Info {
        var i: Info = .{ .critical = o.critical, .size = o.artifact.size };
        i.version_len = @intCast(copy(&i.version_buf, o.version_text));
        i.notes_len = @intCast(copy(&i.notes_buf, o.notes_url));
        i.summary_len = @intCast(copy(&i.summary_buf, o.summary));
        return i;
    }

    fn copy(dst: []u8, src: []const u8) usize {
        const n = @min(dst.len, src.len);
        @memcpy(dst[0..n], src[0..n]);
        return n;
    }
};

/// A failed check.
pub const Failure = struct {
    err: anyerror,
    /// A network error: the schedule retries with backoff. Verification
    /// errors wait for the next scheduled check.
    network: bool,
};

pub const Status = union(enum) {
    idle,
    checking,
    up_to_date,
    /// An update exists but this install does not download it (portable,
    /// unmanaged) or no room is left on the volume.
    available: Info,
    /// Bytes so far are in `Updater.progress`.
    downloading: Info,
    /// Staged under `<root>/staged/`; applies on restart.
    ready: Info,
    failed: Failure,
    disabled: DisabledReason,
};

pub const Config = struct {
    mode: Mode = .automatic,
    /// E16 policy forces updates off.
    policy_disabled: bool = false,
    channel: []const u8,
    /// Feed URL templates (`{channel}`), the setting or policy first.
    feed_urls: []const []const u8,
    layout: layout_mod.Layout,
    keys: []const zg_release.minisign.PublicKey,
    current: zg_release.Version,
    /// `BuildInfo.target`, e.g. "x86_64-linux-gnu.2.28".
    target: []const u8,
    build_epoch: i64,
    /// Directory of `update.zon` (the persisted `state.State`).
    state_dir: []const u8,
    fetch: fetch.Options = .{},
    /// False stops at `available` (`zg update check`).
    download: bool = true,
};

/// Creates the HTTP client on first use; never called when updates are
/// off.
pub const HttpSource = struct {
    ctx: ?*anyopaque,
    get: *const fn (?*anyopaque) anyerror!*zg_net.http.Client,
};

pub const Subscriber = struct {
    ctx: ?*anyopaque,
    func: *const fn (?*anyopaque, Status) void,
};

pub const max_subscribers = 8;
/// File name of the persisted state in `Config.state_dir`.
pub const state_file = "update.zon";

pub const Updater = struct {
    gpa: Allocator,
    io: Io,
    cfg: Config,
    http_src: HttpSource,
    mutex: Io.Mutex = .init,
    current: Status = .idle,
    subs: [max_subscribers]Subscriber = undefined,
    n_subs: usize = 0,
    /// Download progress in bytes.
    progress: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    busy: std.atomic.Value(bool) = .init(false),
    /// Consecutive network failures (backoff).
    failures: u32 = 0,
    task: ?Io.Future(void) = null,
    loop_task: ?Io.Future(Io.Cancelable!void) = null,

    pub fn init(gpa: Allocator, io: Io, cfg: Config, http_src: HttpSource) Updater {
        var u: Updater = .{ .gpa = gpa, .io = io, .cfg = cfg, .http_src = http_src };
        if (u.disabledReason()) |r| u.current = .{ .disabled = r };
        return u;
    }

    /// Stops the schedule, cancels a running check and waits for it.
    pub fn deinit(u: *Updater) void {
        u.cancel.store(true, .release);
        if (u.loop_task) |*t| t.cancel(u.io) catch {};
        if (u.task) |*t| t.await(u.io);
        u.loop_task = null;
        u.task = null;
    }

    fn disabledReason(u: *const Updater) ?DisabledReason {
        if (u.cfg.policy_disabled) return .policy;
        if (u.cfg.mode == .none) return .setting;
        if (u.cfg.layout.kind == .distro) return .distro;
        if (u.cfg.feed_urls.len == 0) return .no_feed;
        return null;
    }

    /// A snapshot for the UI.
    pub fn status(u: *Updater) Status {
        u.mutex.lockUncancelable(u.io);
        defer u.mutex.unlock(u.io);
        return u.current;
    }

    /// Calls `func` on every status change (on the updater's task; post
    /// to the UI thread from there).
    pub fn subscribe(u: *Updater, s: Subscriber) error{TooManySubscribers}!void {
        u.mutex.lockUncancelable(u.io);
        defer u.mutex.unlock(u.io);
        if (u.n_subs == max_subscribers) return error.TooManySubscribers;
        u.subs[u.n_subs] = s;
        u.n_subs += 1;
    }

    fn set(u: *Updater, s: Status) void {
        var subs: [max_subscribers]Subscriber = undefined;
        u.mutex.lockUncancelable(u.io);
        u.current = s;
        const n = u.n_subs;
        @memcpy(subs[0..n], u.subs[0..n]);
        u.mutex.unlock(u.io);
        for (subs[0..n]) |sub| sub.func(sub.ctx, s);
    }

    /// Runs `check` as a background task unless one is running.
    pub fn checkNow(u: *Updater, manual: bool) void {
        if (u.busy.load(.acquire)) return;
        if (u.task) |*t| t.await(u.io);
        u.task = u.io.async(runCheck, .{ u, manual });
    }

    fn runCheck(u: *Updater, manual: bool) void {
        _ = u.check(manual);
    }

    /// Keeps the automatic schedule: first check `schedule.first_delay_ms`
    /// after `first_frame_ms`, then every 6 h ± 30 min, backing off on
    /// network errors. Only for `.automatic`.
    pub fn start(u: *Updater, first_frame_ms: i64) !void {
        if (u.cfg.mode != .automatic or u.disabledReason() != null) return;
        u.loop_task = try u.io.concurrent(loop, .{ u, schedule.first(first_frame_ms) });
    }

    fn loop(u: *Updater, first_deadline: i64) Io.Cancelable!void {
        var deadline = first_deadline;
        while (true) {
            // Short sleeps against the real clock: a deadline passed while
            // the machine slept fires once on wake.
            while (!schedule.due(deadline, u.nowMs())) {
                const left: i64 = @min(deadline - u.nowMs(), std.time.ms_per_min);
                try u.io.sleep(.fromMilliseconds(@max(left, 1)), .awake);
            }
            const s = u.check(false);
            var r: [8]u8 = undefined;
            u.io.random(&r);
            const bits = std.mem.readInt(u64, &r, .little);
            deadline = switch (s) {
                .failed => |f| if (f.network) schedule.retry(u.nowMs(), u.failures, bits) else schedule.next(u.nowMs(), bits),
                else => schedule.next(u.nowMs(), bits),
            };
        }
    }

    fn nowMs(u: *const Updater) i64 {
        return @intCast(@divFloor(Io.Clock.real.now(u.io).nanoseconds, std.time.ns_per_ms));
    }

    /// Runs the pipeline once and returns the final status. A concurrent
    /// call returns the current status without doing anything.
    pub fn check(u: *Updater, manual: bool) Status {
        if (u.disabledReason()) |r| {
            u.set(.{ .disabled = r });
            return .{ .disabled = r };
        }
        if (u.busy.swap(true, .acq_rel)) return u.status();
        defer u.busy.store(false, .release);
        u.cancel.store(false, .release);
        u.set(.checking);
        var arena: std.heap.ArenaAllocator = .init(u.gpa);
        defer arena.deinit();
        const s = u.pipeline(arena.allocator(), manual) catch |err| blk: {
            const network = isNetworkError(err);
            u.failures = if (network) u.failures + 1 else 0;
            break :blk Status{ .failed = .{ .err = err, .network = network } };
        };
        if (s != .failed) u.failures = 0;
        u.set(s);
        return s;
    }

    fn pipeline(u: *Updater, arena: Allocator, manual: bool) anyerror!Status {
        const io = u.io;
        var st = try loadState(arena, io, u.cfg.state_dir);
        if (st.needsInstallId()) io.random(&st.install_id);
        const cs = st.channelState(u.cfg.channel);
        const http = try u.http_src.get(u.http_src.ctx);

        const now_s = @divFloor(u.nowMs(), std.time.ms_per_s);
        st.last_check_unix = now_s;
        const fetched = try fetch.fetchFeed(arena, http, u.cfg.feed_urls, u.cfg.channel, if (cs.etag.len > 0) cs.etag else null, &u.cancel, u.cfg.fetch);
        if (fetched.not_modified) {
            try saveState(io, u.cfg.state_dir, st);
            return u.stagedOr(arena, .up_to_date);
        }
        const expected_file = try std.fmt.allocPrint(arena, "update-{s}.json", .{u.cfg.channel});
        const res = try verify.decide(arena, .{
            .now_unix = now_s,
            .build_epoch = u.cfg.build_epoch,
            .current = u.cfg.current,
            .target = verify.artifactKey(u.cfg.target),
            .channel = u.cfg.channel,
            .expected_file = expected_file,
            .last_serial = cs.last_serial,
            .install_id = st.install_id,
            .manual = manual,
        }, u.cfg.keys, fetched.manifest, fetched.sig);
        // A suspect clock keeps both the serial and the ETag, so the next
        // check fetches and verifies again.
        if (!res.clock_suspect) st = try st.withChannel(arena, .{ .channel = u.cfg.channel, .last_serial = res.serial, .etag = fetched.etag orelse "" });
        try saveState(io, u.cfg.state_dir, st);

        const offer = switch (res.decision) {
            .up_to_date => return .up_to_date,
            .offer => |o| o,
        };
        const info: Info = .from(offer);
        if (!manual and !offer.critical and st.isSkipped(offer.version_text)) return .up_to_date;

        var root = try Io.Dir.cwd().openDir(io, u.cfg.layout.root, .{});
        defer root.close(io);
        if (stage.readStaged(arena, io, root)) |s| {
            if (std.mem.eql(u8, s.version, offer.version_text)) return .{ .ready = info };
        }
        if (!u.cfg.layout.kind.managed()) return .{ .available = info };
        if (u.cfg.mode == .manual and !manual) return .{ .available = info };
        if (!u.cfg.download) return .{ .available = info };
        if (!disk.enoughFor(disk.freeBytes(arena, u.cfg.layout.root), offer.artifact.size)) return error.NoSpace;

        u.progress.store(0, .release);
        u.set(.{ .downloading = info });
        try root.createDirPath(io, names.download);
        var dl = try root.openDir(io, names.download, .{});
        defer dl.close(io);
        const file_name = archiveName(offer.artifact.url) orelse return error.UnknownArchive;
        _ = try download.download(arena, io, http, dl, offer.artifact, file_name, &u.progress, &u.cancel, u.cfg.fetch);
        try stage.stage(arena, io, root, file_name, .{
            .version = offer.version_text,
            .target = u.cfg.target,
            .sha256 = offer.artifact.sha256,
            .serial = offer.serial,
            .now_unix = now_s,
        });
        return .{ .ready = info };
    }

    /// `ready` when an update is already staged, else `s`.
    fn stagedOr(u: *Updater, arena: Allocator, s: Status) Status {
        var root = Io.Dir.cwd().openDir(u.io, u.cfg.layout.root, .{}) catch return s;
        defer root.close(u.io);
        const staged = stage.readStaged(arena, u.io, root) orelse return s;
        var info: Info = .{};
        info.version_len = @intCast(Info.copy(&info.version_buf, staged.version));
        return .{ .ready = info };
    }
};

/// The archive's file name: the URL's last path segment, which must be a
/// `.zip` or `.tar.gz` and a plain name.
pub fn archiveName(url: []const u8) ?[]const u8 {
    const path_end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const path = url[0..path_end];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    const name = path[slash + 1 ..];
    if (name.len == 0 or name[0] == '.' or std.mem.indexOfScalar(u8, name, '\\') != null) return null;
    if (stage.archiveKind(name) == null) return null;
    return name;
}

/// Errors worth retrying soon (as opposed to verification failures).
fn isNetworkError(err: anyerror) bool {
    const verdicts = [_]anyerror{
        error.TooLarge,            error.BadSignature,     error.UnknownKey,       error.MixAndMatch,
        error.WrongProduct,        error.BadSchema,        error.RollbackDetected, error.ExpiredMetadata,
        error.NoArtifactForTarget, error.ArtifactTooLarge, error.Malformed,        error.HashMismatch,
        error.SizeMismatch,        error.VersionMismatch,  error.TargetMismatch,   error.BadLayout,
        error.MissingBuildInfo,    error.UnknownArchive,   error.InsecureUrl,      error.NoSpace,
        error.OutOfMemory,         error.Canceled,
    };
    for (verdicts) |v| if (err == v) return false;
    return true;
}

/// The persisted state, or a fresh one.
pub fn loadState(arena: Allocator, io: Io, dir_path: []const u8) !state_mod.State {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{}) catch return .{};
    defer dir.close(io);
    const text = dir.readFileAllocOptions(io, state_file, arena, .limited(64 * 1024), .of(u8), 0) catch return .{};
    return state_mod.State.parseZon(arena, text) catch .{};
}

/// Writes `update.zon` through a temporary file.
pub fn saveState(io: Io, dir_path: []const u8, s: state_mod.State) !void {
    try Io.Dir.cwd().createDirPath(io, dir_path);
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try s.writeZon(&w);
    try dir.writeFile(io, .{ .sub_path = state_file ++ ".tmp", .data = w.buffered() });
    try dir.rename(state_file ++ ".tmp", dir, state_file, io);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const minisign = zg_release.minisign;
const TestServer = zg_net.test_server.TestServer;

test "updater: archive names" {
    try testing.expectEqualStrings("z-0.5.0-x86_64-windows.zip", archiveName("https://h/r/download/v0.5.0/z-0.5.0-x86_64-windows.zip").?);
    try testing.expectEqualStrings("z.tar.gz", archiveName("https://h/z.tar.gz?x=1").?);
    try testing.expect(archiveName("https://h/z.exe") == null);
    try testing.expect(archiveName("https://h/") == null);
    try testing.expect(archiveName("https://h/..zip") == null);
}

const NoHttp = struct {
    var calls: u32 = 0;
    fn get(_: ?*anyopaque) anyerror!*zg_net.http.Client {
        calls += 1;
        return error.Unexpected;
    }
};

fn baseConfig(root: []const u8, state_dir: []const u8) Config {
    return .{
        .channel = "stable",
        .feed_urls = &.{"https://example.invalid/update-{channel}.json"},
        .layout = .{ .root = root, .kind = .user },
        .keys = &.{},
        .current = zg_release.Version.parse("0.4.0") catch unreachable,
        .target = "x86_64-linux-gnu.2.28",
        .build_epoch = 1_700_000_000,
        .state_dir = state_dir,
    };
}

test "updater: mode none and policy never create the http client" {
    NoHttp.calls = 0;
    var cfg = baseConfig("/nonexistent", "/nonexistent");
    cfg.mode = .none;
    var u: Updater = .init(testing.allocator, testing.io, cfg, .{ .ctx = null, .get = NoHttp.get });
    defer u.deinit();
    try testing.expectEqual(Status{ .disabled = .setting }, u.check(true));
    try u.start(0);
    try testing.expect(u.loop_task == null);
    cfg.mode = .automatic;
    cfg.policy_disabled = true;
    var p: Updater = .init(testing.allocator, testing.io, cfg, .{ .ctx = null, .get = NoHttp.get });
    defer p.deinit();
    try testing.expectEqual(Status{ .disabled = .policy }, p.status());
    p.checkNow(true);
    if (p.task) |*t| t.await(testing.io);
    p.task = null;
    try testing.expectEqual(@as(u32, 0), NoHttp.calls);
}

/// A signed feed for version 0.5.0 with one artifact served by `Feed`.
const Feed = struct {
    var manifest_bytes: []const u8 = "";
    var sig_text: []const u8 = "";
    var archive: []const u8 = "";

    fn h(_: *TestServer, req: *std.http.Server.Request) !void {
        const t = req.head.target;
        if (std.mem.eql(u8, t, "/update-stable.json")) return req.respond(manifest_bytes, .{ .extra_headers = &.{.{ .name = "etag", .value = "\"m1\"" }}, .keep_alive = false });
        if (std.mem.eql(u8, t, "/update-stable.json.minisig")) return req.respond(sig_text, .{ .keep_alive = false });
        if (std.mem.eql(u8, t, "/dl/zigguro-0.5.0-x86_64-linux.tar.gz")) return req.respond(archive, .{ .keep_alive = false });
        return req.respond("", .{ .status = .not_found, .keep_alive = false });
    }
};

const TestHttp = struct {
    tc: *fetch.TestClient,
    var calls: u32 = 0;
    fn get(ctx: ?*anyopaque) anyerror!*zg_net.http.Client {
        const self: *TestHttp = @ptrCast(@alignCast(ctx.?));
        calls += 1;
        return self.tc.client;
    }
};

const Recorder = struct {
    seen: [16]std.meta.Tag(Status) = undefined,
    n: usize = 0,
    fn cb(ctx: ?*anyopaque, s: Status) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        if (r.n < r.seen.len) r.seen[r.n] = s;
        r.n += 1;
    }
};

test "updater: checking to ready end to end, then up to date, unmanaged stops at available" {
    const gpa = testing.allocator;
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var srv: TestServer = .{ .server = undefined, .port = 0, .max = 64, .handler = Feed.h };
    try srv.start(io);
    defer srv.stop(io);

    // The archive: one top dir with BUILDINFO.zon.
    Feed.archive = try stage.testArchive(a, "zigguro-0.5.0-x86_64-linux", "0.5.0+gabc", "x86_64-linux-gnu.2.28");
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(Feed.archive, &sha, .{});

    const now_s: i64 = @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
    const serial: u64 = @intCast(now_s);
    Feed.manifest_bytes = try std.fmt.allocPrint(a,
        \\{{"schema":1,"product":"{s}","channel":"stable","serial":{d},"issued_at":"2026-10-21T00:00:00Z","expires_at":"2099-01-01T00:00:00Z",
        \\"latest":{{"version":"0.5.0+gabc","released_at":"2026-10-20T12:00:00Z","summary":"Faster","notes_url":"https://example.invalid/notes","critical":false,
        \\"artifacts":{{"x86_64-linux":{{"url":"https://example.invalid/dl/zigguro-0.5.0-x86_64-linux.tar.gz","size":{d},"sha256":"{x}"}}}}}},"blocked":[]}}
    , .{ zg_release.product.app_id, serial, Feed.archive.len, &sha });
    Feed.sig_text = try verify.testing_support.signManifest(a, Feed.manifest_bytes, "update-stable.json", "stable", serial);

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = pbuf[0..try tmp.dir.realPath(io, &pbuf)];
    const root = try std.fs.path.join(a, &.{ base, "root" });
    const state_dir = try std.fs.path.join(a, &.{ base, "state" });
    try Io.Dir.cwd().createDirPath(io, root);

    var tc: fetch.TestClient = undefined;
    try tc.init();
    defer tc.deinit();
    var th: TestHttp = .{ .tc = &tc };

    var cfg = baseConfig(root, state_dir);
    cfg.feed_urls = &.{try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/update-{{channel}}.json", .{srv.port})};
    cfg.keys = &.{verify.testing_support.key().pk};
    const origin = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{srv.port});
    cfg.fetch = .{ .allow_http = true, .test_origin = origin };

    var u: Updater = .init(gpa, io, cfg, .{ .ctx = &th, .get = TestHttp.get });
    defer u.deinit();
    var rec: Recorder = .{};
    try u.subscribe(.{ .ctx = &rec, .func = Recorder.cb });
    const s = u.check(false);
    if (s == .failed) std.debug.print("failed: {s}\n", .{@errorName(s.failed.err)});
    try testing.expect(s == .ready);
    try testing.expectEqualStrings("0.5.0+gabc", s.ready.version());
    try testing.expectEqualSlices(std.meta.Tag(Status), &.{ .checking, .downloading, .ready }, rec.seen[0..rec.n]);
    try testing.expectEqual(@as(u64, Feed.archive.len), u.progress.load(.acquire));

    // The serial and ETag are persisted; the next check is a 304-less
    // refetch (the fixture ignores If-None-Match) of the same serial,
    // which finds the update already staged.
    const st = try loadState(a, io, state_dir);
    try testing.expectEqual(serial, st.channelState("stable").last_serial);
    try testing.expectEqualStrings("\"m1\"", st.channelState("stable").etag);
    try testing.expect(u.check(false) == .ready);

    // An unmanaged install stops at available.
    var cfg2 = cfg;
    cfg2.layout.kind = .portable;
    const root2 = try std.fs.path.join(a, &.{ base, "root2" });
    try Io.Dir.cwd().createDirPath(io, root2);
    cfg2.layout.root = root2;
    var portable_updater: Updater = .init(gpa, io, cfg2, .{ .ctx = &th, .get = TestHttp.get });
    defer portable_updater.deinit();
    const s2 = portable_updater.check(true);
    try testing.expect(s2 == .available);
    try testing.expectEqualStrings("https://example.invalid/notes", s2.available.notesUrl());

    // A forged signature fails without retrying soon.
    const forged = try minisign.keyPairFromSeed(@splat(3), .{ 9, 9, 9, 9, 9, 9, 9, 9 });
    Feed.sig_text = try minisign.sign(a, forged.kp, verify.testing_support.key().pk.key_id, Feed.manifest_bytes, "x", "timestamp:1\tfile:update-stable.json\tchannel:stable\tserial:1");
    const s3 = portable_updater.check(true);
    try testing.expect(s3 == .failed and !s3.failed.network);
}
