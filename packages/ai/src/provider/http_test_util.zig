//! Test helper: a conformance `ProviderFactory` serving each fixture through
//! a fresh `FakeTransport`, for any HTTP provider with
//! `create(gpa, transport, cfg)` and `provider()`.

const std = @import("std");
const Provider = @import("Provider.zig");
const fake = @import("fake_server.zig");
const conformance = @import("conformance.zig");

/// Factory for provider type `P` created with config `cfg`.
pub fn Factory(comptime P: type) type {
    return struct {
        cfg: P.Config,
        fake: ?fake.FakeTransport = null,

        /// Frees the last fake transport.
        pub fn deinit(f: *@This()) void {
            if (f.fake) |*x| x.deinit();
        }

        /// The conformance view.
        pub fn factory(f: *@This()) conformance.ProviderFactory {
            return .{ .ctx = f, .make = make };
        }

        fn make(ctx: *anyopaque, gpa: std.mem.Allocator, fx: *const conformance.Fixture, opts: conformance.MakeOptions) anyerror!Provider {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.fake) |*x| x.deinit();
            self.fake = try .init(gpa, &.{});
            const routes = try self.fake.?.arena.allocator().alloc(fake.Route, 1);
            routes[0] = .{ .status = fx.status, .headers = fx.headers, .body = fx.body, .chunk_size = opts.chunk_size, .chunk_delay_ms = opts.chunk_delay_ms };
            self.fake.?.routes = routes;
            self.fake.?.used = try self.fake.?.arena.allocator().alloc(bool, 1);
            self.fake.?.used[0] = false;
            const p = try P.create(gpa, self.fake.?.transport(), self.cfg);
            return p.provider();
        }
    };
}

/// Builds an SSE body from `data:` payloads (one event each).
pub fn sse(comptime datas: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (datas) |d| out = out ++ "data: " ++ d ++ "\n\n";
        return out;
    }
}

/// Runs the suite and fails the test on any failure.
pub fn expectConformance(factory: conformance.ProviderFactory, fixtures: []const conformance.Fixture) !void {
    const user_hi = [_]@import("zg_ai_proto").Message{.{ .role = .user, .content = &.{.{ .text = .{ .text = "Hello" } }} }};
    var report = try conformance.runConformance(std.testing.io, std.testing.allocator, factory, .{ .fixtures = fixtures, .request = .{ .model = "test-model", .messages = &user_hi } });
    defer report.deinit(std.testing.allocator);
    for (report.failures.items) |x| std.debug.print("{s}\n", .{x});
    try std.testing.expectEqual(@as(u32, 0), report.failed);
}

/// Encodes `req` with `writeBody(w, ctx)` and compares with a golden.
pub fn expectBodyGolden(comptime src: std.builtin.SourceLocation, comptime dir: []const u8, name: []const u8, ctx: anytype, comptime writeBody: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    try writeBody(&out.writer, ctx);
    _ = try @import("zg_ai_proto").json.parseValue(a, out.written());
    try @import("zg_core").testkit.golden.expectGoldenOpts(std.testing.io, src, name, out.written(), .{ .root = @import("zg_options").package_root, .dir = "testdata/golden/" ++ dir });
}
