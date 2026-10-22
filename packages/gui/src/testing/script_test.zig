//! `.zgui` scripts (E04.F01.S03.T01): every script in `scripts/` runs
//! against the example views below (snapshots compare with golden files
//! under `testdata/golden/scripts`), and the interpreter's own behavior:
//! parse errors with positions, query candidates, virtual time.

const std = @import("std");
const ui_mod = @import("../core/ui.zig");
const controls = @import("../widgets/controls.zig");
const tooltip = @import("../widgets/tooltip.zig");
const text_field = @import("../widgets/text_field/root.zig");
const dock = @import("../dock/root.zig");
const script = @import("script.zig");

const Ui = ui_mod.Ui;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const gpa = testing.allocator;

fn argInt(args: []const script.Arg, key: []const u8, default: i64) !i64 {
    for (args) |a| if (std.mem.eql(u8, a.key, key)) return std.fmt.parseInt(i64, a.value, 10);
    return default;
}

/// Mounts a heap-allocated `T` (with `init(gpa, args)` and `deinit`).
fn mount(comptime T: type) script.ViewEntry {
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

const views = [_]script.ViewEntry{ mount(Counter), mount(Form), mount(DockPage) };

fn golden(_: ?*anyopaque, kind: script.SnapshotKind, name: []const u8, text: []const u8) anyerror!void {
    var buf: [128]u8 = undefined;
    const file = try std.fmt.bufPrint(&buf, "{s}.{t}", .{ name, kind });
    try @import("zg_core").testkit.golden.expectGoldenOpts(testing.io, @src(), file, text, .{
        .root = @import("zg_options").package_root,
        .dir = "testdata/golden/scripts",
    });
}

fn runScript(src: []const u8) !void {
    var diag: script.Diag = .{};
    script.run(gpa, src, .{ .views = &views, .snapshot = .{ .f = golden } }, &diag) catch |e| {
        std.debug.print("script failed: {s}\n", .{diag.message()});
        return e;
    };
}

test "zgui scripts" {
    inline for (.{ "counter", "form", "tooltip", "dock" }) |name| {
        runScript(@embedFile("scripts/" ++ name ++ ".zgui")) catch |e| {
            std.debug.print("in scripts/{s}.zgui\n", .{name});
            return e;
        };
    }
}

test "click button example" {
    try runScript(
        \\open Counter
        \\click role=button name="Increment"
        \\expect role=text name="Count: 1"
    );
}

test "type and select-all delete" {
    try runScript(
        \\open Form
        \\click role=textbox
        \\type "hello"
        \\press ctrl+a
        \\press delete
        \\expect role=textbox text=""
    );
}

test "query not found lists candidates" {
    var diag: script.Diag = .{};
    try testing.expectError(error.ScriptFailed, script.run(gpa,
        \\open Counter
        \\click role=button name="Incremnet"
    , .{ .views = &views }, &diag));
    try testing.expectEqual(@as(u32, 2), diag.line);
    const msg = diag.message();
    try testing.expect(std.mem.indexOf(u8, msg, "nothing matches role=button name=\"Incremnet\"") != null);
    // The closest name comes first.
    try testing.expect(std.mem.indexOf(u8, msg, "closest: button \"Increment\"") != null);
}

test "script parse errors have positions" {
    const cases = [_]struct { src: []const u8, line: u32, col: u32, has: []const u8 }{
        .{ .src = "open Counter\nclik role=button", .line = 2, .col = 1, .has = "unknown command \"clik\"" },
        .{ .src = "open Counter\n\n  click role=buton", .line = 3, .col = 9, .has = "unknown role \"buton\"" },
        .{ .src = "type \"unterminated", .line = 1, .col = 6, .has = "unterminated string" },
        .{ .src = "press ctrl+nokey", .line = 1, .col = 7, .has = "unknown key chord" },
        .{ .src = "wait soon", .line = 1, .col = 6, .has = "expected a duration" },
        .{ .src = "expect role=button sideways", .line = 1, .col = 20, .has = "unknown expectation" },
        .{ .src = "click within(role=list", .line = 1, .col = 23, .has = "expected )" },
        .{ .src = "snapshot layout name", .line = 1, .col = 17, .has = "in quotes" },
        .{ .src = "ime \"ni\"", .line = 1, .col = 1, .has = "ime is not supported" },
    };
    for (cases) |c| {
        var diag: script.Diag = .{};
        try testing.expectError(error.ScriptSyntax, script.run(gpa, c.src, .{ .views = &views }, &diag));
        testing.expectEqual(c.line, diag.line) catch |e| {
            std.debug.print("{s}\n", .{diag.message()});
            return e;
        };
        testing.expectEqual(c.col, diag.col) catch |e| {
            std.debug.print("{s}\n", .{diag.message()});
            return e;
        };
        try testing.expect(std.mem.indexOf(u8, diag.message(), c.has) != null);
    }
}

test "virtual time tooltip after 500ms" {
    try runScript(
        \\open Form
        \\hover role=button name="Clear"
        \\wait 499ms
        \\expect role=tooltip absent
        \\wait 1ms
        \\expect role=tooltip
    );
}

test "failures stop at their line; commands need an open view" {
    var diag: script.Diag = .{};
    try testing.expectError(error.ScriptFailed, script.run(gpa, "click role=button", .{ .views = &views }, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message(), "no view is open") != null);
    try testing.expectError(error.ScriptFailed, script.run(gpa,
        \\open Counter
        \\expect role=button count=3
    , .{ .views = &views }, &diag));
    try testing.expectEqual(@as(u32, 2), diag.line);
    try testing.expect(std.mem.indexOf(u8, diag.message(), "expected 3 of role=button, found 2") != null);
    try testing.expectError(error.ScriptFailed, script.run(gpa, "open Nope", .{ .views = &views }, &diag));
}
