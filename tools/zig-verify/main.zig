//! zig-verify: minisign verification and the toolchain pin.
//!
//!   zig-verify verify --pubkey <b64> --file <path> --sig <path>
//!   zig-verify pin --version 0.16.0 --out .github/zig-toolchain.txt
//!       [--mirrors <url>] [--fallback <base url>] [--pubkey <b64>]
//!
//! `pin` downloads each tier-1 host archive and its `.minisig` from the
//! shuffled community mirrors, falling back to ziglang.org, verifies the
//! signature and `file:` name, and writes the SHA-256 pin file atomically.
//! It refuses to write anything if any archive fails to verify.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
pub const minisign = @import("minisign.zig");

/// The tier-1 hosts in pin order: (pin triple, archive name prefix, suffix).
pub const hosts = [_]struct { triple: []const u8, arch_os: []const u8, ext: []const u8 }{
    .{ .triple = "x86_64-linux", .arch_os = "x86_64-linux", .ext = ".tar.xz" },
    .{ .triple = "aarch64-linux", .arch_os = "aarch64-linux", .ext = ".tar.xz" },
    .{ .triple = "x86_64-windows", .arch_os = "x86_64-windows", .ext = ".zip" },
    .{ .triple = "aarch64-windows", .arch_os = "aarch64-windows", .ext = ".zip" },
};

pub const PinEntry = struct { triple: []const u8, file: []const u8, sha256: [64]u8 };

/// `zig-<arch>-<os>-<version><ext>`.
pub fn archiveName(buf: []u8, arch_os: []const u8, version: []const u8, ext: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "zig-{s}-{s}{s}", .{ arch_os, version, ext }) catch unreachable;
}

/// Writes the pin file in the F02 format.
pub fn writePin(w: *Io.Writer, version: []const u8, pubkey: []const u8, entries: []const PinEntry) Io.Writer.Error!void {
    try w.writeAll("# Zig toolchain pin. Regenerate with `zig build zig-pin -Dzig-version=<v>`; see docs/ci.md.\n");
    try w.print("version {s}\npubkey {s}\n", .{ version, pubkey });
    for (entries) |e| try w.print("{s: <15} {s: <33} {s}\n", .{ e.triple, e.file, e.sha256 });
}

/// One parsed pin file (slices point into the source text).
pub const Pin = struct {
    version: []const u8,
    pubkey: []const u8,
    entries: [hosts.len]struct { triple: []const u8, file: []const u8, sha256: []const u8 },
    len: usize,
};

pub fn parsePin(text: []const u8) error{MalformedPin}!Pin {
    var p: Pin = .{ .version = "", .pubkey = "", .entries = undefined, .len = 0 };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        if (line.len == 0) continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const a = f.next().?;
        const b = f.next() orelse return error.MalformedPin;
        if (std.mem.eql(u8, a, "version")) {
            p.version = b;
        } else if (std.mem.eql(u8, a, "pubkey")) {
            p.pubkey = b;
        } else {
            const c = f.next() orelse return error.MalformedPin;
            if (c.len != 64 or p.len == hosts.len) return error.MalformedPin;
            p.entries[p.len] = .{ .triple = a, .file = b, .sha256 = c };
            p.len += 1;
        }
        if (f.next() != null) return error.MalformedPin;
    }
    if (p.version.len == 0 or p.pubkey.len == 0) return error.MalformedPin;
    return p;
}

/// Mirror URLs from `community-mirrors.txt` (one per line, `#` comments).
pub fn parseMirrors(gpa: Allocator, text: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "https://")) continue;
        try out.append(gpa, std.mem.trimEnd(u8, line, "/"));
    }
    return out.toOwnedSlice(gpa);
}

fn fetchAlloc(client: *std.http.Client, gpa: Allocator, url: []const u8) !?[]u8 {
    var aw: Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const res = client.fetch(.{ .location = .{ .url = url }, .response_writer = &aw.writer }) catch |err| {
        std.log.warn("{s}: {t}", .{ url, err });
        aw.deinit();
        return null;
    };
    if (res.status != .ok) {
        std.log.warn("{s}: HTTP {d}", .{ url, @intFromEnum(res.status) });
        aw.deinit();
        return null;
    }
    return try aw.toOwnedSlice();
}

const PinArgs = struct {
    version: []const u8 = "0.16.0",
    out: []const u8 = ".github/zig-toolchain.txt",
    mirrors: []const u8 = "https://ziglang.org/download/community-mirrors.txt",
    fallback: []const u8 = "https://ziglang.org/download",
    pubkey: []const u8 = minisign.zsf_public_key,
};

fn pin(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, a: PinArgs) !u8 {
    const pk = try minisign.PublicKey.parseBase64(a.pubkey);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    try client.initDefaultProxies(gpa, env);

    var mirrors: [][]const u8 = &.{};
    if (try fetchAlloc(&client, gpa, a.mirrors)) |text| mirrors = try parseMirrors(gpa, text);
    const src: std.Random.IoSource = .{ .io = io };
    src.interface().shuffle([]const u8, mirrors);

    var entries: [hosts.len]PinEntry = undefined;
    for (hosts, &entries) |h, *e| {
        var nb: [128]u8 = undefined;
        const file = try gpa.dupe(u8, archiveName(&nb, h.arch_os, a.version, h.ext));
        e.* = .{ .triple = h.triple, .file = file, .sha256 = undefined };
        var done = false;
        for (0..mirrors.len + 1) |i| {
            const base = if (i < mirrors.len) mirrors[i] else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ a.fallback, a.version });
            const q = if (i < mirrors.len) "?source=zigguro-ci" else "";
            const data = (try fetchAlloc(&client, gpa, try std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ base, file, q }))) orelse continue;
            const sig_text = (try fetchAlloc(&client, gpa, try std.fmt.allocPrint(gpa, "{s}/{s}.minisig{s}", .{ base, file, q }))) orelse continue;
            const sig = minisign.Signature.parse(sig_text) catch {
                std.log.warn("{s}: malformed signature from {s}", .{ file, base });
                continue;
            };
            var r: Io.Reader = .fixed(data);
            minisign.verify(pk, sig, &r, file) catch |err| {
                std.log.err("{s}: signature check failed ({t}) from {s}", .{ file, err, base });
                continue;
            };
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
            e.sha256 = std.fmt.bytesToHex(digest, .lower);
            std.log.info("{s}: verified ({s})", .{ file, base });
            done = true;
            break;
        }
        if (!done) {
            std.log.err("{s}: no source produced a verified archive; pin not written", .{file});
            return 1;
        }
    }

    var out: Io.Writer.Allocating = .init(gpa);
    try writePin(&out.writer, a.version, a.pubkey, &entries);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{a.out});
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = out.written() });
    try cwd.rename(tmp, cwd, a.out, io);
    std.log.info("wrote {s}", .{a.out});
    return 0;
}

fn verifyCmd(gpa: Allocator, io: Io, pubkey: []const u8, file: []const u8, sig_path: []const u8) !u8 {
    const pk = try minisign.PublicKey.parseBase64(pubkey);
    const sig_text = try Io.Dir.cwd().readFileAlloc(io, sig_path, gpa, .limited(4096));
    const sig = try minisign.Signature.parse(sig_text);
    var f = try Io.Dir.cwd().openFile(io, file, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fr = f.reader(io, &buf);
    minisign.verify(pk, sig, &fr.interface, std.fs.path.basename(file)) catch |err| {
        std.log.err("{s}: {t}", .{ file, err });
        return 1;
    };
    std.log.info("{s}: signature and trusted comment verified", .{file});
    return 0;
}

const usage =
    \\usage: zig-verify verify --pubkey <b64> --file <path> --sig <path>
    \\       zig-verify pin --version <v> --out <path> [--mirrors <url>] [--fallback <url>] [--pubkey <b64>]
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) {
        std.debug.print(usage, .{});
        return 2;
    }
    var opt: std.StringHashMapUnmanaged([]const u8) = .empty;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (!std.mem.startsWith(u8, args[i], "--")) break;
        try opt.put(gpa, args[i][2..], args[i + 1]);
    }
    if (i != args.len) {
        std.debug.print(usage, .{});
        return 2;
    }
    if (std.mem.eql(u8, args[1], "verify")) {
        return verifyCmd(gpa, io, opt.get("pubkey") orelse minisign.zsf_public_key, opt.get("file") orelse return 2, opt.get("sig") orelse return 2);
    }
    if (std.mem.eql(u8, args[1], "pin")) {
        var a: PinArgs = .{};
        inline for (.{ "version", "out", "mirrors", "fallback", "pubkey" }) |k| {
            if (opt.get(k)) |v| @field(a, k) = v;
        }
        return pin(gpa, io, init.environ_map, a);
    }
    std.debug.print(usage, .{});
    return 2;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test {
    _ = minisign;
}

test "pin: write and parse round trip" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var entries: [hosts.len]PinEntry = undefined;
    var names: [hosts.len][128]u8 = undefined;
    for (hosts, &entries, &names, 0..) |h, *e, *nb, k| {
        e.* = .{ .triple = h.triple, .file = archiveName(nb, h.arch_os, "0.16.0", h.ext), .sha256 = @splat(@intCast('a' + k)) };
    }
    try writePin(&aw.writer, "0.16.0", minisign.zsf_public_key, &entries);
    const p = try parsePin(aw.written());
    try testing.expectEqualStrings("0.16.0", p.version);
    try testing.expectEqualStrings(minisign.zsf_public_key, p.pubkey);
    try testing.expectEqual(hosts.len, p.len);
    try testing.expectEqualStrings("zig-aarch64-windows-0.16.0.zip", p.entries[3].file);
    try testing.expectEqualStrings("aarch64-windows", p.entries[3].triple);
    try testing.expectEqualStrings(&entries[1].sha256, p.entries[1].sha256);
    try testing.expect(std.mem.indexOf(u8, aw.written(), "x86_64-linux    zig-x86_64-linux-0.16.0.tar.xz    ") != null);
    try testing.expectError(error.MalformedPin, parsePin("version 0.16.0\n"));
    try testing.expectError(error.MalformedPin, parsePin("version 0.16.0\npubkey k\nx86_64-linux f short\n"));
}

test "pin: mirror list parsing" {
    const m = try parseMirrors(testing.allocator, "# comment\nhttps://a.example/zig/\n\nhttp://insecure.example\r\nhttps://b.example\n");
    defer testing.allocator.free(m);
    try testing.expectEqual(@as(usize, 2), m.len);
    try testing.expectEqualStrings("https://a.example/zig", m[0]);
    try testing.expectEqualStrings("https://b.example", m[1]);
}
