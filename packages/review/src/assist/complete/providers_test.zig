const std = @import("std");
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const providers = @import("providers.zig");
const chat = @import("provider_chat.zig");
const llamacpp = @import("provider_llamacpp.zig");
const ollama = @import("provider_ollama.zig");
const oai = @import("provider_oai_completions.zig");
const fim = @import("fim.zig");
const context = @import("context.zig");

const testing = std.testing;
const Io = std.Io;
const gpa = testing.allocator;
const TestServer = zg_net.test_server.TestServer;

const req_fixture: context.CompletionRequest = .{
    .path = "src/a.zig",
    .language = "zig",
    .prefix = "fn f() u32 {\n    re",
    .suffix = "\n}\n",
    .extras = &.{.{ .path = "src/b.zig", .text = "const x = 1;\n" }},
    .multiline = false,
    .max_tokens = 32,
    .stop = &.{"\n"},
};

/// Collects streamed text.
const Collect = struct {
    io: Io,
    mutex: Io.Mutex = .init,
    text: std.ArrayList(u8) = .empty,
    first: Io.Event = .unset,

    fn sink(c: *Collect) providers.Sink {
        return .{ .ctx = c, .text = f };
    }

    fn f(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const c: *Collect = @ptrCast(@alignCast(ctx.?));
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        try c.text.appendSlice(gpa, bytes);
        c.first.set(c.io);
    }

    fn deinit(c: *Collect) void {
        c.text.deinit(gpa);
    }
};

/// A fake FIM server: records the last request and streams `chunks`.
const Fake = struct {
    status: std.http.Status = .ok,
    chunks: []const []const u8 = &.{},
    /// Waits here after the first chunk (cancel tests).
    hold: ?*Io.Event = null,
    target: [64]u8 = undefined,
    target_len: usize = 0,
    auth: [64]u8 = undefined,
    auth_len: usize = 0,
    body: [4096]u8 = undefined,
    body_len: usize = 0,

    fn lastTarget(f: *const Fake) []const u8 {
        return f.target[0..f.target_len];
    }

    fn lastBody(f: *const Fake) []const u8 {
        return f.body[0..f.body_len];
    }

    fn handler(srv: *TestServer, req: *std.http.Server.Request) anyerror!void {
        const f: *Fake = @ptrCast(@alignCast(srv.ctx.?));
        f.target_len = @min(req.head.target.len, f.target.len);
        @memcpy(f.target[0..f.target_len], req.head.target[0..f.target_len]);
        f.auth_len = 0;
        var it = req.iterateHeaders();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "authorization")) {
            f.auth_len = @min(h.value.len, f.auth.len);
            @memcpy(f.auth[0..f.auth_len], h.value[0..f.auth_len]);
        };
        f.body_len = 0;
        if (req.head.method == .POST) {
            var rb: [1024]u8 = undefined;
            const rd = try req.readerExpectContinue(&rb);
            f.body_len = try rd.readSliceShort(&f.body);
        }
        if (f.status != .ok) return req.respond("{\"error\":\"no\"}", .{ .status = f.status });
        var out: [512]u8 = undefined;
        var bw = try req.respondStreaming(&out, .{});
        for (f.chunks, 0..) |c, i| {
            try bw.writer.writeAll(c);
            try bw.writer.flush();
            try bw.flush();
            if (i == 0) if (f.hold) |h| h.waitUncancelable(testing.io);
        }
        try bw.end();
    }
};

const Fixture = struct {
    rt: zg_core.Runtime,
    env: std.process.Environ.Map,
    client: *zg_net.http.Client,
    srv: TestServer,
    url_buf: [64]u8 = undefined,

    fn init(fx: *Fixture, fake: *Fake, max: u32) !void {
        fx.rt.initTesting();
        fx.env = .init(gpa);
        fx.client = try zg_net.http.Client.init(&fx.rt, .{ .proxy = .none, .environ_map = &fx.env, .max_retries = 0 });
        fx.srv = .{ .server = undefined, .port = 0, .max = max, .handler = Fake.handler, .ctx = fake };
        try fx.srv.start(testing.io);
    }

    fn base(fx: *Fixture) []const u8 {
        return fx.srv.url(&fx.url_buf, "");
    }

    fn deinit(fx: *Fixture) void {
        fx.srv.stop(testing.io);
        fx.client.deinit();
        fx.env.deinit();
        _ = fx.rt.deinit();
    }
};

const VirtualClock = struct {
    ms: u64 = 1_000,

    fn clock(v: *VirtualClock) providers.Clock {
        return .{ .ctx = v, .now_ms = f };
    }

    fn f(ctx: ?*anyopaque, _: Io) u64 {
        const v: *VirtualClock = @ptrCast(@alignCast(ctx.?));
        return v.ms;
    }
};

test "providers: llamacpp request JSON golden + SSE stream parse" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Field names as in llama.cpp tools/server/README.md, POST /infill.
    try testing.expectEqualStrings(
        \\{"input_prefix":"fn f() u32 {\n    re","input_suffix":"\n}\n","input_extra":[{"filename":"src/b.zig","text":"const x = 1;\n"}],"prompt":"","n_predict":32,"stop":["\n"],"stream":true,"cache_prompt":true,"id_slot":2}
    , try llamacpp.body(arena.allocator(), &req_fixture, .{ .base_url = "", .id_slot = 2 }));

    var fake: Fake = .{ .chunks = &.{
        "data: {\"content\":\"tu\",\"stop\":false}\n\n",
        "data: {\"content\":\"rn 1",
        ";\",\"stop\":false}\n\ndata: {\"content\":\"\",\"stop\":true}\n\n",
    } };
    var fx: Fixture = undefined;
    try fx.init(&fake, 1);
    defer fx.deinit();
    var h: providers.HttpFim = try .init(gpa, fx.client, .{ .llamacpp = .{ .base_url = fx.base() } }, .{});
    var c: Collect = .{ .io = testing.io };
    defer c.deinit();
    try h.provider().complete(testing.io, arena.allocator(), &req_fixture, c.sink());
    try testing.expectEqualStrings("turn 1;", c.text.items);
    try testing.expectEqualStrings("/infill", fake.lastTarget());
    try testing.expect(std.mem.indexOf(u8, fake.lastBody(), "\"cache_prompt\":true") != null);
    try testing.expect(h.provider().caps.server_side_template);
}

test "providers: cancel mid-stream returns Canceled and is not a failure" {
    var gate: Io.Event = .unset;
    var fake: Fake = .{ .hold = &gate, .chunks = &.{
        "data: {\"content\":\"tu\"}\n\n",
        "data: {\"content\":\"rn\"}\n\n",
    } };
    var fx: Fixture = undefined;
    try fx.init(&fake, 1);
    defer fx.deinit();
    defer gate.set(testing.io);
    var h: providers.HttpFim = try .init(gpa, fx.client, .{ .llamacpp = .{ .base_url = fx.base() } }, .{});
    var c: Collect = .{ .io = testing.io };
    defer c.deinit();
    const Run = struct {
        fn run(p: providers.FimProvider, sink: providers.Sink) anyerror!void {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            return p.complete(testing.io, arena.allocator(), &req_fixture, sink);
        }
    };
    var fut = try testing.io.concurrent(Run.run, .{ h.provider(), c.sink() });
    try c.first.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectError(error.Canceled, fut.cancel(testing.io));
    try testing.expectEqualStrings("tu", c.text.items);
    try testing.expectEqual(@as(u8, 0), h.health.failures);
}

test "providers: ollama request golden + NDJSON stream + keep_alive" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // Fields as in Ollama's OpenAPI spec, GenerateRequest; snippets become
    // comments before the prefix.
    try testing.expectEqualStrings(
        \\{"model":"qwen2.5-coder:1.5b","prompt":"// src/b.zig\n// const x = 1;\nfn f() u32 {\n    re","suffix":"\n}\n","stream":true,"raw":false,"keep_alive":"30m","options":{"num_predict":32,"stop":["\n"],"temperature":0.2}}
    , try ollama.body(arena.allocator(), &req_fixture, .{ .model = "qwen2.5-coder:1.5b" }));

    var fake: Fake = .{ .chunks = &.{
        "{\"response\":\"tu\",\"done\":false}\n{\"resp",
        "onse\":\"rn 1;\",\"done\":false}\n",
        "{\"response\":\"\",\"done\":true,\"total_duration\":5}\n",
    } };
    var fx: Fixture = undefined;
    try fx.init(&fake, 1);
    defer fx.deinit();
    var h: providers.HttpFim = try .init(gpa, fx.client, .{ .ollama = .{ .base_url = fx.base(), .model = "m", .keep_alive = "5m" } }, .{});
    var c: Collect = .{ .io = testing.io };
    defer c.deinit();
    try h.provider().complete(testing.io, arena.allocator(), &req_fixture, c.sink());
    try testing.expectEqualStrings("turn 1;", c.text.items);
    try testing.expectEqualStrings("/api/generate", fake.lastTarget());
    try testing.expect(std.mem.indexOf(u8, fake.lastBody(), "\"keep_alive\":\"5m\"") != null);
}

test "providers: oai completions renders template and strips EOT" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const t = fim.find(fim.catalog, "qwen2.5-coder").?;
    // At most four stops: the request's, then the template's end tokens.
    try testing.expectEqualStrings(
        \\{"model":"m","prompt":"<|fim_prefix|>fn f() u32 {\n    re<|fim_suffix|>\n}\n<|fim_middle|>","max_tokens":32,"stop":["\n","<|endoftext|>","<|fim_pad|>","<|repo_name|>"],"temperature":0.2,"stream":true}
    , try oai.body(arena.allocator(), &req_fixture, .{ .base_url = "", .model = "m", .template = t }));

    var fake: Fake = .{ .chunks = &.{
        "data: {\"choices\":[{\"text\":\"turn 1;<|endo\"}]}\n\n",
        "data: {\"choices\":[{\"text\":\"ftext|>junk\"}]}\n\n",
        "data: [DONE]\n\n",
    } };
    var fx: Fixture = undefined;
    try fx.init(&fake, 1);
    defer fx.deinit();
    var url_buf: [80]u8 = undefined;
    const base = try std.fmt.bufPrint(&url_buf, "{s}/v1", .{fx.base()});
    var h: providers.HttpFim = try .init(gpa, fx.client, .{ .oai_completions = .{ .base_url = base, .model = "m", .template = t } }, .{ .api_key = "sk-test" });
    var c: Collect = .{ .io = testing.io };
    defer c.deinit();
    try h.provider().complete(testing.io, arena.allocator(), &req_fixture, c.sink());
    try testing.expectEqualStrings("turn 1;", c.text.items);
    try testing.expectEqualStrings("/v1/completions", fake.lastTarget());
    try testing.expectEqualStrings("Bearer sk-test", fake.auth[0..fake.auth_len]);
    try testing.expect(!h.provider().caps.server_side_template);
}

test "providers: token filter holds a partial token across chunks" {
    var c: Collect = .{ .io = testing.io };
    defer c.deinit();
    var f: providers.TokenFilter = .{ .tokens = &.{ "<EOT>", "<|fim_middle|>" } };
    try f.feed("abc<", c.sink());
    try testing.expectEqualStrings("abc", c.text.items);
    try f.feed("b>d<E", c.sink());
    try testing.expectEqualStrings("abc<b>d", c.text.items);
    try f.feed("OT>zz", c.sink());
    try testing.expectEqualStrings("abc<b>d", c.text.items);
    try f.feed("more", c.sink());
    try f.finish(c.sink());
    try testing.expectEqualStrings("abc<b>d", c.text.items);

    var g: providers.TokenFilter = .{ .tokens = &.{"<EOT>"} };
    try g.feed("x <E", c.sink());
    try g.finish(c.sink());
    try testing.expectEqualStrings("abc<b>dx <E", c.text.items);
}

test "providers: chat fallback via a chat port" {
    const Port = struct {
        user: []const u8 = "",
        system: []const u8 = "",
        temperature: f32 = 1,

        fn stream(ctx: *anyopaque, _: Io, arena: std.mem.Allocator, r: *const chat.ChatRequest, sink: providers.Sink) anyerror!void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            p.user = try arena.dupe(u8, r.user);
            p.system = r.system;
            p.temperature = r.temperature;
            for ([_][]const u8{ "``", "`zig\nret", "urn 1;", "\n`", "``\n" }) |d| try sink.text(sink.ctx, d);
        }
    };
    var port: Port = .{};
    var cf: chat.ChatFim = .{ .opts = .{ .port = .{ .ctx = &port, .stream = Port.stream }, .model = "claude" } };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: Collect = .{ .io = testing.io };
    defer c.deinit();
    const p = cf.provider();
    try testing.expect(p.caps.server_side_template);
    try p.complete(testing.io, arena.allocator(), &req_fixture, c.sink());
    try testing.expectEqualStrings("return 1;", c.text.items);
    try testing.expect(std.mem.indexOf(u8, port.user, "    re<CURSOR>\n}") != null);
    try testing.expect(std.mem.indexOf(u8, port.user, "Related file src/b.zig:\nconst x = 1;\n") != null);
    try testing.expect(std.mem.startsWith(u8, port.system, "You are a code completion engine."));
    try testing.expectEqual(@as(f32, 0), port.temperature);

    // An unfenced reply passes through.
    c.text.clearRetainingCapacity();
    var plain: chat.FenceFilter = .{ .out = c.sink() };
    try plain.sink().text(plain.sink().ctx, "x`y");
    try plain.finish();
    try testing.expectEqualStrings("x`y", c.text.items);
}

test "providers: unhealthy after 3 failures, recovers after 30 s" {
    var fake: Fake = .{ .status = .internal_server_error };
    var fx: Fixture = undefined;
    try fx.init(&fake, 4);
    defer fx.deinit();
    var vc: VirtualClock = .{};
    var h: providers.HttpFim = try .init(gpa, fx.client, .{ .llamacpp = .{ .base_url = fx.base() } }, .{ .clock = vc.clock() });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var c: Collect = .{ .io = testing.io };
    defer c.deinit();
    const p = h.provider();
    for (0..3) |_| try testing.expectError(error.BadStatus, p.complete(testing.io, arena.allocator(), &req_fixture, c.sink()));
    try testing.expect(!h.healthy(testing.io));
    // No request while cooling down.
    try testing.expectError(error.Unhealthy, p.complete(testing.io, arena.allocator(), &req_fixture, c.sink()));
    try testing.expectEqual(@as(u32, 3), fx.srv.served.load(.monotonic));
    vc.ms += 30_000;
    try testing.expect(h.healthy(testing.io));
    fake.status = .ok;
    fake.chunks = &.{"data: {\"content\":\"ok\",\"stop\":true}\n\n"};
    try p.complete(testing.io, arena.allocator(), &req_fixture, c.sink());
    try testing.expectEqualStrings("ok", c.text.items);
    try testing.expectEqual(@as(u8, 0), h.health.failures);
}

test "providers: warm() rate-limited" {
    var fake: Fake = .{};
    var fx: Fixture = undefined;
    try fx.init(&fake, 3);
    defer fx.deinit();
    var vc: VirtualClock = .{};
    var h: providers.HttpFim = try .init(gpa, fx.client, .{ .ollama = .{ .base_url = fx.base(), .model = "m" } }, .{ .clock = vc.clock() });
    const p = h.provider();
    p.warm(testing.io);
    try testing.expectEqualStrings("/api/version", fake.lastTarget());
    vc.ms += 59_000;
    p.warm(testing.io);
    try testing.expectEqual(@as(u32, 1), fx.srv.served.load(.monotonic));
    vc.ms += 1_000;
    p.warm(testing.io);
    try testing.expectEqual(@as(u32, 2), fx.srv.served.load(.monotonic));
}

test "providers: endpoints need HTTPS unless loopback or allowed" {
    try providers.checkEndpoint("http://127.0.0.1:8080", false);
    try providers.checkEndpoint("http://localhost:11434/", false);
    try providers.checkEndpoint("http://[::1]:8080", false);
    try providers.checkEndpoint("https://api.example.com/v1", false);
    try testing.expectError(error.InsecureEndpoint, providers.checkEndpoint("http://192.168.1.5:8080", false));
    try providers.checkEndpoint("http://192.168.1.5:8080", true);
    try testing.expectError(error.InvalidUrl, providers.checkEndpoint("ftp://x", true));
    try testing.expectError(error.InsecureEndpoint, providers.HttpFim.init(gpa, undefined, .{ .llamacpp = .{ .base_url = "http://10.0.0.2" } }, .{}));
}
