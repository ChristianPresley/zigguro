//! IANA time zones for the scheduler (E13.F02.S01.T04): `TimeZone` built
//! from TZif bytes (`tzif.zig`) or a POSIX TZ string (`posix_tz.zig`),
//! local-zone discovery (`$TZ`, `/etc/localtime`; on Windows the system
//! zone through `tz_windows.zig`), and the `ZoneResolver` the cron
//! engine consumes. Instants after the last transition follow the
//! footer rule. A zone owns one buffer; `utc()` owns none.

const std = @import("std");
const builtin = @import("builtin");
const zone = @import("zone.zig");
const tzif = @import("tzif.zig");
const posix_tz = @import("posix_tz.zig");
const tz_embedded = @import("tz_embedded.zig");
const tz_windows = @import("tz_windows.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const LocalDateTime = zone.LocalDateTime;
const Resolved = zone.Resolved;
const ZoneResolver = zone.ZoneResolver;

pub const PosixRule = posix_tz.PosixRule;
pub const RuleDate = posix_tz.RuleDate;

pub const TType = struct { utoff: i32, is_dst: bool, abbr_idx: u8 };

pub const Offset = struct { utoff: i32, is_dst: bool, abbr: []const u8 };

/// Where zoneinfo files live on Unix.
pub const zoneinfo_dir = "/usr/share/zoneinfo";

/// No real zone's offset is a day or more from UTC; wall times are
/// searched within this distance.
const max_utoff = 26 * 3600;

pub const TimeZone = struct {
    /// IANA name, or the TZ string for rule-only zones.
    name: []const u8,
    transitions: []const i64 = &.{},
    /// The type in effect from each transition on.
    types_idx: []const u8 = &.{},
    types: []const TType,
    /// NUL-separated designations.
    abbrs: []const u8,
    /// For instants after the last transition (or all of them, if none).
    footer: ?PosixRule = null,
    buf: []align(8) u8 = &.{},

    pub fn utc() TimeZone {
        return .{ .name = "UTC", .types = &.{.{ .utoff = 0, .is_dst = false, .abbr_idx = 0 }}, .abbrs = "UTC\x00" };
    }

    /// Copies the zone out of `bytes` into one allocation of at most twice
    /// `bytes.len` plus the name.
    pub fn fromTzif(gpa: Allocator, bytes: []const u8, name: []const u8) !TimeZone {
        const p = try tzif.parse(bytes);
        const footer: ?PosixRule = if (p.footer) |f| PosixRule.parse(f) catch return error.InvalidTzif else null;
        const n = p.counts.time;
        const t = p.counts.type;
        const size = n * 8 + t * @sizeOf(TType) + n + p.counts.char + name.len;
        const buf = try gpa.alignedAlloc(u8, .@"8", size);
        var o: usize = 0;
        const trans: []i64 = @alignCast(std.mem.bytesAsSlice(i64, buf[o..][0 .. n * 8]));
        o += n * 8;
        const types: []TType = @alignCast(std.mem.bytesAsSlice(TType, buf[o..][0 .. t * @sizeOf(TType)]));
        o += t * @sizeOf(TType);
        const idx = buf[o..][0..n];
        o += n;
        const abbrs = buf[o..][0..p.counts.char];
        o += abbrs.len;
        const nm = buf[o..][0..name.len];
        for (trans, 0..) |*x, i| x.* = p.transition(i);
        for (types, 0..) |*x, i| {
            const ti = p.ttinfo(i);
            x.* = .{ .utoff = ti.utoff, .is_dst = ti.is_dst, .abbr_idx = ti.desig_idx };
        }
        @memcpy(idx, p.indices);
        @memcpy(abbrs, p.designations);
        @memcpy(nm, name);
        return .{ .name = nm, .transitions = trans, .types_idx = idx, .types = types, .abbrs = abbrs, .footer = footer, .buf = buf };
    }

    /// A zone that is only a POSIX TZ rule (`$TZ=EST5EDT,M3.2.0,M11.1.0`).
    pub fn fromRule(gpa: Allocator, rule: PosixRule, name: []const u8) !TimeZone {
        const buf = try gpa.alignedAlloc(u8, .@"8", @sizeOf(TType) + 8 + name.len);
        const types: []TType = @alignCast(std.mem.bytesAsSlice(TType, buf[0..@sizeOf(TType)]));
        types[0] = .{ .utoff = rule.std_off, .is_dst = false, .abbr_idx = 0 };
        const abbrs = buf[@sizeOf(TType)..][0..8];
        @memcpy(abbrs, &rule.std_abbr);
        abbrs[7] = 0;
        const nm = buf[@sizeOf(TType) + 8 ..];
        @memcpy(nm, name);
        return .{ .name = nm, .types = types, .abbrs = abbrs, .footer = rule, .buf = buf };
    }

    pub fn deinit(tz: *TimeZone, gpa: Allocator) void {
        if (tz.buf.len > 0) gpa.free(tz.buf);
        tz.* = utc();
    }

    /// Bytes this zone holds.
    pub fn allocated(tz: *const TimeZone) usize {
        return tz.buf.len;
    }

    /// The system's zone. `env` supplies `$TZ` (Unix); unreadable zones
    /// fall back to UTC.
    pub fn local(io: Io, gpa: Allocator, env: ?*const std.process.Environ.Map) !TimeZone {
        if (builtin.os.tag == .windows) return tz_windows.systemZone(gpa);
        if (env) |e| if (e.get("TZ")) |v| return fromTzVar(io, gpa, v);
        return fromLocaltime(io, gpa, "/etc/localtime");
    }

    /// `$TZ`: empty is UTC; `:Area/City` or `Area/City` names a zoneinfo
    /// file; an absolute path is read; anything else is a POSIX rule.
    pub fn fromTzVar(io: Io, gpa: Allocator, v: []const u8) !TimeZone {
        const name = if (v.len > 0 and v[0] == ':') v[1..] else v;
        if (name.len == 0) return utc();
        if (name[0] == '/') {
            if (readFile(io, gpa, name)) |bytes| {
                defer gpa.free(bytes);
                return fromTzif(gpa, bytes, ianaFromPath(name));
            } else |e| if (e == error.OutOfMemory) return e;
        } else if (named(io, gpa, name)) |z| return z else |e| if (e == error.OutOfMemory) return e;
        if (v[0] != ':') if (PosixRule.parse(v)) |r| return fromRule(gpa, r, v) else |_| {};
        return utc();
    }

    /// `/etc/localtime` (named after its symlink target when it has one).
    pub fn fromLocaltime(io: Io, gpa: Allocator, path: []const u8) !TimeZone {
        const bytes = readFile(io, gpa, path) catch |e| return if (e == error.OutOfMemory) e else utc();
        defer gpa.free(bytes);
        var lb: [Io.Dir.max_path_bytes]u8 = undefined;
        const name = if (Io.Dir.cwd().readLink(io, path, &lb)) |n| ianaFromPath(lb[0..n]) else |_| "localtime";
        return fromTzif(gpa, bytes, name) catch |e| if (e == error.OutOfMemory) e else utc();
    }

    /// By IANA name: the zoneinfo file on Unix, else the embedded set.
    pub fn named(io: Io, gpa: Allocator, iana: []const u8) !TimeZone {
        if (!validName(iana)) return error.UnknownTimeZone;
        if (std.mem.eql(u8, iana, "UTC")) return utc();
        if (builtin.os.tag != .windows) {
            var pb: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, zoneinfo_dir ++ "/{s}", .{iana}) catch return error.UnknownTimeZone;
            if (readFile(io, gpa, path)) |bytes| {
                defer gpa.free(bytes);
                return fromTzif(gpa, bytes, iana);
            } else |e| if (e == error.OutOfMemory) return e;
        }
        return embedded(gpa, iana);
    }

    /// From the embedded zone set (what Windows uses).
    pub fn embedded(gpa: Allocator, iana: []const u8) !TimeZone {
        const canon = tz_windows.canonical(iana);
        const bytes = tz_embedded.find(canon) orelse return error.UnknownTimeZone;
        return fromTzif(gpa, bytes, canon);
    }

    pub fn offsetAt(tz: *const TimeZone, unix_s: i64) Offset {
        const n = tz.transitions.len;
        const i = std.sort.upperBound(i64, tz.transitions, unix_s, orderI64);
        if (i == n) if (tz.footer) |*f| if (n == 0 or unix_s >= tz.transitions[n - 1]) {
            const info = f.at(unix_s);
            return .{ .utoff = info.utoff, .is_dst = info.is_dst, .abbr = if (info.is_dst) f.dstAbbr() else f.stdAbbr() };
        };
        const ty = tz.types[if (i == 0) 0 else tz.types_idx[i - 1]];
        return .{ .utoff = ty.utoff, .is_dst = ty.is_dst, .abbr = std.mem.sliceTo(tz.abbrs[@min(ty.abbr_idx, tz.abbrs.len)..], 0) };
    }

    /// The first change of offset strictly after `unix_s`, if any.
    pub fn nextTransition(tz: *const TimeZone, unix_s: i64) ?i64 {
        const i = std.sort.upperBound(i64, tz.transitions, unix_s, orderI64);
        if (i < tz.transitions.len) return tz.transitions[i];
        const f = tz.footer orelse return null;
        return f.nextChange(unix_s);
    }

    /// The instant(s) of a wall time: walks the constant-offset segments
    /// of the instants that could show it.
    pub fn fromLocal(tz: *const TimeZone, l: LocalDateTime) Resolved {
        const w = l.toUnixUtc();
        var seg = w - max_utoff;
        const last = w + max_utoff;
        var found: [2]i64 = undefined;
        var count: usize = 0;
        var gap: ?i64 = null;
        var prev_off: ?i32 = null;
        while (seg <= last) {
            const off = tz.offsetAt(seg).utoff;
            // A boundary the wall time falls into: clocks jumped over it.
            if (prev_off) |po| if (w >= seg + po and w < seg + off and gap == null) {
                gap = seg;
            };
            const nxt = tz.nextTransition(seg) orelse std.math.maxInt(i64);
            const t = w - off;
            if (t >= seg and t < nxt and count < 2 and (count == 0 or found[0] != t)) {
                found[count] = t;
                count += 1;
            }
            if (nxt == std.math.maxInt(i64)) break;
            prev_off = off;
            seg = nxt;
        }
        return switch (count) {
            0 => .{ .gap = gap orelse w - tz.offsetAt(w).utoff },
            1 => .{ .unique = found[0] },
            else => .{ .ambiguous = found },
        };
    }

    pub fn toLocal(tz: *const TimeZone, unix_s: i64) LocalDateTime {
        return .fromUnixUtc(unix_s + tz.offsetAt(unix_s).utoff);
    }

    /// `tz` must outlive the resolver.
    pub fn resolver(tz: *const TimeZone) ZoneResolver {
        return .{ .ctx = tz, .fromLocal = fromLocalFn, .toLocal = toLocalFn };
    }

    fn fromLocalFn(ctx: *const anyopaque, l: LocalDateTime) Resolved {
        const tz: *const TimeZone = @ptrCast(@alignCast(ctx));
        return tz.fromLocal(l);
    }

    fn toLocalFn(ctx: *const anyopaque, unix_s: i64) LocalDateTime {
        const tz: *const TimeZone = @ptrCast(@alignCast(ctx));
        return tz.toLocal(unix_s);
    }
};

fn orderI64(a: i64, b: i64) std.math.Order {
    return std.math.order(a, b);
}

/// `Area/City` names: letters, digits, `/_+-`, no `..` or leading `/`.
pub fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 255 or s[0] == '/' or std.mem.indexOf(u8, s, "..") != null) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/_+-", c) == null) return false;
    return true;
}

/// `/usr/share/zoneinfo/Europe/Berlin` → `Europe/Berlin`.
pub fn ianaFromPath(p: []const u8) []const u8 {
    const key = "zoneinfo/";
    if (std.mem.lastIndexOf(u8, p, key)) |i| return p[i + key.len ..];
    return p;
}

fn readFile(io: Io, gpa: Allocator, path: []const u8) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}
