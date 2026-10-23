//! Data mode (E13.F06.S01.T02): the grid over a dataset, its query bar,
//! column profile, row detail and "Chart this".

const std = @import("std");

pub const grid_vm = @import("grid_vm.zig");
pub const chart_this = @import("chart_this.zig");
pub const query_bar = @import("query_bar.zig");
pub const profile_panel = @import("profile_panel.zig");
pub const row_detail = @import("row_detail.zig");
pub const grid = @import("grid.zig");

pub const GridVM = grid_vm.GridVM;
pub const DataGrid = grid.DataGrid;
pub const dataGrid = grid.dataGrid;

test {
    std.testing.refAllDecls(@This());
    _ = @import("grid_vm_test.zig");
    _ = @import("grid_test.zig");
}
