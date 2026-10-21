//! Fuzzing conventions on Zig 0.16's Smith-based fuzzer.
//!
//! - Name fuzz tests `"fuzz: <target>"`; one target per untrusted-input parser.
//! - Seed corpora live in `packages/<pkg>/fuzz/corpus/<target>/*`;
//!   `zg_build.addPackage` embeds them as the package's own `zg_corpus`
//!   module (`@import("zg_corpus").<target>`). Pass that module to `corpus`:
//!   ```zig
//!   try std.testing.fuzz({}, one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "sse") });
//!   ```
//! - Without `--fuzz`, each fuzz test runs once per corpus entry as a plain test.
//! - Rules: fuzz in ReleaseSafe; use `std.testing.allocator`; no network or
//!   file I/O in fuzz bodies; bound input sizes; feed streaming parsers via
//!   `chunked`; commit minimised crash inputs to the corpus with the fix.

const std = @import("std");
const Smith = std.testing.Smith;

/// The embedded seeds for `name` from a package's `zg_corpus` module, or an
/// empty list when the package has no such corpus directory.
pub fn corpus(comptime Corpus: type, comptime name: []const u8) []const []const u8 {
    if (@hasDecl(Corpus, name)) return @field(Corpus, name);
    return &.{};
}

/// Splits `input` at up to `max_chunks - 1` random points into `out` and
/// returns the used prefix of `out`; the chunks concatenate to `input`.
/// Use it to feed streaming parsers arbitrary chunk boundaries.
pub fn chunked(s: *Smith, input: []const u8, max_chunks: u8, out: [][]const u8) [][]const u8 {
    std.debug.assert(out.len >= max_chunks and max_chunks >= 1);
    var n: usize = 0;
    var pos: usize = 0;
    while (n + 1 < max_chunks and pos < input.len and !s.eos()) {
        const take: usize = s.valueRangeAtMost(u32, 0, @intCast(@min(input.len - pos, std.math.maxInt(u32))));
        out[n] = input[pos..][0..take];
        pos += take;
        n += 1;
    }
    out[n] = input[pos..];
    return out[0 .. n + 1];
}

/// A random value of type `T` (shorthand for `s.value(T)`).
pub fn pick(s: *Smith, comptime T: type) T {
    return s.value(T);
}

test "fuzz kit: chunked splits cover the input exactly" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var parts: [8][]const u8 = undefined;
            const chunks = chunked(s, input, 8, &parts);
            var joined: [256]u8 = undefined;
            var n: usize = 0;
            for (chunks) |c| {
                @memcpy(joined[n..][0..c.len], c);
                n += c.len;
            }
            try std.testing.expectEqualSlices(u8, input, joined[0..n]);
            try std.testing.expect(chunks.len <= 8);
        }
    }.one, .{ .corpus = &.{ "hello world", "" } });
}

test "fuzz kit: corpus(\"example\") returns the 2 embedded seeds" {
    const seeds = corpus(@import("zg_corpus"), "example");
    try std.testing.expectEqual(@as(usize, 2), seeds.len);
    try std.testing.expectEqualStrings("seed one\n", seeds[0]);
    try std.testing.expectEqual(@as(usize, 0), corpus(@import("zg_corpus"), "does_not_exist").len);
}

test "fuzz: example target" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *Smith) anyerror!void {
            var buf: [64]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            _ = std.mem.count(u8, input, "seed");
        }
    }.one, .{ .corpus = corpus(@import("zg_corpus"), "example") });
}
