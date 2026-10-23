//! The notes sidebar dock panel (E08.F06.S01.T04): backlinks, outgoing
//! links, tags and properties of the active note, each a labelled region.
//! `SidebarView` keeps the per-view state (tag tree, text buffers); the
//! data is `NotesSidebarModel`'s.

const std = @import("std");
const zg_gui = @import("zg_gui");
const model_mod = @import("sidebar_model.zig");
const ports = @import("ports.zig");
const backlinks_panel = @import("backlinks_panel.zig");
const outgoing_panel = @import("outgoing_panel.zig");
const tags_panel = @import("tags_panel.zig");
const properties_panel = @import("properties_panel.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const TreeView = zg_gui.virtual.TreeView;
const TextBuffer = zg_gui.w.text_field.TextBuffer;

pub const NotesSidebarModel = model_mod.NotesSidebarModel;

/// Called with a note search query (`tag:#x` from the tags pane).
pub const SearchHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, query: []const u8) void,
};

pub const Options = struct {
    open: ?ports.OpenPort = null,
    search: ?SearchHook = null,
};

pub const SidebarView = struct {
    gpa: Allocator,
    m: *NotesSidebarModel,
    o: Options,
    tags: TreeView,
    tags_version: u32 = 0,
    tag_filter: TextBuffer,
    show_unlinked: bool = false,
    /// Per-property edit buffers, reset when the note changes.
    bufs: std.StringArrayHashMapUnmanaged(*TextBuffer) = .empty,
    bufs_version: u32 = 0,
    /// The last failure, shown at the top.
    err: ?[]const u8 = null,

    pub fn init(gpa: Allocator, m: *NotesSidebarModel, o: Options) !*SidebarView {
        const v = try gpa.create(SidebarView);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa, .m = m, .o = o, .tags = undefined, .tag_filter = try .init(gpa, "") };
        v.tags = try TreeView.init(gpa, m.tagsSource(), .{ .label = "Tags", .test_id = "notes-tags", .on_open = .{ .ctx = v, .f = tags_panel.onOpen } });
        return v;
    }

    pub fn deinit(v: *SidebarView) void {
        v.tags.deinit();
        v.tag_filter.deinit();
        v.clearBufs();
        v.bufs.deinit(v.gpa);
        v.gpa.destroy(v);
    }

    pub fn clearBufs(v: *SidebarView) void {
        var it = v.bufs.iterator();
        while (it.next()) |e| {
            v.gpa.free(e.key_ptr.*);
            e.value_ptr.*.deinit();
            v.gpa.destroy(e.value_ptr.*);
        }
        v.bufs.clearRetainingCapacity();
    }

    /// The edit buffer for property `name`, created with `initial`.
    pub fn buffer(v: *SidebarView, name: []const u8, initial: []const u8) !*TextBuffer {
        if (v.bufs.get(name)) |b| return b;
        const b = try v.gpa.create(TextBuffer);
        errdefer v.gpa.destroy(b);
        b.* = try .init(v.gpa, initial);
        try v.bufs.put(v.gpa, try v.gpa.dupe(u8, name), b);
        return b;
    }

    pub fn fail(v: *SidebarView, e: anyerror) void {
        v.err = @errorName(e);
    }

    pub fn open(v: *SidebarView, path: []const u8, range: ?[2]u32) void {
        if (v.o.open) |p| p.open(p.ctx, path, range, false);
    }

    pub fn build(v: *SidebarView, ui: *Ui) void {
        notesSidebar(ui, v);
    }
};

/// The sidebar: four sections in a scrollable column.
pub fn notesSidebar(ui: *Ui, v: *SidebarView) void {
    v.m.sync() catch |e| v.fail(e);
    if (v.m.tags_version != v.tags_version) {
        v.tags_version = v.m.tags_version;
        v.tags.reload() catch |e| v.fail(e);
    }
    if (v.m.version != v.bufs_version) {
        v.bufs_version = v.m.version;
        v.clearBufs();
    }
    const th = ui.theme();
    _ = zg_gui.w.scroll.scrollArea(ui, .{ .style = .{ .grow = 1, .dir = .column, .gap = th.dim(.space_md), .padding = .all(th.dim(.space_sm)) }, .test_id = "notes-sidebar" });
    defer ui.close();
    if (v.err) |e| ui.textf("Error: {s}", .{e}, .{ .color = .danger });
    if (v.m.active == null) ui.text("No note is active.", .{ .color = .fg_muted });
    backlinks_panel.build(ui, v);
    outgoing_panel.build(ui, v);
    properties_panel.build(ui, v);
    tags_panel.build(ui, v);
}

/// A section: a labelled region with a heading.
pub fn section(ui: *Ui, label: []const u8) void {
    const th = ui.theme();
    ui.open(.{ .role = .group, .label = label, .style = .{ .dir = .column, .gap = th.dim(.space_xs) } });
    ui.text(label, .{ .style = .{ .weight = 700 } });
}

/// `text` with `hl` drawn as a link.
pub fn highlighted(ui: *Ui, text: []const u8, hl: [2]u32) void {
    const a = @min(hl[0], text.len);
    const b = @min(@max(hl[1], hl[0]), text.len);
    ui.open(.{ .style = .{ .dir = .row, .wrap = true } });
    defer ui.close();
    if (a > 0) ui.text(text[0..a], .{ .color = .fg_muted, .wrap = false });
    if (b > a) ui.text(text[a..b], .{ .color = .fg_link, .wrap = false });
    if (b < text.len) ui.text(text[b..], .{ .color = .fg_muted, .wrap = false });
}
