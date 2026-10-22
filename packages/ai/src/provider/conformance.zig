//! The provider conformance suite. Every concrete provider (F02, F03) runs
//! it from its tests with its own fixtures; it is self-tested against the
//! scripted provider. Checks per fixture:
//! - the response equals the fold of the emitted events (the E10.F01 invariant);
//! - expected text, tool calls, stop reason and usage;
//! - chunk-boundary robustness: the same result when the body is re-chunked
//!   at 1..64 bytes;
//! - cancellation mid-stream returns `error.Canceled` within 50 ms.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("Provider.zig");
const request = @import("request.zig");
const events = @import("events.zig");
const MessageAssembler = @import("assembler.zig").MessageAssembler;

const Allocator = std.mem.Allocator;

/// What a fixture must produce.
pub const Expect = struct {
    /// Concatenated text of the response, when checked.
    text: ?[]const u8 = null,
    tool_names: []const []const u8 = &.{},
    stop: proto.StopReason = .end_turn,
    usage: ?proto.Usage = null,
    thinking: bool = false,
    /// The stream must fail with this error instead.
    err: ?Provider.StreamError = null,
};

/// One conformance case.
pub const Fixture = struct {
    name: []const u8,
    /// Provider-specific payload (the HTTP body for HTTP providers).
    body: []const u8 = "",
    status: u16 = 200,
    headers: []const std.http.Header = &.{},
    expect: Expect = .{},
    /// Use this fixture for the cancellation check.
    cancel: bool = false,
};

/// Delivery options passed to the factory.
pub const MakeOptions = struct {
    /// Re-chunk the body at this size (0 = whole).
    chunk_size: usize = 0,
    chunk_delay_ms: u32 = 0,
};

/// Builds a provider serving one fixture.
pub const ProviderFactory = struct {
    ctx: *anyopaque,
    make: *const fn (ctx: *anyopaque, gpa: Allocator, fx: *const Fixture, opts: MakeOptions) anyerror!Provider,
};

/// The fixtures plus the request sent for each.
pub const FixtureSet = struct {
    fixtures: []const Fixture,
    request: request.Request,
};

/// Suite outcome. `failures` lives in the gpa passed to `runConformance`.
pub const ConformanceReport = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    failures: std.ArrayList([]const u8) = .empty,

    /// Frees the failure messages.
    pub fn deinit(r: *ConformanceReport, gpa: Allocator) void {
        for (r.failures.items) |f| gpa.free(f);
        r.failures.deinit(gpa);
    }

    fn fail(r: *ConformanceReport, gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
        r.failed += 1;
        try r.failures.append(gpa, try std.fmt.allocPrint(gpa, fmt, args));
    }
};

const chunk_sizes = [_]usize{ 0, 1, 2, 3, 5, 8, 13, 21, 64 };

const Folder = struct {
    asm_: MessageAssembler,
    fn emit(ctx: *anyopaque, ev: events.StreamEvent) void {
        const f: *Folder = @ptrCast(@alignCast(ctx));
        f.asm_.feed(ev) catch {};
    }
};

/// Runs the suite; inspect `failed` and `failures`.
pub fn runConformance(io: std.Io, gpa: Allocator, make: ProviderFactory, fx: FixtureSet) !ConformanceReport {
    var report: ConformanceReport = .{};
    errdefer report.deinit(gpa);
    for (fx.fixtures) |*f| {
        const before = report.failed;
        var reference: ?[]u8 = null;
        defer if (reference) |r| gpa.free(r);
        for (chunk_sizes) |cs| {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            const a = arena.allocator();
            const p = try make.make(make.ctx, gpa, f, .{ .chunk_size = cs });
            defer p.deinit();
            var folder: Folder = .{ .asm_ = .init(a) };
            folder.asm_.origin = p.id;
            const result = p.stream(io, a, &fx.request, .{ .ctx = &folder, .emit = Folder.emit });
            if (f.expect.err) |want| {
                if (result) |_| {
                    try report.fail(gpa, "{s}/chunk {d}: expected error.{s}, got a response", .{ f.name, cs, @errorName(want) });
                } else |got| if (got != want) try report.fail(gpa, "{s}/chunk {d}: expected error.{s}, got error.{s}", .{ f.name, cs, @errorName(want), @errorName(got) });
                continue;
            }
            const resp = result catch |e| {
                try report.fail(gpa, "{s}/chunk {d}: stream failed: {s}", .{ f.name, cs, @errorName(e) });
                break;
            };
            const folded = folder.asm_.finish() catch {
                try report.fail(gpa, "{s}/chunk {d}: events do not fold", .{ f.name, cs });
                break;
            };
            const enc_resp = try contentJson(a, resp.message);
            const enc_fold = try contentJson(a, folded);
            if (!std.mem.eql(u8, enc_resp, enc_fold))
                try report.fail(gpa, "{s}/chunk {d}: response differs from folded events:\n  {s}\n  {s}", .{ f.name, cs, enc_resp, enc_fold });
            if (reference) |r| {
                if (!std.mem.eql(u8, r, enc_resp)) try report.fail(gpa, "{s}/chunk {d}: result depends on chunking:\n  {s}\n  {s}", .{ f.name, cs, r, enc_resp });
            } else reference = try gpa.dupe(u8, enc_resp);
            try checkExpect(&report, gpa, a, f, cs, resp);
        }
        if (report.failed == before) report.passed += 1;
    }
    for (fx.fixtures) |*f| {
        if (!f.cancel) continue;
        try checkCancel(&report, io, gpa, make, f, &fx.request);
        break;
    }
    return report;
}

fn contentJson(a: Allocator, m: proto.Message) ![]const u8 {
    return proto.json.messageAlloc(a, .{ .role = m.role, .content = m.content });
}

fn checkExpect(report: *ConformanceReport, gpa: Allocator, a: Allocator, f: *const Fixture, cs: usize, resp: request.Response) !void {
    if (resp.stop != f.expect.stop) try report.fail(gpa, "{s}/chunk {d}: stop {s}, want {s}", .{ f.name, cs, @tagName(resp.stop), @tagName(f.expect.stop) });
    if (f.expect.text) |want| {
        const got = try resp.message.text(a);
        if (!std.mem.eql(u8, got, want)) try report.fail(gpa, "{s}/chunk {d}: text \"{s}\", want \"{s}\"", .{ f.name, cs, got, want });
    }
    var names: std.ArrayList([]const u8) = .empty;
    var thinking = false;
    for (resp.message.content) |b| switch (b) {
        .tool_use => |t| if (!t.server) try names.append(a, t.name),
        .thinking => thinking = true,
        else => {},
    };
    if (names.items.len != f.expect.tool_names.len) {
        try report.fail(gpa, "{s}/chunk {d}: {d} tool calls, want {d}", .{ f.name, cs, names.items.len, f.expect.tool_names.len });
    } else for (names.items, f.expect.tool_names) |g, w| {
        if (!std.mem.eql(u8, g, w)) try report.fail(gpa, "{s}/chunk {d}: tool {s}, want {s}", .{ f.name, cs, g, w });
    }
    if (thinking != f.expect.thinking) try report.fail(gpa, "{s}/chunk {d}: thinking present = {}", .{ f.name, cs, thinking });
    if (f.expect.usage) |u| if (!std.meta.eql(u, resp.usage))
        try report.fail(gpa, "{s}/chunk {d}: usage in={d} out={d} cr={d} cw={d}, want in={d} out={d} cr={d} cw={d}", .{ f.name, cs, resp.usage.input, resp.usage.output, resp.usage.cache_read, resp.usage.cache_write_5m, u.input, u.output, u.cache_read, u.cache_write_5m });
}

fn checkCancel(report: *ConformanceReport, io: std.Io, gpa: Allocator, make: ProviderFactory, f: *const Fixture, req: *const request.Request) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = try make.make(make.ctx, gpa, f, .{ .chunk_size = 4, .chunk_delay_ms = 20 });
    defer p.deinit();
    const Run = struct {
        fn run(pp: Provider, ii: std.Io, a: Allocator, rq: *const request.Request) Provider.StreamError!request.Response {
            return pp.stream(ii, a, rq, .discard);
        }
    };
    var fut = try io.concurrent(Run.run, .{ p, io, arena.allocator(), req });
    try io.sleep(.fromMilliseconds(10), .awake);
    const t0 = std.Io.Timestamp.now(io, .awake);
    const r = fut.cancel(io);
    const ms = t0.untilNow(io, .awake).toMilliseconds();
    if (r) |_| {
        try report.fail(gpa, "{s}: cancel returned a response", .{f.name});
    } else |e| {
        if (e != error.Canceled) try report.fail(gpa, "{s}: cancel returned error.{s}", .{ f.name, @errorName(e) });
    }
    if (ms > 50) try report.fail(gpa, "{s}: cancel took {d} ms", .{ f.name, ms });
}

/// Fixture names every provider's set should cover (others are optional).
pub const required_cases = [_][]const u8{ "text_only", "parallel_tools", "tool_error_round_trip", "usage", "max_tokens" };

// Self-test against the scripted provider: fixture name -> script.
const scripted = @import("scripted.zig");
const Step = scripted.ScriptedProvider.Step;

const ScriptedFactory = struct {
    fn make(_: *anyopaque, gpa: Allocator, fx: *const Fixture, opts: MakeOptions) anyerror!Provider {
        const base: []const Step = if (std.mem.eql(u8, fx.name, "parallel_tools"))
            comptime scripted.script.tools(&.{ .{ "a", "read_file", "{\"path\":\"a\"}" }, .{ "b", "read_file", "{\"path\":\"b\"}" }, .{ "c", "grep", "{\"q\":\"x\"}" } })
        else if (std.mem.eql(u8, fx.name, "max_tokens"))
            &.{ .{ .event = .{ .block_start = .{ .index = 0, .kind = .text } } }, .{ .event = .{ .text_delta = .{ .index = 0, .text = "cut" } } }, .{ .event = .{ .stop = .max_tokens } } }
        else
            comptime scripted.script.text("Hello world");
        // Chunk delays become delay steps between events.
        const steps = try gpa.alloc(Step, base.len * 2);
        var n: usize = 0;
        for (base) |s| {
            if (opts.chunk_delay_ms > 0) {
                steps[n] = .{ .delay_ms = opts.chunk_delay_ms };
                n += 1;
            }
            steps[n] = s;
            n += 1;
        }
        const Holder = struct {
            var turns: [1][]const Step = undefined;
        };
        Holder.turns[0] = steps[0..n];
        const sp = try scripted.ScriptedProvider.init(gpa, &Holder.turns, .all);
        // The steps are freed with the provider's arena.
        const owned = try sp.arena.allocator().dupe(Step, steps[0..n]);
        gpa.free(steps);
        Holder.turns[0] = owned;
        sp.turns = try sp.arena.allocator().dupe([]const Step, &Holder.turns);
        return sp.provider();
    }
};

test "conformance_suite_passes_for_scripted_provider" {
    var dummy: u8 = 0;
    const fixtures = [_]Fixture{
        .{ .name = "text_only", .expect = .{ .text = "Hello world", .usage = .{ .input = 10, .output = 5 } }, .cancel = true },
        .{ .name = "parallel_tools", .expect = .{ .tool_names = &.{ "read_file", "read_file", "grep" }, .stop = .tool_use } },
        .{ .name = "max_tokens", .expect = .{ .text = "cut", .stop = .max_tokens } },
    };
    var report = try runConformance(std.testing.io, std.testing.allocator, .{ .ctx = &dummy, .make = ScriptedFactory.make }, .{
        .fixtures = &fixtures,
        .request = .{ .model = "m", .messages = &.{} },
    });
    defer report.deinit(std.testing.allocator);
    for (report.failures.items) |f| std.debug.print("{s}\n", .{f});
    try std.testing.expectEqual(@as(u32, 0), report.failed);
    try std.testing.expectEqual(@as(u32, 3), report.passed);
}
