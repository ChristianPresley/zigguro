//! Mission Control (E13.F01.S02): the view-model over the run registry,
//! the filter grammar, the dispatch box and the row actions. Headless;
//! `zg_agents_ui` draws it.

pub const vm = @import("vm.zig");
pub const filter = @import("filter.zig");
pub const dispatch = @import("dispatch.zig");
pub const actions = @import("actions.zig");

pub const MissionVM = vm.MissionVM;
pub const Row = vm.Row;
pub const Item = vm.Item;
pub const Group = vm.Group;
pub const ReviewCounts = vm.ReviewCounts;
pub const Filter = filter.Filter;
pub const parseFilter = filter.parseFilter;
pub const Dispatch = dispatch.Dispatch;
pub const parseDispatch = dispatch.parseDispatch;
pub const Action = actions.Action;
pub const StopGuard = actions.StopGuard;

test {
    _ = vm;
    _ = filter;
    _ = dispatch;
    _ = actions;
    _ = @import("vm_test.zig");
    _ = @import("filter_test.zig");
}
