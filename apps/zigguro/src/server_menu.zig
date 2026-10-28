//! The language server menu (E07.F01.S02.T06): the status bar's server
//! item opens a QuickPick of what can be done to that server now
//! (restart, stop, enable, cancel its progress, show its logs or
//! details, add a `check` step for ZLS build-on-save); the host runs the
//! picked action.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_codeintel = @import("zg_codeintel");

const qp = zg_gui.w.quick_pick;
const Manager = zg_codeintel.Manager;
const ServerStatus = zg_codeintel.features.ServerStatus;

pub const Action = enum { restart, stop, enable, cancel_progress, show_logs, show_details, add_check_step };

pub const ServerMenu = struct {
    pub const Host = struct {
        ctx: *anyopaque,
        run: *const fn (ctx: *anyopaque, action: Action, server: u32) void,
    };

    host: ?Host = null,
    items: [7]qp.QpItem = undefined,
    n: usize = 0,
    server: u32 = 0,
    title: [96]u8 = undefined,
    title_len: usize = 0,
    handle: qp.QuickPickHandle = .{},

    /// The actions that apply to `s` in its current state (`add_check`:
    /// its build lacks the `check` step build-on-save wants).
    pub fn actionsFor(s: *const Manager.Server, st: *ServerStatus, add_check: bool, out: *[7]Action) []const Action {
        var n: usize = 0;
        var pb: [8]u8 = undefined;
        switch (s.status) {
            .running => {
                if (st.progressOf(s.id, &pb)) |p| if (p.cancellable) {
                    out[n] = .cancel_progress;
                    n += 1;
                };
                out[n] = .restart;
                out[n + 1] = .stop;
                n += 2;
            },
            .crashed, .failed, .stopped => {
                out[n] = .restart;
                n += 1;
            },
            .disabled => {
                out[n] = .enable;
                n += 1;
            },
            .starting => {
                out[n] = .stop;
                n += 1;
            },
            .missing => {},
        }
        if (add_check) {
            out[n] = .add_check_step;
            n += 1;
        }
        out[n] = .show_logs;
        out[n + 1] = .show_details;
        n += 2;
        return out[0..n];
    }

    pub fn labelOf(a: Action) []const u8 {
        return switch (a) {
            .restart => "Restart Language Server",
            .stop => "Stop Language Server",
            .enable => "Enable Language Server",
            .cancel_progress => "Cancel the Running Task",
            .show_logs => "Show Language Server Logs",
            .show_details => "Show Language Server Details",
            .add_check_step => "Add a check Step to build.zig (Build-on-Save)",
        };
    }

    /// Opens the menu for `s`.
    pub fn open(m: *ServerMenu, w: *zg_gui.Window, s: *const Manager.Server, st: *ServerStatus, add_check: bool) !void {
        m.handle.close(w);
        var acts: [7]Action = undefined;
        const list = actionsFor(s, st, add_check, &acts);
        for (list, 0..) |a, i| m.items[i] = .{ .id = @intFromEnum(a), .label = labelOf(a) };
        m.n = list.len;
        m.server = s.id;
        var lb: [64]u8 = undefined;
        const t = st.label(s, &lb);
        m.title_len = @min(t.len, m.title.len);
        @memcpy(m.title[0..m.title_len], t[0..m.title_len]);
        const provs = [_]qp.Provider{.{ .ptr = m, .vtable = &vtable }};
        m.handle = try qp.openQuickPick(w, .{ .providers = &provs, .title = m.title[0..m.title_len], .test_id = "lsp-server-menu" });
    }

    const vtable: qp.Provider.VTable = .{
        .placeholder = "Language server action",
        .items = pickItems,
        .accept = accept,
    };

    fn pickItems(ptr: ?*anyopaque) []const qp.QpItem {
        const m: *ServerMenu = @ptrCast(@alignCast(ptr.?));
        return m.items[0..m.n];
    }

    fn accept(ptr: ?*anyopaque, picked: []const qp.QpItem, _: ?[]const u8, _: bool) void {
        const m: *ServerMenu = @ptrCast(@alignCast(ptr.?));
        if (picked.len == 0) return;
        const hk = m.host orelse return;
        hk.run(hk.ctx, @enumFromInt(@as(@typeInfo(Action).@"enum".tag_type, @intCast(picked[0].id))), m.server);
    }
};

test "server_menu: actions follow the server state" {
    const testing = std.testing;
    var st: ServerStatus = .{ .gpa = testing.allocator, .io = testing.io, .mgr = undefined, .waker = .noop };
    defer st.deinit();
    const def: zg_codeintel.registry.Registry.ServerDef = .{ .id = "zls", .command = &.{"zls"}, .languages = &.{"zig"} };
    var s: Manager.Server = .{ .mgr = undefined, .id = 0, .def = &def, .root = &.{}, .exe = &.{}, .status = .running, .arena = undefined };
    var buf: [7]Action = undefined;
    try testing.expectEqualSlices(Action, &.{ .restart, .stop, .show_logs, .show_details }, ServerMenu.actionsFor(&s, &st, false, &buf));
    s.status = .disabled;
    try testing.expectEqualSlices(Action, &.{ .enable, .show_logs, .show_details }, ServerMenu.actionsFor(&s, &st, false, &buf));
    try testing.expectEqualSlices(Action, &.{ .enable, .add_check_step, .show_logs, .show_details }, ServerMenu.actionsFor(&s, &st, true, &buf));
    s.status = .missing;
    try testing.expectEqualSlices(Action, &.{ .show_logs, .show_details }, ServerMenu.actionsFor(&s, &st, false, &buf));
    var lb: [64]u8 = undefined;
    try testing.expectEqualStrings("zls: not installed", st.label(&s, &lb));
}
