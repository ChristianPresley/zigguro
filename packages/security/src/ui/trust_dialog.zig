//! The workspace-trust prompt (E16.F07.S01): asked when a folder of
//! unknown trust opens, before anything in it runs.
//!
//! "Trust folder" and "Trust parent folder" grant trust (the parent only
//! when it is neither the home directory nor a filesystem root); "Stay in
//! Restricted Mode" records an explicit restricted state. Escape and
//! closing the window stay restricted: never trusted by default. The
//! caller persists the choice in the trust store (E16.F07.S01.T01).

const std = @import("std");
const zg_gui = @import("zg_gui");

const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const controls = zg_gui.w.controls;
const overlay = zg_gui.w.overlay;

/// The user's answer.
pub const TrustChoice = enum { trust, trust_parent, restricted };

/// What the prompt asks about.
pub const TrustPrompt = struct {
    /// The folder being opened (absolute).
    folder: []const u8,
    /// Offer parent-folder trust for this folder (see `trustableParent`).
    parent: ?[]const u8 = null,
};

/// Receives the answer once.
pub const TrustCb = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, choice: TrustChoice) void,
};

/// What Restricted Mode turns off, as the prompt lists it.
pub const restricted_effects = [_][]const u8{
    "Tasks, debugging and launch configurations do not run.",
    "Project MCP servers and agent hooks do not start.",
    "Project settings that run code are ignored.",
    "Workspace extensions are disabled.",
};

/// The parent of `folder` that may be trusted with parent scope, or null
/// when the parent is a filesystem root or the home directory.
pub fn trustableParent(folder: []const u8, home: ?[]const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, folder, "/\\");
    const parent = std.fs.path.dirname(trimmed) orelse return null;
    if (isRoot(parent)) return null;
    if (home) |h| if (std.mem.eql(u8, std.mem.trimEnd(u8, h, "/\\"), std.mem.trimEnd(u8, parent, "/\\"))) return null;
    return parent;
}

fn isRoot(p: []const u8) bool {
    const t = std.mem.trimEnd(u8, p, "/\\");
    if (t.len == 0) return true;
    // `C:` or `\\server\share`.
    if (t.len == 2 and t[1] == ':') return true;
    if (std.mem.startsWith(u8, p, "\\\\") and std.mem.count(u8, t[2..], "\\") <= 1) return true;
    return false;
}

/// Asks about `p` in a modal dialog; `cb` runs once with the answer.
/// The strings are copied.
pub fn askTrust(win: *Window, p: TrustPrompt, cb: TrustCb) !overlay.OverlayId {
    const gpa = win.gpa;
    const v = try gpa.create(TrustView);
    errdefer gpa.destroy(v);
    v.* = .{ .gpa = gpa, .win = win, .cb = cb };
    v.folder = try gpa.dupe(u8, p.folder);
    errdefer gpa.free(v.folder);
    if (p.parent) |par| v.parent = try gpa.dupe(u8, par);
    v.id = try win.openOverlay(.of(v), .{
        .layer = .dialog,
        .modal = true,
        .light_dismiss = false,
        .title = "Do you trust the authors of the files in this folder?",
        .label = "Workspace trust",
        .test_id = "trust",
        .width = zg_gui.w.dialog.DialogSize.md.width(win.size.w),
        .on_close = .{ .ctx = v, .f = TrustView.onClose },
    });
    return v.id;
}

/// The view behind `askTrust`; freed when its overlay closes.
const TrustView = struct {
    gpa: std.mem.Allocator,
    win: *Window,
    cb: TrustCb,
    folder: []u8 = &.{},
    parent: ?[]u8 = null,
    id: overlay.OverlayId = .none,
    choice: TrustChoice = .restricted,

    pub fn build(self: *TrustView, ui: *Ui) void {
        const th = ui.theme();
        ui.open(.{ .style = .{ .dir = .column, .gap = th.dim(.space_md) } });
        defer ui.close();
        ui.text(self.folder, .{ .style = .{ .font = .mono }, .wrap = true });
        ui.text("zigguro runs nothing from this folder until you trust it. In Restricted Mode:", .{ .color = .fg_muted });
        for (restricted_effects) |e| ui.textf("\u{2022} {s}", .{e}, .{ .color = .fg_muted });
        ui.text("Only trust folders whose authors you trust: trusted code can run on your machine.", .{ .color = .warning });

        ui.open(.{ .style = .{ .gap = th.dim(.space_sm), .justify = .end, .wrap = true } });
        defer ui.close();
        if (controls.button(ui, .{ .label = "Stay in Restricted Mode" }).clicked) self.answer(.restricted);
        controls.spacer(ui);
        if (self.parent) |par| {
            var buf: [96]u8 = undefined;
            const name = std.fs.path.basename(par);
            const label = std.fmt.bufPrint(&buf, "Trust parent folder '{s}'", .{name[0..@min(name.len, 60)]}) catch "Trust parent folder";
            if (controls.button(ui, .{ .label = label }).clicked) self.answer(.trust_parent);
        }
        if (controls.button(ui, .{ .label = "Trust folder", .variant = .primary }).clicked) self.answer(.trust);
    }

    fn answer(self: *TrustView, c: TrustChoice) void {
        self.choice = c;
        self.win.closeOverlay(self.id);
    }

    fn onClose(ctx: *anyopaque, _: overlay.OverlayId) void {
        const self: *TrustView = @ptrCast(@alignCast(ctx));
        const cb = self.cb;
        const c = self.choice;
        const gpa = self.gpa;
        gpa.free(self.folder);
        if (self.parent) |p| gpa.free(p);
        gpa.destroy(self);
        cb.f(cb.ctx, c);
    }
};

test "trust: the parent is offered unless it is a root or home" {
    try std.testing.expectEqualStrings("/src/work", trustableParent("/src/work/app", "/home/me").?);
    try std.testing.expectEqualStrings("/src/work", trustableParent("/src/work/app/", null).?);
    try std.testing.expectEqual(@as(?[]const u8, null), trustableParent("/home/me/app", "/home/me/"));
    try std.testing.expectEqual(@as(?[]const u8, null), trustableParent("/app", null));
    try std.testing.expect(isRoot("C:\\"));
    try std.testing.expect(isRoot("\\\\server\\share"));
    try std.testing.expect(!isRoot("C:\\work"));
}
