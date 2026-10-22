//! Client acceptance rules for update manifests (E17.F04 Design, rules
//! 1-9, applied in order; each failure has a distinct error).
//!
//! 1. Size <= 64 KiB (endless data).
//! 2. The minisign signature and its global signature verify with a known key.
//! 3. The trusted comment's `file`, `channel` and `serial` match (mix-and-match).
//! 4. `schema == 1` and `product == app_id`.
//! 5. `serial >= last_serial[channel]` (metadata rollback).
//! 6. Not expired, unless the clock is before the build epoch (freeze).
//! 7. Offer only a newer version, or any non-downgrade when the current
//!    version is blocked (then critical).
//! 8. Phased rollout bucket.
//! 9. An artifact for this target exists and is <= 512 MiB.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_release = @import("zg_release");
const minisign = zg_release.minisign;
const manifest = @import("manifest.zig");
const Artifact = manifest.Artifact;
/// Minisign public key type accepted by `decide`.
pub const PublicKey = minisign.PublicKey;

/// Largest artifact a manifest may offer.
pub const max_artifact_bytes: u64 = 512 * 1024 * 1024;

/// Everything `decide` needs to know about this install and this check.
pub const Context = struct {
    now_unix: i64,
    /// `BuildInfo.source_date_epoch`; a clock before it is clearly wrong.
    build_epoch: i64,
    current: zg_release.Version,
    /// Artifact key, e.g. "x86_64-windows" (see `artifactKey`).
    target: []const u8,
    channel: []const u8,
    /// Expected manifest file name, e.g. "update-stable.json".
    expected_file: []const u8,
    /// Highest serial accepted before on this channel.
    last_serial: u64,
    /// Random per-install id used only for the rollout bucket.
    install_id: [16]u8,
    /// A user-initiated check skips the rollout gate.
    manual: bool,
    /// Expected product id.
    app_id: []const u8 = zg_release.product.app_id,
};

/// An update the user may be offered.
pub const Offer = struct {
    version_text: []const u8,
    artifact: Artifact,
    critical: bool,
    summary: []const u8,
    notes_url: []const u8,
    serial: u64,
};

/// The outcome of a successful check.
pub const Decision = union(enum) {
    up_to_date,
    offer: Offer,
};

/// Rule failures, one per rule.
pub const Error = error{
    TooLarge,
    BadSignature,
    UnknownKey,
    MixAndMatch,
    WrongProduct,
    BadSchema,
    RollbackDetected,
    ExpiredMetadata,
    NoArtifactForTarget,
    ArtifactTooLarge,
    Malformed,
} || Allocator.Error;

/// `decide`'s result.
pub const Result = struct {
    decision: Decision,
    /// Serial to persist as `last_serial[channel]`; unchanged when the clock
    /// is suspect.
    serial: u64,
    /// The system clock is before the build epoch; expiry was not enforced.
    clock_suspect: bool,
};

/// Applies rules 1-9 to `manifest_bytes` and its `.minisig` text.
pub fn decide(
    arena: Allocator,
    ctx: Context,
    keys: []const minisign.PublicKey,
    manifest_bytes: []const u8,
    sig_text: []const u8,
) Error!Result {
    // 1. Endless data.
    if (manifest_bytes.len > manifest.max_manifest_bytes) return error.TooLarge;

    // 2. Signature.
    const sig = minisign.Signature.parse(sig_text) catch return error.BadSignature;
    _ = minisign.verify(&sig, keys, manifest_bytes) catch |err| return switch (err) {
        error.UnknownKey => error.UnknownKey,
        else => error.BadSignature,
    };

    // 3. Mix-and-match: the signed trusted comment binds file, channel, serial.
    const tc = parseTrustedComment(sig.trusted_comment) catch return error.MixAndMatch;
    const m = manifest.parse(arena, manifest_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => error.TooLarge,
        error.BadSchema => error.BadSchema,
        error.Malformed => error.Malformed,
    };
    if (!std.mem.eql(u8, tc.file, ctx.expected_file) or
        !std.mem.eql(u8, tc.channel, ctx.channel) or
        !std.mem.eql(u8, m.channel, ctx.channel) or
        tc.serial != m.serial) return error.MixAndMatch;

    // 4. Schema and product (schema is already enforced by the parser).
    if (m.schema != 1) return error.BadSchema;
    if (!std.mem.eql(u8, m.product, ctx.app_id)) return error.WrongProduct;

    // 5. Metadata rollback.
    if (m.serial < ctx.last_serial) return error.RollbackDetected;

    // 6. Freeze.
    var clock_suspect = false;
    if (ctx.now_unix > m.expires_at) {
        if (ctx.now_unix < ctx.build_epoch) clock_suspect = true else return error.ExpiredMetadata;
    }
    const new_serial = if (clock_suspect) ctx.last_serial else m.serial;
    const up: Result = .{ .decision = .up_to_date, .serial = new_serial, .clock_suspect = clock_suspect };

    // 7. Version.
    const blocked = isBlocked(m.blocked, ctx.current);
    const order = m.latest.version.order(ctx.current);
    if (!(order == .gt or (blocked and order == .eq))) return up;
    const critical = m.latest.critical or blocked;

    // 8. Rollout.
    if (!critical and !ctx.manual) {
        if (m.latest.rollout) |r| {
            if (!rolloutEligible(r, ctx.now_unix, rolloutBucket(ctx.install_id, m.latest.version_text))) return up;
        }
    }

    // 9. Artifact for this target.
    const a = m.latest.artifacts.get(ctx.target) orelse return error.NoArtifactForTarget;
    if (a.size > max_artifact_bytes) return error.ArtifactTooLarge;

    return .{
        .decision = .{ .offer = .{
            .version_text = m.latest.version_text,
            .artifact = a,
            .critical = critical,
            .summary = m.latest.summary,
            .notes_url = m.latest.notes_url,
            .serial = m.serial,
        } },
        .serial = new_serial,
        .clock_suspect = clock_suspect,
    };
}

fn isBlocked(blocked: []const []const u8, current: zg_release.Version) bool {
    for (blocked) |b| {
        const v = zg_release.Version.parse(b) catch continue;
        if (v.eqlIgnoringBuild(current)) return true;
    }
    return false;
}

/// The fields of a signed trusted comment
/// `timestamp:<unix>\tfile:<name>\tchannel:<c>\tserial:<n>`.
pub const TrustedComment = struct {
    timestamp: i64,
    file: []const u8,
    channel: []const u8,
    serial: u64,
};

/// Parses a trusted comment; every field is required, unknown keys are
/// rejected.
pub fn parseTrustedComment(text: []const u8) error{Malformed}!TrustedComment {
    var out: TrustedComment = .{ .timestamp = 0, .file = "", .channel = "", .serial = 0 };
    var seen: u4 = 0;
    var it = std.mem.splitScalar(u8, text, '\t');
    while (it.next()) |field| {
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse return error.Malformed;
        const key = field[0..colon];
        const value = field[colon + 1 ..];
        if (std.mem.eql(u8, key, "timestamp")) {
            out.timestamp = std.fmt.parseInt(i64, value, 10) catch return error.Malformed;
            seen |= 1;
        } else if (std.mem.eql(u8, key, "file")) {
            out.file = value;
            seen |= 2;
        } else if (std.mem.eql(u8, key, "channel")) {
            out.channel = value;
            seen |= 4;
        } else if (std.mem.eql(u8, key, "serial")) {
            out.serial = std.fmt.parseInt(u64, value, 10) catch return error.Malformed;
            seen |= 8;
        } else return error.Malformed;
    }
    if (seen != 0xf) return error.Malformed;
    return out;
}

/// Writes the trusted comment for a manifest signature.
pub fn formatTrustedComment(w: *std.Io.Writer, tc: TrustedComment) std.Io.Writer.Error!void {
    try w.print("timestamp:{d}\tfile:{s}\tchannel:{s}\tserial:{d}", .{ tc.timestamp, tc.file, tc.channel, tc.serial });
}

/// Rollout bucket in 0..9999: `u32be(sha256(install_id || version)[0..4]) mod 10000`.
/// (The design's 16-bit prefix skews buckets 0..5535 by 1/6, so a 32-bit
/// prefix is used; the skew is then below 3e-6.)
pub fn rolloutBucket(install_id: [16]u8, version_text: []const u8) u16 {
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    h.update(&install_id);
    h.update(version_text);
    const d = h.finalResult();
    return @intCast(std.mem.readInt(u32, d[0..4], .big) % 10000);
}

/// Eligible when `elapsed / hours * 10000 >= bucket`.
pub fn rolloutEligible(r: manifest.Rollout, now_unix: i64, bucket: u16) bool {
    if (r.hours == 0) return true;
    const elapsed = now_unix - r.start;
    if (elapsed < 0) return false;
    const window: i64 = @as(i64, r.hours) * 3600;
    if (elapsed >= window) return true;
    return @divFloor(elapsed * 10000, window) >= bucket;
}

/// Artifact key of a release target: the first two components,
/// e.g. "x86_64-linux-gnu.2.28" -> "x86_64-linux".
pub fn artifactKey(target: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, target, '-') orelse return target;
    const second = std.mem.indexOfScalarPos(u8, target, first + 1, '-') orelse return target;
    return target[0..second];
}

const testing = std.testing;

/// Test harness: signs manifests with a throwaway key.
pub const testing_support = struct {
    /// Throwaway signing key.
    pub fn key() minisign.KeyPair {
        return minisign.keyPairFromSeed(@splat(0x42), .{ 1, 2, 3, 4, 5, 6, 7, 8 }) catch unreachable;
    }

    /// Signs `bytes` with a trusted comment for `file`/`channel`/`serial`.
    pub fn signManifest(gpa: Allocator, bytes: []const u8, file: []const u8, channel: []const u8, serial: u64) ![]u8 {
        const k = key();
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try formatTrustedComment(&w, .{ .timestamp = 1761016620, .file = file, .channel = channel, .serial = serial });
        return minisign.sign(gpa, k.kp, k.pk.key_id, bytes, "signature from zg-release", w.buffered());
    }
};

const base_ctx: Context = .{
    .now_unix = 1792600000, // 2026-10-21T16:26Z, inside the golden validity window
    .build_epoch = 1792500000,
    .current = .{ .major = 0, .minor = 3, .patch = 9 },
    .target = "x86_64-linux",
    .channel = "stable",
    .expected_file = "update-stable.json",
    .last_serial = 1761000000,
    .install_id = @splat(0),
    .manual = true,
};

fn run(ctx: Context, bytes: []const u8) Error!Result {
    return runSigned(ctx, bytes, "update-stable.json", "stable", 1761016620);
}

fn runSigned(ctx: Context, bytes: []const u8, file: []const u8, channel: []const u8, serial: u64) Error!Result {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena.deinit();
    const sig = testing_support.signManifest(arena.allocator(), bytes, file, channel, serial) catch return error.OutOfMemory;
    const r = try decide(arena.allocator(), ctx, &.{testing_support.key().pk}, bytes, sig);
    // Offers slice into the arena; tests only look at scalars after this.
    arena.deinit();
    return r;
}

fn replaced(needle: []const u8, with: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, testing.allocator, manifest.golden, needle, with);
}

test "verify: happy path offers the newer version" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sig = try testing_support.signManifest(arena.allocator(), manifest.golden, "update-stable.json", "stable", 1761016620);
    const r = try decide(arena.allocator(), base_ctx, &.{testing_support.key().pk}, manifest.golden, sig);
    try testing.expectEqualStrings("0.4.0+g1a2b3c4d5e6f", r.decision.offer.version_text);
    try testing.expectEqual(@as(u64, 20000000), r.decision.offer.artifact.size);
    try testing.expect(!r.decision.offer.critical);
    try testing.expectEqual(@as(u64, 1761016620), r.serial);
    try testing.expect(!r.clock_suspect);
}

test "verify: rule 1 too large" {
    const big = try testing.allocator.alloc(u8, manifest.max_manifest_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try testing.expectError(error.TooLarge, run(base_ctx, big));
}

test "verify: rule 2 bad signature and unknown key" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sig = try testing_support.signManifest(arena.allocator(), manifest.golden, "update-stable.json", "stable", 1761016620);
    const tampered = try arena.allocator().dupe(u8, manifest.golden);
    tampered[tampered.len - 3] = '3';
    try testing.expectError(error.BadSignature, decide(arena.allocator(), base_ctx, &.{testing_support.key().pk}, tampered, sig));
    try testing.expectError(error.BadSignature, decide(arena.allocator(), base_ctx, &.{testing_support.key().pk}, manifest.golden, "garbage"));
    const other = try minisign.keyPairFromSeed(@splat(9), @splat(9));
    try testing.expectError(error.UnknownKey, decide(arena.allocator(), base_ctx, &.{other.pk}, manifest.golden, sig));
}

test "verify: rule 3 mix-and-match" {
    try testing.expectError(error.MixAndMatch, runSigned(base_ctx, manifest.golden, "update-insiders.json", "stable", 1761016620));
    try testing.expectError(error.MixAndMatch, runSigned(base_ctx, manifest.golden, "update-stable.json", "insiders", 1761016620));
    try testing.expectError(error.MixAndMatch, runSigned(base_ctx, manifest.golden, "update-stable.json", "stable", 1));
    var ctx = base_ctx;
    ctx.channel = "insiders";
    ctx.expected_file = "update-insiders.json";
    try testing.expectError(error.MixAndMatch, runSigned(ctx, manifest.golden, "update-insiders.json", "insiders", 1761016620));
}

test "verify: rule 4 schema and product" {
    const wrong = try replaced("\"dev.zigguro.zigguro\"", "\"dev.other.app\"");
    defer testing.allocator.free(wrong);
    try testing.expectError(error.WrongProduct, run(base_ctx, wrong));
    const schema = try replaced("\"schema\": 1", "\"schema\": 2");
    defer testing.allocator.free(schema);
    try testing.expectError(error.BadSchema, run(base_ctx, schema));
}

test "verify: rule 5 rollback detected" {
    var ctx = base_ctx;
    ctx.last_serial = 1761016621;
    try testing.expectError(error.RollbackDetected, run(ctx, manifest.golden));
    ctx.last_serial = 1761016620; // equal: accepted
    _ = try run(ctx, manifest.golden);
}

test "verify: rule 6 expired metadata" {
    var ctx = base_ctx;
    ctx.now_unix = 1794400000; // after 2026-11-11T03:17Z
    try testing.expectError(error.ExpiredMetadata, run(ctx, manifest.golden));
}

test "verify: clock before build epoch → accept, clock_suspect" {
    var ctx = base_ctx;
    ctx.now_unix = 1794400000;
    ctx.build_epoch = 1795000000;
    const r = try run(ctx, manifest.golden);
    try testing.expect(r.clock_suspect);
    try testing.expectEqual(ctx.last_serial, r.serial);
}

test "verify: rule 7 no downgrade, equal is up to date" {
    var ctx = base_ctx;
    ctx.current = .{ .major = 0, .minor = 4, .patch = 0 };
    try testing.expect((try run(ctx, manifest.golden)).decision == .up_to_date);
    ctx.current = .{ .major = 0, .minor = 5, .patch = 0 };
    try testing.expect((try run(ctx, manifest.golden)).decision == .up_to_date);
}

test "verify: blocked current version makes offer critical" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ctx = base_ctx;
    ctx.current = .{ .major = 0, .minor = 3, .patch = 2 };
    ctx.manual = false;
    ctx.now_unix = 1792508400; // 2026-10-20T15:00Z: early in the rollout
    const sig = try testing_support.signManifest(arena.allocator(), manifest.golden, "update-stable.json", "stable", 1761016620);
    const r = try decide(arena.allocator(), ctx, &.{testing_support.key().pk}, manifest.golden, sig);
    try testing.expect(r.decision.offer.critical);
}

test "verify: rule 8 rollout gate" {
    var ctx = base_ctx;
    ctx.manual = false;
    ctx.now_unix = 1792497600 - 10; // before the rollout start (2026-10-20T12:00Z)
    try testing.expect((try run(ctx, manifest.golden)).decision == .up_to_date);
    ctx.now_unix = 1792497600 + 72 * 3600; // window over
    try testing.expect((try run(ctx, manifest.golden)).decision == .offer);
}

test "verify: rule 9 artifact for target" {
    var ctx = base_ctx;
    ctx.target = "aarch64-linux";
    try testing.expectError(error.NoArtifactForTarget, run(ctx, manifest.golden));
    const big = try replaced("\"size\": 20000000", "\"size\": 536870913");
    defer testing.allocator.free(big);
    try testing.expectError(error.ArtifactTooLarge, run(base_ctx, big));
}

test "verify: rollout buckets distribute uniformly" {
    const bins = 10;
    var counts: [bins]u32 = @splat(0);
    var id: [16]u8 = @splat(0);
    const n = 10_000;
    for (0..n) |i| {
        std.mem.writeInt(u64, id[0..8], i, .little);
        const b = rolloutBucket(id, "0.4.0");
        try testing.expect(b < 10000);
        counts[b / 1000] += 1;
    }
    var chi: f64 = 0;
    const expected: f64 = n / bins;
    for (counts) |c| {
        const d = @as(f64, @floatFromInt(c)) - expected;
        chi += d * d / expected;
    }
    // 9 degrees of freedom: p = 0.001 at 27.88.
    try testing.expect(chi < 27.88);
}

test "verify: trusted comment" {
    const tc = try parseTrustedComment("timestamp:5\tfile:update-stable.json\tchannel:stable\tserial:7");
    try testing.expectEqual(@as(u64, 7), tc.serial);
    try testing.expectError(error.Malformed, parseTrustedComment("timestamp:5\tfile:x\tchannel:stable"));
    try testing.expectError(error.Malformed, parseTrustedComment("timestamp:5\tfile:x\tchannel:s\tserial:1\textra:1"));
    try testing.expectEqualStrings("x86_64-linux", artifactKey("x86_64-linux-gnu.2.28"));
    try testing.expectEqualStrings("aarch64-windows", artifactKey("aarch64-windows-gnu"));
    try testing.expectEqualStrings("x86_64-windows", artifactKey("x86_64-windows"));
}
