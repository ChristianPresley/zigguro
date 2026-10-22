//! AT-SPI2 roles (E04.F09.S01.T03): zg_gui roles to `ATSPI_ROLE_*`
//! numbers (atspi-constants.h) and the interfaces each node serves.

const std = @import("std");
const widget = @import("../../core/widget.zig");
const snap = @import("../snapshot.zig");

const Node = snap.Node;

/// `AtspiRole` values zigguro uses.
pub const atspi = struct {
    pub const invalid: u32 = 0;
    pub const check_box: u32 = 7;
    pub const column_header: u32 = 10;
    pub const dialog: u32 = 16;
    pub const frame: u32 = 23;
    pub const image: u32 = 27;
    pub const label: u32 = 29;
    pub const list: u32 = 31;
    pub const list_item: u32 = 32;
    pub const menu: u32 = 33;
    pub const menu_bar: u32 = 34;
    pub const menu_item: u32 = 35;
    pub const page_tab: u32 = 37;
    pub const page_tab_list: u32 = 38;
    pub const panel: u32 = 39;
    pub const progress_bar: u32 = 42;
    pub const push_button: u32 = 43;
    pub const radio_button: u32 = 44;
    pub const separator: u32 = 50;
    pub const slider: u32 = 51;
    pub const status_bar: u32 = 54;
    pub const table: u32 = 55;
    pub const table_cell: u32 = 56;
    pub const toggle_button: u32 = 62;
    pub const tool_bar: u32 = 63;
    pub const tool_tip: u32 = 64;
    pub const tree: u32 = 65;
    pub const application: u32 = 75;
    pub const entry: u32 = 79;
    pub const link: u32 = 88;
    pub const table_row: u32 = 90;
    pub const tree_item: u32 = 91;
};

/// The AT-SPI role of a zg_gui role.
pub fn of(r: widget.Role) u32 {
    const k = atspi;
    return switch (r) {
        .none, .group, .tabpanel => k.panel,
        .text => k.label,
        .button => k.push_button,
        .link => k.link,
        .checkbox => k.check_box,
        .switch_ => k.toggle_button,
        .radio => k.radio_button,
        .slider => k.slider,
        .progressbar => k.progress_bar,
        .textbox => k.entry,
        .separator => k.separator,
        .status => k.status_bar,
        .list => k.list,
        .listitem => k.list_item,
        .tree => k.tree,
        .treeitem => k.tree_item,
        .tab => k.page_tab,
        .tablist => k.page_tab_list,
        .menu => k.menu,
        .menuitem => k.menu_item,
        .menubar => k.menu_bar,
        .dialog => k.dialog,
        .tooltip => k.tool_tip,
        .toolbar => k.tool_bar,
        .img => k.image,
        .window => k.frame,
        .grid => k.table,
        .row => k.table_row,
        .gridcell => k.table_cell,
        .columnheader => k.column_header,
    };
}

/// The role's name as `GetRoleName` reports it (the atspi role nicks).
pub fn name(role: u32) []const u8 {
    const k = atspi;
    return switch (role) {
        k.check_box => "check box",
        k.column_header => "column header",
        k.dialog => "dialog",
        k.frame => "frame",
        k.image => "image",
        k.label => "label",
        k.list => "list",
        k.list_item => "list item",
        k.menu => "menu",
        k.menu_bar => "menu bar",
        k.menu_item => "menu item",
        k.page_tab => "page tab",
        k.page_tab_list => "page tab list",
        k.panel => "panel",
        k.progress_bar => "progress bar",
        k.push_button => "push button",
        k.radio_button => "radio button",
        k.separator => "separator",
        k.slider => "slider",
        k.status_bar => "status bar",
        k.table => "table",
        k.table_cell => "table cell",
        k.toggle_button => "toggle button",
        k.tool_bar => "tool bar",
        k.tool_tip => "tool tip",
        k.tree => "tree",
        k.application => "application",
        k.entry => "entry",
        k.link => "link",
        k.table_row => "table row",
        k.tree_item => "tree item",
        else => "unknown",
    };
}

/// AT-SPI interfaces a node serves.
pub const Ifaces = packed struct(u8) {
    accessible: bool = true,
    application: bool = false,
    component: bool = false,
    action: bool = false,
    value: bool = false,
    text: bool = false,
    selection: bool = false,
    _pad: u1 = 0,

    pub const names = [_][]const u8{
        "org.a11y.atspi.Accessible",
        "org.a11y.atspi.Application",
        "org.a11y.atspi.Component",
        "org.a11y.atspi.Action",
        "org.a11y.atspi.Value",
        "org.a11y.atspi.Text",
        "org.a11y.atspi.Selection",
    };

    /// Whether the interface named `iface` is served.
    pub fn has(s: Ifaces, iface: []const u8) bool {
        const bits: u8 = @bitCast(s);
        for (names, 0..) |n, i| if (bits & (@as(u8, 1) << @intCast(i)) != 0 and std.mem.eql(u8, n, iface)) return true;
        return false;
    }

    /// The served interface names, in `names` order.
    pub fn list(s: Ifaces, out: *[names.len][]const u8) []const []const u8 {
        const bits: u8 = @bitCast(s);
        var n: usize = 0;
        for (names, 0..) |x, i| if (bits & (@as(u8, 1) << @intCast(i)) != 0) {
            out[n] = x;
            n += 1;
        };
        return out[0..n];
    }
};

/// The application root's interfaces.
pub const application_ifaces: Ifaces = .{ .application = true };

/// The interfaces of `n`.
pub fn ifacesOf(n: *const Node) Ifaces {
    return .{
        .component = true,
        .action = actionCount(n) > 0,
        .value = n.role == .slider or n.role == .progressbar,
        .text = n.role == .textbox,
        .selection = switch (n.role) {
            .list, .tree, .tablist, .grid, .menu => true,
            else => false,
        },
    };
}

/// One `Action` entry.
pub const Action = struct { name: []const u8, does: widget.A11yAction };

/// The actions of `n`, in `Action` index order.
pub fn actions(n: *const Node, out: *[4]Action) []const Action {
    var k: usize = 0;
    const st = n.state;
    const clickable = switch (n.role) {
        .button, .link, .tab, .listitem, .treeitem, .row, .gridcell, .columnheader => true,
        .menuitem => !st.checkable and !st.expandable,
        else => false,
    };
    if (clickable) {
        out[k] = .{ .name = "click", .does = .invoke };
        k += 1;
    }
    if (st.checkable) {
        out[k] = .{ .name = "toggle", .does = .toggle };
        k += 1;
    }
    if (st.expandable) {
        out[k] = .{ .name = "expand or contract", .does = if (st.expanded) .collapse else .expand };
        k += 1;
    }
    if (st.selectable and !clickable) {
        out[k] = .{ .name = "select", .does = .select };
        k += 1;
    }
    return out[0..k];
}

/// How many actions `n` has.
pub fn actionCount(n: *const Node) usize {
    var buf: [4]Action = undefined;
    return actions(n, &buf).len;
}
