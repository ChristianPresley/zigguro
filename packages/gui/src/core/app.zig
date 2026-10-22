//! `App`: one per process. Owns entities, windows, observation and
//! subscription tables and the effect queue; `Context` is the handle views
//! and entity updates use to notify, observe and emit.

const std = @import("std");
const builtin = @import("builtin");
const zg_platform = @import("zg_platform");
const zg_core = @import("zg_core");
const ids = @import("ids.zig");
const view = @import("view.zig");
const window_mod = @import("window.zig");
const theme_mod = @import("../theme/theme.zig");
const toast_mod = @import("../widgets/toast.zig");
const NotificationCenter = @import("../widgets/notification_center.zig").NotificationCenter;

const EntityId = view.EntityId;
const Window = window_mod.Window;

/// A view in some window.
pub const ViewRef = struct { win: *Window, view: u16 };

/// A queued effect.
const Effect = union(enum) {
    notify: EntityId,
    emit: struct { source: EntityId, tag: u64, payload: *const anyopaque },
};

/// A live event subscription; drop it with `Subscription.drop`.
pub const Subscription = struct {
    id: u32,

    /// Removes the subscription.
    pub fn drop(s: Subscription, app: *App) void {
        for (app.subs.items) |*sub| {
            if (sub.id == s.id) sub.alive = false;
        }
    }
};

const Sub = struct {
    id: u32,
    source: EntityId,
    tag: u64,
    ctx: *anyopaque,
    handler: *const fn (*anyopaque, *const anyopaque, *Context) void,
    alive: bool = true,
};

/// The app's copy of the text clipboard. Widgets read and write it
/// synchronously; the Host forwards local writes to the platform and
/// refreshes it when the system clipboard changes.
pub const Clipboard = struct {
    text: std.ArrayList(u8) = .empty,
    /// Set by `set`; the Host forwards the text and clears it.
    pending_write: bool = false,

    /// Replaces the text (from a widget: Copy or Cut).
    pub fn set(c: *Clipboard, gpa: std.mem.Allocator, s: []const u8) void {
        c.replace(gpa, s);
        c.pending_write = true;
    }

    /// Replaces the text without forwarding it (from the platform).
    pub fn replace(c: *Clipboard, gpa: std.mem.Allocator, s: []const u8) void {
        c.text.clearRetainingCapacity();
        c.text.appendSlice(gpa, s) catch c.text.clearRetainingCapacity();
    }

    /// The text.
    pub fn get(c: *const Clipboard) []const u8 {
        return c.text.items;
    }
};

/// The process-wide UI state.
pub const App = struct {
    gpa: std.mem.Allocator,
    entities: view.EntityStore,
    windows: std.ArrayList(*Window) = .empty,
    observers: std.AutoHashMapUnmanaged(u32, std.ArrayList(ViewRef)) = .empty,
    subs: std.ArrayList(Sub) = .empty,
    next_sub: u32 = 1,
    effects: std.ArrayList(Effect) = .empty,
    effect_arena: std.heap.ArenaAllocator,
    theme: *const theme_mod.Theme = &theme_mod.zigguro_dark,
    /// Follow the desktop's light/dark/high-contrast setting.
    follow_system: bool = true,
    /// Set when `flushEffects` hit its cycle guard.
    effect_cycle: bool = false,
    /// The text clipboard (kept in sync with the system's by the Host).
    clipboard: Clipboard = .{},
    /// The PRIMARY selection (select to copy, middle-click to paste),
    /// synced like `clipboard`. Only used when `has_primary`.
    primary: Clipboard = .{},
    /// The desktop has a PRIMARY selection (X11 and Wayland, not Windows
    /// or macOS).
    has_primary: bool = builtin.os.tag != .windows and !builtin.os.tag.isDarwin(),
    /// Every toast and notification (`zg_gui.w.toast`).
    notifications: NotificationCenter,
    /// Each window's toast stack.
    toast_hosts: std.ArrayList(*toast_mod.Host) = .empty,
    /// Milliseconds on a monotonic clock: set by the Host on every pump,
    /// by tests directly. Drives undo coalescing and other timing.
    now_ms: u64 = 0,
    /// Worker threads and the UI mailbox (`attachRuntime`); without one,
    /// `spawn` runs work inline and `post` queues locally.
    rt: ?*zg_core.Runtime = null,
    work: ?zg_core.runtime.Subsystem = null,
    /// Calls posted while no runtime is attached.
    local_calls: std.ArrayList(Call) = .empty,
    /// Receives mailbox messages that are not `gui_call`s (other
    /// subsystems' kinds).
    on_message: ?MessageHandler = null,

    /// The mailbox kind of `post`ed calls ("G\x04" + 0x0100).
    pub const gui_call: u32 = 0x4704_0100;

    /// A function to run on the UI thread with its context.
    pub const Call = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, app: *App) void,
    };

    /// Handles mailbox messages of other kinds.
    pub const MessageHandler = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, app: *App, msg: zg_core.runtime.UiMsg) void,
    };

    /// An empty app.
    pub fn init(gpa: std.mem.Allocator) App {
        @import("../widgets/box.zig").registerBuiltins();
        return .{
            .gpa = gpa,
            .entities = .{ .gpa = gpa },
            .effect_arena = .init(gpa),
            .notifications = .init(gpa),
        };
    }

    /// Closes every window and frees every entity.
    pub fn deinit(app: *App) void {
        // Background work first: it may post into what follows.
        if (app.work) |*wk| wk.shutdown();
        // Deliver what finished work posted, so its owners can release it.
        _ = app.drainMessages();
        app.local_calls.deinit(app.gpa);
        for (app.windows.items) |w| w.destroy();
        app.windows.deinit(app.gpa);
        app.toast_hosts.deinit(app.gpa);
        app.notifications.deinit();
        var it = app.observers.valueIterator();
        while (it.next()) |l| l.deinit(app.gpa);
        app.observers.deinit(app.gpa);
        app.subs.deinit(app.gpa);
        app.effects.deinit(app.gpa);
        app.effect_arena.deinit();
        app.entities.deinit();
        app.clipboard.text.deinit(app.gpa);
        app.primary.text.deinit(app.gpa);
    }

    // -- background work ----------------------------------------------------

    /// Gives the app worker threads and a UI mailbox. `rt` must outlive the
    /// app, and the UI thread must be bound (`Runtime.bindUiThread`; the
    /// Host does it).
    pub fn attachRuntime(app: *App, rt: *zg_core.Runtime) void {
        app.rt = rt;
        app.work = .init(rt.io);
    }

    /// Runs `func(args)` on a worker (inline when no runtime is attached).
    /// `func` returns `void` or `std.Io.Cancelable!void`; it reports back
    /// with `post`. Cancelled when the app shuts down.
    pub fn spawn(app: *App, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) void {
        if (app.work) |*wk| {
            wk.spawn(func, args);
        } else {
            _ = @call(.auto, func, args);
        }
    }

    /// Waits for every spawned task to finish (tests, shutdown).
    pub fn joinWork(app: *App) void {
        if (app.work) |*wk| wk.join() catch {};
    }

    /// Runs `c` on the UI thread at the next `drainMessages`. Any thread;
    /// never blocks. Fails when the mailbox is full or closed.
    pub fn post(app: *App, c: Call) zg_core.runtime.Runtime.PostError!void {
        if (app.rt) |rt| return rt.post(.{ .kind = gui_call, .a = @intFromPtr(c.f), .b = @intFromPtr(c.ctx) });
        app.local_calls.append(app.gpa, c) catch return error.Full;
    }

    /// UI thread: runs posted calls and hands other messages to
    /// `on_message`. Returns how many were handled.
    pub fn drainMessages(app: *App) usize {
        var n: usize = 0;
        while (app.local_calls.items.len > 0) {
            const c = app.local_calls.orderedRemove(0);
            c.f(c.ctx, app);
            n += 1;
        }
        const rt = app.rt orelse return n;
        var buf: [64]zg_core.runtime.UiMsg = undefined;
        while (true) {
            const got = rt.drain(&buf);
            for (buf[0..got]) |m| {
                if (m.kind == gui_call) {
                    const f: *const fn (*anyopaque, *App) void = @ptrFromInt(@as(usize, @intCast(m.a)));
                    f(@ptrFromInt(@as(usize, @intCast(m.b))), app);
                } else if (app.on_message) |h| h.f(h.ctx, app, m);
            }
            n += got;
            if (got < buf.len) break;
        }
        return n;
    }

    /// Opens a window (see `Window.Options`).
    pub fn openWindow(app: *App, opts: Window.Options) !*Window {
        const w = try Window.create(app, opts);
        errdefer w.destroy();
        try app.windows.append(app.gpa, w);
        return w;
    }

    /// Closes and frees `w`.
    pub fn closeWindow(app: *App, w: *Window) void {
        for (app.windows.items, 0..) |x, i| {
            if (x == w) {
                _ = app.windows.swapRemove(i);
                break;
            }
        }
        app.dropObserversOf(w);
        w.destroy();
    }

    /// Creates an entity.
    pub fn new(app: *App, comptime T: type, value: T) !view.Entity(T) {
        return app.entities.new(T, value);
    }

    /// Drops a reference to an entity.
    pub fn release(app: *App, id: EntityId) void {
        if (app.entities.release(id)) {
            if (app.observers.fetchRemove(id.raw())) |kv| {
                var l = kv.value;
                l.deinit(app.gpa);
            }
            for (app.subs.items) |*s| {
                if (s.source.raw() == id.raw()) s.alive = false;
            }
        }
    }

    /// Runs `f` on entity `e` with a `Context` whose `emit` source is `e`,
    /// then flushes effects.
    pub fn update(app: *App, comptime T: type, e: view.Entity(T), comptime f: fn (*T, *Context) void) void {
        var cx: Context = .{ .app = app, .entity = e.id };
        f(app.entities.get(T, e.id), &cx);
        app.flushEffects();
    }

    /// Queues a notification: every view observing `id` rebuilds.
    pub fn notifyEntity(app: *App, id: EntityId) void {
        app.effects.append(app.gpa, .{ .notify = id }) catch {
            app.applyNotify(id);
        };
    }

    fn applyNotify(app: *App, id: EntityId) void {
        if (app.observers.get(id.raw())) |list| {
            for (list.items) |r| r.win.markViewDirty(r.view);
        }
    }

    /// Runs queued effects until none are left (guarded against cycles).
    pub fn flushEffects(app: *App) void {
        var rounds: u32 = 0;
        while (app.effects.items.len > 0) : (rounds += 1) {
            if (rounds >= 1000) {
                if (!@import("builtin").is_test) std.log.scoped(.zg_gui).err("effect cycle: dropped {d} effects", .{app.effects.items.len});
                app.effect_cycle = true;
                app.effects.clearRetainingCapacity();
                break;
            }
            const eff = app.effects.orderedRemove(0);
            switch (eff) {
                .notify => |id| app.applyNotify(id),
                .emit => |em| {
                    var i: usize = 0;
                    while (i < app.subs.items.len) : (i += 1) {
                        const s = app.subs.items[i];
                        if (!s.alive or s.tag != em.tag or s.source.raw() != em.source.raw()) continue;
                        var cx: Context = .{ .app = app };
                        s.handler(s.ctx, em.payload, &cx);
                    }
                },
            }
        }
        if (app.effects.items.len == 0) {
            _ = app.effect_arena.reset(.retain_capacity);
            var k: usize = 0;
            while (k < app.subs.items.len) {
                if (!app.subs.items[k].alive) _ = app.subs.swapRemove(k) else k += 1;
            }
        }
    }

    /// Records that `r` rebuilds when `id` notifies.
    pub fn observe(app: *App, id: EntityId, r: ViewRef) !void {
        const gop = try app.observers.getOrPut(app.gpa, id.raw());
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |x| {
            if (x.win == r.win and x.view == r.view) return;
        }
        try gop.value_ptr.append(app.gpa, r);
    }

    /// Removes `r` from the observers of `id`.
    pub fn unobserve(app: *App, id: EntityId, r: ViewRef) void {
        const list = app.observers.getPtr(id.raw()) orelse return;
        var i: usize = 0;
        while (i < list.items.len) {
            if (list.items[i].win == r.win and list.items[i].view == r.view) _ = list.swapRemove(i) else i += 1;
        }
    }

    fn dropObserversOf(app: *App, w: *Window) void {
        var it = app.observers.valueIterator();
        while (it.next()) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i].win == w) _ = list.swapRemove(i) else i += 1;
            }
        }
    }

    /// Subscribes `handler(ctx, *const Ev, cx)` to events of type `Ev`
    /// emitted by entity `source`.
    pub fn subscribe(app: *App, comptime Ev: type, source: EntityId, ctx: *anyopaque, comptime handler: fn (*anyopaque, *const Ev, *Context) void) !Subscription {
        const Gen = struct {
            fn call(c: *anyopaque, p: *const anyopaque, cx: *Context) void {
                handler(c, @ptrCast(@alignCast(p)), cx);
            }
        };
        const id = app.next_sub;
        app.next_sub += 1;
        try app.subs.append(app.gpa, .{ .id = id, .source = source, .tag = ids.kindTag(Ev), .ctx = ctx, .handler = Gen.call });
        return .{ .id = id };
    }

    /// Switches every window to `t` (repaint only; layout when dimensions differ).
    pub fn setTheme(app: *App, t: *const theme_mod.Theme) void {
        const relayout = !std.mem.eql(f32, &app.theme.dims, &t.dims);
        app.theme = t;
        for (app.windows.items) |w| w.themeChanged(relayout);
    }

    /// Applies a desktop appearance change when `follow_system` is set.
    pub fn onAppearance(app: *App, a: zg_platform.event.Appearance) void {
        if (!app.follow_system) return;
        const want: theme_mod.Theme.Kind = switch (a.contrast) {
            .high => if (a.scheme == .light) .hc_light else .hc_dark,
            .normal => if (a.scheme == .light) .light else .dark,
        };
        for (theme_mod.builtins) |t| {
            if (t.kind == want) {
                if (t != app.theme) app.setTheme(t);
                return;
            }
        }
    }
};

/// The handle views and entity updates use for effects.
pub const Context = struct {
    app: *App,
    win: ?*Window = null,
    /// The view being built (0 = none).
    view: u16 = 0,
    /// The entity being updated (source of `emit`).
    entity: EntityId = .none,

    /// Rebuilds the current view: in this frame when called during input
    /// dispatch, in the next frame when called during build.
    pub fn notify(cx: *Context) void {
        if (cx.win) |w| {
            if (cx.view != 0) w.markViewDirty(cx.view);
        }
        if (!cx.entity.isNone()) cx.app.notifyEntity(cx.entity);
    }

    /// Rebuilds every view observing `id`.
    pub fn notifyEntity(cx: *Context, id: EntityId) void {
        cx.app.notifyEntity(id);
    }

    /// The current view rebuilds whenever `id` notifies. Observations are
    /// re-collected on every build.
    pub fn observe(cx: *Context, id: EntityId) void {
        const w = cx.win orelse return;
        if (cx.view == 0) return;
        w.recordObservation(cx.view, id);
    }

    /// Queues `ev` for subscribers of the current entity; delivered after
    /// the current phase.
    pub fn emit(cx: *Context, ev: anytype) void {
        const T = @TypeOf(ev);
        if (cx.entity.isNone()) return;
        const copy = cx.app.effect_arena.allocator().create(T) catch return;
        copy.* = ev;
        cx.app.effects.append(cx.app.gpa, .{ .emit = .{ .source = cx.entity, .tag = ids.kindTag(T), .payload = copy } }) catch {};
    }

    /// Runs `func(args)` on a worker; see `App.spawn`.
    pub fn spawn(cx: *Context, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) void {
        cx.app.spawn(func, args);
    }

    /// Asks for another frame (animation, polling).
    pub fn requestFrame(cx: *Context) void {
        if (cx.win) |w| w.needs_frame = true;
    }
};

test "update, notify and subscribe" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    const Counter = struct { n: u32 };
    const Bumped = struct { to: u32 };
    const c = try app.new(Counter, .{ .n = 0 });
    var seen: u32 = 0;
    const sub = try app.subscribe(Bumped, c.id, &seen, struct {
        fn h(ctx: *anyopaque, ev: *const Bumped, _: *Context) void {
            const s: *u32 = @ptrCast(@alignCast(ctx));
            s.* = ev.to;
        }
    }.h);
    app.update(Counter, c, struct {
        fn f(self: *Counter, cx: *Context) void {
            self.n += 1;
            cx.emit(Bumped{ .to = self.n });
            cx.notify();
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 1), c.read(&app).n);
    try std.testing.expectEqual(@as(u32, 1), seen);
    sub.drop(&app);
    app.update(Counter, c, struct {
        fn f(self: *Counter, cx: *Context) void {
            self.n += 1;
            cx.emit(Bumped{ .to = self.n });
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 1), seen);
}

test "effect cycle guard" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    const Ping = struct {};
    const e = try app.new(u8, 0);
    const Loop = struct {
        id: EntityId,
        fn h(ctx: *anyopaque, _: *const Ping, cx: *Context) void {
            const l: *@This() = @ptrCast(@alignCast(ctx));
            cx.entity = l.id;
            cx.emit(Ping{});
        }
    };
    var l: Loop = .{ .id = e.id };
    _ = try app.subscribe(Ping, e.id, &l, Loop.h);
    var cx: Context = .{ .app = &app, .entity = e.id };
    cx.emit(Ping{});
    app.flushEffects();
    try std.testing.expect(app.effect_cycle);
}

const Tally = struct {
    n: std.atomic.Value(u32) = .init(0),
    seen: u32 = 0,

    fn work(t: *Tally, app: *App) void {
        _ = t.n.fetchAdd(1, .monotonic);
        app.post(.{ .ctx = t, .f = done }) catch {};
    }

    fn done(ctx: *anyopaque, _: *App) void {
        const t: *Tally = @ptrCast(@alignCast(ctx));
        t.seen += 1;
    }
};

test "spawn and post without a runtime run inline and locally" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    var t: Tally = .{};
    app.spawn(Tally.work, .{ &t, &app });
    try std.testing.expectEqual(@as(u32, 1), t.n.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), t.seen);
    try std.testing.expectEqual(@as(usize, 1), app.drainMessages());
    try std.testing.expectEqual(@as(u32, 1), t.seen);
}

test "spawn with 1 000 concurrent tasks delivers all results" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    rt.bindUiThread(.noop);
    var app = App.init(std.testing.allocator);
    defer app.deinit();
    app.attachRuntime(&rt);
    var t: Tally = .{};
    for (0..1000) |_| app.spawn(Tally.work, .{ &t, &app });
    app.joinWork();
    while (app.drainMessages() > 0) {}
    try std.testing.expectEqual(@as(u32, 1000), t.n.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1000), t.seen);
}
