//! zg_scm's `ModelPort` over a zg_ai provider (E09.F06 ports, E10 side):
//! each `AiRequest` is one `Provider.stream` call, and text arrives in
//! the scm sink as the provider emits it, with no extra buffering. A
//! request with a JSON schema asks for structured output when the model
//! supports it and its chunks go to `onJson`; otherwise the schema is
//! left to the prompt and the reply arrives as text.
//!
//! `Backend` builds the providers the way `zg agent` does (keys from the
//! environment, optional cassette) for the `zg scm ai` commands.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_ai = @import("zg_ai");
const zg_net = @import("zg_net");
const zg_scm = @import("zg_scm");

const proto = zg_ai.proto;
const ports = zg_scm.ai.ports;
const ModelInfo = zg_ai.models.registry.ModelInfo;
const Cassette = zg_ai.testing.cassette.Cassette;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ProviderModel = struct {
    /// Must be thread-safe: `zg scm ai resolve` calls from several workers.
    gpa: Allocator,
    io: Io,
    provider: zg_ai.Provider,
    model: *const ModelInfo,

    pub fn port(self: *ProviderModel) ports.ModelPort {
        return .{ .ctx = self, .complete = complete };
    }

    fn complete(ctx: *anyopaque, req: *const ports.AiRequest, sink: *ports.AiSink) anyerror!void {
        const self: *ProviderModel = @ptrCast(@alignCast(ctx));
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();

        const msgs = try a.alloc(proto.Message, req.messages.len);
        for (msgs, req.messages) |*m, src| {
            const role: proto.Role = switch (src.role) {
                .user => .user,
                .assistant => .assistant,
            };
            m.* = .{ .role = role, .content = try a.dupe(proto.ContentBlock, &.{.{ .text = .{ .text = src.text } }}) };
        }
        const structured = req.json_schema != null and self.model.caps.structured_output;
        const r: zg_ai.Request = .{
            .model = self.model.id,
            .system = try a.dupe(zg_ai.request.SystemPart, &.{.{ .text = req.system }}),
            .messages = msgs,
            .max_output_tokens = @min(req.max_output_tokens, self.model.max_output),
            .output_schema_json = if (structured) req.json_schema else null,
        };
        var fwd: Forward = .{ .sink = sink, .req = req, .json = structured };
        const resp = self.provider.stream(self.io, a, &r, .{ .ctx = &fwd, .emit = Forward.emit }) catch |e| switch (e) {
            error.Canceled => return sink.done(.cancelled, fwd.usage),
            else => {
                const msg = if (fwd.err_len > 0) fwd.err_buf[0..fwd.err_len] else @errorName(e);
                return sink.fail(msg);
            },
        };
        const usage: ports.Usage = .{ .input_tokens = clamp(resp.usage.input), .output_tokens = clamp(resp.usage.output) };
        const reason: ports.StopReason = if (req.cancelled()) .cancelled else switch (resp.stop) {
            .max_tokens, .context_window_exceeded => .max_tokens,
            .canceled => .cancelled,
            else => .end,
        };
        sink.done(reason, usage);
    }

    fn clamp(n: u64) u32 {
        return @intCast(@min(n, std.math.maxInt(u32)));
    }
};

/// Forwards text deltas; keeps the provider's error message.
const Forward = struct {
    sink: *ports.AiSink,
    req: *const ports.AiRequest,
    json: bool,
    usage: ports.Usage = .{},
    err_buf: [256]u8 = undefined,
    err_len: usize = 0,

    fn emit(ctx: *anyopaque, ev: zg_ai.StreamEvent) void {
        const f: *Forward = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .text_delta => |d| {
                // A cancelled request drops the rest of the reply.
                if (f.req.cancelled()) return;
                if (f.json) f.sink.json(d.text) else f.sink.text(d.text);
            },
            .provider_error => |e| {
                const msg = if (e.message.len > 0) e.message else e.kind;
                f.err_len = @min(msg.len, f.err_buf.len);
                @memcpy(f.err_buf[0..f.err_len], msg[0..f.err_len]);
            },
            else => {},
        }
    }
};

/// The providers and model registry for one CLI run.
pub const Backend = struct {
    gpa: Allocator,
    env: std.process.Environ.Map,
    registry: zg_ai.ModelRegistry,
    client: *zg_net.http.Client,
    net: zg_ai.transport.ZgNet,
    cassette: ?*Cassette = null,
    limiter: zg_ai.ratelimit.RateLimiter,
    notes: Notes,
    hub: *zg_ai.ProviderHub,

    /// Initializes `b` in place (it must not move). Environment: the
    /// provider keys, `ZG_MODEL` and `ZG_CASSETTE[_MODE]` as for `zg agent`.
    pub fn init(b: *Backend, rt: *zg_core.Runtime, min: std.process.Init.Minimal, err: *Io.Writer) !void {
        const gpa = rt.gpa;
        const io = rt.io;
        b.gpa = gpa;
        b.cassette = null;
        b.env = try min.environ.createMap(gpa);
        errdefer b.env.deinit();
        b.registry = zg_ai.ModelRegistry.init(gpa, io, zg_ai.models.registry.builtin_catalog);
        errdefer b.registry.deinit();
        b.client = try zg_net.http.Client.init(rt, .{ .environ_map = &b.env });
        errdefer b.client.deinit();
        b.net = .{ .client = b.client };
        var transport = b.net.transport();
        if (b.env.get("ZG_CASSETTE")) |path| {
            const mode_name = b.env.get("ZG_CASSETTE_MODE") orelse "replay";
            const mode = std.meta.stringToEnum(zg_ai.testing.cassette.Mode, mode_name) orelse return error.BadCassetteMode;
            b.cassette = try Cassette.open(io, gpa, path, mode, .{ .print_misses = true });
            transport = b.cassette.?.transport(if (mode == .replay) null else b.net.transport());
            if (mode == .replay and b.env.get("ANTHROPIC_API_KEY") == null) try b.env.put("ANTHROPIC_API_KEY", "cassette");
        }
        errdefer if (b.cassette) |c| c.deinit();
        b.limiter = .init(gpa, .real);
        errdefer b.limiter.deinit();
        b.notes = .{ .err = err };
        b.hub = try zg_ai.ProviderHub.init(gpa, .{
            .secrets = no_secrets,
            .environ = &b.env,
            .transport = transport,
            .limiter = &b.limiter,
            .registry = &b.registry,
            .notifier = .{ .ctx = &b.notes, .warn = Notes.warn, .redact = Notes.redact },
        });
        errdefer b.hub.deinit();
        try b.hub.onSettingsChanged(io, &.{});
    }

    pub fn deinit(b: *Backend) void {
        b.hub.deinit();
        b.limiter.deinit();
        if (b.cassette) |c| {
            c.finish() catch {};
            c.deinit();
        }
        b.client.deinit();
        b.registry.deinit();
        b.env.deinit();
    }

    /// The model named `name` (else `ZG_MODEL`, else "sonnet") and its
    /// provider, or null with the reason written to `err`.
    pub fn model(b: *Backend, io: Io, name: ?[]const u8, err: *Io.Writer) !?ProviderModel {
        const want = name orelse b.env.get("ZG_MODEL") orelse "sonnet";
        const info = b.registry.resolve(want) orelse {
            try err.print("zg scm ai: unknown model {s}\n", .{want});
            return null;
        };
        const p = b.hub.forModel(info) orelse {
            try err.print("zg scm ai: no provider for {s}; set its API key (e.g. ANTHROPIC_API_KEY)\n", .{info.id});
            return null;
        };
        return .{ .gpa = b.gpa, .io = io, .provider = p, .model = info };
    }
};

const Notes = struct {
    err: *Io.Writer,

    fn warn(ctx: *anyopaque, msg: []const u8) void {
        const n: *Notes = @ptrCast(@alignCast(ctx));
        n.err.print("zg scm ai: {s}\n", .{msg}) catch {};
    }

    fn redact(_: *anyopaque, _: []const u8) void {}
};

/// Keys come from the environment until E16's keychain lands.
const no_secrets: zg_ai.keyref.SecretStore = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .vtable = &.{ .get = getNone, .put = putNone } };

fn getNone(_: *anyopaque, _: Io, _: []const u8) zg_ai.keyref.SecretError!?[]const u8 {
    return null;
}

fn putNone(_: *anyopaque, _: Io, _: []const u8, _: []const u8) zg_ai.keyref.SecretError!void {
    return error.Unavailable;
}

const testing = std.testing;

const test_model: ModelInfo = .{
    .id = "m-1",
    .provider = .scripted,
    .display = "M",
    .family = "m",
    .context_window = 100_000,
    .max_output = 2048,
    .caps = .{ .structured_output = true },
};

test "ProviderModel streams text and maps the request" {
    const gpa = testing.allocator;
    const turn = [_]zg_ai.ScriptedProvider.Step{
        .{ .event = .{ .message_start = .{ .id = "x", .model = "m-1" } } },
        .{ .event = .{ .block_start = .{ .index = 0, .kind = .text } } },
        .{ .event = .{ .text_delta = .{ .index = 0, .text = "{\"subject\":" } } },
        .{ .event = .{ .text_delta = .{ .index = 0, .text = "\"Fix it\"}" } } },
        .{ .event = .{ .block_stop = .{ .index = 0 } } },
        .{ .event = .{ .usage = .{ .input = 12, .output = 5 } } },
        .{ .event = .{ .stop = .end_turn } },
    };
    const turns = [_][]const zg_ai.ScriptedProvider.Step{ &turn, &turn };
    const sp = try zg_ai.ScriptedProvider.init(gpa, &turns, .{ .structured_output = true });
    const p = sp.provider();
    defer p.deinit();

    var pm: ProviderModel = .{ .gpa = gpa, .io = testing.io, .provider = p, .model = &test_model };
    var col: zg_scm.ai.testing.fake_model.Collector = .init(gpa);
    defer col.deinit();
    var sink = col.sink();
    const msgs = [_]ports.AiMessage{.{ .role = .user, .text = "describe" }};
    const req: ports.AiRequest = .{ .system = "sys", .messages = &msgs, .json_schema = "{}", .max_input_tokens = 1000, .max_output_tokens = 9000 };
    try pm.port().call(&req, &sink);
    try testing.expectEqualStrings("{\"subject\":\"Fix it\"}", col.json.items);
    try testing.expectEqual(@as(usize, 0), col.text.items.len);
    try testing.expectEqual(ports.StopReason.end, col.stop.?);

    const sent = sp.requests()[0];
    try testing.expectEqualStrings("m-1", sent.model);
    try testing.expectEqualStrings("sys", sent.system[0].text);
    try testing.expectEqual(@as(u32, 2048), sent.max_output_tokens);
    try testing.expectEqualStrings("{}", sent.output_schema_json.?);

    // Without a schema the reply is text.
    var col2: zg_scm.ai.testing.fake_model.Collector = .init(gpa);
    defer col2.deinit();
    var sink2 = col2.sink();
    const plain: ports.AiRequest = .{ .system = "sys", .messages = &msgs, .max_input_tokens = 1000 };
    try pm.port().call(&plain, &sink2);
    try testing.expectEqualStrings("{\"subject\":\"Fix it\"}", col2.text.items);
    try testing.expect(sp.requests()[1].output_schema_json == null);
}

test "ProviderModel reports provider errors" {
    const gpa = testing.allocator;
    const turn = [_]zg_ai.ScriptedProvider.Step{
        .{ .event = .{ .provider_error = .{ .status = 401, .kind = "authentication_error", .message = "bad key" } } },
        .{ .fail = error.Auth },
    };
    const turns = [_][]const zg_ai.ScriptedProvider.Step{&turn};
    const sp = try zg_ai.ScriptedProvider.init(gpa, &turns, .{});
    const p = sp.provider();
    defer p.deinit();
    var pm: ProviderModel = .{ .gpa = gpa, .io = testing.io, .provider = p, .model = &test_model };
    var col: zg_scm.ai.testing.fake_model.Collector = .init(gpa);
    defer col.deinit();
    var sink = col.sink();
    const msgs = [_]ports.AiMessage{.{ .role = .user, .text = "x" }};
    const req: ports.AiRequest = .{ .system = "", .messages = &msgs, .max_input_tokens = 10 };
    try pm.port().call(&req, &sink);
    try testing.expectEqualStrings("bad key", col.err.?);
}
