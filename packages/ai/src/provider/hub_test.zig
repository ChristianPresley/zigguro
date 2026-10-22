const std = @import("std");
const proto = @import("zg_ai_proto");
const hubm = @import("hub.zig");
const keyref = @import("keyref.zig");
const ratelimit = @import("ratelimit.zig");
const fake = @import("fake_server.zig");
const events = @import("events.zig");
const request = @import("request.zig");
const Provider = @import("Provider.zig");
const registry = @import("../models/registry.zig");

const testing = std.testing;
const io = testing.io;
const ProviderHub = hubm.ProviderHub;

const models_ok =
    \\{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5","max_input_tokens":1000000,"max_tokens":128000},{"id":"claude-new","max_input_tokens":500000,"max_tokens":64000}],"has_more":false}
;
const auth_err =
    \\{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
;
const text_sse = @embedFile("anthropic/testdata/text_only.sse");
const sse_headers = [_]request.Header{.{ .name = "content-type", .value = "text/event-stream" }};

/// Test fixture: environ, secrets, transport, limiter, notifier capture.
const Fx = struct {
    env: std.process.Environ.Map,
    secrets: keyref.MemorySecretStore,
    fake: fake.FakeTransport,
    limiter: ratelimit.RateLimiter,
    clock: ratelimit.FakeClock = .init(0),
    warnings: std.ArrayList(u8) = .empty,
    redacted: std.ArrayList(u8) = .empty,
    written: std.ArrayList(u8) = .empty,

    fn init(f: *Fx, routes: []const fake.Route) !void {
        f.* = .{
            .env = .init(testing.allocator),
            .secrets = .init(testing.allocator),
            .fake = try .init(testing.allocator, routes),
            .limiter = undefined,
        };
        f.limiter = .init(testing.allocator, f.clock.clock());
    }

    fn deinit(f: *Fx) void {
        f.env.deinit();
        f.secrets.deinit();
        f.fake.deinit();
        f.limiter.deinit();
        f.warnings.deinit(testing.allocator);
        f.redacted.deinit(testing.allocator);
        f.written.deinit(testing.allocator);
    }

    fn deps(f: *Fx, reg: ?*registry.ModelRegistry) hubm.Deps {
        return .{
            .secrets = f.secrets.store(),
            .environ = &f.env,
            .transport = f.fake.transport(),
            .limiter = &f.limiter,
            .registry = reg,
            .clock = f.clock.clock(),
            .notifier = .{ .ctx = f, .warn = warn, .redact = redact },
            .writer = .{ .ctx = f, .write = write },
        };
    }

    fn warn(ctx: *anyopaque, msg: []const u8) void {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.warnings.appendSlice(testing.allocator, msg) catch {};
        f.warnings.append(testing.allocator, '\n') catch {};
    }

    fn redact(ctx: *anyopaque, s: []const u8) void {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.redacted.appendSlice(testing.allocator, s) catch {};
    }

    fn write(ctx: *anyopaque, id: []const u8, s: hubm.ProviderSettings) anyerror!void {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        try f.written.print(testing.allocator, "{s}={s}\n", .{ id, s.key orelse "null" });
    }
};

fn idsOf(h: *ProviderHub, buf: [][]const u8) []const u8 {
    const ids = h.ids(buf);
    var out: [64]u8 = undefined;
    var n: usize = 0;
    for (ids) |id| {
        @memcpy(out[n .. n + id.len], id);
        n += id.len;
        out[n] = ',';
        n += 1;
    }
    return testing.allocator.dupe(u8, out[0..n]) catch unreachable;
}

test "defaults_from_env_and_secret" {
    const Case = struct { anth_env: bool = false, anth_secret: bool = false, oai_env: bool = false, oai_secret: bool = false, want: []const u8 };
    const cases = [_]Case{
        .{ .want = "" },
        .{ .anth_env = true, .want = "anthropic," },
        .{ .anth_secret = true, .want = "anthropic," },
        .{ .oai_env = true, .want = "openai," },
        .{ .oai_secret = true, .anth_env = true, .want = "anthropic,openai," },
        .{ .anth_secret = true, .oai_env = true, .oai_secret = true, .want = "anthropic,openai," },
    };
    for (cases) |c| {
        var f: Fx = undefined;
        try f.init(&.{});
        defer f.deinit();
        if (c.anth_env) try f.env.put("ANTHROPIC_API_KEY", "sk-ant-env");
        if (c.anth_secret) try f.secrets.store().put(io, "ai/anthropic/default", "sk-ant-secret");
        if (c.oai_env) try f.env.put("OPENAI_API_KEY", "sk-oai-env");
        if (c.oai_secret) try f.secrets.store().put(io, "ai/openai/default", "sk-oai-secret");
        const h = try ProviderHub.init(testing.allocator, f.deps(null));
        defer h.deinit();
        try h.onSettingsChanged(io, &.{});
        var buf: [8][]const u8 = undefined;
        const got = idsOf(h, &buf);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "resolution_order_table" {
    var f: Fx = undefined;
    try f.init(&.{});
    defer f.deinit();
    const h = try ProviderHub.init(testing.allocator, f.deps(null));
    defer h.deinit();
    try f.env.put("ANTHROPIC_API_KEY", "from-conventional-env");
    try f.env.put("MY_KEY", "from-explicit-env");
    const s = f.secrets.store();
    try s.put(io, "custom", "from-explicit-secret");
    const K = keyref.KeyRef;
    // Explicit refs win; a missing explicit ref falls through to defaults.
    try testing.expectEqualStrings("from-explicit-secret", (try h.resolveKey(io, .anthropic, K{ .secret = "custom" })).?);
    try testing.expectEqualStrings("from-explicit-env", (try h.resolveKey(io, .anthropic, K{ .env = "MY_KEY" })).?);
    try testing.expectEqualStrings("from-conventional-env", (try h.resolveKey(io, .anthropic, .none)).?);
    try s.put(io, "ai/anthropic/default", "from-default-secret");
    try testing.expectEqualStrings("from-default-secret", (try h.resolveKey(io, .anthropic, .none)).?);
    try testing.expectEqualStrings("from-default-secret", (try h.resolveKey(io, .anthropic, K{ .secret = "absent" })).?);
    try testing.expectEqualStrings("raw", (try h.resolveKey(io, .anthropic, K{ .raw = "raw" })).?);
    try testing.expect(try h.resolveKey(io, .openai_chat, .none) == null);
}

test "raw_key_in_settings_warns_and_redacts" {
    var f: Fx = undefined;
    try f.init(&.{});
    defer f.deinit();
    const h = try ProviderHub.init(testing.allocator, f.deps(null));
    defer h.deinit();
    const entries = [_]hubm.NamedSettings{.{ .id = "anthropic", .settings = .{ .kind = .anthropic, .key = "sk-ant-RAW-123" } }};
    try h.onSettingsChanged(io, &entries);
    try h.onSettingsChanged(io, &entries);
    try testing.expect(h.get("anthropic") != null);
    try testing.expectEqualStrings("sk-ant-RAW-123", f.redacted.items[0.."sk-ant-RAW-123".len]);
    // Warned once, without the key.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, f.warnings.items, "\n"));
    try testing.expect(std.mem.indexOf(u8, f.warnings.items, "raw API key") != null);
    try testing.expect(std.mem.indexOf(u8, f.warnings.items, "sk-ant") == null);
}

test "connect_stores_secret_writes_ref_and_tests" {
    const routes = [_]fake.Route{
        .{ .url_contains = "/v1/models", .status = 401, .body = auth_err, .once = true },
        .{ .url_contains = "/v1/models", .body = models_ok },
    };
    var f: Fx = undefined;
    try f.init(&routes);
    defer f.deinit();
    var reg = registry.ModelRegistry.init(testing.allocator, io, registry.builtin_catalog);
    defer reg.deinit();
    const h = try ProviderHub.init(testing.allocator, f.deps(&reg));
    defer h.deinit();
    try h.onSettingsChanged(io, &.{});
    try testing.expect(h.get("anthropic") == null);

    const bad = try h.connect(io, "anthropic", "sk-ant-wrong", .{ .kind = .anthropic });
    try testing.expect(!bad.ok);
    try testing.expectEqual(@as(?u16, 401), bad.status);
    const good = try h.connect(io, "anthropic", "sk-ant-right", .{ .kind = .anthropic });
    try testing.expect(good.ok);
    try testing.expectEqual(@as(u32, 2), good.models_found);
    try testing.expectEqualStrings("sk-ant-right", (try f.secrets.store().get(io, "ai/anthropic/default")).?);
    try testing.expectEqualStrings("anthropic=${secret:ai/anthropic/default}\nanthropic=${secret:ai/anthropic/default}\n", f.written.items);
    // The second connect rebuilt with the new key.
    const seen = f.fake.requests();
    var key_hdr: []const u8 = "";
    for (seen[seen.len - 1].headers) |hd| if (std.ascii.eqlIgnoreCase(hd.name, "x-api-key")) {
        key_hdr = hd.value;
    };
    try testing.expectEqualStrings("sk-ant-right", key_hdr);
    // Discovery fed the registry.
    try testing.expectEqual(@as(u32, 500_000), reg.resolve("claude-new").?.context_window);
}

test "settings_change_rebuilds_only_changed" {
    var f: Fx = undefined;
    try f.init(&.{});
    defer f.deinit();
    try f.env.put("ANTHROPIC_API_KEY", "k");
    const h = try ProviderHub.init(testing.allocator, f.deps(null));
    defer h.deinit();
    var entries = [_]hubm.NamedSettings{
        .{ .id = "anthropic", .settings = .{ .kind = .anthropic } },
        .{ .id = "ollama", .settings = .{ .kind = .openai_chat, .base_url = "http://localhost:11434/v1" } },
    };
    try h.onSettingsChanged(io, &entries);
    const a1 = h.get("anthropic").?.ptr;
    const o1 = h.get("ollama").?.ptr;
    entries[1].settings.base_url = "http://localhost:11435/v1";
    try h.onSettingsChanged(io, &entries);
    try testing.expectEqual(a1, h.get("anthropic").?.ptr);
    try testing.expect(o1 != h.get("ollama").?.ptr);
    entries[1].settings.enabled = false;
    try h.onSettingsChanged(io, &entries);
    try testing.expect(h.get("ollama") == null);
    try testing.expectEqual(a1, h.get("anthropic").?.ptr);
    // Local servers default to one stream at a time.
    try testing.expectEqual(@as(u32, 1), f.limiter.providers.get("ollama").?.max);
    try testing.expectEqual(@as(u32, 8), f.limiter.providers.get("anthropic").?.max);
}

test "forModel" {
    var f: Fx = undefined;
    try f.init(&.{});
    defer f.deinit();
    try f.env.put("ANTHROPIC_API_KEY", "k");
    var reg = registry.ModelRegistry.init(testing.allocator, io, registry.builtin_catalog);
    defer reg.deinit();
    const h = try ProviderHub.init(testing.allocator, f.deps(&reg));
    defer h.deinit();
    try h.onSettingsChanged(io, &.{});
    const p = h.forModel(reg.resolve("opus").?).?;
    try testing.expectEqual(proto.ProviderId.anthropic, p.id);
    try testing.expect(h.forModel(&.{ .id = "x", .provider = .gemini, .display = "", .family = "", .context_window = 1, .max_output = 1, .caps = .{} }) == null);
}

const Collect = struct {
    buf: std.ArrayList(u8) = .empty,
    fn sink(c: *Collect) events.EventSink {
        return .{ .ctx = c, .emit = emit };
    }
    fn emit(ctx: *anyopaque, ev: events.StreamEvent) void {
        const c: *Collect = @ptrCast(@alignCast(ctx));
        c.buf.print(testing.allocator, "{any}\n", .{ev}) catch {};
    }
};

test "in_flight_stream_survives_rebuild" {
    const routes = [_]fake.Route{.{ .url_contains = "/v1/messages", .headers = &sse_headers, .body = text_sse, .chunk_size = 64, .chunk_delay_ms = 5 }};
    var f: Fx = undefined;
    try f.init(&routes);
    defer f.deinit();
    try f.env.put("ANTHROPIC_API_KEY", "k");
    const h = try ProviderHub.init(testing.allocator, f.deps(null));
    defer h.deinit();
    var entries = [_]hubm.NamedSettings{.{ .id = "anthropic", .settings = .{ .kind = .anthropic } }};
    try h.onSettingsChanged(io, &entries);
    const p = h.get("anthropic").?;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const msgs = [_]proto.Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "hi" } }} }};
    const req: request.Request = .{ .model = "claude-opus-5-5", .messages = &msgs };
    var fut = try io.concurrent(Provider.stream, .{ p, io, arena.allocator(), &req, events.EventSink.discard });
    try io.sleep(.fromMilliseconds(10), .awake);
    entries[0].settings.label = "changed";
    try h.onSettingsChanged(io, &entries);
    try h.onSettingsChanged(io, &entries);
    try testing.expect(h.get("anthropic").?.ptr != p.ptr);
    const resp = try fut.await(io);
    try testing.expectEqualStrings("Hello world", resp.message.content[0].text.text);
}

test "cli_missing_key_message_and_exit_2" {
    var f: Fx = undefined;
    try f.init(&.{});
    defer f.deinit();
    const h = try ProviderHub.init(testing.allocator, f.deps(null));
    defer h.deinit();
    const entries = [_]hubm.NamedSettings{.{ .id = "anthropic", .settings = .{ .kind = .anthropic } }};
    try h.onSettingsChanged(io, &entries);
    try testing.expect(h.get("anthropic") == null);
    try testing.expect(h.isMissingKey(io, "anthropic"));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("No API key for anthropic: set ANTHROPIC_API_KEY or run `zg ai connect anthropic`", ProviderHub.missingKeyMessage(&buf, "anthropic", .anthropic));
    const r = try h.testConnection(io, "anthropic");
    try testing.expect(!r.ok);
    try testing.expectError(error.UnknownProvider, h.testConnection(io, "nope"));
}

test "key_never_in_session_or_bus" {
    const secret = "sk-ant-SUPER-SECRET-0042";
    const routes = [_]fake.Route{.{ .url_contains = "/v1/messages", .headers = &sse_headers, .body = text_sse }};
    var f: Fx = undefined;
    try f.init(&routes);
    defer f.deinit();
    try f.secrets.store().put(io, "ai/anthropic/default", secret);
    const h = try ProviderHub.init(testing.allocator, f.deps(null));
    defer h.deinit();
    try h.onSettingsChanged(io, &.{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const msgs = [_]proto.Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "hi" } }} }};
    const req: request.Request = .{ .model = "claude-opus-5-5", .messages = &msgs };
    var c: Collect = .{};
    defer c.buf.deinit(testing.allocator);
    const resp = try h.get("anthropic").?.stream(io, arena.allocator(), &req, c.sink());
    // The key went on the wire only.
    var on_wire = false;
    for (f.fake.requests()[0].headers) |hd| on_wire = on_wire or std.mem.eql(u8, hd.value, secret);
    try testing.expect(on_wire);
    try testing.expect(std.mem.indexOf(u8, c.buf.items, secret) == null);
    const line = try proto.json.messageAlloc(arena.allocator(), resp.message);
    try testing.expect(std.mem.indexOf(u8, line, secret) == null);
    try testing.expect(req.api_key == null);
    try testing.expectEqual(@as(usize, 0), f.warnings.items.len);
}
