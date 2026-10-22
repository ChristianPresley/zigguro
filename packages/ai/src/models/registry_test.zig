const std = @import("std");
const proto = @import("zg_ai_proto");
const reg = @import("registry.zig");
const Provider = @import("../provider/Provider.zig");
const Capabilities = @import("../provider/capabilities.zig").Capabilities;

const testing = std.testing;
const ModelRegistry = reg.ModelRegistry;

const mini_catalog: [:0]const u8 =
    \\.{
    \\    .retrieved = "test",
    \\    .models = .{
    \\        .{ .id = "big", .display = "Big", .context_window = 200_000, .max_output = 64_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 5_000_000, .output_per_mtok_micros = 25_000_000 }, .aliases = .{"b"} },
    \\        .{ .id = "small", .context_window = 100_000, .max_output = 8_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 100_000, .output_per_mtok_micros = 500_000 } },
    \\        .{ .id = "notools", .context_window = 1000, .max_output = 100,
    \\           .price = .{ .input_per_mtok_micros = 1, .output_per_mtok_micros = 1 } },
    \\    },
    \\}
;

test "catalog_entries_complete" {
    var r = ModelRegistry.init(testing.allocator, testing.io, reg.builtin_catalog);
    defer r.deinit();
    const s = try r.snapshot();
    try testing.expect(s.models.len >= 10);
    for (s.models) |m| {
        try testing.expect(m.context_window > 0 and m.max_output > 0);
        try testing.expect(m.price != null);
        try testing.expect(m.caps.tools and m.caps.streaming);
    }
    const opus = r.resolve("opus").?;
    try testing.expectEqualStrings("claude-opus-5-5", opus.id);
    try testing.expectEqual(@as(u32, 50), opus.price.?.cache_read_mult_milli);
    try testing.expect(!opus.caps.forced_tool_choice and !opus.caps.thinking_budget and opus.caps.thinking_adaptive);
    try testing.expectEqual(@as(u32, 25), r.resolve("fable").?.price.?.cache_read_mult_milli);
    try testing.expectEqual(@as(usize, 1), r.resolve("haiku").?.price.?.tiers.len);
    try testing.expectEqualStrings("claude-haiku-5-5", r.resolve("fast").?.id);
}

test "lazy_parse_not_on_init" {
    var r = ModelRegistry.init(testing.allocator, testing.io, mini_catalog);
    defer r.deinit();
    try testing.expectEqual(@as(u32, 0), r.parse_count);
    _ = r.resolve("big");
    try testing.expectEqual(@as(u32, 1), r.parse_count);
    _ = r.resolve("small");
    try r.applyUser(&.{}, &.{});
    try testing.expectEqual(@as(u32, 1), r.parse_count);
}

test "invalid catalog" {
    var r = ModelRegistry.init(testing.allocator, testing.io, ".{ .nope = 1 }");
    defer r.deinit();
    try testing.expectError(error.InvalidCatalog, r.snapshot());
    try testing.expect(r.resolve("x") == null);
}

test "alias_resolution" {
    var r = ModelRegistry.init(testing.allocator, testing.io, mini_catalog);
    defer r.deinit();
    try testing.expectEqualStrings("big", r.resolve("b").?.id);
    try testing.expectEqualStrings("small", r.resolve("fast").?.id);
    try testing.expectEqualStrings("big", r.resolve("anthropic/big").?.id);
    try testing.expect(r.resolve("openai_chat/big") == null);
    try testing.expect(r.resolve("local") == null);
    try r.applyApi(.openai_chat, .{ .tools = true }, &.{ .{ .id = "llama3" }, .{ .id = "qwen" } });
    try testing.expectEqualStrings("llama3", r.resolve("local").?.id);
    try r.applyUser(&.{}, &.{ .{ .name = "b", .target = "small" }, .{ .name = "mine", .target = "local" }, .{ .name = "dangling", .target = "nope" } });
    try testing.expectEqualStrings("small", r.resolve("b").?.id);
    try testing.expectEqualStrings("llama3", r.resolve("mine").?.id);
    try testing.expect(r.resolve("dangling") == null);
}

test "merge_precedence_table" {
    const Case = struct {
        name: []const u8,
        api: ?Provider.ModelInfo = null,
        user: ?reg.UserModel = null,
        id: []const u8 = "big",
        window: u32,
        max_output: u32,
        in_price: ?u64,
        tools: bool = true,
    };
    const cases = [_]Case{
        .{ .name = "catalog only", .window = 200_000, .max_output = 64_000, .in_price = 5_000_000 },
        .{ .name = "api beats catalog limits", .api = .{ .id = "big", .context_window = 300_000, .max_output = 32_000 }, .window = 300_000, .max_output = 32_000, .in_price = 5_000_000 },
        .{ .name = "api nulls keep catalog", .api = .{ .id = "big" }, .window = 200_000, .max_output = 64_000, .in_price = 5_000_000 },
        .{ .name = "user beats api", .api = .{ .id = "big", .context_window = 300_000 }, .user = .{ .id = "big", .context_window = 150_000 }, .window = 150_000, .max_output = 64_000, .in_price = 5_000_000 },
        .{ .name = "user beats catalog", .user = .{ .id = "big", .max_output = 1000 }, .window = 200_000, .max_output = 1000, .in_price = 5_000_000 },
        .{ .name = "user price beats catalog", .user = .{ .id = "big", .price = .{ .input_per_mtok_micros = 7, .output_per_mtok_micros = 8 } }, .window = 200_000, .max_output = 64_000, .in_price = 7 },
        .{ .name = "api-only model has no price", .api = .{ .id = "new", .context_window = 50_000 }, .id = "new", .window = 50_000, .max_output = 4096, .in_price = null },
        .{ .name = "user-only model", .user = .{ .id = "custom", .provider = .anthropic, .context_window = 9_000, .max_output = 900 }, .id = "custom", .window = 9_000, .max_output = 900, .in_price = null, .tools = false },
        .{ .name = "user caps beat catalog", .user = .{ .id = "big", .caps = .{ .streaming = true } }, .window = 200_000, .max_output = 64_000, .in_price = 5_000_000, .tools = false },
    };
    for (cases) |c| {
        var r = ModelRegistry.init(testing.allocator, testing.io, mini_catalog);
        defer r.deinit();
        if (c.api) |m| try r.applyApi(.anthropic, .{ .tools = true }, &.{m});
        if (c.user) |u| try r.applyUser(&.{u}, &.{});
        const m = r.resolve(c.id) orelse {
            std.debug.print("case {s}: missing\n", .{c.name});
            return error.TestUnexpectedResult;
        };
        errdefer std.debug.print("case {s} failed\n", .{c.name});
        try testing.expectEqual(c.window, m.context_window);
        try testing.expectEqual(c.max_output, m.max_output);
        try testing.expectEqual(c.in_price, if (m.price) |p| p.input_per_mtok_micros else null);
        try testing.expectEqual(c.tools, m.caps.tools);
    }
}

test "profiles and roles" {
    var r = ModelRegistry.init(testing.allocator, testing.io, mini_catalog);
    defer r.deinit();
    const p = r.profile("big", .main);
    try testing.expect(p.thinking == .adaptive);
    try testing.expectEqual(@as(?u32, 64), r.profile("big", .title).max_output);
    try testing.expect(r.profile("notools", .main).thinking == .off);
    try r.applyUser(&.{.{ .id = "big", .profiles = &.{.{ .role = .main, .profile = .{ .effort = .max } }} }}, &.{});
    try testing.expect(r.profile("b", .main).effort.? == .max);
    const big = r.resolve("big").?;
    try testing.expectEqualStrings("small", r.modelForRole(big, .title).id);
    try testing.expectEqualStrings("big", r.modelForRole(big, .subagent).id);
}

test "listeners see each swap" {
    var r = ModelRegistry.init(testing.allocator, testing.io, mini_catalog);
    defer r.deinit();
    const Counter = struct {
        n: u32 = 0,
        last: u64 = 0,
        fn f(ctx: *anyopaque, s: *const reg.Snapshot) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n += 1;
            self.last = s.version;
        }
    };
    var c: Counter = .{};
    try r.subscribe(.{ .ctx = &c, .models_changed = Counter.f });
    try r.applyApi(.anthropic, .{}, &.{});
    try r.applyUser(&.{}, &.{});
    try testing.expectEqual(@as(u32, 2), c.n);
    try testing.expectEqual(r.version, c.last);
}

test "snapshot_swap_concurrent" {
    var r = ModelRegistry.init(testing.allocator, testing.io, mini_catalog);
    defer r.deinit();
    _ = try r.snapshot();
    const Reader = struct {
        fn run(reg_: *ModelRegistry, stop: *std.atomic.Value(bool), torn: *std.atomic.Value(u32), reads: *std.atomic.Value(u64)) void {
            while (!stop.load(.acquire)) {
                const s = reg_.snapshot() catch unreachable;
                const m = s.resolve("big") orelse {
                    _ = torn.fetchAdd(1, .monotonic);
                    continue;
                };
                // Writers keep max_output = context_window / 10.
                if (m.context_window != 200_000 and m.max_output * 10 != m.context_window) _ = torn.fetchAdd(1, .monotonic);
                _ = reads.fetchAdd(1, .monotonic);
            }
        }
    };
    var stop: std.atomic.Value(bool) = .init(false);
    var torn: std.atomic.Value(u32) = .init(0);
    var reads: std.atomic.Value(u64) = .init(0);
    const t = try std.Thread.spawn(.{}, Reader.run, .{ &r, &stop, &torn, &reads });
    for (0..1000) |i| {
        const w: u32 = @intCast(10_000 + i * 10);
        try r.applyApi(.anthropic, .{ .tools = true }, &.{.{ .id = "big", .context_window = w, .max_output = w / 10 }});
    }
    stop.store(true, .release);
    t.join();
    try testing.expectEqual(@as(u32, 0), torn.load(.monotonic));
    try testing.expectEqual(@as(u32, 19_990), r.resolve("big").?.context_window);
}
