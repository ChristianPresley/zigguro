//! Document mode's version timeline (E13.F04.S02.T01): checkpoints of
//! accepted agent changes, snapshots and save points, newest first. A
//! version compares with the working copy or with another version
//! ("Compare with…", then click the second) in the app's diff view, or
//! restores as a reviewed change.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const versions = zg_agents.docs.versions;
const Version = versions.Version;

pub const Ports = struct {
    /// Opens the diff view: `from` (null: the working copy) against `to`.
    compare: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, from: ?Version, to: Version) void },
    restore: struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, v: Version) void },
    /// Marks a save point now (`docs.markVersion`).
    mark: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque) void } = null,
};

pub const VersionsView = struct {
    ports: Ports,
    /// Newest first (owned by the caller, from `versions.listVersions`).
    items: []const Version = &.{},
    selected: ?usize = null,
    /// A second version, for comparing two.
    other: ?usize = null,
    /// The next click picks `other`.
    picking: bool = false,

    pub fn init(ports: Ports) VersionsView {
        return .{ .ports = ports };
    }

    pub fn setVersions(v: *VersionsView, items: []const Version) void {
        v.items = items;
        if (v.selected) |s| if (s >= items.len) {
            v.selected = null;
        };
        v.other = null;
    }

    pub fn click(v: *VersionsView, i: usize) void {
        if (v.picking and v.selected != null and v.selected.? != i) {
            v.other = i;
            v.picking = false;
        } else {
            v.picking = false;
            v.selected = i;
            v.other = null;
        }
    }

    pub fn compareSelected(v: *VersionsView) void {
        const s = v.selected orelse return;
        const from: ?Version = if (v.other) |o| v.items[o] else null;
        v.ports.compare.f(v.ports.compare.ctx, from, v.items[s]);
    }

    pub fn restoreSelected(v: *VersionsView) void {
        const s = v.selected orelse return;
        v.ports.restore.f(v.ports.restore.ctx, v.items[s]);
    }

    pub fn build(v: *VersionsView, ui: *Ui) void {
        ui.open(.{ .role = .group, .label = "Versions", .test_id = "doc-versions", .style = .{ .dir = .column, .gap = 4, .padding = .all(6), .grow = 1 } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center } });
        ui.text("Versions", .{ .wrap = false, .style = .{ .weight = 700 } });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (v.ports.mark) |m| if (controls.button(ui, .{ .label = "Mark version", .variant = .ghost }).clicked) m.f(m.ctx);
        ui.close();
        if (v.items.len == 0) {
            ui.text("No versions yet. Accepted agent changes, snapshots and marked versions show here.", .{ .color = .fg_muted });
            return;
        }
        if (v.selected != null) {
            ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
            if (controls.button(ui, .{ .label = if (v.other != null) "Compare these two" else "Compare with current" }).clicked) v.compareSelected();
            if (controls.button(ui, .{ .label = if (v.picking) "Pick a version…" else "Compare with…", .variant = .ghost }).clicked) v.picking = !v.picking;
            if (controls.button(ui, .{ .label = "Restore", .variant = .ghost }).clicked) v.restoreSelected();
            ui.close();
        }
        for (v.items, 0..) |ver, i| v.row(ui, ver, i);
    }

    fn row(v: *VersionsView, ui: *Ui, ver: Version, i: usize) void {
        var tbuf: [32]u8 = undefined;
        const when = fmtTime(&tbuf, ver.at_ms);
        const who = switch (ver.author) {
            .user => |u| if (u.len > 0) u else "you",
            .agent => "agent",
        };
        const label = std.fmt.allocPrint(ui.arena(), "{s}, {s}, {s}, {s}, {d} words", .{ ver.label, sourceName(ver.source), when, who, ver.words }) catch ver.label;
        const sel = v.selected != null and v.selected.? == i;
        const other = v.other != null and v.other.? == i;
        ui.id(@as(u64, i) + 1);
        ui.open(.{ .role = .listitem, .label = label, .hit = true, .style = .{
            .dir = .column,
            .padding = .xy(6, 3),
            .bg = if (sel or other) .{ .token = .selection_bg } else .none,
        } });
        defer ui.close();
        const resp = ui.response();
        if (resp.clicked) v.click(i);
        ui.text(ver.label, .{ .wrap = false, .style = .{ .weight = 600 } });
        ui.textf("{s} · {s} · {s} · {d} words", .{ sourceName(ver.source), when, who, ver.words }, .{ .color = .fg_muted, .wrap = false });
    }
};

pub fn sourceName(s: versions.SourceKind) []const u8 {
    return switch (s) {
        .checkpoint => "agent change",
        .scm_snapshot => "snapshot",
        .save => "marked",
    };
}

/// `YYYY-MM-DD HH:MM` (UTC).
pub fn fmtTime(buf: *[32]u8, ms: i64) []const u8 {
    const secs: u64 = @intCast(@max(0, @divFloor(ms, 1000)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
}
