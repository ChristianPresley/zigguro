//! Document mode's workbench layout (E13.F04.S01.T02): the outline on the
//! left (240 px), the document in the middle in a writing column (72
//! characters by default, soft wrap, no line numbers, live preview), the
//! agent pane on the right (420 px), the bottom panel hidden. Leaving puts
//! back the layout as it was, from a snapshot taken on entry.

const std = @import("std");
const zg_gui = @import("zg_gui");

const Allocator = std.mem.Allocator;
const dock = zg_gui.dock;
const DockModel = dock.DockModel;
const PanelRef = dock.model.PanelRef;
const PanelKindId = dock.model.PanelKindId;
const Area = dock.model.Area;

/// The app's panel kinds for the three panes.
pub const Kinds = struct { editor: PanelKindId, outline: PanelKindId, agent: PanelKindId };

/// Settings `agents.docs.*`.
pub const Settings = struct {
    /// The writing column's width, in characters.
    measure: u16 = 72,
    outline_w: f32 = 240,
    agent_w: f32 = 420,
    typewriter: bool = false,
};

/// The editor panel's state in document mode (JSON in the panel).
pub const EditorState = struct {
    path: []const u8,
    mode: []const u8 = "document",
    measure: u16,
    soft_wrap: bool = true,
    line_numbers: bool = false,
    live_preview: bool = true,
    typewriter: bool,
};

pub const DocumentMode = struct {
    gpa: Allocator,
    dock: *DockModel,
    kinds: Kinds,
    settings: Settings = .{},
    saved: ?dock.model.Snapshot = null,
    panels: [3]?PanelRef = @splat(null),
    path: ?[]u8 = null,

    pub fn init(gpa: Allocator, d: *DockModel, kinds: Kinds, settings: Settings) DocumentMode {
        return .{ .gpa = gpa, .dock = d, .kinds = kinds, .settings = settings };
    }

    pub fn deinit(m: *DocumentMode) void {
        if (m.saved) |*s| s.deinit();
        if (m.path) |p| m.gpa.free(p);
        m.* = undefined;
    }

    pub fn active(m: *const DocumentMode) bool {
        return m.saved != null;
    }

    /// Opens `path` in document mode (palette `docs.open`). In document
    /// mode already, switches documents and keeps the saved layout.
    pub fn enter(m: *DocumentMode, path: []const u8) !void {
        const state = try std.json.Stringify.valueAlloc(m.gpa, EditorState{ .path = path, .measure = m.settings.measure, .typewriter = m.settings.typewriter }, .{});
        defer m.gpa.free(state);
        if (m.active()) {
            if (m.panels[0]) |p| if (m.dock.panels.getPtr(p)) |panel| {
                if (panel.state) |old| m.gpa.free(old);
                panel.state = try m.gpa.dupe(u8, state);
            };
            try m.setPath(path);
            m.dock.revision +%= 1;
            return;
        }
        m.saved = try m.dock.snapshot(m.gpa);
        errdefer {
            m.saved.?.deinit();
            m.saved = null;
        }
        const editor = try m.dock.addPanel(m.kinds.editor, state);
        const outline = try m.dock.addPanel(m.kinds.outline, null);
        const agent = try m.dock.addPanel(m.kinds.agent, null);
        m.panels = .{ editor, outline, agent };
        try m.dock.move(editor, .{ .area = .center });
        try m.dock.move(outline, .{ .area = .left });
        try m.dock.move(agent, .{ .area = .agent });
        m.dock.areas[@intFromEnum(Area.left)].size = m.settings.outline_w;
        m.dock.areas[@intFromEnum(Area.agent)].size = m.settings.agent_w;
        m.dock.areaVisible(.left, true);
        m.dock.areaVisible(.agent, true);
        m.dock.areaVisible(.bottom, false);
        m.dock.areaVisible(.right, false);
        if (m.dock.groupOf(editor)) |g| m.dock.focused = g;
        try m.setPath(path);
    }

    /// Leaves document mode: the panes close and the layout is as before.
    pub fn exit(m: *DocumentMode) !void {
        var saved = m.saved orelse return;
        for (&m.panels) |*p| if (p.*) |x| {
            try m.dock.close(x);
            p.* = null;
        };
        try m.dock.restore(&saved);
        saved.deinit();
        m.saved = null;
        if (m.path) |p| m.gpa.free(p);
        m.path = null;
    }

    fn setPath(m: *DocumentMode, path: []const u8) !void {
        const p = try m.gpa.dupe(u8, path);
        if (m.path) |old| m.gpa.free(old);
        m.path = p;
    }
};

/// Words, reading time (238 words a minute) and the current section's
/// words, for the status bar.
pub fn statusText(a: Allocator, total_words: u32, section_words: ?u32) Allocator.Error![]const u8 {
    const minutes = (total_words + 237) / 238;
    if (section_words) |sw| return std.fmt.allocPrint(a, "{d} words · {d} min read · section {d}", .{ total_words, minutes, sw });
    return std.fmt.allocPrint(a, "{d} words · {d} min read", .{ total_words, minutes });
}
