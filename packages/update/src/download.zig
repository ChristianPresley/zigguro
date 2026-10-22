//! Resumable, verified artifact download (E17.F04.S01.T02).
//!
//! The archive streams into `<dir>/<name>.partial`, hashed with SHA-256 as
//! it arrives and never allowed past the manifest's size. Next to it,
//! `<name>.partial.zon` records `{url, etag, size}` so an interrupted
//! download resumes with `Range` and `If-Range`; std has no serializable
//! SHA-256 state, so a resume re-hashes the bytes already on disk first.
//! A server that ignores the range (200) restarts the file. Only a
//! download whose size and hash match is renamed to `<dir>/<name>`; a
//! mismatch deletes the partial file.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_net = @import("zg_net");
const manifest = @import("manifest.zig");
const fetch = @import("fetch.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Writes reach the disk in chunks of this size.
pub const chunk_bytes = 256 * 1024;

pub const Result = struct {
    /// `name` inside the download directory.
    name: []const u8,
    bytes: u64,
};

pub const Error = error{
    /// More bytes arrived than the manifest's size.
    ArtifactTooLarge,
    /// The response ended short of the manifest's size.
    SizeMismatch,
    HashMismatch,
    BadStatus,
    Canceled,
};

/// What `.partial.zon` records.
const Meta = struct {
    url: []const u8,
    etag: []const u8,
    size: u64,
};

/// Downloads `art` into `dir` as `name`, resuming a matching partial
/// download. `progress` holds the bytes on disk so far.
pub fn download(
    arena: Allocator,
    io: Io,
    http: *zg_net.http.Client,
    dir: Io.Dir,
    art: manifest.Artifact,
    name: []const u8,
    progress: *std.atomic.Value(u64),
    cancel: *const std.atomic.Value(bool),
    opts: fetch.Options,
) anyerror!Result {
    const partial = try std.mem.concat(arena, u8, &.{ name, ".partial" });
    const meta_name = try std.mem.concat(arena, u8, &.{ name, ".partial.zon" });

    var st: Stream = .{ .io = io, .dir = dir, .meta_name = meta_name, .art = art, .progress = progress, .cancel = cancel, .file = undefined, .w = undefined };
    var range_buf: [64]u8 = undefined;
    var headers_buf: [2]std.http.Header = undefined;
    var headers: []const std.http.Header = &.{};

    const resume_from = try resumable(arena, io, dir, partial, meta_name, art);
    if (resume_from) |r| {
        st.file = try dir.openFile(io, partial, .{ .mode = .read_write });
        st.written = try rehash(io, st.file, r.len, &st.hash);
        headers_buf = .{
            .{ .name = "Range", .value = try std.fmt.bufPrint(&range_buf, "bytes={d}-", .{st.written}) },
            .{ .name = "If-Range", .value = r.etag },
        };
        headers = &headers_buf;
        st.resumed = true;
    } else {
        dir.deleteFile(io, meta_name) catch {};
        st.file = try dir.createFile(io, partial, .{ .truncate = true });
    }
    progress.store(st.written, .release);
    var wbuf: [chunk_bytes]u8 = undefined;
    st.w = st.file.writer(io, &wbuf);
    try st.w.seekTo(st.written);

    {
        defer st.file.close(io);
        if (st.written < art.size) {
            const final = fetch.streamHttps(arena, http, art.url, headers, st.bodySink(), opts) catch |err| {
                st.w.interface.flush() catch {};
                if (err == error.ArtifactTooLarge) discard(io, dir, partial, meta_name);
                return err;
            };
            try st.w.interface.flush();
            if (final.status != .ok and final.status != .partial_content) return error.BadStatus;
        }
    }
    if (st.written != art.size) {
        discard(io, dir, partial, meta_name);
        return error.SizeMismatch;
    }
    var digest: [32]u8 = undefined;
    st.hash.final(&digest);
    if (!std.crypto.timing_safe.eql([32]u8, digest, art.sha256)) {
        discard(io, dir, partial, meta_name);
        return error.HashMismatch;
    }
    try dir.rename(partial, dir, name, io);
    dir.deleteFile(io, meta_name) catch {};
    return .{ .name = name, .bytes = st.written };
}

fn discard(io: Io, dir: Io.Dir, partial: []const u8, meta_name: []const u8) void {
    dir.deleteFile(io, partial) catch {};
    dir.deleteFile(io, meta_name) catch {};
}

const Resume = struct { len: u64, etag: []const u8 };

/// A partial download of the same URL and size with an ETag, shorter
/// than the artifact.
fn resumable(arena: Allocator, io: Io, dir: Io.Dir, partial: []const u8, meta_name: []const u8, art: manifest.Artifact) !?Resume {
    const text = dir.readFileAllocOptions(io, meta_name, arena, .limited(4096), .of(u8), 0) catch return null;
    const m = std.zon.parse.fromSliceAlloc(Meta, arena, text, null, .{}) catch return null;
    if (!std.mem.eql(u8, m.url, art.url) or m.size != art.size or m.etag.len == 0) return null;
    const stat = dir.statFile(io, partial, .{}) catch return null;
    if (stat.size > art.size) return null;
    return .{ .len = stat.size, .etag = m.etag };
}

fn writeMeta(io: Io, dir: Io.Dir, meta_name: []const u8, m: Meta) !void {
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try std.zon.stringify.serialize(m, .{ .whitespace = false }, &w);
    try dir.writeFile(io, .{ .sub_path = meta_name, .data = w.buffered() });
}

/// Hashes the first `len` bytes of `file`; returns `len`.
fn rehash(io: Io, file: Io.File, len: u64, hash: *Sha256) !u64 {
    var buf: [64 * 1024]u8 = undefined;
    var off: u64 = 0;
    while (off < len) {
        const want: usize = @intCast(@min(buf.len, len - off));
        const n = try file.readPositionalAll(io, buf[0..want], off);
        if (n == 0) break;
        hash.update(buf[0..n]);
        off += n;
    }
    return off;
}

/// The response body's destination.
const Stream = struct {
    io: Io,
    dir: Io.Dir,
    meta_name: []const u8,
    art: manifest.Artifact,
    progress: *std.atomic.Value(u64),
    cancel: *const std.atomic.Value(bool),
    file: Io.File,
    w: Io.File.Writer,
    hash: Sha256 = .init(.{}),
    written: u64 = 0,
    resumed: bool = false,

    fn bodySink(s: *Stream) zg_net.http.BodySink {
        return .{ .ctx = s, .onChunk = onChunk, .onHead = onHead };
    }

    fn onHead(ctx: ?*anyopaque, status: std.http.Status, headers: *const zg_net.http.OwnedHeaders) anyerror!void {
        const s: *Stream = @ptrCast(@alignCast(ctx.?));
        // Network errors keep the partial file; the ETag makes it resumable.
        if (headers.get("etag")) |e| {
            if (status == .ok or status == .partial_content) try writeMeta(s.io, s.dir, s.meta_name, .{ .url = s.art.url, .etag = e, .size = s.art.size });
        }
        switch (status) {
            .partial_content => if (!s.resumed) return error.BadStatus,
            .ok => if (s.written != 0) {
                // The server ignored the range: start over.
                try s.w.seekTo(0);
                try s.file.setLength(s.io, 0);
                s.hash = .init(.{});
                s.written = 0;
                s.progress.store(0, .release);
            },
            else => return error.BadStatus,
        }
    }

    fn onChunk(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const s: *Stream = @ptrCast(@alignCast(ctx.?));
        if (s.cancel.load(.acquire)) return error.Canceled;
        if (bytes.len > s.art.size - s.written) return error.ArtifactTooLarge;
        s.hash.update(bytes);
        try s.w.interface.writeAll(bytes);
        s.written += bytes.len;
        s.progress.store(s.written, .release);
    }
};

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;
const TestServer = zg_net.test_server.TestServer;

/// Serves `/a.zip` (the artifact bytes, honouring `Range` against ETag
/// "e1" unless `ignore_range`), `/short.zip` (truncated) and `/slow.zip`.
const Server = struct {
    var body: []const u8 = &.{};
    var ignore_range = false;
    var ranges_seen: u32 = 0;

    fn h(_: *TestServer, req: *std.http.Server.Request) !void {
        const t = req.head.target;
        var range: ?u64 = null;
        var if_range: ?[]const u8 = null;
        var it = req.iterateHeaders();
        while (it.next()) |hd| {
            if (std.ascii.eqlIgnoreCase(hd.name, "range")) {
                ranges_seen += 1;
                const v = hd.value["bytes=".len .. hd.value.len - 1];
                range = std.fmt.parseInt(u64, v, 10) catch null;
            }
            if (std.ascii.eqlIgnoreCase(hd.name, "if-range")) if_range = hd.value;
        }
        const etag: std.http.Header = .{ .name = "etag", .value = "\"e1\"" };
        if (std.mem.eql(u8, t, "/a.zip")) {
            if (range) |r| if (!ignore_range and if_range != null and std.mem.eql(u8, if_range.?, "\"e1\"")) {
                return req.respond(body[r..], .{ .status = .partial_content, .extra_headers = &.{etag}, .keep_alive = false });
            };
            return req.respond(body, .{ .extra_headers = &.{etag}, .keep_alive = false });
        }
        if (std.mem.eql(u8, t, "/short.zip")) return req.respond(body[0 .. body.len / 2], .{ .extra_headers = &.{etag}, .keep_alive = false });
        if (std.mem.eql(u8, t, "/redirect.zip")) return req.respond("", .{ .status = .found, .extra_headers = &.{.{ .name = "location", .value = "/a.zip" }}, .keep_alive = false });
        return req.respond("", .{ .status = .not_found, .keep_alive = false });
    }
};

const Fixture = struct {
    srv: TestServer,
    tc: fetch.TestClient,
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    body: [300 * 1024]u8,
    progress: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),

    fn init(f: *Fixture) !void {
        for (&f.body, 0..) |*b, i| b.* = @truncate(i *% 131 +% (i >> 9));
        Server.body = &f.body;
        Server.ignore_range = false;
        Server.ranges_seen = 0;
        f.srv = .{ .server = undefined, .port = 0, .max = 64, .handler = Server.h };
        try f.srv.start(testing.io);
        try f.tc.init();
        f.tmp = testing.tmpDir(.{});
        f.arena = .init(testing.allocator);
        f.progress = .init(0);
        f.cancel = .init(false);
    }

    fn deinit(f: *Fixture) void {
        f.arena.deinit();
        f.tmp.cleanup();
        f.tc.deinit();
        f.srv.stop(testing.io);
    }

    fn artifact(f: *Fixture, path: []const u8) !manifest.Artifact {
        var sha: [32]u8 = undefined;
        Sha256.hash(&f.body, &sha, .{});
        return .{ .url = try std.fmt.allocPrint(f.arena.allocator(), "http://127.0.0.1:{d}{s}", .{ f.srv.port, path }), .size = f.body.len, .sha256 = sha };
    }

    fn run(f: *Fixture, art: manifest.Artifact) anyerror!Result {
        return download(f.arena.allocator(), testing.io, f.tc.client, f.tmp.dir, art, "a.zip", &f.progress, &f.cancel, .{ .allow_http = true });
    }

    fn exists(f: *Fixture, name: []const u8) bool {
        _ = f.tmp.dir.statFile(testing.io, name, .{}) catch return false;
        return true;
    }

    /// Leaves the first `n` bytes as a partial download of `art`.
    fn plantPartial(f: *Fixture, art: manifest.Artifact, n: usize) !void {
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zip.partial", .data = f.body[0..n] });
        try writeMeta(testing.io, f.tmp.dir, "a.zip.partial.zon", .{ .url = art.url, .etag = "\"e1\"", .size = art.size });
    }

    fn expectComplete(f: *Fixture) !void {
        var buf: [300 * 1024]u8 = undefined;
        try testing.expectEqualSlices(u8, &f.body, try f.tmp.dir.readFile(testing.io, "a.zip", &buf));
        try testing.expect(!f.exists("a.zip.partial") and !f.exists("a.zip.partial.zon"));
    }
};

test "download: full, through a redirect" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.run(try f.artifact("/redirect.zip"));
    try testing.expectEqual(@as(u64, f.body.len), r.bytes);
    try testing.expectEqual(@as(u64, f.body.len), f.progress.load(.acquire));
    try f.expectComplete();
}

test "download: resume with 206" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const art = try f.artifact("/a.zip");
    try f.plantPartial(art, 100_000);
    _ = try f.run(art);
    try testing.expectEqual(@as(u32, 1), Server.ranges_seen);
    try f.expectComplete();
}

test "download: server ignores range (200) restarts" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const art = try f.artifact("/a.zip");
    try f.plantPartial(art, 100_000);
    Server.ignore_range = true;
    _ = try f.run(art);
    try testing.expectEqual(@as(u32, 1), Server.ranges_seen);
    try f.expectComplete();
}

test "download: size overflow aborts, short body and sha mismatch delete the partial" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var art = try f.artifact("/a.zip");
    art.size -= 1;
    try testing.expectError(error.ArtifactTooLarge, f.run(art));
    try testing.expect(!f.exists("a.zip.partial") and !f.exists("a.zip"));

    try testing.expectError(error.SizeMismatch, f.run(try f.artifact("/short.zip")));
    try testing.expect(!f.exists("a.zip.partial") and !f.exists("a.zip"));

    art = try f.artifact("/a.zip");
    art.sha256[0] ^= 1;
    try testing.expectError(error.HashMismatch, f.run(art));
    try testing.expect(!f.exists("a.zip.partial") and !f.exists("a.zip.partial.zon") and !f.exists("a.zip"));

    try testing.expectError(error.BadStatus, f.run(try f.artifact("/missing.zip")));
}

test "download: cancel mid-way keeps the partial for a resume" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const art = try f.artifact("/a.zip");
    f.cancel.store(true, .release);
    try testing.expectError(error.Canceled, f.run(art));
    try testing.expect(f.exists("a.zip.partial") and !f.exists("a.zip"));
    f.cancel.store(false, .release);
    _ = try f.run(art);
    try f.expectComplete();
}
