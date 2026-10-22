//! Example views for `.zgui` scripts (E04.F01.S03.T01): what the script
//! tests and `zg ui-test` open by name.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const controls = @import("../widgets/controls.zig");
const tooltip = @import("../widgets/tooltip.zig");
const text_field = @import("../widgets/text_field/root.zig");
const dock = @import("../dock/root.zig");
const script = @import("script.zig");

const Ui = ui_mod.Ui;
const Allocator = std.mem.Allocator;

/// `Counter` (`start=N`), `Form` and `Dock` (`tabs=N`).
pub const views = [_]script.ViewEntry{ mount(Counter), mount(Form), mount(DockPage) };

fn argInt(args: []const script.Arg, key: []const u8, default: i64) !i64 {
    for (args) |a| if (std.mem.eql(u8, a.key, key)) return std.fmt.parseInt(i64, a.value, 10);
    return default;
}

/// Mounts a heap-allocated `T` (with `init(gpa, args)` and `deinit`).
pub fn mount(comptime T: type) script.ViewEntry {
    return .{ .name = T.view_name, .open = struct {
        fn open(_: ?*anyopaque, a: Allocator, args: []const script.Arg) anyerror!script.Mounted {
            const v = try a.create(T);
            errdefer a.destroy(v);
            try v.init(a, args);
            return .{ .view = .of(v), .ptr = v, .destroy = destroy };
        }
        fn destroy(p: *anyopaque, a: Allocator) void {
            const v: *T = @ptrCast(@alignCast(p));
            v.deinit();
            a.destroy(v);
        }
    }.open };
}

/// A count, an Increment button and an Enabled checkbox.
const Counter = struct {
    const view_name = "Counter";
    count: i64 = 0,
    enabled: bool = true,
    label: [32]u8 = undefined,

    fn init(c: *Counter, _: Allocator, args: []const script.Arg) !void {
        c.* = .{ .count = try argInt(args, "start", 0) };
    }
    fn deinit(_: *Counter) void {}

    pub fn build(c: *Counter, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 8, .padding = .all(8) } });
        defer ui.close();
        ui.text(std.fmt.bufPrint(&c.label, "Count: {d}", .{c.count}) catch "", .{});
        if (controls.button(ui, .{ .label = "Increment", .disabled = !c.enabled }).clicked) {
            c.count += 1;
            ui.window().markViewDirty(ui.currentView());
        }
        _ = controls.checkbox(ui, "Enabled", &c.enabled);
        _ = controls.button(ui, .{ .label = "Reset" });
    }
};

/// A name field and a Clear button with a tooltip.
const Form = struct {
    const view_name = "Form";
    buf: text_field.TextBuffer,

    fn init(f: *Form, a: Allocator, _: []const script.Arg) !void {
        f.* = .{ .buf = try .init(a, "") };
    }
    fn deinit(f: *Form) void {
        f.buf.deinit();
    }

    pub fn build(f: *Form, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 8, .padding = .all(8), .w = .{ .px = 320 } }, .test_id = "form" });
        defer ui.close();
        _ = text_field.textField(ui, .{ .buffer = &f.buf, .a11y_label = "Name", .placeholder = "Your name" });
        if (controls.button(ui, .{ .label = "Clear" }).clicked) {
            f.buf.replace(.{ 0, f.buf.len() }, "") catch {};
            ui.window().markViewDirty(ui.currentView());
        }
        tooltip.tooltipLast(ui, "Empties the field", .{});
    }
};

/// A dock with `tabs` editors in the center.
const DockPage = struct {
    const view_name = "Dock";
    const names = [_][]const u8{ "a.zig", "b.zig", "c.zig", "d.zig", "e.zig", "f.zig" };
    model: dock.DockModel,
    dv: dock.DockView,
    titles: std.AutoHashMapUnmanaged(dock.model.PanelRef, []const u8) = .empty,
    gpa: Allocator,

    fn init(d: *DockPage, a: Allocator, args: []const script.Arg) !void {
        d.* = .{ .model = try .init(a), .dv = undefined, .gpa = a };
        d.dv = .init(a, &d.model, .{ .ctx = d, .tab = tab, .build = content });
        const g = d.model.focused.?;
        const n: usize = @intCast(std.math.clamp(try argInt(args, "tabs", 2), 0, names.len));
        for (names[0..n]) |name| {
            const p = try d.model.addPanel(1, null);
            try d.titles.put(a, p, name);
            try d.model.openIn(p, g, null, .{});
        }
    }
    fn deinit(d: *DockPage) void {
        d.titles.deinit(d.gpa);
        d.dv.deinit();
        d.model.deinit();
    }

    fn tab(ctx: *anyopaque, p: dock.model.PanelRef) dock.view.TabInfo {
        const d: *DockPage = @ptrCast(@alignCast(ctx));
        return .{ .title = d.titles.get(p) orelse "?" };
    }
    fn content(ctx: *anyopaque, ui: *Ui, p: dock.model.PanelRef) void {
        const d: *DockPage = @ptrCast(@alignCast(ctx));
        ui.text(std.fmt.allocPrint(ui.arena(), "content {s}", .{d.titles.get(p) orelse "?"}) catch "", .{});
    }

    pub fn build(d: *DockPage, ui: *Ui) void {
        d.dv.beginFrame(ui);
        ui.open(.{ .style = .{ .dir = .row, .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .align_items = .stretch } });
        defer ui.close();
        d.dv.dockArea(ui, .center);
        d.dv.dropOverlay(ui);
    }
};
