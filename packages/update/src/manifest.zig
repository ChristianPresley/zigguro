//! Update manifest schema v1 (`update-<channel>.json`, E17.F04 Design).
//!
//! The manifest is signed as raw bytes, so no canonicalization is needed.
//! Parsing is strict: unknown fields are rejected, timestamps must be RFC
//! 3339 UTC (`YYYY-MM-DDTHH:MM:SSZ`), digests 64 lowercase hex characters,
//! and URLs `https://`. Every string slices into the arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_release = @import("zg_release");

/// Hard cap on manifest size (endless-data defense, rule 1).
pub const max_manifest_bytes = 64 * 1024;

/// One downloadable artifact.
pub const Artifact = struct {
    /// `https://` URL of the archive.
    url: []const u8,
    /// Exact size in bytes.
    size: u64,
    /// SHA-256 of the whole archive.
    sha256: [32]u8,
};

/// A phased rollout window.
pub const Rollout = struct {
    /// Unix seconds when the rollout starts.
    start: i64,
    /// Hours until every install is eligible; 0 means immediately.
    hours: u32,
};

/// A parsed, validated manifest.
pub const Manifest = struct {
    schema: u32,
    /// Product app id; must equal `zg_release.product.app_id`.
    product: []const u8,
    channel: []const u8,
    /// Monotonic metadata serial.
    serial: u64,
    issued_at: i64,
    expires_at: i64,
    latest: Latest,
    /// Versions that must not keep running (an offer from them is critical).
    blocked: []const []const u8,

    /// The newest release on the channel.
    pub const Latest = struct {
        version: zg_release.Version,
        version_text: []const u8,
        released_at: i64,
        summary: []const u8,
        notes_url: []const u8,
        critical: bool,
        rollout: ?Rollout,
        /// Keyed by artifact target, e.g. "x86_64-windows".
        artifacts: std.StringArrayHashMapUnmanaged(Artifact),
    };
};

/// Errors of `parse`.
pub const ParseError = Allocator.Error || error{ TooLarge, Malformed, BadSchema };

const RawArtifact = struct { url: []const u8, size: u64, sha256: []const u8 };
const RawRollout = struct { start: []const u8, hours: u32 };
const RawLatest = struct {
    version: []const u8,
    released_at: []const u8,
    summary: []const u8 = "",
    notes_url: []const u8,
    critical: bool = false,
    rollout: ?RawRollout = null,
    artifacts: std.json.ArrayHashMap(RawArtifact),
};
const RawManifest = struct {
    schema: u32,
    product: []const u8,
    channel: []const u8,
    serial: u64,
    issued_at: []const u8,
    expires_at: []const u8,
    latest: RawLatest,
    blocked: []const []const u8 = &.{},
};

/// Parses and validates manifest `bytes`. Unknown fields, a schema other
/// than 1 (`BadSchema`), malformed timestamps, digests or non-HTTPS URLs
/// (`Malformed`) are all rejected.
pub fn parse(arena: Allocator, bytes: []const u8) ParseError!Manifest {
    if (bytes.len > max_manifest_bytes) return error.TooLarge;
    // Peek at the schema first so a future schema reports BadSchema rather
    // than an unknown-field error.
    const Peek = struct { schema: u32 };
    const peek = std.json.parseFromSliceLeaky(Peek, arena, bytes, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };
    if (peek.schema != 1) return error.BadSchema;

    const raw = std.json.parseFromSliceLeaky(RawManifest, arena, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
    };

    var artifacts: std.StringArrayHashMapUnmanaged(Artifact) = .empty;
    var it = raw.latest.artifacts.map.iterator();
    while (it.next()) |e| {
        const a = e.value_ptr.*;
        try requireHttps(a.url);
        try artifacts.put(arena, e.key_ptr.*, .{ .url = a.url, .size = a.size, .sha256 = try parseSha256(a.sha256) });
    }
    try requireHttps(raw.latest.notes_url);
    for (raw.blocked) |b| _ = zg_release.Version.parse(b) catch return error.Malformed;

    return .{
        .schema = raw.schema,
        .product = raw.product,
        .channel = raw.channel,
        .serial = raw.serial,
        .issued_at = try parseRfc3339(raw.issued_at),
        .expires_at = try parseRfc3339(raw.expires_at),
        .latest = .{
            .version = zg_release.Version.parse(raw.latest.version) catch return error.Malformed,
            .version_text = raw.latest.version,
            .released_at = try parseRfc3339(raw.latest.released_at),
            .summary = raw.latest.summary,
            .notes_url = raw.latest.notes_url,
            .critical = raw.latest.critical,
            .rollout = if (raw.latest.rollout) |r| .{ .start = try parseRfc3339(r.start), .hours = r.hours } else null,
            .artifacts = artifacts,
        },
        .blocked = raw.blocked,
    };
}

fn requireHttps(url: []const u8) error{Malformed}!void {
    if (!std.mem.startsWith(u8, url, "https://") or url.len == "https://".len) return error.Malformed;
    for (url) |c| if (c <= ' ' or c == 0x7f) return error.Malformed;
}

/// Parses 64 lowercase hex characters.
pub fn parseSha256(hex: []const u8) error{Malformed}![32]u8 {
    if (hex.len != 64) return error.Malformed;
    for (hex) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return error.Malformed;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return error.Malformed;
    return out;
}

/// Parses an RFC 3339 UTC timestamp of the exact form
/// `YYYY-MM-DDTHH:MM:SSZ` into Unix seconds. Leap seconds (`:60`) are
/// rejected.
pub fn parseRfc3339(s: []const u8) error{Malformed}!i64 {
    if (s.len != 20) return error.Malformed;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') return error.Malformed;
    const year = try digits(s[0..4]);
    const month = try digits(s[5..7]);
    const day = try digits(s[8..10]);
    const hour = try digits(s[11..13]);
    const minute = try digits(s[14..16]);
    const second = try digits(s[17..19]);
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return error.Malformed;
    if (hour > 23 or minute > 59 or second > 59) return error.Malformed;
    const days = daysFromCivil(year, month, day);
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

/// Formats Unix seconds as `YYYY-MM-DDTHH:MM:SSZ` (years 0..9999).
pub fn formatRfc3339(buf: *[20]u8, unix: i64) []const u8 {
    const days = @divFloor(unix, 86400);
    const secs: u32 = @intCast(unix - days * 86400);
    const c = civilFromDays(days);
    _ = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(c.year)), c.month, c.day, secs / 3600, secs / 60 % 60, secs % 60,
    }) catch unreachable;
    return buf;
}

fn digits(s: []const u8) error{Malformed}!u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return error.Malformed;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn isLeap(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

fn daysInMonth(y: u32, m: u32) u32 {
    const t = [12]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (m == 2 and isLeap(y)) 29 else t[m - 1];
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn daysFromCivil(year: u32, month: u32, day: u32) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(z0: i64) struct { year: i64, month: u32, day: u32 } {
    const z = z0 + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @intFromBool(m <= 2), .month = m, .day = d };
}

const testing = std.testing;

/// The golden manifest used by tests here and in verify.zig.
pub const golden =
    \\{ "schema": 1, "product": "dev.zigguro.zigguro", "channel": "stable",
    \\  "serial": 1761016620, "issued_at": "2026-10-21T03:17:00Z", "expires_at": "2026-11-11T03:17:00Z",
    \\  "latest": { "version": "0.4.0+g1a2b3c4d5e6f", "released_at": "2026-10-20T12:00:00Z",
    \\              "summary": "Faster search", "notes_url": "https://github.com/ChristianPresley/zigguro/releases/tag/v0.4.0",
    \\              "critical": false, "rollout": { "start": "2026-10-20T12:00:00Z", "hours": 72 },
    \\              "artifacts": { "x86_64-windows": { "url": "https://github.com/ChristianPresley/zigguro/releases/download/v0.4.0/zigguro-0.4.0-x86_64-windows.zip",
    \\                                                 "size": 21733120, "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    \\                             "x86_64-linux": { "url": "https://github.com/ChristianPresley/zigguro/releases/download/v0.4.0/zigguro-0.4.0-x86_64-linux.tar.gz",
    \\                                               "size": 20000000, "sha256": "0000000000000000000000000000000000000000000000000000000000000000" } } },
    \\  "blocked": ["0.3.2"] }
;

test "manifest: parse golden" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try parse(arena.allocator(), golden);
    try testing.expectEqual(@as(u32, 1), m.schema);
    try testing.expectEqualStrings("dev.zigguro.zigguro", m.product);
    try testing.expectEqual(@as(u64, 1761016620), m.serial);
    try testing.expectEqual(@as(i64, 1792552620), m.issued_at);
    try testing.expectEqualStrings("0.4.0+g1a2b3c4d5e6f", m.latest.version_text);
    try testing.expectEqual(@as(u32, 4), m.latest.version.minor);
    try testing.expectEqual(@as(u32, 72), m.latest.rollout.?.hours);
    const a = m.latest.artifacts.get("x86_64-windows").?;
    try testing.expectEqual(@as(u64, 21733120), a.size);
    try testing.expectEqual(@as(u8, 0xe3), a.sha256[0]);
    try testing.expectEqual(@as(usize, 1), m.blocked.len);
}

test "manifest: reject unknown field" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bad = try std.mem.replaceOwned(u8, arena.allocator(), golden, "\"blocked\"", "\"blockedx\"");
    try testing.expectError(error.Malformed, parse(arena.allocator(), bad));
    const schema2 = try std.mem.replaceOwned(u8, arena.allocator(), golden, "\"schema\": 1", "\"schema\": 2");
    try testing.expectError(error.BadSchema, parse(arena.allocator(), schema2));
}

test "manifest: reject http url" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const bad = try std.mem.replaceOwned(u8, arena.allocator(), golden, "https://github.com/ChristianPresley/zigguro/releases/download/v0.4.0/zigguro-0.4.0-x86_64-linux", "http://example.com/x");
    try testing.expectError(error.Malformed, parse(arena.allocator(), bad));
    const upper = try std.mem.replaceOwned(u8, arena.allocator(), golden, "e3b0c442", "E3B0C442");
    try testing.expectError(error.Malformed, parse(arena.allocator(), upper));
    var big: [max_manifest_bytes + 1]u8 = @splat(' ');
    try testing.expectError(error.TooLarge, parse(arena.allocator(), &big));
}

test "manifest: rfc3339 parser table" {
    const ok = [_]struct { []const u8, i64 }{
        .{ "1970-01-01T00:00:00Z", 0 },
        .{ "2026-10-21T03:17:00Z", 1792552620 },
        .{ "2025-10-21T03:17:00Z", 1761016620 },
        .{ "2000-02-29T23:59:59Z", 951868799 },
        .{ "1969-12-31T23:59:59Z", -1 },
        .{ "2038-01-19T03:14:08Z", 2147483648 },
    };
    for (ok) |c| {
        try testing.expectEqual(c[1], try parseRfc3339(c[0]));
        var buf: [20]u8 = undefined;
        try testing.expectEqualStrings(c[0], formatRfc3339(&buf, c[1]));
    }
    const bad = [_][]const u8{
        "2026-10-21T03:17:00",  "2026-10-21 03:17:00Z", "2026-10-21T03:17:00+00:00", "2026-13-01T00:00:00Z",
        "2026-02-29T00:00:00Z", "2026-10-32T00:00:00Z", "2026-10-21T24:00:00Z",      "2026-10-21T00:60:00Z",
        "2026-10-21T00:00:60Z", "2026-1a-21T00:00:00Z", "",                          "2026-00-10T00:00:00Z",
    };
    for (bad) |b| try testing.expectError(error.Malformed, parseRfc3339(b));
}

test "fuzz: manifest parse" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var input: [2048]u8 = undefined;
            const n = s.slice(&input);
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const m = parse(arena.allocator(), input[0..n]) catch return;
            try testing.expectEqual(@as(u32, 1), m.schema);
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "manifest") });
}
