//! The `.vtt` corpus under `testdata/conformance/` (embedded at build time)
//! and the per-category minimum case counts. `zig build
//! test-terminal-conformance` runs only these tests.

const std = @import("std");
const corpus = @import("zg_conformance");
const runner = @import("runner.zig");
const vtt = @import("vtt.zig");

/// Minimum cases per category directory (E06.F02.S03.T01). Warned about
/// until the owning tasks land; `-Dterminal_conformance_strict` fails.
const minimums = [_]struct { []const u8, usize }{
    .{ "core", 120 },   .{ "sgr", 40 },   .{ "modes", 30 },
    .{ "reports", 25 }, .{ "osc", 40 },   .{ "unicode", 40 },
    .{ "reflow", 40 },  .{ "input", 40 }, .{ "marks", 25 },
};

test "conformance: every .vtt case passes" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const r = try runner.runCorpus(gpa, corpus.files, &out.writer);
    if (r.failed > 0) {
        std.debug.print("{s}\n{d} of {d} conformance cases failed\n", .{ out.written(), r.failed, r.cases });
        return error.ConformanceFailures;
    }
}

test "conformance: category minimums" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var counts: [minimums.len]usize = @splat(0);
    for (corpus.files) |f| {
        if (!std.mem.endsWith(u8, f[0], ".vtt")) continue;
        const slash = std.mem.indexOfScalar(u8, f[0], '/') orelse continue;
        const cat = f[0][0..slash];
        var d: vtt.Diagnostic = .{};
        const scripts = vtt.parseFile(arena.allocator(), f[0], f[1], &d) catch continue;
        for (minimums, 0..) |m, i| {
            if (std.mem.eql(u8, m[0], cat)) counts[i] += scripts.len;
        }
    }
    var short = false;
    for (minimums, counts) |m, n| {
        if (n >= m[1]) continue;
        short = true;
        std.log.warn("conformance category {s}: {d} cases, minimum {d}", .{ m[0], n, m[1] });
    }
    if (short and corpus.strict) return error.ConformanceCategoryUnderMinimum;
}
