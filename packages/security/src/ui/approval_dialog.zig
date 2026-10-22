//! `DialogApprovalPort`: an `ApprovalPort` that asks in a modal zg_gui
//! dialog, until E12.F05's approvals inbox lands (E16.F02 trust dialogs).
//!
//! `present` may run on any thread: it copies the request and posts the
//! dialog to the UI thread. `await` blocks its task on an `Io.Event` that
//! the dialog sets with the answer. The card shows who asks, the command
//! (editable when the request allows it), risk hints and the rule an
//! "Always allow" would add, with a reason field for a denial.
//!
//! Answers: Allow once, Allow for session (the suggested rule, or the
//! command), Always allow (only with a suggested rule), Run edited (when
//! the command was changed) and Deny (Escape and closing deny too).
//!
//! Requests and answers live in an arena owned by the port, so answer
//! strings stay valid for the port's life (approvals are rare and small).

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_security = @import("zg_security");

const contracts = zg_security.contracts;
const Answer = contracts.Answer;
const ApprovalRequest = contracts.ApprovalRequest;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const controls = zg_gui.w.controls;
const overlay = zg_gui.w.overlay;
const TextBuffer = zg_gui.w.TextBuffer;

/// One request, from `present` until the port is freed.
const Pending = struct {
    port: *DialogApprovalPort,
    id: u64,
    req: ApprovalRequest,
    answer: ?Answer = null,
    done: std.Io.Event = .unset,
    overlay: overlay.OverlayId = .none,
    /// UI thread only; freed with the port (the closing frame may still
    /// paint the fields).
    edit: ?TextBuffer = null,
    reason: ?TextBuffer = null,

    pub fn build(p: *Pending, ui: *Ui) void {
        const r = &p.req;
        const th = ui.theme();
        ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_md) } });
        defer ui.close();
        var actor_buf: [160]u8 = undefined;
        const actor = std.fmt.bufPrint(&actor_buf, "Requested by {f}", .{r.actor}) catch "Requested by an agent";
        ui.text(actor, .{ .color = .fg_muted });
        if (r.command) |c| {
            if (p.edit) |*b| {
                _ = zg_gui.w.textField(ui, .{ .buffer = b, .multiline = true, .max_rows = 6, .font = .mono, .a11y_label = "Command" });
            } else {
                ui.open(.{ .style = .{ .padding = .xy(8, 6), .bg = .{ .token = .bg_base } } });
                ui.text(c, .{ .style = .{ .font = .mono } });
                ui.close();
            }
        }
        for (r.risk) |risk| ui.textf("\u{26a0} {s}", .{risk}, .{ .color = .warning });
        if (r.rule_suggestion) |rule| ui.textf("Always allow adds the rule: {s}", .{rule}, .{ .color = .fg_muted });
        if (p.reason) |*b| _ = zg_gui.w.textField(ui, .{ .buffer = b, .placeholder = "Reason for denying (sent back)", .a11y_label = "Reason" });

        ui.open(.{ .style = .{ .gap = th.dim(.space_sm), .justify = .end } });
        defer ui.close();
        if (controls.button(ui, .{ .label = "Deny", .variant = .danger }).clicked) p.answerDeny();
        controls.spacer(ui);
        if (controls.button(ui, .{ .label = "Allow for session" }).clicked) p.finish(.{ .allow_session = r.rule_suggestion orelse r.command orelse r.title });
        if (r.rule_suggestion) |rule| if (controls.button(ui, .{ .label = "Always allow" }).clicked) p.finish(.{ .allow_always = rule });
        const edited = p.editedCommand();
        if (controls.button(ui, .{ .label = if (edited != null) "Run edited" else "Allow once", .variant = .primary }).clicked) {
            p.finish(if (edited) |e| .{ .edit = e } else .allow_once);
        }
    }

    /// The edited command, when it differs from the request's.
    fn editedCommand(p: *Pending) ?[]const u8 {
        const b = &(p.edit orelse return null);
        const now = b.slice();
        return if (std.mem.eql(u8, now, p.req.command orelse "")) null else now;
    }

    fn answerDeny(p: *Pending) void {
        const reason = if (p.reason) |*b| b.slice() else "";
        p.finish(.{ .deny = if (reason.len > 0) reason else "denied by the user" });
    }

    /// Records `a` (copying its text), wakes `await` and closes the dialog.
    fn finish(p: *Pending, a: Answer) void {
        const port = p.port;
        {
            port.mutex.lockUncancelable(port.io);
            defer port.mutex.unlock(port.io);
            if (p.answer != null) return;
            p.answer = port.copyAnswer(a) catch .{ .deny = "out of memory" };
        }
        p.done.set(port.io);
        if (p.overlay != .none) port.win.closeOverlay(p.overlay);
    }

    fn onClose(ctx: *anyopaque, _: overlay.OverlayId) void {
        const p: *Pending = @ptrCast(@alignCast(ctx));
        p.overlay = .none;
        // Escape or the window closing: a denial.
        p.finish(.{ .deny = "dismissed" });
    }
};

/// See the module doc.
pub const DialogApprovalPort = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    win: *Window,
    /// Guards `arena`, `pending`, `next_id` and every `Pending.answer`.
    mutex: std.Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    pending: std.ArrayList(*Pending) = .empty,
    next_id: u64 = 1,

    /// A port that opens its dialogs on `win`.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, win: *Window) DialogApprovalPort {
        return .{ .gpa = gpa, .io = io, .win = win, .arena = .init(gpa) };
    }

    /// Closes open dialogs (answering them with a denial) and frees every
    /// request and answer. UI thread; no task may still be awaiting.
    pub fn deinit(self: *DialogApprovalPort) void {
        for (self.pending.items) |p| if (p.overlay != .none) self.win.closeOverlay(p.overlay);
        for (self.pending.items) |p| {
            if (p.edit) |*b| b.deinit();
            if (p.reason) |*b| b.deinit();
        }
        self.pending.deinit(self.gpa);
        self.arena.deinit();
    }

    /// The port interface.
    pub fn port(self: *DialogApprovalPort) contracts.ApprovalPort {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: contracts.ApprovalPort.VTable = .{ .present = present, .await = await, .cancel = cancel };

    /// Requests not answered yet (tests, a pending-count badge).
    pub fn openCount(self: *DialogApprovalPort) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.pending.items) |p| n += @intFromBool(p.answer == null);
        return n;
    }

    fn copyAnswer(self: *DialogApprovalPort, a: Answer) !Answer {
        const ar = self.arena.allocator();
        return switch (a) {
            .allow_once => .allow_once,
            .allow_session => |s| .{ .allow_session = try ar.dupe(u8, s) },
            .allow_always => |s| .{ .allow_always = try ar.dupe(u8, s) },
            .deny => |s| .{ .deny = try ar.dupe(u8, s) },
            .edit => |s| .{ .edit = try ar.dupe(u8, s) },
        };
    }

    fn find(self: *DialogApprovalPort, id: u64) ?*Pending {
        for (self.pending.items) |p| if (p.id == id) return p;
        return null;
    }

    fn present(ctx: *anyopaque, req: ApprovalRequest) anyerror!u64 {
        const self: *DialogApprovalPort = @ptrCast(@alignCast(ctx));
        const p = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const a = self.arena.allocator();
            var copy = req;
            copy.title = try a.dupe(u8, req.title);
            copy.detail_json = try a.dupe(u8, req.detail_json);
            if (req.command) |c| copy.command = try a.dupe(u8, c);
            if (req.rule_suggestion) |r| copy.rule_suggestion = try a.dupe(u8, r);
            const risk = try a.alloc([]const u8, req.risk.len);
            for (req.risk, risk) |r, *d| d.* = try a.dupe(u8, r);
            copy.risk = risk;
            copy.actor = switch (req.actor) {
                .human => |h| .{ .human = try a.dupe(u8, h) },
                .agent => |g| .{ .agent = .{ .session = try a.dupe(u8, g.session), .agent = try a.dupe(u8, g.agent) } },
                .mcp_server => |s| .{ .mcp_server = try a.dupe(u8, s) },
                .system => .system,
            };
            const p = try a.create(Pending);
            p.* = .{ .port = self, .id = self.next_id, .req = copy };
            self.next_id += 1;
            try self.pending.append(self.gpa, p);
            break :blk p;
        };
        try self.win.app.post(.{ .ctx = p, .f = openOnUi });
        return p.id;
    }

    fn openOnUi(ctx: *anyopaque, _: *zg_gui.App) void {
        const p: *Pending = @ptrCast(@alignCast(ctx));
        const self = p.port;
        if (p.answer != null) return; // cancelled before it showed
        if (p.req.command) |c| if (p.req.editable) {
            p.edit = TextBuffer.init(self.gpa, c) catch null;
        };
        p.reason = TextBuffer.init(self.gpa, "") catch null;
        p.overlay = self.win.openOverlay(.of(p), .{
            .layer = .dialog,
            .modal = true,
            .light_dismiss = false,
            .title = p.req.title,
            .label = p.req.title,
            .test_id = "approval",
            .width = zg_gui.w.dialog.DialogSize.md.width(self.win.size.w),
            .on_close = .{ .ctx = p, .f = Pending.onClose },
        }) catch {
            p.finish(.{ .deny = "could not show the approval dialog" });
            return;
        };
    }

    fn await(ctx: *anyopaque, id: u64, io: std.Io) std.Io.Cancelable!Answer {
        const self: *DialogApprovalPort = @ptrCast(@alignCast(ctx));
        const p = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk self.find(id) orelse return .{ .deny = "unknown approval" };
        };
        p.done.wait(io) catch |e| {
            cancel(ctx, id);
            return e;
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return p.answer.?;
    }

    fn cancel(ctx: *anyopaque, id: u64) void {
        const self: *DialogApprovalPort = @ptrCast(@alignCast(ctx));
        const p = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const p = self.find(id) orelse return;
            if (p.answer != null) return;
            p.answer = .{ .deny = "cancelled" };
            break :blk p;
        };
        p.done.set(self.io);
        self.win.app.post(.{ .ctx = p, .f = closeOnUi }) catch {};
    }

    fn closeOnUi(ctx: *anyopaque, _: *zg_gui.App) void {
        const p: *Pending = @ptrCast(@alignCast(ctx));
        if (p.overlay != .none) p.port.win.closeOverlay(p.overlay);
    }
};
