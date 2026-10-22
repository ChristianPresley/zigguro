//! Deterministic throughput corpora for the terminal benchmarks, modelled on
//! what real programs write to a terminal (vtebench methodology).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The corpus kinds.
pub const Corpus = enum { ascii_lines, unicode_mixed, sgr_heavy, cursor_motion, scroll_region, alt_screen_tui };

const words = [_][]const u8{ "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "error:", "warning:", "src/main.zig:42:13", "expected", "found", "struct", "const", "return" };
const cjk = [_][]const u8{ "日", "本", "語", "漢", "字", "한", "국", "어", "中", "文" };
const emoji = [_][]const u8{ "🧑‍🌾", "👍🏽", "🇯🇵", "❤️", "😀", "👨‍👩‍👧" };

/// Appends `size` bytes (rounded to a whole line) of corpus `c` to `out`.
pub fn generate(c: Corpus, size: usize, seed: u64, out: *std.ArrayList(u8), gpa: Allocator) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    try out.ensureUnusedCapacity(gpa, size + 512);
    const start = out.items.len;
    var col: usize = 0;
    while (out.items.len - start < size) {
        switch (c) {
            .ascii_lines => {
                const w = words[r.uintLessThan(usize, words.len)];
                if (col + w.len + 1 > 80) {
                    try out.append(gpa, '\n');
                    col = 0;
                }
                try out.appendSlice(gpa, w);
                try out.append(gpa, ' ');
                col += w.len + 1;
            },
            .unicode_mixed => {
                const roll = r.uintLessThan(u8, 100);
                const w = if (roll < 30) cjk[r.uintLessThan(usize, cjk.len)] else if (roll < 40) emoji[r.uintLessThan(usize, emoji.len)] else words[r.uintLessThan(usize, words.len)];
                try out.appendSlice(gpa, w);
                col += 2;
                if (col > 70) {
                    try out.appendSlice(gpa, "\r\n");
                    col = 0;
                } else try out.append(gpa, ' ');
            },
            .sgr_heavy => {
                switch (r.uintLessThan(u8, 4)) {
                    0 => try out.appendSlice(gpa, "\x1b[1;31m"),
                    1 => try out.print(gpa, "\x1b[38;5;{d}m", .{r.int(u8)}),
                    2 => try out.print(gpa, "\x1b[38;2;{d};{d};{d}m", .{ r.int(u8), r.int(u8), r.int(u8) }),
                    else => try out.appendSlice(gpa, "\x1b[0m"),
                }
                try out.appendSlice(gpa, "0123456789");
                col += 10;
                if (col >= 80) {
                    try out.appendSlice(gpa, "\x1b[0m\r\n");
                    col = 0;
                }
            },
            .cursor_motion => {
                try out.print(gpa, "\x1b[{d};{d}H", .{ r.uintAtMost(u8, 50) + 1, r.uintAtMost(u8, 190) + 1 });
                try out.appendSlice(gpa, words[r.uintLessThan(usize, words.len)]);
            },
            .scroll_region => {
                if (r.uintLessThan(u8, 64) == 0) try out.print(gpa, "\x1b[{d};{d}r", .{ r.uintAtMost(u8, 10) + 1, r.uintAtMost(u8, 30) + 20 });
                try out.appendSlice(gpa, "scrolling line of output\n");
            },
            .alt_screen_tui => {
                try out.appendSlice(gpa, "\x1b[?2026h\x1b[H");
                for (0..50) |row| {
                    try out.print(gpa, "\x1b[{d};1H\x1b[7m{d:>4}\x1b[m ", .{ row + 1, row });
                    for (0..12) |_| {
                        try out.appendSlice(gpa, words[r.uintLessThan(usize, words.len)]);
                        try out.append(gpa, ' ');
                    }
                    try out.appendSlice(gpa, "\x1b[K");
                }
                try out.appendSlice(gpa, "\x1b[?2026l");
            },
        }
    }
}

test "generate is deterministic" {
    const gpa = std.testing.allocator;
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    for (std.enums.values(Corpus)) |c| {
        a.clearRetainingCapacity();
        b.clearRetainingCapacity();
        try generate(c, 4096, 7, &a, gpa);
        try generate(c, 4096, 7, &b, gpa);
        try std.testing.expectEqualSlices(u8, a.items, b.items);
        try std.testing.expect(a.items.len >= 4096);
    }
}
