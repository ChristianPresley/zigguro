//! Exact request pricing in integer micro-USD. Multipliers are per model
//! (from the catalog), never constants: cache reads cost 0.1× input on
//! most models but 0.05× or 0.025× on some.

const std = @import("std");
const proto = @import("zg_ai_proto");

const Usage = proto.Usage;

/// Long-prompt pricing: applies to the whole request once the prompt
/// (input + cache reads + cache writes) exceeds `above_prompt_tokens`.
pub const Tier = struct {
    above_prompt_tokens: u64,
    input_per_mtok_micros: u64,
    output_per_mtok_micros: u64,
};

/// Per-million-token prices of one model.
pub const Price = struct {
    input_per_mtok_micros: u64,
    output_per_mtok_micros: u64,
    /// Multipliers on the input price, in thousandths.
    cache_write_5m_mult_milli: u32 = 1250,
    cache_write_1h_mult_milli: u32 = 2000,
    cache_read_mult_milli: u32 = 100,
    /// Sorted by `above_prompt_tokens`, ascending.
    tiers: []const Tier = &.{},
};

/// A request's cost. `estimated` is set when usage came from the estimator.
pub const Cost = struct {
    micros: u64,
    estimated: bool = false,
};

/// The cost of one request. Reasoning tokens are already part of
/// `u.output` (Anthropic and OpenAI both bill them as output), so
/// `u.reasoning` is never added again.
pub fn costOf(p: Price, u: Usage) Cost {
    const prompt = u.input + u.cache_read + u.cache_write_5m + u.cache_write_1h;
    var in_price: u128 = p.input_per_mtok_micros;
    var out_price: u128 = p.output_per_mtok_micros;
    for (p.tiers) |t| if (prompt > t.above_prompt_tokens) {
        in_price = t.input_per_mtok_micros;
        out_price = t.output_per_mtok_micros;
    };
    // Units: micro-USD × tokens × milli; divide by 1e6 tokens and 1e3 milli.
    var n: u128 = 0;
    n += @as(u128, u.input) * in_price * 1000;
    n += @as(u128, u.cache_write_5m) * in_price * p.cache_write_5m_mult_milli;
    n += @as(u128, u.cache_write_1h) * in_price * p.cache_write_1h_mult_milli;
    n += @as(u128, u.cache_read) * in_price * p.cache_read_mult_milli;
    n += @as(u128, u.output) * out_price * 1000;
    const d: u128 = 1_000_000_000;
    return .{ .micros = @intCast((n + d / 2) / d) };
}

/// Formats micro-USD as dollars with 4 decimals, e.g. `$0.0125`; a `~`
/// prefix marks an estimate.
pub fn formatUsd(buf: []u8, c: Cost) []const u8 {
    const hundredths_of_cents = (c.micros + 50) / 100;
    return std.fmt.bufPrint(buf, "{s}${d}.{d:0>4}", .{ if (c.estimated) "~" else "", hundredths_of_cents / 10_000, hundredths_of_cents % 10_000 }) catch buf[0..0];
}

/// The `total_cost_usd` float of stream-json results.
pub fn toUsd(micros: u64) f64 {
    return @as(f64, @floatFromInt(micros)) / 1_000_000.0;
}

test "format" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("$0.0125", formatUsd(&buf, .{ .micros = 12_500 }));
    try std.testing.expectEqualStrings("~$24.0000", formatUsd(&buf, .{ .micros = 24_000_000, .estimated = true }));
    try std.testing.expectEqualStrings("$0.0001", formatUsd(&buf, .{ .micros = 50 }));
}
