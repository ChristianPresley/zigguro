//! `PanelModel`: the terminal panel's tabs and split groups as plain data
//! (E06.F05.S04.T01), with no GUI and no PTYs, so it tests headless.
//!
//! The panel shows one tab per group; a group's terminals sit side by
//! side. A new terminal opens as a new group (tab) after the active one;
//! `split` adds one to the active group. Removing a terminal selects its
//! neighbour, and an emptied group goes away. Agent terminals (section
//! `agents`) list after the user's. Titles are the host's; the model keeps
//! only user renames.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const TerminalId = u32;

/// Which list a terminal shows in.
pub const Section = enum { user, agents };

pub const Group = struct {
    /// Stable across reorders (for UI keys).
    id: u32,
    terminals: std.ArrayList(TerminalId) = .empty,
    /// Index into `terminals` of the focused one.
    active: usize = 0,

    pub fn activeId(g: *const Group) TerminalId {
        return g.terminals.items[g.active];
    }
};

pub const Direction = enum { next, prev };

/// See the module doc.
pub const PanelModel = struct {
    gpa: Allocator,
    groups: std.ArrayList(Group) = .empty,
    /// Index into `groups` of the shown tab.
    active: usize = 0,
    next_group: u32 = 1,
    sections: std.AutoHashMapUnmanaged(TerminalId, Section) = .empty,
    names: std.AutoHashMapUnmanaged(TerminalId, []u8) = .empty,

    pub fn init(gpa: Allocator) PanelModel {
        return .{ .gpa = gpa };
    }

    pub fn deinit(m: *PanelModel) void {
        for (m.groups.items) |*g| g.terminals.deinit(m.gpa);
        m.groups.deinit(m.gpa);
        m.sections.deinit(m.gpa);
        var it = m.names.valueIterator();
        while (it.next()) |n| m.gpa.free(n.*);
        m.names.deinit(m.gpa);
    }

    /// How many terminals there are.
    pub fn count(m: *const PanelModel) usize {
        return m.sections.count();
    }

    /// The focused terminal, if any.
    pub fn activeId(m: *const PanelModel) ?TerminalId {
        if (m.groups.items.len == 0) return null;
        return m.groups.items[m.active].activeId();
    }

    /// The shown group, if any.
    pub fn activeGroup(m: *const PanelModel) ?*const Group {
        if (m.groups.items.len == 0) return null;
        return &m.groups.items[m.active];
    }

    pub fn sectionOf(m: *const PanelModel, id: TerminalId) ?Section {
        return m.sections.get(id);
    }

    /// The user's name for `id`, if renamed.
    pub fn nameOf(m: *const PanelModel, id: TerminalId) ?[]const u8 {
        return m.names.get(id);
    }

    /// The group index and position of `id`.
    pub fn find(m: *const PanelModel, id: TerminalId) ?struct { group: usize, index: usize } {
        for (m.groups.items, 0..) |g, gi| {
            for (g.terminals.items, 0..) |t, ti| if (t == id) return .{ .group = gi, .index = ti };
        }
        return null;
    }

    /// Adds `id` as a new tab, focused: after the active tab in its
    /// section (user tabs stay before agent tabs).
    pub fn add(m: *PanelModel, id: TerminalId, section: Section) !void {
        std.debug.assert(m.find(id) == null);
        try m.sections.put(m.gpa, id, section);
        errdefer _ = m.sections.remove(id);
        var g: Group = .{ .id = m.next_group };
        try g.terminals.append(m.gpa, id);
        errdefer g.terminals.deinit(m.gpa);
        const at = m.insertAt(section);
        try m.groups.insert(m.gpa, at, g);
        m.next_group += 1;
        m.active = at;
    }

    fn insertAt(m: *const PanelModel, section: Section) usize {
        const n = m.groups.items.len;
        if (n == 0) return 0;
        const first_agent = for (m.groups.items, 0..) |g, i| {
            if (m.sections.get(g.terminals.items[0]) == .agents) break i;
        } else n;
        return switch (section) {
            .user => if (m.active < first_agent) m.active + 1 else first_agent,
            .agents => if (m.active >= first_agent) m.active + 1 else n,
        };
    }

    /// Adds `new_id` to `id`'s group, right after it, focused.
    pub fn split(m: *PanelModel, id: TerminalId, new_id: TerminalId) !void {
        const at = m.find(id) orelse return error.NoSuchTerminal;
        std.debug.assert(m.find(new_id) == null);
        try m.sections.put(m.gpa, new_id, m.sections.get(id).?);
        errdefer _ = m.sections.remove(new_id);
        const g = &m.groups.items[at.group];
        try g.terminals.insert(m.gpa, at.index + 1, new_id);
        g.active = at.index + 1;
        m.active = at.group;
    }

    /// Forgets `id`; its neighbour (in its group, else the next tab, else
    /// the previous one) becomes active.
    pub fn remove(m: *PanelModel, id: TerminalId) void {
        const at = m.find(id) orelse return;
        _ = m.sections.remove(id);
        if (m.names.fetchRemove(id)) |kv| m.gpa.free(kv.value);
        const g = &m.groups.items[at.group];
        _ = g.terminals.orderedRemove(at.index);
        if (g.terminals.items.len > 0) {
            if (g.active > at.index or g.active == g.terminals.items.len) g.active -|= 1;
            return;
        }
        g.terminals.deinit(m.gpa);
        _ = m.groups.orderedRemove(at.group);
        if (m.groups.items.len == 0) {
            m.active = 0;
        } else if (m.active > at.group or m.active == m.groups.items.len) {
            m.active -= 1;
        }
    }

    /// Focuses `id` (and shows its tab).
    pub fn select(m: *PanelModel, id: TerminalId) void {
        const at = m.find(id) orelse return;
        m.active = at.group;
        m.groups.items[at.group].active = at.index;
    }

    /// Focuses the next or previous terminal in tab order, wrapping; the
    /// one now focused.
    pub fn focusNext(m: *PanelModel, dir: Direction) ?TerminalId {
        if (m.groups.items.len == 0) return null;
        var gi = m.active;
        var ti = m.groups.items[gi].active;
        switch (dir) {
            .next => {
                ti += 1;
                if (ti == m.groups.items[gi].terminals.items.len) {
                    gi = (gi + 1) % m.groups.items.len;
                    ti = 0;
                }
            },
            .prev => if (ti > 0) {
                ti -= 1;
            } else {
                gi = (gi + m.groups.items.len - 1) % m.groups.items.len;
                ti = m.groups.items[gi].terminals.items.len - 1;
            },
        }
        m.active = gi;
        m.groups.items[gi].active = ti;
        return m.groups.items[gi].activeId();
    }

    /// Moves tab `from` to index `to` (within its section).
    pub fn moveTab(m: *PanelModel, from: usize, to: usize) void {
        if (from >= m.groups.items.len or to >= m.groups.items.len or from == to) return;
        const sec = m.sections.get(m.groups.items[from].terminals.items[0]);
        if (m.sections.get(m.groups.items[to].terminals.items[0]) != sec) return;
        const g = m.groups.orderedRemove(from);
        m.groups.insertAssumeCapacity(to, g);
        if (m.active == from) {
            m.active = to;
        } else if (from < m.active and to >= m.active) {
            m.active -= 1;
        } else if (from > m.active and to <= m.active) {
            m.active += 1;
        }
    }

    /// Gives `id` a name (empty clears it).
    pub fn rename(m: *PanelModel, id: TerminalId, name: []const u8) !void {
        if (m.sections.get(id) == null) return error.NoSuchTerminal;
        if (m.names.fetchRemove(id)) |kv| m.gpa.free(kv.value);
        if (name.len > 0) {
            const copy = try m.gpa.dupe(u8, name);
            errdefer m.gpa.free(copy);
            try m.names.put(m.gpa, id, copy);
        }
    }

    /// `id` changes hands (an agent's terminal taken over by the user):
    /// its group moves to the end of its new section.
    pub fn setSection(m: *PanelModel, id: TerminalId, section: Section) void {
        const at = m.find(id) orelse return;
        const g = &m.groups.items[at.group];
        for (g.terminals.items) |t| m.sections.putAssumeCapacity(t, section);
        const was_active = m.active == at.group;
        const group = m.groups.orderedRemove(at.group);
        if (m.active > at.group) m.active -= 1;
        const end = for (m.groups.items, 0..) |x, i| {
            if (m.sections.get(x.terminals.items[0]) == .agents) break i;
        } else m.groups.items.len;
        const to = if (section == .user) end else m.groups.items.len;
        m.groups.insertAssumeCapacity(to, group);
        if (was_active) {
            m.active = to;
        } else if (m.active >= to and m.groups.items.len > 1) {
            m.active += 1;
        }
    }
};

const testing = std.testing;

fn order(m: *const PanelModel, buf: []TerminalId) []TerminalId {
    var n: usize = 0;
    for (m.groups.items) |g| for (g.terminals.items) |t| {
        buf[n] = t;
        n += 1;
    };
    return buf[0..n];
}

test "panel model: new terminals open as tabs after the active one, agents last" {
    var m: PanelModel = .init(testing.allocator);
    defer m.deinit();
    try testing.expect(m.activeId() == null);
    try m.add(1, .user);
    try m.add(2, .agents);
    try m.add(3, .user);
    var buf: [8]TerminalId = undefined;
    try testing.expectEqualSlices(TerminalId, &.{ 1, 3, 2 }, order(&m, &buf));
    try testing.expectEqual(@as(?TerminalId, 3), m.activeId());
    m.select(1);
    try m.add(4, .user);
    try testing.expectEqualSlices(TerminalId, &.{ 1, 4, 3, 2 }, order(&m, &buf));
    try testing.expectEqual(Section.agents, m.sectionOf(2).?);
    try testing.expectEqual(@as(usize, 4), m.count());
}

test "panel model: split, focusNext and remove selecting the neighbour" {
    var m: PanelModel = .init(testing.allocator);
    defer m.deinit();
    try m.add(1, .user);
    try m.add(2, .user);
    try m.split(2, 3);
    try testing.expectEqual(@as(usize, 2), m.groups.items.len);
    try testing.expectEqualSlices(TerminalId, &.{ 2, 3 }, m.activeGroup().?.terminals.items);
    try testing.expectEqual(@as(?TerminalId, 3), m.activeId());
    try testing.expectEqual(@as(?TerminalId, 1), m.focusNext(.next));
    try testing.expectEqual(@as(?TerminalId, 3), m.focusNext(.prev));
    try testing.expectEqual(@as(?TerminalId, 2), m.focusNext(.prev));
    try testing.expectError(error.NoSuchTerminal, m.split(9, 10));

    // In a group, the neighbour; an emptied group goes, the previous tab
    // shows.
    m.remove(2);
    try testing.expectEqual(@as(?TerminalId, 3), m.activeId());
    m.remove(3);
    try testing.expectEqual(@as(usize, 1), m.groups.items.len);
    try testing.expectEqual(@as(?TerminalId, 1), m.activeId());
    m.remove(1);
    try testing.expect(m.activeId() == null);
    m.remove(1);
}

test "panel model: removing a tab before the active one keeps the focus" {
    var m: PanelModel = .init(testing.allocator);
    defer m.deinit();
    try m.add(1, .user);
    try m.add(2, .user);
    try m.add(3, .user);
    m.remove(1);
    try testing.expectEqual(@as(?TerminalId, 3), m.activeId());
    m.select(2);
    m.remove(3);
    try testing.expectEqual(@as(?TerminalId, 2), m.activeId());
}

test "panel model: rename, reorder and take-over" {
    var m: PanelModel = .init(testing.allocator);
    defer m.deinit();
    try m.add(1, .user);
    try m.add(2, .user);
    try m.add(3, .agents);
    try m.rename(1, "build");
    try testing.expectEqualStrings("build", m.nameOf(1).?);
    try m.rename(1, "");
    try testing.expect(m.nameOf(1) == null);
    try testing.expectError(error.NoSuchTerminal, m.rename(9, "x"));

    var buf: [8]TerminalId = undefined;
    m.moveTab(0, 1);
    try testing.expectEqualSlices(TerminalId, &.{ 2, 1, 3 }, order(&m, &buf));
    // Not across sections.
    m.moveTab(0, 2);
    try testing.expectEqualSlices(TerminalId, &.{ 2, 1, 3 }, order(&m, &buf));
    try testing.expectEqual(@as(?TerminalId, 3), m.activeId());

    // The user takes over the agent's terminal: it joins the user tabs.
    try m.add(4, .agents);
    m.setSection(3, .user);
    try testing.expectEqualSlices(TerminalId, &.{ 2, 1, 3, 4 }, order(&m, &buf));
    try testing.expectEqual(Section.user, m.sectionOf(3).?);
    try testing.expectEqual(@as(?TerminalId, 4), m.activeId());
}
