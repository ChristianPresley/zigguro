//! The Run and Debug panel (E07.F07.S01.T01, .T03): the debug toolbar,
//! the configuration row, then the Variables, Watch, Call Stack,
//! Loaded Scripts and Modules (while debugging) and Breakpoints views, over the debug
//! service. The console is a panel of its own.
//!
//! The trees are rebuilt only when the service's `generation` changed,
//! so a stop paints in the frame after the models applied it. UI thread
//! only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_dap = @import("zg_dap");
const service = @import("service.zig");
const toolbar = @import("toolbar.zig");
const call_stack = @import("call_stack.zig");
const var_tree = @import("var_tree.zig");
const bp_view = @import("bp_view.zig");
const sources_view = @import("sources_view.zig");
const modules_view = @import("modules_view.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const Debug = service.Debug;
const CallStack = call_stack.CallStack;
const VarTree = var_tree.VarTree;
const BpView = bp_view.BpView;
const SourcesView = sources_view.SourcesView;
const ModulesView = modules_view.ModulesView;

pub const DebugPanel = struct {
    gpa: Allocator,
    d: *Debug,
    stack: CallStack = undefined,
    vars: VarTree = undefined,
    watch: VarTree = undefined,
    bpv: BpView = undefined,
    srcs: SourcesView = undefined,
    mods: ModulesView = undefined,
    /// The service generation the tree was built from.
    seen: u64 = 0,
    snap_arena: std.heap.ArenaAllocator,

    /// `p` must not move afterwards.
    pub fn init(p: *DebugPanel, gpa: Allocator, d: *Debug) !void {
        p.* = .{ .gpa = gpa, .d = d, .snap_arena = .init(gpa) };
        try p.stack.init(gpa, d.stackHooks());
        errdefer p.stack.deinit();
        try p.vars.init(gpa, .variables, d.varHooks());
        errdefer p.vars.deinit();
        try p.watch.init(gpa, .watch, d.varHooks());
        errdefer p.watch.deinit();
        try p.bpv.init(gpa, d.bpHooks());
        errdefer p.bpv.deinit();
        try p.srcs.init(gpa, d.sourcesHooks());
        errdefer p.srcs.deinit();
        try p.mods.init(gpa);
        p.seen = 0;
        _ = p.refresh();
    }

    pub fn deinit(p: *DebugPanel) void {
        p.mods.deinit();
        p.srcs.deinit();
        p.bpv.deinit();
        p.watch.deinit();
        p.vars.deinit();
        p.stack.deinit();
        p.snap_arena.deinit();
    }

    /// Follows the service; true when the tree changed.
    pub fn refresh(p: *DebugPanel) bool {
        if (p.d.generation == p.seen) return false;
        p.seen = p.d.generation;
        _ = p.snap_arena.reset(.retain_capacity);
        const snap = p.d.snapshot(p.snap_arena.allocator()) catch return true;
        p.stack.update(snap, p.d.selectedFrame()) catch {};
        p.vars.update(p.d.viewInspector()) catch {};
        p.watch.update(p.d.viewInspector()) catch {};
        if (p.d.bpSnapshot(p.snap_arena.allocator())) |bs| p.bpv.update(bs) catch {} else |_| {}
        if (p.d.sourcesSnapshot(p.snap_arena.allocator())) |ss| p.srcs.update(ss) catch {} else |_| {}
        if (p.d.modulesSnapshot(p.snap_arena.allocator())) |ms| p.mods.update(ms) catch {} else |_| {}
        if (p.d.reveal_req) |id| {
            if (p.d.entryById(id) == null) {
                p.d.reveal_req = null;
            } else if (p.d.revealThread(id)) |t| if (p.stack.reveal(id, t)) {
                p.d.reveal_req = null;
            };
        }
        return true;
    }

    /// Focuses the call stack.
    pub fn focus(p: *DebugPanel, w: *Window) void {
        p.stack.focus(w);
    }

    pub const View = enum { variables, watch, call_stack, loaded_scripts, modules, breakpoints };

    /// Edits breakpoint `id`'s `field` in the Breakpoints view (just made:
    /// the rows are read again first).
    pub fn editBreakpoint(p: *DebugPanel, id: zg_dap.breakpoints.BreakpointManager.BpId, field: bp_view.Field) bool {
        p.seen = 0;
        _ = p.refresh();
        const row = p.bpv.rowId(id);
        if (p.bpv.tv.flat.rowOf(row)) |r| {
            p.bpv.tv.moveTo(r, .replace);
            p.bpv.tv.reveal(r);
        }
        return p.bpv.startEditField(row, field);
    }

    /// Focuses one of the views.
    pub fn focusView(p: *DebugPanel, w: *Window, v: View) void {
        switch (v) {
            .variables => p.vars.focus(w),
            .watch => p.watch.focus(w),
            .call_stack => p.stack.focus(w),
            .loaded_scripts => p.srcs.focus(w),
            .modules => p.mods.focus(w),
            .breakpoints => p.bpv.focus(w),
        }
    }

    /// The call stack's text for the thread of the active row, else the
    /// selected frame's thread.
    pub fn copyCallStack(p: *DebugPanel, a: Allocator) !?[]u8 {
        if (p.stack.activeThread()) |t| return try p.stack.copyText(a, t.session, t.thread);
        const sel = p.d.selectedFrame() orelse return null;
        return try p.stack.copyText(a, sel.session, sel.thread);
    }

    pub fn build(p: *DebugPanel, ui: *Ui) void {
        p.d.win = ui.window();
        _ = p.refresh();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .bg = .{ .token = .bg_elevated } }, .role = .group, .label = "Run and Debug", .key_context = "debugViewFocus" });
        defer ui.close();
        p.toolbarRow(ui);
        p.configRow(ui);
        const debugging = p.d.sessionCount() > 0;
        heading(ui, "VARIABLES");
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "variablesFocus" });
        if (debugging) p.vars.build(ui) else hint(ui, "Not debugging. Pick a configuration and press F5 (Start Debugging); F9 or a click left of the line numbers sets a breakpoint.");
        ui.close();
        heading(ui, "WATCH");
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "watchExpressionsFocus" });
        p.watch.build(ui);
        ui.close();
        heading(ui, "CALL STACK");
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "callStackFocus" });
        if (debugging) p.stack.build(ui);
        ui.close();
        if (debugging) {
            heading(ui, "LOADED SCRIPTS");
            ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "loadedScriptsFocus" });
            if (p.srcs.isEmpty()) hint(ui, "No loaded scripts yet.") else p.srcs.build(ui);
            ui.close();
            heading(ui, "MODULES");
            ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "modulesFocus" });
            if (p.mods.isEmpty()) hint(ui, "No modules yet.") else p.mods.build(ui);
            ui.close();
        }
        p.breakpointsHeading(ui);
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "breakpointsFocus" });
        p.bpv.build(ui);
        ui.close();
    }

    fn breakpointsHeading(p: *DebugPanel, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center, .padding = .xy(10, 0), .shrink = 0 }, .role = .toolbar, .label = "Breakpoints actions" });
        defer ui.close();
        ui.text("BREAKPOINTS", .{ .color = .fg_muted, .wrap = false });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (zg_gui.w.button(ui, .{ .label = "Add Function", .variant = .ghost }).clicked) p.bpv.startAddFunction();
        if (zg_gui.w.button(ui, .{ .label = "Toggle All", .variant = .ghost }).clicked) p.d.toggleAllBreakpointsCmd();
        if (zg_gui.w.button(ui, .{ .label = "Remove All", .variant = .ghost }).clicked) p.d.removeAllBreakpointsCmd();
    }

    fn heading(ui: *Ui, text: []const u8) void {
        ui.open(.{ .style = .{ .padding = .xy(10, 2), .shrink = 0 } });
        ui.text(text, .{ .color = .fg_muted, .wrap = false });
        ui.close();
    }

    fn hint(ui: *Ui, text: []const u8) void {
        ui.open(.{ .style = .{ .padding = .xy(12, 6), .shrink = 0 } });
        ui.text(text, .{ .color = .fg_muted });
        ui.close();
    }

    fn toolbarRow(p: *DebugPanel, ui: *Ui) void {
        const st = p.d.toolbarState();
        if (st.shown.count() == 0) return;
        ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center, .padding = .xy(8, 2), .h = .{ .px = 30 }, .shrink = 0 }, .role = .toolbar, .label = "Debug toolbar" });
        defer ui.close();
        inline for (comptime std.enums.values(toolbar.Button)) |b| if (st.isShown(b)) {
            if (zg_gui.w.button(ui, .{ .label = b.label(), .variant = .ghost, .disabled = !st.isEnabled(b) }).clicked) p.d.press(b);
        };
        if (st.session_picker) if (zg_gui.w.button(ui, .{ .label = sessionName(p.d), .variant = .ghost }).clicked) p.d.openSessionPicker() catch {};
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        switch (st.badge) {
            .none => {},
            .agent => {
                zg_gui.w.badge(ui, "Agent");
                if (zg_gui.w.button(ui, .{ .label = "Take Control", .variant = .primary }).clicked) p.d.takeControlCmd();
            },
            .taken => if (zg_gui.w.button(ui, .{ .label = "Hand Back to Agent", .variant = .ghost }).clicked) p.d.handBackCmd(),
        }
    }

    fn sessionName(d: *const Debug) []const u8 {
        const e = d.active() orelse return "Session";
        return e.s.cfg.name;
    }

    fn configRow(p: *DebugPanel, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center, .padding = .xy(8, 2), .h = .{ .px = 30 }, .shrink = 0 } });
        defer ui.close();
        if (zg_gui.w.button(ui, .{ .label = "Start", .variant = .primary }).clicked) p.d.startCmd(false);
        if (zg_gui.w.button(ui, .{ .label = p.d.configLabel(), .variant = .secondary }).clicked) p.d.openConfigPicker(false) catch {};
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (zg_gui.w.button(ui, .{ .label = "Add Configuration\u{2026}", .variant = .ghost }).clicked) p.d.addConfigurationCmd();
    }
};
