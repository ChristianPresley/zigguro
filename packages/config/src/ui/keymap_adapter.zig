//! The E04 adapter (E15.F04.S01.T02, #1077): plugs the `Resolver` and the
//! `CommandRegistry` into a `zg_gui.Window`.
//!
//! - **Keys.** `keyHandler` resolves the keys no focused widget handled
//!   (and, while a chord is pending, every key first). Actions run through
//!   `CommandRegistry.executeArgText` with origin `keybinding`; the arg text
//!   is the keymap's interned text, so nothing is parsed on the key path.
//! - **Chord timeouts.** When a chord has an exact binding and a longer one,
//!   the adapter arms a window timer at the resolver's deadline, so an idle
//!   app sleeps until then (no polling).
//! - **Actions.** `actionHandler` runs menu and toolbar actions (command id
//!   strings) and labels them with their key bindings.
//! - **Contexts.** Each focus-path `key_context` string is a space-separated
//!   list of context names, and `name=value` tokens add attributes to the
//!   name before them: `"editorFocus editorTextFocus vim.mode=normal"`. The
//!   adapter is also the registry's `EnvProvider`, so enablement clauses see
//!   the same focus stack.
//! - **Status.** A pending chord's label and a chord mismatch message are
//!   kept in `status` for the status bar.

const std = @import("std");
const zg_gui = @import("zg_gui");
const registry = @import("../commands/registry.zig");
const resolver_mod = @import("../keymap/resolver.zig");
const keys = @import("../keymap/keys.zig");
const context = @import("../when/context.zig");

const Window = zg_gui.Window;
const KeyPress = zg_gui.input.event.KeyPress;
const CommandRegistry = registry.CommandRegistry;
const CommandId = registry.CommandId;
const Resolver = resolver_mod.Resolver;
const Resolution = resolver_mod.Resolution;
const KeyContext = context.KeyContext;
const EvalEnv = context.EvalEnv;

/// Connects one window to the keymap and the command registry.
pub const KeymapAdapter = struct {
    gpa: std.mem.Allocator,
    reg: *CommandRegistry,
    resolver: *Resolver,
    win: *Window,
    stack: std.ArrayList(KeyContext) = .empty,
    attrs: std.ArrayList(KeyContext.Attr) = .empty,
    env: EvalEnv,
    timer: Window.TimerId = .none,
    status_buf: [128]u8 = undefined,
    status_len: usize = 0,
    /// The error of the last command the adapter ran, if it failed.
    last_error: ?anyerror = null,
    /// Told when `status` changes (the status bar re-renders).
    on_status: ?StatusListener = null,

    /// See `on_status`.
    pub const StatusListener = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, status: ?[]const u8) void,
    };

    /// An adapter for `win`; call `install` once it has its final address.
    pub fn init(gpa: std.mem.Allocator, reg: *CommandRegistry, r: *Resolver, win: *Window) KeymapAdapter {
        return .{ .gpa = gpa, .reg = reg, .resolver = r, .win = win, .env = .{ .global = r.keys } };
    }

    /// Becomes the window's key and action handler and the registry's
    /// environment provider.
    pub fn install(a: *KeymapAdapter) void {
        a.win.key_handler = a.keyHandler();
        a.win.action_handler = a.actionHandler();
        a.reg.setEnvProvider(.{ .ctx = a, .get = envFn });
    }

    /// Detaches from the window and frees the scratch lists.
    pub fn deinit(a: *KeymapAdapter) void {
        if (a.timer != .none) a.win.cancelTimer(a.timer);
        if (a.win.key_handler) |h| if (h.ptr == @as(*anyopaque, a)) {
            a.win.key_handler = null;
        };
        if (a.win.action_handler) |h| if (h.ptr == @as(*anyopaque, a)) {
            a.win.action_handler = null;
        };
        if (a.reg.env_provider) |p| if (p.ctx == @as(?*anyopaque, a)) {
            a.reg.env_provider = null;
        };
        a.stack.deinit(a.gpa);
        a.attrs.deinit(a.gpa);
    }

    /// The `zg_gui` key handler.
    pub fn keyHandler(a: *KeymapAdapter) zg_gui.input.KeyHandler {
        return .{ .ptr = a, .handle = handleKey, .pending = isPending };
    }

    /// The `zg_gui` action handler (menus, toolbar).
    pub fn actionHandler(a: *KeymapAdapter) zg_gui.input.ActionHandler {
        return .{ .ptr = a, .run = runAction, .label_for = labelFor };
    }

    /// The pending chord's label or the last chord message, if any.
    pub fn status(a: *const KeymapAdapter) ?[]const u8 {
        return if (a.status_len > 0) a.status_buf[0..a.status_len] else null;
    }

    /// The focus path as resolver contexts, outermost first. Valid until
    /// the next call.
    pub fn contexts(a: *KeymapAdapter) []const KeyContext {
        const strs = a.win.keyContexts();
        a.stack.clearRetainingCapacity();
        a.attrs.clearRetainingCapacity();
        // Reserve first: `attrs` slices must not move while filling.
        var n_tokens: usize = 0;
        for (strs) |s| {
            var it = std.mem.tokenizeScalar(u8, s, ' ');
            while (it.next()) |_| n_tokens += 1;
        }
        a.stack.ensureTotalCapacity(a.gpa, n_tokens) catch return &.{};
        a.attrs.ensureTotalCapacity(a.gpa, n_tokens) catch return &.{};
        // `strs` is innermost first; the resolver wants outermost first.
        var i = strs.len;
        while (i > 0) {
            i -= 1;
            var it = std.mem.tokenizeScalar(u8, strs[i], ' ');
            while (it.next()) |tok| {
                if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
                    if (a.stack.items.len == 0) continue;
                    a.attrs.appendAssumeCapacity(.{ .key = tok[0..eq], .value = tok[eq + 1 ..] });
                    const last = &a.stack.items[a.stack.items.len - 1];
                    const start = a.attrs.items.len - last.attrs.len - 1;
                    last.attrs = a.attrs.items[start..];
                } else {
                    a.stack.appendAssumeCapacity(.{ .name = tok });
                }
            }
        }
        return a.stack.items;
    }

    fn envFn(ctx: ?*anyopaque) *const EvalEnv {
        const a: *KeymapAdapter = @ptrCast(@alignCast(ctx.?));
        a.env = .{ .global = a.resolver.keys, .stack = a.contexts(), .settings = a.resolver.settings };
        return &a.env;
    }

    fn nowNs(a: *const KeymapAdapter) u64 {
        return a.win.app.now_ms * std.time.ns_per_ms;
    }

    /// Converts a `zg_gui` key event (its `Key` values are HID usages).
    pub fn keyInput(k: KeyPress, t_ns: u64) keys.KeyInput {
        return .{
            .usage = @intFromEnum(k.key),
            .mods = .{
                .ctrl = k.mods.ctrl,
                .shift = k.mods.shift,
                .alt = k.mods.alt,
                .super = k.mods.super,
                .caps_lock = k.mods.caps_lock,
                .num_lock = k.mods.num_lock,
                .alt_gr = k.mods.alt_gr,
            },
            .action = switch (k.action) {
                .press => .press,
                .repeat => .repeat,
                .release => .release,
            },
            .codepoint = if (k.codepoint != 0) k.codepoint else null,
            .t_ns = t_ns,
        };
    }

    fn handleKey(ptr: *anyopaque, k: KeyPress, _: []const []const u8) bool {
        const a: *KeymapAdapter = @ptrCast(@alignCast(ptr));
        const res = a.resolver.resolve(a.contexts(), keyInput(k, a.nowNs()));
        // Releases only matter when they finish a double tap; they leave
        // the status (a pending chord, a mismatch message) alone.
        if (k.action == .release and res == .none) return false;
        const consumed = a.apply(res);
        a.armTimer();
        return consumed;
    }

    fn isPending(ptr: *anyopaque) bool {
        const a: *KeymapAdapter = @ptrCast(@alignCast(ptr));
        return a.resolver.isPending();
    }

    /// Acts on a resolution; true when the key was consumed.
    fn apply(a: *KeymapAdapter, res: Resolution) bool {
        switch (res) {
            .none => {
                a.setStatus(null);
                return false;
            },
            .pending => |label| {
                a.setStatus(label);
                return true;
            },
            .swallow => |msg| {
                a.setStatus(if (msg.len > 0) msg else null);
                return true;
            },
            .action => |act| {
                a.setStatus(null);
                a.run(act.id, act.arg, .keybinding);
                // The key that broke a chord, re-processed.
                if (a.resolver.takeDeferred()) |d| _ = a.apply(d);
                return true;
            },
        }
    }

    fn run(a: *KeymapAdapter, id: CommandId, arg: ?[]const u8, origin: registry.Origin) void {
        a.last_error = null;
        a.reg.executeArgText(id, arg, origin) catch |e| {
            a.last_error = e;
        };
    }

    fn setStatus(a: *KeymapAdapter, s: ?[]const u8) void {
        const t = s orelse "";
        const n = @min(t.len, a.status_buf.len);
        if (n == a.status_len and std.mem.eql(u8, a.status_buf[0..n], t[0..n])) return;
        @memcpy(a.status_buf[0..n], t[0..n]);
        a.status_len = n;
        if (a.on_status) |cb| cb.f(cb.ctx, a.status());
    }

    /// Keeps one window timer at the resolver's chord deadline.
    fn armTimer(a: *KeymapAdapter) void {
        if (a.timer != .none) {
            a.win.cancelTimer(a.timer);
            a.timer = .none;
        }
        const d = a.resolver.deadline() orelse return;
        const at_ms = std.math.divCeil(u64, d, std.time.ns_per_ms) catch unreachable;
        a.timer = a.win.setTimer(at_ms, .{ .ctx = a, .f = onTimer }) catch .none;
    }

    fn onTimer(ctx: *anyopaque, _: *Window) void {
        const a: *KeymapAdapter = @ptrCast(@alignCast(ctx));
        a.timer = .none;
        if (a.resolver.onTimer(a.nowNs())) |res| _ = a.apply(res);
        a.armTimer();
    }

    fn runAction(ptr: *anyopaque, action: []const u8, arg: ?[]const u8) bool {
        const a: *KeymapAdapter = @ptrCast(@alignCast(ptr));
        const id = a.reg.lookup(action) orelse return false;
        a.run(id, arg, .menu);
        return true;
    }

    fn labelFor(ptr: *anyopaque, action: []const u8) ?[]const u8 {
        const a: *KeymapAdapter = @ptrCast(@alignCast(ptr));
        const id = a.reg.lookup(action) orelse return null;
        return a.resolver.labelFor(id, null);
    }
};
