//! Cassettes (E10.F10.S02.T01): a `Transport` wrapper that records
//! provider HTTP exchanges, raw SSE bytes and chunk timing included, into
//! a JSONL file and replays them without a network.
//!
//! Requests are matched by an XxHash3 key over the method, the URL path
//! and query, and the body after canonicalization: JSON re-serialized
//! with sorted keys and volatile fields (`metadata.user_id`, cache TTL
//! hints, ...) removed. Duplicate keys are consumed in recorded order.
//!
//! Secrets never reach the file: credential headers and `key=` query
//! parameters become `<redacted>`, and bodies pass through the E16
//! redactor. Recordings are written atomically by `finish`, so an aborted
//! recording leaves no partial cassette.
//!
//! A replay miss fails the request with `error.Aborted` (the transport's
//! error set) and leaves a unified diff against the nearest recorded
//! request in `last_miss`.

const std = @import("std");
const tp = @import("../provider/transport.zig");
const ratelimit = @import("../provider/ratelimit.zig");
const writer_mod = @import("../session/writer.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Header = tp.Header;

pub const Mode = enum {
    /// Pass every request to the inner transport.
    off,
    /// Record every exchange (the file is replaced by `finish`).
    record,
    /// Serve from the file; a request not in it fails.
    replay,
    /// Serve from the file, recording what is missing.
    record_missing,
};

/// One body chunk and the time since the previous one.
pub const Chunk = struct {
    dt_ms: u32,
    bytes: []const u8,
};

/// One recorded exchange.
pub const Entry = struct {
    req_hash: u64,
    method: []const u8,
    url: []const u8,
    req_headers: []const Header,
    req_body: []const u8,
    status: u16,
    resp_headers: []const Header,
    chunks: []const Chunk,
};

/// Header values replaced by `<redacted>` (case-insensitive).
pub const secret_headers = [_][]const u8{ "authorization", "x-api-key", "x-goog-api-key", "api-key", "openai-organization", "openai-project", "cookie", "set-cookie", "proxy-authorization" };

/// Key paths dropped before hashing; a rule matches a path that equals it
/// or ends with `.` + it.
pub const default_volatile = [_][]const u8{ "metadata.user_id", "cache_control.ttl", "prompt_cache_key", "safety_identifier" };

pub const Options = struct {
    /// `ZG_CASSETTE_SPEED`: 0 replays instantly, 1 with recorded timing.
    speed: u8 = 0,
    /// Sleeps for timed replay (tests inject a fake clock).
    clock: ratelimit.Clock = .real,
    volatile_keys: []const []const u8 = &default_volatile,
    /// E16 redactor applied to bodies before writing.
    redactor: writer_mod.Redactor = .{},
    /// Print the diff of a replay miss to stderr.
    print_misses: bool = false,
};

pub const Cassette = struct {
    gpa: Allocator,
    io: Io,
    path: []const u8,
    mode: Mode,
    opts: Options,
    /// Owns entries, recordings and miss reports.
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    used: std.ArrayList(bool) = .empty,
    /// Entries recorded in this run.
    recorded: std.ArrayList(Entry) = .empty,
    inner: ?tp.Transport = null,
    mutex: Io.Mutex = .init,
    /// Diff of the latest replay miss.
    last_miss: ?[]const u8 = null,
    replays: u32 = 0,

    /// Opens `path` (read in the replay modes; it need not exist for
    /// `record` and `record_missing`).
    pub fn open(io: Io, gpa: Allocator, path: []const u8, mode: Mode, opts: Options) !*Cassette {
        const c = try gpa.create(Cassette);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .path = "", .mode = mode, .opts = opts, .arena = .init(gpa) };
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.path = try a.dupe(u8, path);
        if (mode == .replay or mode == .record_missing) {
            const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 30)) catch |e| switch (e) {
                error.FileNotFound => if (mode == .record_missing) "" else return e,
                else => return e,
            };
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.trim(u8, line, " \r").len == 0) continue;
                try c.entries.append(a, try decodeEntry(a, line));
                try c.used.append(a, false);
            }
        }
        return c;
    }

    /// Frees the cassette without writing (an aborted recording).
    pub fn deinit(c: *Cassette) void {
        const gpa = c.gpa;
        c.arena.deinit();
        gpa.destroy(c);
    }

    /// The transport view. `inner` serves `off`, `record` and the misses
    /// of `record_missing`.
    pub fn transport(c: *Cassette, inner: ?tp.Transport) tp.Transport {
        c.inner = inner;
        return .{ .ptr = c, .vtable = &.{ .send = send } };
    }

    /// Writes the cassette atomically (record modes; a no-op otherwise or
    /// when `record_missing` recorded nothing).
    pub fn finish(c: *Cassette) !void {
        switch (c.mode) {
            .off, .replay => return,
            .record_missing => if (c.recorded.items.len == 0) return,
            .record => {},
        }
        var out: Io.Writer.Allocating = .init(c.gpa);
        defer out.deinit();
        if (c.mode == .record_missing) for (c.entries.items) |e| try encodeEntry(&out.writer, e);
        for (c.recorded.items) |e| try encodeEntry(&out.writer, e);
        const dir_path = std.fs.path.dirname(c.path) orelse ".";
        try Io.Dir.cwd().createDirPath(c.io, dir_path);
        var dir = try Io.Dir.cwd().openDir(c.io, dir_path, .{});
        defer dir.close(c.io);
        var af = try dir.createFileAtomic(c.io, std.fs.path.basename(c.path), .{ .replace = true });
        defer af.deinit(c.io);
        try af.file.writeStreamingAll(c.io, out.written());
        try af.replace(c.io);
    }

    fn send(ptr: *anyopaque, io: Io, arena: Allocator, req: tp.HttpRequest, sink: tp.ChunkSink) tp.TransportError!tp.Head {
        const c: *Cassette = @ptrCast(@alignCast(ptr));
        if (c.mode == .off) return (c.inner orelse return error.Network).send(io, arena, req, sink);
        const key = requestKey(arena, req, c.opts.volatile_keys) catch return error.OutOfMemory;
        if (c.mode != .record) {
            if (c.take(key)) |e| return c.play(io, arena, e, sink);
            if (c.mode == .replay) {
                c.reportMiss(arena, req) catch {};
                return error.Aborted;
            }
        }
        return c.recordOne(io, arena, req, sink, key);
    }

    /// The first unused entry with `key`, marked used.
    fn take(c: *Cassette, key: u64) ?Entry {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        for (c.entries.items, c.used.items) |e, *u| if (!u.* and e.req_hash == key) {
            u.* = true;
            c.replays += 1;
            return e;
        };
        return null;
    }

    fn play(c: *Cassette, io: Io, arena: Allocator, e: Entry, sink: tp.ChunkSink) tp.TransportError!tp.Head {
        for (e.chunks) |ch| {
            if (c.opts.speed > 0 and ch.dt_ms > 0) c.opts.clock.sleep(io, ch.dt_ms) catch return error.Canceled;
            sink.on_chunk(sink.ctx, ch.bytes) catch return error.Aborted;
        }
        const hs = arena.alloc(Header, e.resp_headers.len) catch return error.OutOfMemory;
        for (e.resp_headers, hs) |h, *o| o.* = .{ .name = arena.dupe(u8, h.name) catch return error.OutOfMemory, .value = arena.dupe(u8, h.value) catch return error.OutOfMemory };
        return .{ .status = e.status, .headers = hs, .request_id = tp.requestIdFrom(hs) };
    }

    fn recordOne(c: *Cassette, io: Io, arena: Allocator, req: tp.HttpRequest, sink: tp.ChunkSink, key: u64) tp.TransportError!tp.Head {
        const inner = c.inner orelse return error.Network;
        var tap: Tap = .{ .c = c, .io = io, .outer = sink, .last = Io.Timestamp.now(io, .awake) };
        const head = try inner.send(io, arena, req, .{ .ctx = &tap, .on_chunk = Tap.onChunk });
        if (tap.oom) return error.OutOfMemory;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        const a = c.arena.allocator();
        c.recorded.append(a, .{
            .req_hash = key,
            .method = @tagName(req.method),
            .url = redactUrl(a, req.url) catch return error.OutOfMemory,
            .req_headers = redactHeaders(a, req.headers) catch return error.OutOfMemory,
            .req_body = c.redactBody(a, req.body) catch return error.OutOfMemory,
            .status = head.status,
            .resp_headers = redactHeaders(a, head.headers) catch return error.OutOfMemory,
            .chunks = tap.chunks.items,
        }) catch return error.OutOfMemory;
        return head;
    }

    fn redactBody(c: *Cassette, a: Allocator, body: []const u8) Allocator.Error![]const u8 {
        const f = c.opts.redactor.redact orelse return a.dupe(u8, body);
        const r = try f(c.opts.redactor.ctx, a, body);
        return a.dupe(u8, r.text);
    }

    /// Fills `last_miss` with a diff against the nearest recorded body.
    fn reportMiss(c: *Cassette, arena: Allocator, req: tp.HttpRequest) !void {
        const want = try canonicalPretty(arena, req.body, c.opts.volatile_keys);
        var best: ?[]const u8 = null;
        var best_d: usize = std.math.maxInt(usize);
        for (c.entries.items) |e| {
            const have = try canonicalPretty(arena, e.req_body, c.opts.volatile_keys);
            const d = try lineDistance(arena, have, want);
            if (d < best_d) {
                best_d = d;
                best = have;
            }
        }
        var out: std.ArrayList(u8) = .empty;
        const a = c.arena.allocator();
        try out.print(a, "cassette miss: {s} {s} ({s})\n", .{ @tagName(req.method), try redactUrl(arena, req.url), c.path });
        if (best) |b| {
            try out.appendSlice(a, "--- nearest recorded request\n+++ this request\n");
            try unifiedDiff(a, &out, b, want);
        } else try out.appendSlice(a, "(the cassette is empty)\n");
        c.last_miss = out.items;
        if (c.opts.print_misses) std.debug.print("{s}", .{out.items});
    }
};

/// Records chunks with their timing while forwarding them.
const Tap = struct {
    c: *Cassette,
    io: Io,
    outer: tp.ChunkSink,
    last: Io.Timestamp,
    chunks: std.ArrayList(Chunk) = .empty,
    oom: bool = false,

    fn onChunk(ctx: *anyopaque, bytes: []const u8) anyerror!void {
        const t: *Tap = @ptrCast(@alignCast(ctx));
        const now = Io.Timestamp.now(t.io, .awake);
        const dt: u32 = @intCast(std.math.clamp(t.last.durationTo(now).toMilliseconds(), 0, std.math.maxInt(u32)));
        t.last = now;
        {
            t.c.mutex.lockUncancelable(t.io);
            defer t.c.mutex.unlock(t.io);
            const a = t.c.arena.allocator();
            const copy = t.c.redactBody(a, bytes) catch blk: {
                t.oom = true;
                break :blk "";
            };
            t.chunks.append(a, .{ .dt_ms = dt, .bytes = copy }) catch {
                t.oom = true;
            };
        }
        try t.outer.on_chunk(t.outer.ctx, bytes);
    }
};

/// The matching key of a request.
pub fn requestKey(arena: Allocator, req: tp.HttpRequest, volatile_keys: []const []const u8) Allocator.Error!u64 {
    var h: std.hash.XxHash3 = .init(0);
    h.update(@tagName(req.method));
    h.update("\x00");
    // Redacted, so a replay with another API key still matches.
    h.update(try redactUrl(arena, pathAndQuery(req.url)));
    h.update("\x00");
    h.update(try canonicalBody(arena, req.body, volatile_keys));
    return h.final();
}

/// `/path?query` of a URL (the whole string when it has no scheme).
pub fn pathAndQuery(url: []const u8) []const u8 {
    const after = if (std.mem.indexOf(u8, url, "://")) |i| url[i + 3 ..] else return url;
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return "/";
    return after[slash..];
}

/// JSON with sorted keys and volatile fields removed; other bodies as is.
pub fn canonicalBody(arena: Allocator, body: []const u8, volatile_keys: []const []const u8) Allocator.Error![]const u8 {
    return canonical(arena, body, volatile_keys, false);
}

/// `canonicalBody` with one value per line, for diffs.
pub fn canonicalPretty(arena: Allocator, body: []const u8, volatile_keys: []const []const u8) Allocator.Error![]const u8 {
    return canonical(arena, body, volatile_keys, true);
}

fn canonical(arena: Allocator, body: []const u8, volatile_keys: []const []const u8, pretty: bool) Allocator.Error![]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return body,
    };
    var out: Io.Writer.Allocating = .init(arena);
    var path: std.ArrayList(u8) = .empty;
    writeCanonical(arena, &out.writer, v, volatile_keys, &path, pretty, 0) catch return error.OutOfMemory;
    return out.written();
}

fn writeCanonical(arena: Allocator, w: *Io.Writer, v: std.json.Value, rules: []const []const u8, path: *std.ArrayList(u8), pretty: bool, depth: usize) !void {
    switch (v) {
        .object => |o| {
            const keys = try arena.dupe([]const u8, o.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            try w.writeByte('{');
            var first = true;
            for (keys) |k| {
                const mark = path.items.len;
                if (mark > 0) try path.append(arena, '.');
                try path.appendSlice(arena, k);
                defer path.items.len = mark;
                if (dropped(path.items, rules)) continue;
                if (!first) try w.writeByte(',');
                first = false;
                if (pretty) try indent(w, depth + 1);
                try std.json.Stringify.value(k, .{}, w);
                try w.writeByte(':');
                try writeCanonical(arena, w, o.get(k).?, rules, path, pretty, depth + 1);
            }
            if (pretty and !first) try indent(w, depth);
            try w.writeByte('}');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                if (pretty) try indent(w, depth + 1);
                try writeCanonical(arena, w, x, rules, path, pretty, depth + 1);
            }
            if (pretty and arr.items.len > 0) try indent(w, depth);
            try w.writeByte(']');
        },
        else => try std.json.Stringify.value(v, .{}, w),
    }
}

fn indent(w: *Io.Writer, depth: usize) !void {
    try w.writeByte('\n');
    try w.splatByteAll(' ', depth * 2);
}

fn dropped(path: []const u8, rules: []const []const u8) bool {
    for (rules) |r| {
        if (std.mem.eql(u8, path, r)) return true;
        if (path.len > r.len and std.mem.endsWith(u8, path, r) and path[path.len - r.len - 1] == '.') return true;
    }
    return false;
}

fn isSecretHeader(name: []const u8) bool {
    for (secret_headers) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    // anthropic-*-key and similar.
    return std.ascii.endsWithIgnoreCase(name, "-key") or std.ascii.endsWithIgnoreCase(name, "-token");
}

/// Copies `hs` with secret values replaced.
pub fn redactHeaders(a: Allocator, hs: []const Header) Allocator.Error![]const Header {
    const out = try a.alloc(Header, hs.len);
    for (hs, out) |h, *o| o.* = .{ .name = try a.dupe(u8, h.name), .value = if (isSecretHeader(h.name)) "<redacted>" else try a.dupe(u8, h.value) };
    return out;
}

/// Copies `url` with `key=` and `api_key=` query values replaced.
pub fn redactUrl(a: Allocator, url: []const u8) Allocator.Error![]const u8 {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return a.dupe(u8, url);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, url[0 .. q + 1]);
    var it = std.mem.splitScalar(u8, url[q + 1 ..], '&');
    var first = true;
    while (it.next()) |p| {
        if (!first) try out.append(a, '&');
        first = false;
        const eq = std.mem.indexOfScalar(u8, p, '=') orelse {
            try out.appendSlice(a, p);
            continue;
        };
        const name = p[0..eq];
        if (std.ascii.eqlIgnoreCase(name, "key") or std.ascii.eqlIgnoreCase(name, "api_key") or std.ascii.eqlIgnoreCase(name, "access_token")) {
            try out.print(a, "{s}=<redacted>", .{name});
        } else try out.appendSlice(a, p);
    }
    return out.items;
}

/// Lines that differ between `a` and `b` (n + m - 2 * LCS).
fn lineDistance(arena: Allocator, a: []const u8, b: []const u8) Allocator.Error!usize {
    const la = try splitLines(arena, a);
    const lb = try splitLines(arena, b);
    const l = try lcs(arena, la, lb);
    return la.len + lb.len - 2 * l[0];
}

fn splitLines(arena: Allocator, s: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| try out.append(arena, l);
    return out.items;
}

/// The LCS table of suffixes, row-major `(la.len + 1) * (lb.len + 1)`.
fn lcs(arena: Allocator, la: []const []const u8, lb: []const []const u8) Allocator.Error![]usize {
    const w = lb.len + 1;
    const t = try arena.alloc(usize, (la.len + 1) * w);
    @memset(t, 0);
    var i = la.len;
    while (i > 0) {
        i -= 1;
        var j = lb.len;
        while (j > 0) {
            j -= 1;
            t[i * w + j] = if (std.mem.eql(u8, la[i], lb[j])) t[(i + 1) * w + j + 1] + 1 else @max(t[(i + 1) * w + j], t[i * w + j + 1]);
        }
    }
    return t;
}

/// Appends a line diff of `old` → `new` (" ", "-", "+" prefixes).
fn unifiedDiff(a: Allocator, out: *std.ArrayList(u8), old: []const u8, new: []const u8) Allocator.Error!void {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const la = try splitLines(arena.allocator(), old);
    const lb = try splitLines(arena.allocator(), new);
    const t = try lcs(arena.allocator(), la, lb);
    const w = lb.len + 1;
    var i: usize = 0;
    var j: usize = 0;
    while (i < la.len or j < lb.len) {
        if (i < la.len and j < lb.len and std.mem.eql(u8, la[i], lb[j])) {
            try out.print(a, " {s}\n", .{la[i]});
            i += 1;
            j += 1;
        } else if (j < lb.len and (i == la.len or t[i * w + j + 1] >= t[(i + 1) * w + j])) {
            try out.print(a, "+{s}\n", .{lb[j]});
            j += 1;
        } else {
            try out.print(a, "-{s}\n", .{la[i]});
            i += 1;
        }
    }
}

// JSONL encoding. Bodies are text when valid UTF-8, else base64.

fn encodeEntry(w: *Io.Writer, e: Entry) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("req_hash");
    try s.write(e.req_hash);
    try s.objectField("method");
    try s.write(e.method);
    try s.objectField("url");
    try s.write(e.url);
    try s.objectField("req_headers");
    try writeHeaders(&s, e.req_headers);
    try writeBytes(&s, "req_body", e.req_body);
    try s.objectField("status");
    try s.write(e.status);
    try s.objectField("resp_headers");
    try writeHeaders(&s, e.resp_headers);
    try s.objectField("chunks");
    try s.beginArray();
    for (e.chunks) |c| {
        try s.beginObject();
        try s.objectField("dt_ms");
        try s.write(c.dt_ms);
        try writeBytes(&s, "text", c.bytes);
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try w.writeByte('\n');
}

fn writeHeaders(s: *std.json.Stringify, hs: []const Header) !void {
    try s.beginArray();
    for (hs) |h| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(h.name);
        try s.objectField("value");
        try s.write(h.value);
        try s.endObject();
    }
    try s.endArray();
}

/// Writes `name` as text, or `name_b64` when `bytes` is not UTF-8.
fn writeBytes(s: *std.json.Stringify, comptime name: []const u8, bytes: []const u8) !void {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        try s.objectField(name);
        try s.write(bytes);
        return;
    }
    try s.objectField(name ++ "_b64");
    var buf: [4096]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    try s.beginWriteRaw();
    try s.writer.writeByte('"');
    var i: usize = 0;
    while (i < bytes.len) {
        const n = @min(3 * (buf.len / 4), bytes.len - i);
        try s.writer.writeAll(enc.encode(&buf, bytes[i .. i + n]));
        i += n;
    }
    try s.writer.writeByte('"');
    s.endWriteRaw();
}

fn decodeEntry(a: Allocator, line: []const u8) !Entry {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch return error.InvalidCassette;
    if (v != .object) return error.InvalidCassette;
    const o = v.object;
    const chunks_v = o.get("chunks") orelse return error.InvalidCassette;
    if (chunks_v != .array) return error.InvalidCassette;
    const chunks = try a.alloc(Chunk, chunks_v.array.items.len);
    for (chunks_v.array.items, chunks) |cv, *c| {
        if (cv != .object) return error.InvalidCassette;
        c.* = .{ .dt_ms = @intCast(intOf(cv.object, "dt_ms") orelse 0), .bytes = try bytesOf(a, cv.object, "text") };
    }
    return .{
        .req_hash = @intCast(intOf(o, "req_hash") orelse return error.InvalidCassette),
        .method = strOf(o, "method") orelse "POST",
        .url = strOf(o, "url") orelse "",
        .req_headers = try headersOf(a, o.get("req_headers")),
        .req_body = try bytesOf(a, o, "req_body"),
        .status = @intCast(intOf(o, "status") orelse return error.InvalidCassette),
        .resp_headers = try headersOf(a, o.get("resp_headers")),
        .chunks = chunks,
    };
}

fn intOf(o: std.json.ObjectMap, k: []const u8) ?u64 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch null,
        else => null,
    };
}

fn strOf(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

fn bytesOf(a: Allocator, o: std.json.ObjectMap, comptime k: []const u8) ![]const u8 {
    if (strOf(o, k)) |s| return s;
    const b = strOf(o, k ++ "_b64") orelse return "";
    const dec = std.base64.standard.Decoder;
    const out = try a.alloc(u8, dec.calcSizeForSlice(b) catch return error.InvalidCassette);
    dec.decode(out, b) catch return error.InvalidCassette;
    return out;
}

fn headersOf(a: Allocator, v: ?std.json.Value) ![]const Header {
    const arr = v orelse return &.{};
    if (arr != .array) return error.InvalidCassette;
    const out = try a.alloc(Header, arr.array.items.len);
    for (arr.array.items, out) |h, *o| {
        if (h != .object) return error.InvalidCassette;
        o.* = .{ .name = strOf(h.object, "name") orelse "", .value = strOf(h.object, "value") orelse "" };
    }
    return out;
}

test "path and query" {
    try std.testing.expectEqualStrings("/v1/messages?beta=true", pathAndQuery("https://api.anthropic.com/v1/messages?beta=true"));
    try std.testing.expectEqualStrings("/", pathAndQuery("http://localhost:8080"));
}
