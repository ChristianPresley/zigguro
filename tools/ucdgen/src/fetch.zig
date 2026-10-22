//! `ucdgen fetch`: downloads the vendored UCD files for a Unicode version,
//! verifies them against (or records them in) `manifest.zon`, and writes
//! them atomically (`<rel>.tmp` then rename). Maintainer-only; no build
//! step depends on it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const file_list = @import("file_list.zig");
const lib = @import("lib.zig");

/// Downloads one URL; injectable so tests need no network.
pub const Fetcher = struct {
    ctx: ?*anyopaque = null,
    get: *const fn (ctx: ?*anyopaque, gpa: Allocator, url: []const u8) anyerror![]u8,
};

/// What a fetch did.
pub const FetchReport = struct {
    downloaded: u32 = 0,
    verified: u32 = 0,
    /// Files whose digest differs from the manifest (or that it lacks).
    mismatched: []const []const u8 = &.{},
};

/// Where versions live upstream.
pub const default_base = "https://www.unicode.org/Public/{s}/ucd/";
/// License text URL.
pub const license_url = "https://www.unicode.org/license.txt";

/// Fetches every file for `version` from unicode.org into `dest` over
/// HTTPS (proxies from the environment, SSL_CERT_FILE honoured).
pub fn fetch(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map, version: []const u8, dest: std.Io.Dir, update_manifest: bool) !FetchReport {
    var http: HttpFetcher = try .init(gpa, io, environ);
    defer http.deinit();
    const base = try std.fmt.allocPrint(gpa, default_base, .{version});
    defer gpa.free(base);
    return fetchWith(gpa, io, http.fetcher(), base, version, dest, update_manifest);
}

/// `fetch` with an explicit fetcher and base URL (ending in '/').
pub fn fetchWith(gpa: Allocator, io: std.Io, f: Fetcher, base: []const u8, version: []const u8, dest: std.Io.Dir, update_manifest: bool) !FetchReport {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const old = try readManifest(arena, io, dest);

    var report: FetchReport = .{};
    var mismatched: std.ArrayList([]const u8) = .empty;
    var entries: std.ArrayList(lib.ManifestEntry) = .empty;
    for (file_list.files) |rel| {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ base, rel });
        const data = try f.get(f.ctx, gpa, url);
        defer gpa.free(data);
        report.downloaded += 1;
        const hex = digest(data);
        const want = find(old, rel);
        const ok = if (want) |w| std.mem.eql(u8, w, &hex) else false;
        if (ok) report.verified += 1 else try mismatched.append(arena, rel);
        if (ok or update_manifest) try writeAtomic(io, dest, rel, data);
        try entries.append(arena, .{ .file = rel, .sha256 = try arena.dupe(u8, &hex) });
    }
    // LICENSE: downloaded only when absent; always part of the manifest.
    const lic = dest.readFileAlloc(io, file_list.license, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => blk: {
            const data = try f.get(f.ctx, gpa, license_url);
            defer gpa.free(data);
            report.downloaded += 1;
            try writeAtomic(io, dest, file_list.license, data);
            break :blk try arena.dupe(u8, data);
        },
        else => return err,
    };
    try entries.append(arena, .{ .file = file_list.license, .sha256 = try arena.dupe(u8, &digest(lic)) });

    if (update_manifest) {
        var out: std.Io.Writer.Allocating = .init(arena);
        try writeManifest(&out.writer, version, base, entries.items);
        try writeAtomic(io, dest, "manifest.zon", out.written());
    }
    report.mismatched = try gpa.dupe([]const u8, mismatched.items);
    return report;
}

fn find(m: []const lib.ManifestEntry, rel: []const u8) ?[]const u8 {
    for (m) |e| if (std.mem.eql(u8, e.file, rel)) return e.sha256;
    return null;
}

fn digest(data: []const u8) [64]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}

/// The manifest in `dest`, or empty when there is none.
fn readManifest(arena: Allocator, io: std.Io, dest: std.Io.Dir) ![]const lib.ManifestEntry {
    const src = dest.readFileAllocOptions(io, "manifest.zon", arena, .limited(1 << 20), .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    return std.zon.parse.fromSliceAlloc([]const lib.ManifestEntry, arena, src, null, .{});
}

/// Writes a deterministic manifest: a header and entries sorted by path.
pub fn writeManifest(w: *std.Io.Writer, version: []const u8, base: []const u8, entries: []lib.ManifestEntry) !void {
    std.mem.sort(lib.ManifestEntry, entries, {}, struct {
        fn lt(_: void, a: lib.ManifestEntry, b: lib.ManifestEntry) bool {
            return std.mem.lessThan(u8, a.file, b.file);
        }
    }.lt);
    try w.print("// Unicode {s} UCD files fetched from\n// {s} by `ucdgen fetch`.\n// ucdgen verifies every input against these digests.\n.{{\n", .{ version, base });
    for (entries) |e| try w.print("    .{{ .file = \"{s}\", .sha256 = \"{s}\" }},\n", .{ e.file, e.sha256 });
    try w.writeAll("}\n");
}

/// Writes `rel` under `dest` via `<rel>.tmp` and a rename, so an
/// interrupted fetch never leaves a partial file.
pub fn writeAtomic(io: std.Io, dest: std.Io.Dir, rel: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel)) |d| try dest.createDirPath(io, d);
    var buf: [256]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&buf, "{s}.tmp", .{rel});
    errdefer dest.deleteFile(io, tmp) catch {};
    try dest.writeFile(io, .{ .sub_path = tmp, .data = data });
    try std.Io.Dir.rename(dest, tmp, dest, rel, io);
}

/// HTTPS downloads with std.http.Client: redirects followed, 3 retries
/// with backoff.
pub const HttpFetcher = struct {
    gpa: Allocator,
    io: std.Io,
    client: std.http.Client,
    arena: std.heap.ArenaAllocator,

    /// A client with proxies from `environ` and the system CA bundle.
    pub fn init(gpa: Allocator, io: std.Io, environ: *const std.process.Environ.Map) !HttpFetcher {
        var h: HttpFetcher = .{ .gpa = gpa, .io = io, .client = .{ .allocator = gpa, .io = io }, .arena = .init(gpa) };
        try h.client.initDefaultProxies(h.arena.allocator(), environ);
        const now = std.Io.Clock.real.now(io);
        try h.client.ca_bundle.rescan(gpa, io, now);
        if (environ.get("SSL_CERT_FILE")) |path| {
            if (std.fs.path.isAbsolute(path)) h.client.ca_bundle.addCertsFromFilePathAbsolute(gpa, io, now, path) catch {};
        }
        h.client.now = now;
        return h;
    }

    /// Frees the client.
    pub fn deinit(h: *HttpFetcher) void {
        h.client.deinit();
        h.arena.deinit();
    }

    /// The `Fetcher` interface over this client.
    pub fn fetcher(h: *HttpFetcher) Fetcher {
        return .{ .ctx = h, .get = get };
    }

    fn get(ctx: ?*anyopaque, gpa: Allocator, url: []const u8) anyerror![]u8 {
        const h: *HttpFetcher = @ptrCast(@alignCast(ctx.?));
        var attempt: u6 = 0;
        while (true) : (attempt += 1) {
            if (getOnce(h, gpa, url)) |data| return data else |err| {
                if (attempt == 3) {
                    std.debug.print("ucdgen fetch: {s}: {t}\n", .{ url, err });
                    return err;
                }
                try h.io.sleep(.fromSeconds(@as(i64, 1) << attempt), .awake);
            }
        }
    }

    fn getOnce(h: *HttpFetcher, gpa: Allocator, url: []const u8) ![]u8 {
        const uri = try std.Uri.parse(url);
        var req = try h.client.request(.GET, uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
        });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buf: [8 * 1024]u8 = undefined;
        var resp = try req.receiveHead(&redirect_buf);
        if (resp.head.status != .ok) return error.HttpStatus;
        var transfer_buf: [16 * 1024]u8 = undefined;
        const r = resp.reader(&transfer_buf);
        return r.allocRemaining(gpa, .limited(64 << 20)) catch |err| switch (err) {
            // Surface the underlying transport or body error.
            error.ReadFailed => return resp.bodyErr() orelse
                (if (req.connection) |c| c.stream_reader.err orelse error.ReadFailed else error.ReadFailed),
            else => |e| return e,
        };
    }
};

const testing = std.testing;

const FakeFetcher = struct {
    /// Returns "data:<url-suffix>" for every file, a corrupted body for
    /// `corrupt`, and an error for `fail`.
    corrupt: []const u8 = "",
    fail: []const u8 = "",

    fn get(ctx: ?*anyopaque, gpa: Allocator, url: []const u8) anyerror![]u8 {
        const self: *FakeFetcher = @ptrCast(@alignCast(ctx.?));
        if (self.fail.len > 0 and std.mem.endsWith(u8, url, self.fail)) return error.ConnectionRefused;
        if (self.corrupt.len > 0 and std.mem.endsWith(u8, url, self.corrupt)) return gpa.dupe(u8, "tampered");
        return std.fmt.allocPrint(gpa, "data:{s}", .{url});
    }
};

test "manifest roundtrip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake: FakeFetcher = .{};
    const f: Fetcher = .{ .ctx = &fake, .get = FakeFetcher.get };
    const r1 = try fetchWith(testing.allocator, testing.io, f, "https://x/", "18.0.0", tmp.dir, true);
    defer testing.allocator.free(r1.mismatched);
    try testing.expectEqual(@as(u32, file_list.files.len + 1), r1.downloaded);
    // A second fetch verifies everything against the written manifest.
    const r2 = try fetchWith(testing.allocator, testing.io, f, "https://x/", "18.0.0", tmp.dir, false);
    defer testing.allocator.free(r2.mismatched);
    try testing.expectEqual(@as(u32, file_list.files.len), r2.verified);
    try testing.expectEqual(@as(usize, 0), r2.mismatched.len);
    // The manifest parses and lists every file plus LICENSE, sorted.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m = try readManifest(arena.allocator(), testing.io, tmp.dir);
    try testing.expectEqual(file_list.files.len + 1, m.len);
    for (m[1..], m[0 .. m.len - 1]) |b, a| try testing.expect(std.mem.lessThan(u8, a.file, b.file));
    const nested = try tmp.dir.readFileAlloc(testing.io, "emoji/emoji-data.txt", arena.allocator(), .limited(1024));
    try testing.expectEqualStrings("data:https://x/emoji/emoji-data.txt", nested);
}

test "mismatch reported" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake: FakeFetcher = .{};
    const f: Fetcher = .{ .ctx = &fake, .get = FakeFetcher.get };
    const r1 = try fetchWith(testing.allocator, testing.io, f, "https://x/", "18.0.0", tmp.dir, true);
    testing.allocator.free(r1.mismatched);
    fake.corrupt = "LineBreak.txt";
    const r2 = try fetchWith(testing.allocator, testing.io, f, "https://x/", "18.0.0", tmp.dir, false);
    defer testing.allocator.free(r2.mismatched);
    try testing.expectEqual(@as(usize, 1), r2.mismatched.len);
    try testing.expectEqualStrings("LineBreak.txt", r2.mismatched[0]);
    // The mismatching file was not overwritten.
    var buf: [128]u8 = undefined;
    const kept = try tmp.dir.readFile(testing.io, "LineBreak.txt", &buf);
    try testing.expectEqualStrings("data:https://x/LineBreak.txt", kept);
}

test "tmp+rename on failure leaves no partial file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fake: FakeFetcher = .{ .fail = "Scripts.txt" };
    const f: Fetcher = .{ .ctx = &fake, .get = FakeFetcher.get };
    try testing.expectError(error.ConnectionRefused, fetchWith(testing.allocator, testing.io, f, "https://x/", "18.0.0", tmp.dir, true));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "Scripts.txt", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "Scripts.txt.tmp", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "manifest.zon", .{}));
}
