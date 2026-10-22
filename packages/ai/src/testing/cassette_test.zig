//! Tests for cassette.zig (E10.F10.S02.T01).

const std = @import("std");
const proto = @import("zg_ai_proto");
const cassette = @import("cassette.zig");
const tp = @import("../provider/transport.zig");
const fake = @import("../provider/fake_server.zig");
const ratelimit = @import("../provider/ratelimit.zig");
const writer_mod = @import("../session/writer.zig");
const Anthropic = @import("../provider/anthropic/Anthropic.zig");

const testing = std.testing;
const io = testing.io;
const Cassette = cassette.Cassette;

/// A cassette path inside a fresh tmp dir.
const Tmp = struct {
    dir: testing.TmpDir,
    buf: [128]u8 = undefined,

    fn init() Tmp {
        return .{ .dir = testing.tmpDir(.{}) };
    }

    fn path(t: *Tmp, name: []const u8) []const u8 {
        return std.fmt.bufPrint(&t.buf, ".zig-cache/tmp/{s}/{s}", .{ &t.dir.sub_path, name }) catch unreachable;
    }

    fn read(t: *Tmp, name: []const u8) ![]u8 {
        return t.dir.dir.readFileAlloc(io, name, testing.allocator, .limited(1 << 20));
    }
};

fn send(t: tp.Transport, arena: std.mem.Allocator, req: tp.HttpRequest) !struct { head: tp.Head, body: []const u8 } {
    const r = try t.sendCollect(io, arena, req);
    return .{ .head = r.head, .body = r.body };
}

const sse_body = "event: message_start\ndata: {\"a\":1}\n\nevent: ping\ndata: {}\n\nevent: message_stop\ndata: {}\n\n";

test "record then replay is byte exact" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const routes = [_]fake.Route{.{ .body = sse_body, .chunk_size = 7, .headers = &.{ .{ .name = "request-id", .value = "req_1" }, .{ .name = "content-type", .value = "text/event-stream" } } }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: tp.HttpRequest = .{ .url = "https://api.test/v1/messages", .body = "{\"model\":\"m\",\"stream\":true}" };
    {
        const c = try Cassette.open(io, testing.allocator, tmp.path("c.jsonl"), .record, .{});
        defer c.deinit();
        const r = try send(c.transport(f.transport()), arena.allocator(), req);
        try testing.expectEqualStrings(sse_body, r.body);
        try c.finish();
    }
    try testing.expectEqual(@as(usize, 1), f.requests().len);

    const c = try Cassette.open(io, testing.allocator, tmp.path("c.jsonl"), .replay, .{});
    defer c.deinit();
    const Rec = struct {
        n: usize = 0,
        fn on(ctx: *anyopaque, _: []const u8) anyerror!void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.n += 1;
        }
    };
    // Chunk boundaries are kept.
    var rec: Rec = .{};
    const t = c.transport(null);
    _ = try t.send(io, arena.allocator(), req, .{ .ctx = &rec, .on_chunk = Rec.on });
    try testing.expectEqual((sse_body.len + 6) / 7, rec.n);
    // Without a network: no inner transport, and the fake saw nothing new.
    try testing.expectEqual(@as(usize, 1), f.requests().len);
    // A second identical request was recorded once, so it misses.
    try testing.expectError(error.Aborted, send(t, arena.allocator(), req));

    const c2 = try Cassette.open(io, testing.allocator, tmp.path("c.jsonl"), .replay, .{});
    defer c2.deinit();
    const r = try send(c2.transport(null), arena.allocator(), req);
    try testing.expectEqualStrings(sse_body, r.body);
    try testing.expectEqual(@as(u16, 200), r.head.status);
    try testing.expectEqualStrings("req_1", r.head.request_id.?);
}

test "canonicalization ignores key order and volatile fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const k = cassette.default_volatile[0..];
    const one = try cassette.requestKey(a, .{ .url = "https://x/v1/messages", .body = "{\"model\":\"m\",\"metadata\":{\"user_id\":\"u1\"},\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\",\"cache_control\":{\"type\":\"ephemeral\",\"ttl\":\"5m\"}}]}]}" }, k);
    const two = try cassette.requestKey(a, .{ .url = "https://y/v1/messages", .body = "{\"messages\":[{\"content\":[{\"cache_control\":{\"ttl\":\"1h\",\"type\":\"ephemeral\"},\"text\":\"hi\",\"type\":\"text\"}],\"role\":\"user\"}],\"metadata\":{\"user_id\":\"u2\"},\"model\":\"m\"}" }, k);
    try testing.expectEqual(one, two);
    // A real change, a different path or method changes the key.
    const three = try cassette.requestKey(a, .{ .url = "https://x/v1/messages", .body = "{\"model\":\"m2\",\"messages\":[]}" }, k);
    try testing.expect(one != three);
    const four = try cassette.requestKey(a, .{ .url = "https://x/v1/messages?beta=true", .body = "{\"model\":\"m2\",\"messages\":[]}" }, k);
    try testing.expect(three != four);
    const five = try cassette.requestKey(a, .{ .method = .GET, .url = "https://x/v1/messages?beta=true", .body = "{\"model\":\"m2\",\"messages\":[]}" }, k);
    try testing.expect(four != five);
    // Non-JSON bodies hash as they are.
    try testing.expectEqualStrings("a=1", try cassette.canonicalBody(a, "a=1", k));
    try testing.expectEqualStrings("{\"a\":1,\"b\":[2,{\"c\":3}]}", try cassette.canonicalBody(a, "{ \"b\": [2, {\"c\": 3}], \"a\": 1 }", k));
}

test "redaction removes keys" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const routes = [_]fake.Route{.{ .body = "{\"ok\":true,\"echo\":\"sk-ant-SECRET\"}", .headers = &.{.{ .name = "set-cookie", .value = "session=SECRET" }} }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Red = struct {
        fn redact(_: ?*anyopaque, a: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!writer_mod.Redacted {
            const out = try std.mem.replaceOwned(u8, a, text, "sk-ant-SECRET", "[REDACTED]");
            return .{ .text = out, .count = if (std.mem.eql(u8, out, text)) 0 else 1 };
        }
    };
    const c = try Cassette.open(io, testing.allocator, tmp.path("r.jsonl"), .record, .{ .redactor = .{ .redact = Red.redact } });
    defer c.deinit();
    const req: tp.HttpRequest = .{
        .url = "https://gen.test/v1beta/models/g:streamGenerateContent?alt=sse&key=SECRET",
        .headers = &.{
            .{ .name = "x-api-key", .value = "sk-ant-SECRET" },
            .{ .name = "Authorization", .value = "Bearer SECRET" },
            .{ .name = "x-goog-api-key", .value = "SECRET" },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        },
        .body = "{\"note\":\"sk-ant-SECRET\"}",
    };
    // The caller still sees the real bytes.
    const r = try send(c.transport(f.transport()), arena.allocator(), req);
    try testing.expect(std.mem.indexOf(u8, r.body, "sk-ant-SECRET") != null);
    try c.finish();

    const text = try tmp.read("r.jsonl");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "SECRET") == null);
    try testing.expect(std.mem.indexOf(u8, text, "key=<redacted>") != null);
    try testing.expect(std.mem.indexOf(u8, text, "alt=sse") != null);
    try testing.expect(std.mem.indexOf(u8, text, "2023-06-01") != null);

    // The redacted recording still replays: the key ignores headers, and
    // the request body was hashed before redaction.
    const c2 = try Cassette.open(io, testing.allocator, tmp.path("r.jsonl"), .replay, .{});
    defer c2.deinit();
    const r2 = try send(c2.transport(null), arena.allocator(), req);
    try testing.expectEqualStrings("{\"ok\":true,\"echo\":\"[REDACTED]\"}", r2.body);
}

test "miss reports nearest diff" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const routes = [_]fake.Route{.{ .body = "ok" }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    {
        const c = try Cassette.open(io, testing.allocator, tmp.path("m.jsonl"), .record, .{});
        defer c.deinit();
        const t = c.transport(f.transport());
        _ = try send(t, arena.allocator(), .{ .url = "https://x/v1/messages", .body = "{\"model\":\"m\",\"max_tokens\":100,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}" });
        _ = try send(t, arena.allocator(), .{ .url = "https://x/v1/messages", .body = "{\"model\":\"other\",\"system\":\"long\",\"tools\":[1,2,3],\"messages\":[]}" });
        try c.finish();
    }
    const c = try Cassette.open(io, testing.allocator, tmp.path("m.jsonl"), .replay, .{});
    defer c.deinit();
    try testing.expectError(error.Aborted, send(c.transport(null), arena.allocator(), .{ .url = "https://x/v1/messages", .body = "{\"model\":\"m\",\"max_tokens\":200,\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}" }));
    const miss = c.last_miss.?;
    try testing.expect(std.mem.startsWith(u8, miss, "cassette miss: POST https://x/v1/messages"));
    try testing.expect(std.mem.indexOf(u8, miss, "-  \"max_tokens\":100,\n") != null);
    try testing.expect(std.mem.indexOf(u8, miss, "+  \"max_tokens\":200,\n") != null);
    try testing.expect(std.mem.indexOf(u8, miss, "   \"model\":\"m\"\n") != null);
    try testing.expect(std.mem.indexOf(u8, miss, "other") == null);
}

test "record missing appends new exchanges" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const routes = [_]fake.Route{ .{ .url_contains = "/a", .body = "A" }, .{ .url_contains = "/b", .body = "B" } };
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    {
        const c = try Cassette.open(io, testing.allocator, tmp.path("rm.jsonl"), .record_missing, .{});
        defer c.deinit();
        _ = try send(c.transport(f.transport()), arena.allocator(), .{ .url = "https://x/a" });
        try c.finish();
    }
    {
        const c = try Cassette.open(io, testing.allocator, tmp.path("rm.jsonl"), .record_missing, .{});
        defer c.deinit();
        const t = c.transport(f.transport());
        try testing.expectEqualStrings("A", (try send(t, arena.allocator(), .{ .url = "https://x/a" })).body);
        try testing.expectEqualStrings("B", (try send(t, arena.allocator(), .{ .url = "https://x/b" })).body);
        try testing.expectEqual(@as(u32, 1), c.replays);
        try c.finish();
    }
    try testing.expectEqual(@as(usize, 2), f.requests().len);
    const c = try Cassette.open(io, testing.allocator, tmp.path("rm.jsonl"), .replay, .{});
    defer c.deinit();
    try testing.expectEqual(@as(usize, 2), c.entries.items.len);
}

test "timed replay respects dt" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const line = "{\"req_hash\":0,\"method\":\"POST\",\"url\":\"https://x/v1\",\"req_headers\":[],\"req_body\":\"\",\"status\":200,\"resp_headers\":[],\"chunks\":[{\"dt_ms\":250,\"text\":\"a\"},{\"dt_ms\":0,\"text\":\"b\"},{\"dt_ms\":40,\"text\":\"c\"}]}\n";
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: tp.HttpRequest = .{ .url = "https://x/v1" };
    const key = try cassette.requestKey(arena.allocator(), req, &cassette.default_volatile);
    var buf: [32]u8 = undefined;
    const data = try std.mem.replaceOwned(u8, arena.allocator(), line, "\"req_hash\":0", try std.fmt.bufPrint(&buf, "\"req_hash\":{d}", .{key}));
    try tmp.dir.dir.writeFile(io, .{ .sub_path = "t.jsonl", .data = data });

    inline for (.{ 0, 1 }) |speed| {
        var clock: ratelimit.FakeClock = .init(0);
        const c = try Cassette.open(io, testing.allocator, tmp.path("t.jsonl"), .replay, .{ .speed = speed, .clock = clock.clock() });
        defer c.deinit();
        const r = try send(c.transport(null), arena.allocator(), req);
        try testing.expectEqualStrings("abc", r.body);
        try testing.expectEqual(@as(u64, if (speed == 0) 0 else 290), clock.slept_ms.load(.monotonic));
        try testing.expectEqual(@as(u32, if (speed == 0) 0 else 2), clock.sleeps.load(.monotonic));
    }
}

test "binary body base64 roundtrip" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const bin = "\x00\xff\xfe binary \x80\x81";
    const routes = [_]fake.Route{.{ .body = bin, .chunk_size = 4 }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const req: tp.HttpRequest = .{ .url = "https://x/upload", .body = "\xc3\x28 not utf8" };
    {
        const c = try Cassette.open(io, testing.allocator, tmp.path("b.jsonl"), .record, .{});
        defer c.deinit();
        _ = try send(c.transport(f.transport()), arena.allocator(), req);
        try c.finish();
    }
    const text = try tmp.read("b.jsonl");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "\"req_body_b64\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"text_b64\"") != null);
    const c = try Cassette.open(io, testing.allocator, tmp.path("b.jsonl"), .replay, .{});
    defer c.deinit();
    try testing.expectEqualStrings(req.body, c.entries.items[0].req_body);
    try testing.expectEqualStrings(bin, (try send(c.transport(null), arena.allocator(), req)).body);
}

test "atomic write on abort" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const routes = [_]fake.Route{.{ .body = "new" }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try tmp.dir.dir.writeFile(io, .{ .sub_path = "a.jsonl", .data = "old cassette\n" });
    {
        // Recording aborted before finish: the old file stays as it was.
        const c = try Cassette.open(io, testing.allocator, tmp.path("a.jsonl"), .record, .{});
        defer c.deinit();
        _ = try send(c.transport(f.transport()), arena.allocator(), .{ .url = "https://x/a" });
    }
    const text = try tmp.read("a.jsonl");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("old cassette\n", text);
    {
        const c = try Cassette.open(io, testing.allocator, tmp.path("fresh/n.jsonl"), .record, .{});
        defer c.deinit();
    }
    try testing.expectError(error.FileNotFound, tmp.dir.dir.access(io, "fresh/n.jsonl", .{}));
    // Replay of a missing cassette fails up front.
    try testing.expectError(error.FileNotFound, Cassette.open(io, testing.allocator, tmp.path("none.jsonl"), .replay, .{}));
}

test "off passes through" {
    const routes = [_]fake.Route{.{ .body = "live" }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try Cassette.open(io, testing.allocator, "unused.jsonl", .off, .{});
    defer c.deinit();
    try testing.expectEqualStrings("live", (try send(c.transport(f.transport()), arena.allocator(), .{ .url = "https://x/" })).body);
    try c.finish();
}

test "anthropic stream replays from a cassette" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    const body = @embedFile("../provider/anthropic/testdata/text_only.sse");
    const routes = [_]fake.Route{.{ .body = body, .chunk_size = 64, .headers = &.{.{ .name = "request-id", .value = "req_c" }} }};
    var f: fake.FakeTransport = try .init(testing.allocator, &routes);
    defer f.deinit();
    const user_hi = [_]proto.Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "Hello" } }} }};
    var texts: [2][]const u8 = undefined;
    inline for (.{ cassette.Mode.record, cassette.Mode.replay }, 0..) |mode, i| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const c = try Cassette.open(io, testing.allocator, tmp.path("anthropic.jsonl"), mode, .{});
        defer c.deinit();
        const an = try Anthropic.create(testing.allocator, c.transport(if (mode == .record) f.transport() else null), .{ .api_key = "sk-ant-test-key" });
        const p = an.provider();
        defer p.deinit();
        const resp = try p.stream(io, arena.allocator(), &.{ .model = "m", .messages = &user_hi }, .discard);
        try testing.expectEqualStrings("req_c", resp.request_id.?);
        texts[i] = try testing.allocator.dupe(u8, resp.message.content[0].text.text);
        try c.finish();
    }
    defer for (texts) |t| testing.allocator.free(t);
    try testing.expectEqualStrings(texts[0], texts[1]);
    try testing.expectEqual(@as(usize, 1), f.requests().len);
    const text = try tmp.read("anthropic.jsonl");
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "sk-ant-test-key") == null);
}

test "match any entries serve unmatched requests in order" {
    var tmp: Tmp = .init();
    defer tmp.dir.cleanup();
    try tmp.dir.dir.writeFile(io, .{ .sub_path = "any.jsonl", .data =
        \\{"match":"any","method":"POST","url":"https://x/v1","status":200,"chunks":[{"dt_ms":0,"text":"first"}]}
        \\{"match":"any","method":"POST","url":"https://x/v1","status":201,"chunks":[{"dt_ms":0,"text":"second"}]}
        \\
    });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c = try Cassette.open(io, testing.allocator, tmp.path("any.jsonl"), .replay, .{});
    defer c.deinit();
    const t = c.transport(null);
    try testing.expectEqualStrings("first", (try send(t, arena.allocator(), .{ .url = "https://x/v1", .body = "{\"a\":1}" })).body);
    const r = try send(t, arena.allocator(), .{ .url = "https://x/other" });
    try testing.expectEqualStrings("second", r.body);
    try testing.expectEqual(@as(u16, 201), r.head.status);
    try testing.expectError(error.Aborted, send(t, arena.allocator(), .{ .url = "https://x/v1" }));
}
