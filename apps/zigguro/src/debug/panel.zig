//! The Run and Debug panel (E07.F07.S01.T01): the debug toolbar, the
//! configuration row and the Call Stack, over the debug service. The
//! Variables, Watch, Breakpoints and console views join it later
//! (E07.F07.S01.T03).
//!
//! The call stack is rebuilt only when the service's `generation`
//! changed, so a stop paints in the frame after the models applied it.
//! UI thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const service = @import("service.zig");
const toolbar = @import("toolbar.zig");
const call_stack = @import("call_stack.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const Debug = service.Debug;
const CallStack = call_stack.CallStack;

pub const DebugPanel = struct {
    gpa: Allocator,
    d: *Debug,
    stack: CallStack = undefined,
    /// The service generation the tree was built from.
    seen: u64 = 0,
    snap_arena: std.heap.ArenaAllocator,

    /// `p` must not move afterwards.
    pub fn init(p: *DebugPanel, gpa: Allocator, d: *Debug) !void {
        p.* = .{ .gpa = gpa, .d = d, .snap_arena = .init(gpa) };
        try p.stack.init(gpa, d.stackHooks());
    }

    pub fn deinit(p: *DebugPanel) void {
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
        ui.open(.{ .style = .{ .padding = .xy(10, 2), .shrink = 0 } });
        ui.text("CALL STACK", .{ .color = .fg_muted, .wrap = false });
        ui.close();
        if (p.d.sessionCount() == 0) {
            ui.open(.{ .style = .{ .padding = .xy(12, 6), .shrink = 0 } });
            ui.text("Not debugging. Pick a configuration and press F5 (Start Debugging); F9 sets a breakpoint on the caret's line.", .{ .color = .fg_muted });
            ui.close();
            return;
        }
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "callStackFocus" });
        p.stack.build(ui);
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
