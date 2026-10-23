//! Vault setup (E08.F06.S01.T04): when a workspace root holds
//! `.obsidian/` or `.zigguro/vault.zon` and no decision is stored, a
//! non-modal banner asks "Treat <folder> as a notes vault?" (Yes / Not
//! now / Never). Yes and Never are stored (the workspace file's `vaults`
//! list, or per-workspace storage, behind `DecisionStore`); Not now lasts
//! for the session.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_notes = @import("zg_notes");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;

pub const Decision = enum { vault, never };

pub const DecisionStore = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, folder: []const u8) ?Decision,
    put: *const fn (ctx: *anyopaque, folder: []const u8, d: Decision) anyerror!void,
};

pub const Choice = enum { yes, not_now, never };

/// The commands the app registers with E15.
pub const Command = struct { id: []const u8, title: []const u8 };
pub const commands = [_]Command{
    .{ .id = "notes.markFolderAsVault", .title = "Notes: Mark Folder as Vault" },
    .{ .id = "notes.openVault", .title = "Notes: Open Folder as Vault" },
    .{ .id = "notes.showBacklinks", .title = "Notes: Show Backlinks" },
    .{ .id = "notes.showTags", .title = "Notes: Show Tags" },
};

pub const VaultSetup = struct {
    gpa: Allocator,
    store: DecisionStore,
    /// The folder being asked about and its detected configuration.
    pending: ?struct { folder: []u8, config: zg_notes.VaultConfig, arena: std.heap.ArenaAllocator } = null,
    /// Folders answered "Not now" this session.
    snoozed: std.StringHashMapUnmanaged(void) = .empty,
    /// The arena holding the last accepted configuration's strings.
    kept: ?std.heap.ArenaAllocator = null,

    pub fn deinit(s: *VaultSetup) void {
        s.clearPending();
        s.deinitKept();
        var it = s.snoozed.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        s.snoozed.deinit(s.gpa);
    }

    fn clearPending(s: *VaultSetup) void {
        if (s.pending) |*p| {
            s.gpa.free(p.folder);
            p.arena.deinit();
        }
        s.pending = null;
    }

    /// Looks for a vault in workspace root `dir` (named `folder`); true
    /// when the banner should ask. Run it off the UI thread (it reads).
    pub fn check(s: *VaultSetup, io: Io, folder: []const u8, dir: Io.Dir) !bool {
        if (s.store.get(s.store.ctx, folder) != null or s.snoozed.contains(folder)) return false;
        if (s.pending != null) return false;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        errdefer arena.deinit();
        const cfg = (try zg_notes.vault.detectVault(arena.allocator(), io, dir)) orelse {
            arena.deinit();
            return false;
        };
        s.pending = .{ .folder = try s.gpa.dupe(u8, folder), .config = cfg, .arena = arena };
        return true;
    }

    /// Answers the banner. Returns the configuration to mount for Yes.
    pub fn answer(s: *VaultSetup, c: Choice) !?zg_notes.VaultConfig {
        const p = s.pending orelse return null;
        switch (c) {
            .yes => try s.store.put(s.store.ctx, p.folder, .vault),
            .never => try s.store.put(s.store.ctx, p.folder, .never),
            .not_now => try s.snoozed.put(s.gpa, try s.gpa.dupe(u8, p.folder), {}),
        }
        const cfg = p.config;
        // The config's strings live in the pending arena: keep it for Yes.
        if (c == .yes) {
            s.gpa.free(p.folder);
            s.deinitKept();
            s.kept = p.arena;
            s.pending = null;
            return cfg;
        }
        s.clearPending();
        return null;
    }

    pub fn deinitKept(s: *VaultSetup) void {
        if (s.kept) |*k| k.deinit();
        s.kept = null;
    }
};

/// The banner, while a folder is pending; returns the answer clicked.
pub fn vaultBanner(ui: *Ui, s: *const VaultSetup) ?Choice {
    const p = s.pending orelse return null;
    const th = ui.theme();
    const q = std.fmt.allocPrint(ui.arena(), "Treat {s} as a notes vault?", .{p.folder}) catch "Treat this folder as a notes vault?";
    ui.open(.{ .role = .status, .label = q, .test_id = "vault-banner", .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center, .padding = .all(th.dim(.space_sm)), .bg = .{ .token = .bg_elevated } } });
    defer ui.close();
    ui.open(.{ .style = .{ .grow = 1 } });
    ui.text(q, .{});
    ui.close();
    var out: ?Choice = null;
    if (controls.button(ui, .{ .label = "Yes", .variant = .primary }).clicked) out = .yes;
    if (controls.button(ui, .{ .label = "Not now" }).clicked) out = .not_now;
    if (controls.button(ui, .{ .label = "Never" }).clicked) out = .never;
    return out;
}
