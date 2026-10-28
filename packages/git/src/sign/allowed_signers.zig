//! The allowed signers file (ssh-keygen(1) ALLOWED SIGNERS), which git
//! reads from `gpg.ssh.allowedSignersFile` to decide whose SSH
//! signatures count: `principals [options] keytype base64key`, with the
//! `namespaces=`, `valid-after=`, `valid-before=` and `cert-authority`
//! options. Times without `Z` are read as UTC (zg_git has no zone
//! database).

const std = @import("std");
const Allocator = std.mem.Allocator;
const pubkey = @import("../ssh/pubkey.zig");
const known_hosts = @import("../ssh/known_hosts.zig");

pub const Entry = struct {
    principals: []const u8,
    namespaces: ?[]const u8 = null,
    valid_after: ?i64 = null,
    valid_before: ?i64 = null,
    cert_authority: bool = false,
    blob: []u8,
};

pub const AllowedSigners = struct {
    gpa: Allocator,
    /// A copy of the file; entries' strings point into it.
    text: []u8,
    entries: []Entry,

    pub fn deinit(s: *AllowedSigners) void {
        for (s.entries) |e| s.gpa.free(e.blob);
        s.gpa.free(s.entries);
        s.gpa.free(s.text);
    }

    /// Parses the file. Bad lines are skipped.
    pub fn parse(gpa: Allocator, text_in: []const u8) !AllowedSigners {
        const text = try gpa.dupe(u8, text_in);
        errdefer gpa.free(text);
        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |e| gpa.free(e.blob);
            list.deinit(gpa);
        }
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (try parseLine(gpa, line)) |e| try list.append(gpa, e);
        }
        return .{ .gpa = gpa, .text = text, .entries = try list.toOwnedSlice(gpa) };
    }

    /// The principals of the first entry that lists this key for
    /// `namespace` at `now` (seconds since the epoch). Certificate
    /// authorities are not matched (certificates are not supported).
    pub fn findPrincipals(s: *const AllowedSigners, blob: []const u8, namespace: []const u8, now: i64) ?[]const u8 {
        for (s.entries) |e| {
            if (e.cert_authority or !std.mem.eql(u8, e.blob, blob)) continue;
            if (e.namespaces) |ns| if (!known_hosts.matchList(ns, namespace)) continue;
            if (e.valid_after) |t| if (now < t) continue;
            if (e.valid_before) |t| if (now >= t) continue;
            return e.principals;
        }
        return null;
    }
};

/// The next whitespace-separated field, keeping quoted spans together.
fn field(s: *[]const u8) ?[]const u8 {
    s.* = std.mem.trimStart(u8, s.*, " \t");
    if (s.len == 0) return null;
    var quoted = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s.*[i] == '"') quoted = !quoted;
        if (!quoted and (s.*[i] == ' ' or s.*[i] == '\t')) break;
    }
    defer s.* = s.*[i..];
    return s.*[0..i];
}

fn isKeyType(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "ssh-") or std.mem.startsWith(u8, t, "ecdsa-") or std.mem.startsWith(u8, t, "sk-");
}

fn parseLine(gpa: Allocator, line: []const u8) !?Entry {
    var rest = line;
    const principals = std.mem.trim(u8, field(&rest) orelse return null, "\"");
    var e: Entry = .{ .principals = principals, .blob = undefined };
    var next = field(&rest) orelse return null;
    if (!isKeyType(next)) {
        var start: usize = 0;
        var quoted = false;
        var i: usize = 0;
        while (i <= next.len) : (i += 1) {
            if (i < next.len and next[i] == '"') quoted = !quoted;
            if (i < next.len and (quoted or next[i] != ',')) continue;
            const o = next[start..i];
            start = i + 1;
            const eq = std.mem.indexOfScalar(u8, o, '=');
            const name = if (eq) |q| o[0..q] else o;
            const value = if (eq) |q| std.mem.trim(u8, o[q + 1 ..], "\"") else "";
            if (std.ascii.eqlIgnoreCase(name, "cert-authority")) e.cert_authority = true else if (std.ascii.eqlIgnoreCase(name, "namespaces")) e.namespaces = value else if (std.ascii.eqlIgnoreCase(name, "valid-after")) {
                e.valid_after = parseTime(value) orelse return null;
            } else if (std.ascii.eqlIgnoreCase(name, "valid-before")) {
                e.valid_before = parseTime(value) orelse return null;
            } else return null;
        }
        next = field(&rest) orelse return null;
    }
    const key = std.mem.trimStart(u8, line[@intFromPtr(next.ptr) - @intFromPtr(line.ptr) ..], " \t");
    const t = pubkey.Text.parse(gpa, key) catch return null;
    e.blob = t.blob;
    return e;
}

/// `YYYYMMDD[HHMM[SS]][Z]` to seconds since the epoch.
pub fn parseTime(s0: []const u8) ?i64 {
    var s = s0;
    if (s.len > 0 and (s[s.len - 1] == 'Z' or s[s.len - 1] == 'z')) s = s[0 .. s.len - 1];
    if (s.len != 8 and s.len != 12 and s.len != 14) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[4..6], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[6..8], 10) catch return null;
    const h: i64 = if (s.len >= 12) std.fmt.parseInt(i64, s[8..10], 10) catch return null else 0;
    const mi: i64 = if (s.len >= 12) std.fmt.parseInt(i64, s[10..12], 10) catch return null else 0;
    const sec: i64 = if (s.len == 14) std.fmt.parseInt(i64, s[12..14], 10) catch return null else 0;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    return daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec;
}

fn daysFromCivil(y0: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "allowed signers rules" {
    const gpa = std.testing.allocator;
    const kp = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io);
    var b: @import("../ssh/wire.zig").Builder = .init(gpa);
    defer b.deinit();
    try b.string("ssh-ed25519");
    try b.string(&kp.public_key.toBytes());
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try pubkey.writeText(&w.writer, b.bytes());
    const key = w.written();
    const text = try std.fmt.allocPrint(gpa,
        \\# comment
        \\a@x.com,b@x.com namespaces="file,other",valid-after=20200101 {0s}
        \\c@x.com namespaces="git",valid-before="20300101Z" {0s} laptop
        \\*@ca.com cert-authority {0s}
        \\
    , .{key});
    defer gpa.free(text);
    var s = try AllowedSigners.parse(gpa, text);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 3), s.entries.len);
    const t2025 = parseTime("20250101").?;
    try std.testing.expectEqualStrings("c@x.com", s.findPrincipals(b.bytes(), "git", t2025).?);
    try std.testing.expectEqualStrings("a@x.com,b@x.com", s.findPrincipals(b.bytes(), "file", t2025).?);
    try std.testing.expect(s.findPrincipals(b.bytes(), "git", parseTime("20310101").?) == null);
    try std.testing.expectEqual(@as(i64, 1700000000), parseTime("20231114221320Z").?);
}
