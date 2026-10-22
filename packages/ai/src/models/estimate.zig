//! `TokenEstimator`: a fast bytes-per-token estimate for budgeting before
//! a response exists, calibrated per model family from observed usage.
//! Families matter: newer Claude tokenizers yield about 30% more tokens
//! for the same text, so one global ratio would be wrong for someone.

const std = @import("std");

/// Default bytes per token, in thousandths.
pub const default_ratio_milli: u32 = 4000;
pub const min_ratio_milli: u32 = 2000;
pub const max_ratio_milli: u32 = 6000;
/// Families tracked; further families share the default ratio.
pub const max_families = 32;

const Entry = struct {
    name: [48]u8 = undefined,
    len: u8 = 0,
    ratio_milli: std.atomic.Value(u32) = .init(default_ratio_milli),
};

pub const TokenEstimator = struct {
    entries: [max_families]Entry = [_]Entry{.{}} ** max_families,
    /// Published entry count; entries below it are immutable except the ratio.
    count: std.atomic.Value(u32) = .init(0),
    /// Serializes inserts (held for a few instructions).
    insert_lock: std.atomic.Mutex = .unlocked,

    fn find(e: *const TokenEstimator, family: []const u8) ?*const Entry {
        const n = e.count.load(.acquire);
        for (e.entries[0..n]) |*x| if (std.mem.eql(u8, x.name[0..x.len], family)) return x;
        return null;
    }

    /// Current calibrated ratio for `family`, in bytes per token × 1000.
    pub fn ratioMilli(e: *const TokenEstimator, family: []const u8) u32 {
        const x = e.find(family) orelse return default_ratio_milli;
        return x.ratio_milli.load(.monotonic);
    }

    /// Estimated tokens for `text`. Code-heavy text (more than 30% of
    /// sampled bytes are not letters or spaces) gets 15% fewer bytes per token.
    pub fn estimate(e: *const TokenEstimator, family: []const u8, text: []const u8) u32 {
        if (text.len == 0) return 0;
        var ratio: u64 = e.ratioMilli(family);
        if (codeHeavy(text)) ratio = ratio * 85 / 100;
        const t = (@as(u64, text.len) * 1000 + ratio - 1) / ratio;
        return @intCast(@min(t, std.math.maxInt(u32)));
    }

    /// Estimated tokens for `bytes` of mixed text (no content scan).
    pub fn estimateBytes(e: *const TokenEstimator, family: []const u8, bytes: u64) u64 {
        const ratio: u64 = e.ratioMilli(family);
        return (bytes * 1000 + ratio - 1) / ratio;
    }

    /// Folds one observation (request bytes vs. reported input tokens) into
    /// the family's ratio: EWMA with alpha 0.1, clamped to [2.0, 6.0].
    pub fn calibrate(e: *TokenEstimator, family: []const u8, chars: u64, actual_tokens: u64) void {
        if (actual_tokens == 0 or chars == 0) return;
        const x = e.findOrInsert(family) orelse return;
        const observed: i64 = @intCast(std.math.clamp(chars * 1000 / actual_tokens, min_ratio_milli, max_ratio_milli));
        var cur = x.ratio_milli.load(.monotonic);
        while (true) {
            const c: i64 = cur;
            var step = @divTrunc(observed - c, 10);
            if (step == 0) step = std.math.sign(observed - c);
            const next: u32 = @intCast(std.math.clamp(c + step, min_ratio_milli, max_ratio_milli));
            if (next == cur) return;
            cur = x.ratio_milli.cmpxchgWeak(cur, next, .monotonic, .monotonic) orelse return;
        }
    }

    fn findOrInsert(e: *TokenEstimator, family: []const u8) ?*Entry {
        if (e.find(family)) |x| return @constCast(x);
        if (family.len > 48) return null;
        while (!e.insert_lock.tryLock()) std.atomic.spinLoopHint();
        defer e.insert_lock.unlock();
        if (e.find(family)) |x| return @constCast(x);
        const n = e.count.load(.monotonic);
        if (n == max_families) return null;
        const x = &e.entries[n];
        @memcpy(x.name[0..family.len], family);
        x.len = @intCast(family.len);
        e.count.store(n + 1, .release);
        return x;
    }
};

fn codeHeavy(text: []const u8) bool {
    const sample = text[0..@min(text.len, 4096)];
    var other: usize = 0;
    for (sample) |c| {
        if (!std.ascii.isAlphabetic(c) and c != ' ' and c < 0x80) other += 1;
    }
    return other * 10 > sample.len * 3;
}

const testing = std.testing;

test "default ratio and code adjustment" {
    const e: TokenEstimator = .{};
    try testing.expectEqual(@as(u32, 3), e.estimate("x", "hello world!"));
    // 40 bytes of prose: 10 tokens.
    try testing.expectEqual(@as(u32, 10), e.estimate("x", "the quick brown fox jumps over a lazy do"));
    // Code: 3.4 bytes per token.
    const code = "fn f(a: u8) !void { try x(a[0..]); }\n";
    try testing.expectEqual(@as(u32, (code.len * 1000 + 3399) / 3400), e.estimate("x", code));
    try testing.expectEqual(@as(u32, 0), e.estimate("x", ""));
}

test "estimator_calibration_converges" {
    var e: TokenEstimator = .{};
    // True ratio 3.2 bytes/token for family A; family B stays at default.
    var rng = std.Random.DefaultPrng.init(42);
    for (0..50) |_| {
        const bytes = 10_000 + rng.random().uintLessThan(u64, 50_000);
        e.calibrate("claude-tok2", bytes, bytes * 10 / 32);
    }
    const r = e.ratioMilli("claude-tok2");
    try testing.expect(r >= 3200 * 97 / 100 and r <= 3200 * 103 / 100);
    try testing.expectEqual(default_ratio_milli, e.ratioMilli("claude-tok1"));
}

test "calibration clamps" {
    var e: TokenEstimator = .{};
    for (0..200) |_| e.calibrate("f", 100, 1000);
    try testing.expectEqual(min_ratio_milli, e.ratioMilli("f"));
    for (0..200) |_| e.calibrate("f", 100_000, 1);
    try testing.expectEqual(max_ratio_milli, e.ratioMilli("f"));
}
