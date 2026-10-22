//! AT-SPI2 states (E04.F09.S01.T03): a node's `State` as the two u32
//! words of `GetState`, bit `ATSPI_STATE_*` (atspi-constants.h).

const snap = @import("../snapshot.zig");

const Node = snap.Node;

/// `AtspiStateType` values zigguro sets.
pub const atspi = struct {
    pub const active: u6 = 1;
    pub const checked: u6 = 4;
    pub const collapsed: u6 = 5;
    pub const defunct: u6 = 6;
    pub const editable: u6 = 7;
    pub const enabled: u6 = 8;
    pub const expandable: u6 = 9;
    pub const expanded: u6 = 10;
    pub const focusable: u6 = 11;
    pub const focused: u6 = 12;
    pub const modal: u6 = 16;
    pub const selectable: u6 = 22;
    pub const selected: u6 = 23;
    pub const sensitive: u6 = 24;
    pub const showing: u6 = 25;
    pub const single_line: u6 = 26;
    pub const visible: u6 = 30;
    pub const checkable: u6 = 41;
    pub const read_only: u6 = 43;
};

/// A state set as `GetState` returns it.
pub const Set = struct {
    words: [2]u32 = .{ 0, 0 },

    pub fn add(s: *Set, bit: u6) void {
        s.words[bit >> 5] |= @as(u32, 1) << @intCast(bit & 31);
    }

    pub fn has(s: Set, bit: u6) bool {
        return s.words[bit >> 5] & (@as(u32, 1) << @intCast(bit & 31)) != 0;
    }
};

/// The states of `n`. `active` marks the window node of the focused
/// window.
pub fn of(n: *const Node, active: bool) Set {
    const k = atspi;
    const st = n.state;
    var s: Set = .{};
    if (!st.disabled) {
        s.add(k.enabled);
        s.add(k.sensitive);
    }
    if (!st.offscreen) {
        s.add(k.visible);
        s.add(k.showing);
    }
    if (st.focusable) s.add(k.focusable);
    if (st.focused) s.add(k.focused);
    if (st.checkable) s.add(k.checkable);
    if (st.checked) s.add(k.checked);
    if (st.expandable) {
        s.add(k.expandable);
        s.add(if (st.expanded) k.expanded else k.collapsed);
    }
    if (st.selectable) s.add(k.selectable);
    if (st.selected) s.add(k.selected);
    if (st.modal) s.add(k.modal);
    if (st.editable) {
        s.add(k.editable);
        s.add(k.single_line);
    }
    if (n.role == .textbox and !st.editable) s.add(k.read_only);
    if (active) s.add(k.active);
    return s;
}
