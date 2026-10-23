//! Data mode (E13.F06): CSV/TSV files opened instantly, with dialect
//! sniffing, a parallel SIMD row index and random access to cells.

pub const encoding = @import("encoding.zig");
pub const csv = @import("csv.zig");
pub const sniff = @import("sniff.zig");
pub const scan_simd = @import("scan_simd.zig");
pub const row_index = @import("row_index.zig");
pub const dataset = @import("dataset.zig");

pub const Dataset = dataset.Dataset;
pub const Dialect = csv.Dialect;
pub const RowIndex = row_index.RowIndex;

test {
    _ = @import("csv_test.zig");
    _ = @import("sniff_test.zig");
    _ = @import("row_index_test.zig");
}
