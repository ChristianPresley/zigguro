const std = @import("std");
const proto = @import("zg_ai_proto");
const pricing = @import("pricing.zig");
const ledger = @import("ledger.zig");
const reg = @import("registry.zig");

const testing = std.testing;
const Price = pricing.Price;

const opus55: Price = .{ .input_per_mtok_micros = 4_000_000, .output_per_mtok_micros = 20_000_000, .cache_read_mult_milli = 50 };
const sonnet55: Price = .{ .input_per_mtok_micros = 2_000_000, .output_per_mtok_micros = 10_000_000 };
const opus5: Price = .{ .input_per_mtok_micros = 5_000_000, .output_per_mtok_micros = 25_000_000 };
const fable51: Price = .{ .input_per_mtok_micros = 10_000_000, .output_per_mtok_micros = 50_000_000, .cache_read_mult_milli = 25 };
const haiku55: Price = .{
    .input_per_mtok_micros = 100_000,
    .output_per_mtok_micros = 500_000,
    .tiers = &.{.{ .above_prompt_tokens = 100_000, .input_per_mtok_micros = 500_000, .output_per_mtok_micros = 2_500_000 }},
};

test "pricing_golden" {
    const Case = struct { name: []const u8, price: Price, usage: proto.Usage, micros: u64 };
    // Hand-computed: tokens × $/MTok × multiplier.
    const cases = [_]Case{
        .{ .name = "plain in/out", .price = opus55, .usage = .{ .input = 1_000_000, .output = 1_000_000 }, .micros = 24_000_000 },
        .{ .name = "5m write 1.25x", .price = sonnet55, .usage = .{ .cache_write_5m = 10_000 }, .micros = 25_000 },
        .{ .name = "1h write 2x", .price = sonnet55, .usage = .{ .cache_write_1h = 10_000 }, .micros = 40_000 },
        .{ .name = "read 0.1x", .price = opus5, .usage = .{ .cache_read = 1_000_000 }, .micros = 500_000 },
        .{ .name = "read 0.05x", .price = opus55, .usage = .{ .cache_read = 1_000_000 }, .micros = 200_000 },
        .{ .name = "read 0.025x", .price = fable51, .usage = .{ .cache_read = 1_000_000 }, .micros = 250_000 },
        .{ .name = "haiku below tier", .price = haiku55, .usage = .{ .input = 50_000, .output = 10_000 }, .micros = 10_000 },
        .{ .name = "haiku above tier", .price = haiku55, .usage = .{ .input = 150_000, .output = 10_000 }, .micros = 100_000 },
        .{ .name = "tier counts cached prompt", .price = haiku55, .usage = .{ .input = 1_000, .cache_read = 120_000 }, .micros = 6_500 },
        .{ .name = "reasoning not double-counted", .price = opus55, .usage = .{ .output = 1_000, .reasoning = 800 }, .micros = 20_000 },
        .{ .name = "mixed turn", .price = sonnet55, .usage = .{ .input = 1_200, .cache_read = 50_000, .cache_write_5m = 3_000, .output = 800 }, .micros = 2_400 + 10_000 + 7_500 + 8_000 },
        .{ .name = "round half up", .price = haiku55, .usage = .{ .input = 5 }, .micros = 1 },
        .{ .name = "round down", .price = haiku55, .usage = .{ .input = 4 }, .micros = 0 },
    };
    for (cases) |c| {
        errdefer std.debug.print("case {s}\n", .{c.name});
        try testing.expectEqual(c.micros, pricing.costOf(c.price, c.usage).micros);
    }
}

test "catalog prices drive costs" {
    var r = reg.ModelRegistry.init(testing.allocator, testing.io, reg.builtin_catalog);
    defer r.deinit();
    const m = r.resolve("claude-opus-5-5").?;
    try testing.expectEqual(@as(u64, 24_000_000), pricing.costOf(m.price.?, .{ .input = 1_000_000, .output = 1_000_000 }).micros);
}

fn testModel(price: ?Price) reg.ModelInfo {
    return .{ .id = "m", .provider = .scripted, .display = "m", .family = "f", .context_window = 1000, .max_output = 100, .caps = .{}, .price = price };
}

test "estimated_flag_propagates" {
    var l = ledger.CostLedger.init(testing.allocator, testing.io);
    defer l.deinit();
    const m = testModel(sonnet55);
    const a: proto.AgentRef = .{ .session = 1 };
    _ = try l.record(a, &m, .{ .input = 1000 }, false);
    try testing.expect(!l.total(.{ .session = 1 }).estimated);
    const c = try l.record(.{ .session = 1, .agent = 2 }, &m, .{ .output = 1000 }, true);
    try testing.expect(c.estimated);
    try testing.expect(l.total(.{ .session = 1 }).estimated);
    try testing.expect(l.total(.workspace).estimated);
    try testing.expect(!l.total(.{ .agent = a }).estimated);
    try testing.expect(l.total(.{ .request = 1 }).estimated);
    try testing.expect(!l.total(.{ .request = 0 }).estimated);
    const unpriced = testModel(null);
    _ = try l.record(a, &unpriced, .{ .input = 5 }, false);
    try testing.expect(l.total(.{ .agent = a }).unpriced);
    try testing.expectEqual(@as(u64, 3), l.total(.workspace).requests);
    try testing.expectEqual(@as(u64, 2_000 + 10_000), l.total(.{ .session = 1 }).micros);
    try testing.expectEqual(@as(u64, 0), l.total(.{ .session = 9 }).requests);
}

test "ledger_concurrent_record" {
    var l = ledger.CostLedger.init(testing.allocator, testing.io);
    defer l.deinit();
    const m = testModel(sonnet55);
    const Seen = struct {
        n: std.atomic.Value(u64) = .init(0),
        fn f(ctx: *anyopaque, _: ledger.Record) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            _ = s.n.fetchAdd(1, .monotonic);
        }
    };
    var seen: Seen = .{};
    try l.subscribe(.{ .ctx = &seen, .on_record = Seen.f });
    const Worker = struct {
        fn run(lg: *ledger.CostLedger, model: *const reg.ModelInfo, idx: u32) void {
            for (0..10_000) |_| _ = lg.record(.{ .session = idx % 2, .agent = idx }, model, .{ .input = 1_000, .output = 100 }, false) catch unreachable;
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &l, &m, @as(u32, @intCast(i)) });
    for (threads) |t| t.join();
    const w = l.total(.workspace);
    try testing.expectEqual(@as(u64, 80_000), w.requests);
    try testing.expectEqual(@as(u64, 80_000 * 1_000), w.usage.input);
    // 1000 in × $2 + 100 out × $10 per MTok = 3000 micros each.
    try testing.expectEqual(@as(u64, 80_000 * 3_000), w.micros);
    try testing.expectEqual(@as(u64, 40_000), l.total(.{ .session = 0 }).requests);
    try testing.expectEqual(@as(u64, 10_000), l.total(.{ .agent = .{ .session = 1, .agent = 3 } }).requests);
    try testing.expectEqual(@as(u64, 80_000), seen.n.load(.monotonic));
}
