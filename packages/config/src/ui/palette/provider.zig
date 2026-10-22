//! The command palette (E15.F03.S02.T01, first cut): the `>` QuickPick
//! provider over the command registry, and `workbench.showCommands`.
//!
//! Items are the commands visible in the palette for the focus at the
//! moment the palette opens (`palette_when`), labelled "Category: Title"
//! with their key binding as a hint. The QuickPick's subsequence matcher
//! ranks them and its recently-used list boosts the last ones run.
//! Frecency, args prompting and the agent fallback come later.

const std = @import("std");
const zg_gui = @import("zg_gui");
const registry = @import("../../commands/registry.zig");
const adapter_mod = @import("../keymap_adapter.zig");

const qp = zg_gui.w.quick_pick;
const QpItem = qp.QpItem;
const Provider = qp.Provider;
const CommandRegistry = registry.CommandRegistry;
const CommandId = registry.CommandId;
const KeymapAdapter = adapter_mod.KeymapAdapter;

/// The command id that opens the palette.
pub const show_commands = "workbench.showCommands";

/// The palette for one window.
pub const PaletteProvider = struct {
    gpa: std.mem.Allocator,
    reg: *CommandRegistry,
    adapter: *KeymapAdapter,
    /// Items of the current list and of the one before it (a closing
    /// picker may still point at those until its next frame).
    arenas: [2]std.heap.ArenaAllocator,
    cur: u1 = 0,
    items_: []QpItem = &.{},
    mru: qp.Mru = .{},
    handle: qp.QuickPickHandle = .{},
    /// Providers shown next to `>` (Go to File as the default, ...).
    extra: []const Provider = &.{},

    /// A palette running commands through `reg`, labelled by `adapter`.
    pub fn init(gpa: std.mem.Allocator, reg: *CommandRegistry, adapter: *KeymapAdapter) PaletteProvider {
        return .{ .gpa = gpa, .reg = reg, .adapter = adapter, .arenas = .{ .init(gpa), .init(gpa) } };
    }

    /// Frees the lists (close the palette first).
    pub fn deinit(p: *PaletteProvider) void {
        for (&p.arenas) |*a| a.deinit();
    }

    const vtable: Provider.VTable = .{ .prefix = ">", .placeholder = "Type a command", .items = itemsFn, .accept = acceptFn };

    /// The `>` provider.
    pub fn provider(p: *PaletteProvider) Provider {
        return .{ .ptr = p, .vtable = &vtable };
    }

    /// Registers `workbench.showCommands`.
    pub fn registerCommands(p: *PaletteProvider) !void {
        _ = try p.reg.register(.{
            .id = show_commands,
            .title = "Show All Commands",
            .category = "View",
            .agent = .never,
            .repeat = false,
            .source = .{ .builtin = "config" },
            .handler = .{ .ctx = p, .run = showCommandsFn },
        });
    }

    fn showCommandsFn(ctx: ?*anyopaque, _: *registry.Invocation) anyerror!void {
        const p: *PaletteProvider = @ptrCast(@alignCast(ctx.?));
        _ = try p.open(">");
    }

    /// Lists the commands for the current focus and opens the picker with
    /// `initial` as its text (">" for commands).
    pub fn open(p: *PaletteProvider, initial: []const u8) !qp.QuickPickHandle {
        const win = p.adapter.win;
        if (p.handle.isOpen(win)) p.handle.close(win);
        try p.refresh();
        var provs: [9]Provider = undefined;
        provs[0] = p.provider();
        const n = @min(p.extra.len, provs.len - 1);
        @memcpy(provs[1 .. 1 + n], p.extra[0..n]);
        p.handle = try qp.openQuickPick(win, .{
            .providers = provs[0 .. 1 + n],
            .initial = initial,
            .title = "Command Palette",
            .mru = &p.mru,
            .test_id = "command_palette",
        });
        return p.handle;
    }

    /// Rebuilds the item list from the registry, for the current focus.
    pub fn refresh(p: *PaletteProvider) !void {
        p.cur +%= 1;
        const arena = &p.arenas[p.cur];
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const ev = if (p.reg.env_provider) |x| x.get(x.ctx) else &p.reg.default_env;
        // Labels need the context stack the env was built from.
        const stack = ev.stack;
        var list: std.ArrayList(QpItem) = .empty;
        var it = p.reg.iterate();
        while (it.next()) |c| {
            if (!p.reg.inPalette(c.id, ev)) continue;
            const label = if (c.cmd.category) |cat| try std.fmt.allocPrint(a, "{s}: {s}", .{ cat, c.cmd.title }) else c.cmd.title;
            const kb = if (p.adapter.resolver.labelFor(c.id, stack)) |l| try a.dupe(u8, l) else null;
            try list.append(a, .{ .id = @intFromEnum(c.id), .label = label, .description = c.cmd.description, .keybinding = kb });
        }
        p.items_ = list.items;
    }

    /// The current list.
    pub fn items(p: *const PaletteProvider) []const QpItem {
        return p.items_;
    }

    fn itemsFn(ptr: ?*anyopaque) []const QpItem {
        const p: *PaletteProvider = @ptrCast(@alignCast(ptr.?));
        return p.items_;
    }

    fn acceptFn(ptr: ?*anyopaque, picked: []const QpItem, _: ?[]const u8, _: bool) void {
        const p: *PaletteProvider = @ptrCast(@alignCast(ptr.?));
        if (picked.len == 0) return;
        const id: CommandId = @enumFromInt(@as(u32, @intCast(picked[0].id)));
        p.adapter.last_error = null;
        p.reg.execute(id, null, .palette) catch |err| {
            p.adapter.last_error = err;
        };
    }
};
