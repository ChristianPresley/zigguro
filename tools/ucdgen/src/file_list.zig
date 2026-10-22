//! The vendored UCD files: the generator inputs plus the conformance test
//! files zg_text reads. `fetch` downloads exactly these, and the manifest
//! lists exactly these plus LICENSE.

const tables = @import("tables.zig");

/// Files `ucdgen` reads to build the tables, in argument order.
pub const generator_inputs = tables.files;

/// Conformance test files used by zg_text's tests.
pub const test_files = [_][]const u8{
    "BidiCharacterTest.txt",
    "BidiTest.txt",
    "NormalizationTest.txt",
    "auxiliary/GraphemeBreakTest.txt",
    "auxiliary/LineBreakTest.txt",
    "auxiliary/WordBreakTest.txt",
};

/// Every file fetched from `https://www.unicode.org/Public/<v>/ucd/`.
pub const files = generator_inputs ++ test_files;

/// The license text, fetched separately when absent.
pub const license = "LICENSE";

test "file list matches generator inputs" {
    const std = @import("std");
    comptime {
        @setEvalBranchQuota(100_000);
        for (tables.files) |g| {
            for (files) |f| {
                if (std.mem.eql(u8, f, g)) break;
            } else @compileError("generator input missing from file list: " ++ g);
        }
        // No duplicates.
        for (files, 0..) |a, i| for (files[i + 1 ..]) |b| if (std.mem.eql(u8, a, b)) @compileError("duplicate " ++ a);
    }
}
