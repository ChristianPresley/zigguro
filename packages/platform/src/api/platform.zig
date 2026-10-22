//! The `Platform` interface: one per process, owning the platform thread,
//! every window and the event and command queues. Backends implement it;
//! the app starts one with `zg_platform.init`.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const window = @import("window.zig");
const event = @import("event.zig");
const surface = @import("surface.zig");
const native_mod = @import("native.zig");

const WindowId = types.WindowId;
const PayloadSlice = types.PayloadSlice;

/// The windowing backends.
pub const Backend = enum(u8) {
    /// Windows (user32 / DWM).
    win32,
    /// Wayland, through our own wire client.
    wayland,
    /// X11, through our own wire client.
    x11,
    /// No display; frames go to a `HeadlessSink`. Used by tests.
    headless,
    /// macOS (later).
    cocoa,
};

/// Errors from `Platform` calls.
pub const Error = error{
    /// The requested backend is not available on this OS or build, or it
    /// could not connect to the display.
    BackendUnavailable,
    /// The window id does not name a live window.
    InvalidWindow,
    /// The backend does not support the request.
    Unsupported,
    /// The command queue is full; try again after the next frame.
    QueueFull,
    /// The OS refused a resource (handles, shared memory, threads).
    SystemResources,
    /// Allocation failed.
    OutOfMemory,
};

/// Options for `init`.
pub const InitOptions = struct {
    /// Force a backend; null selects one with `detectBackend`.
    backend: ?Backend = null,
    /// The process environment (`init.environ_map` from `main`), read for
    /// `ZG_PLATFORM`, `WAYLAND_DISPLAY`, `DISPLAY` and theme settings. The
    /// Wayland backend removes `WAYLAND_SOCKET` once it has used it.
    environ_map: ?*std.process.Environ.Map = null,
    /// Default application id for new windows.
    app_id: []const u8 = "dev.zigguro.zigguro",
    /// Event ring capacity; rounded up to a power of two.
    event_capacity: u32 = 4096,
    /// Also report unaccelerated mouse motion as `Event.pointer_relative`
    /// (for panning and similar features). Win32 only; off by default.
    raw_mouse: bool = false,
};

/// A running platform backend, as a type-erased interface.
pub const Platform = struct {
    /// Backend state.
    ptr: *anyopaque,
    /// Backend functions.
    vtable: *const VTable,

    /// The functions every backend implements.
    pub const VTable = struct {
        /// Creates a window; it appears after the first present.
        createWindow: *const fn (*anyopaque, window.WindowOptions) Error!WindowId,
        /// Destroys a window. Pending events for it are still delivered.
        destroyWindow: *const fn (*anyopaque, WindowId) void,
        /// Queues a command for the platform thread. Non-blocking; any thread.
        submit: *const fn (*anyopaque, window.Command) Error!void,
        /// Where E02 renders the window.
        surfaceTarget: *const fn (*anyopaque, WindowId) Error!surface.SurfaceTarget,
        /// A CPU-buffer presenter for E02's software renderer, on every backend.
        cpuPresenter: *const fn (*anyopaque, WindowId) Error!*surface.Presenter,
        /// Native integration hooks.
        native: *const fn (*anyopaque) *const native_mod.NativeHooks,
        /// The bytes of a payload from an event. Arena slices stay valid until
        /// the next `pollEvents`; large ones until `release`.
        payload: *const fn (*anyopaque, PayloadSlice) []const u8,
        /// Frees a large payload (`PayloadSlice.large`).
        release: *const fn (*anyopaque, PayloadSlice) void,
        /// Writes up to `out.len` monitors and returns the total count.
        monitors: *const fn (*anyopaque, out: []types.MonitorInfo) usize,
        /// Moves pending events into `out`; returns the count. UI thread
        /// only; never blocks. Payloads from the previous call become invalid.
        pollEvents: *const fn (*anyopaque, out: []event.Event) usize,
        /// Blocks until an event is pending, `wake` is called, or the
        /// monotonic clock reaches `deadline_ns`. UI thread only.
        waitEvents: *const fn (*anyopaque, deadline_ns: ?u64) void,
        /// Wakes `waitEvents` and queues `Event.wake`. Any thread.
        wake: *const fn (*anyopaque) void,
        /// Closes every window, stops the platform thread and frees all memory.
        deinit: *const fn (*anyopaque) void,
    };

    /// See `VTable.createWindow`.
    pub fn createWindow(p: Platform, opts: window.WindowOptions) Error!WindowId {
        return p.vtable.createWindow(p.ptr, opts);
    }
    /// See `VTable.destroyWindow`.
    pub fn destroyWindow(p: Platform, win: WindowId) void {
        p.vtable.destroyWindow(p.ptr, win);
    }
    /// See `VTable.submit`.
    pub fn submit(p: Platform, cmd: window.Command) Error!void {
        return p.vtable.submit(p.ptr, cmd);
    }
    /// See `VTable.surfaceTarget`.
    pub fn surfaceTarget(p: Platform, win: WindowId) Error!surface.SurfaceTarget {
        return p.vtable.surfaceTarget(p.ptr, win);
    }
    /// See `VTable.cpuPresenter`.
    pub fn cpuPresenter(p: Platform, win: WindowId) Error!*surface.Presenter {
        return p.vtable.cpuPresenter(p.ptr, win);
    }
    /// See `VTable.native`.
    pub fn native(p: Platform) *const native_mod.NativeHooks {
        return p.vtable.native(p.ptr);
    }
    /// See `VTable.payload`.
    pub fn payload(p: Platform, s: PayloadSlice) []const u8 {
        return p.vtable.payload(p.ptr, s);
    }
    /// See `VTable.release`.
    pub fn release(p: Platform, s: PayloadSlice) void {
        p.vtable.release(p.ptr, s);
    }
    /// See `VTable.monitors`.
    pub fn monitors(p: Platform, out: []types.MonitorInfo) usize {
        return p.vtable.monitors(p.ptr, out);
    }
    /// See `VTable.pollEvents`.
    pub fn pollEvents(p: Platform, out: []event.Event) usize {
        return p.vtable.pollEvents(p.ptr, out);
    }
    /// See `VTable.waitEvents`.
    pub fn waitEvents(p: Platform, deadline_ns: ?u64) void {
        p.vtable.waitEvents(p.ptr, deadline_ns);
    }
    /// See `VTable.wake`.
    pub fn wake(p: Platform) void {
        p.vtable.wake(p.ptr);
    }
    /// See `VTable.deinit`.
    pub fn deinit(p: Platform) void {
        p.vtable.deinit(p.ptr);
    }

    /// Wraps a concrete backend `T` whose methods match `VTable` with
    /// `*T` in place of `*anyopaque`. The vtable is built at comptime, so a
    /// build pinned to one backend (`-Dplatform-backend=`) can call `T`
    /// directly and a dynamic build pays one indirect call.
    pub fn fromImpl(comptime T: type, impl: *T) Platform {
        return .{ .ptr = impl, .vtable = &Erased(T).vtable };
    }
};

fn Erased(comptime T: type) type {
    return struct {
        const vtable: Platform.VTable = blk: {
            var v: Platform.VTable = undefined;
            for (@typeInfo(Platform.VTable).@"struct".fields) |f| {
                @field(v, f.name) = thunk(f.name, f.type);
            }
            break :blk v;
        };

        fn thunk(comptime name: []const u8, comptime F: type) F {
            const Fn = @typeInfo(@typeInfo(F).pointer.child).@"fn";
            const method = @field(T, name);
            const R = Fn.return_type.?;
            return switch (Fn.params.len) {
                1 => struct {
                    fn f(ptr: *anyopaque) R {
                        return method(@as(*T, @ptrCast(@alignCast(ptr))));
                    }
                }.f,
                2 => struct {
                    fn f(ptr: *anyopaque, a: Fn.params[1].type.?) R {
                        return method(@as(*T, @ptrCast(@alignCast(ptr))), a);
                    }
                }.f,
                else => @compileError("Platform.VTable entry with unexpected arity: " ++ name),
            };
        }
    };
}

/// Picks the backend for this process from the environment: `ZG_PLATFORM`
/// (`win32`, `wayland`, `x11`, `headless`), then Windows → win32, a
/// non-empty `WAYLAND_DISPLAY` → wayland, a non-empty `DISPLAY` → x11, else
/// headless. An unknown `ZG_PLATFORM` value is ignored.
pub fn detectBackend(env: *const std.process.Environ.Map) Backend {
    return detectBackendFor(builtin.os.tag, env);
}

/// `detectBackend` for an arbitrary OS, so the rules are testable anywhere.
pub fn detectBackendFor(os: std.Target.Os.Tag, env: *const std.process.Environ.Map) Backend {
    if (env.get("ZG_PLATFORM")) |v| {
        if (std.meta.stringToEnum(Backend, v)) |b| return b;
    }
    if (os == .windows) return .win32;
    if (os == .macos) return .cocoa;
    if (nonEmpty(env.get("WAYLAND_DISPLAY"))) return .wayland;
    if (nonEmpty(env.get("DISPLAY"))) return .x11;
    return .headless;
}

fn nonEmpty(v: ?[]const u8) bool {
    return if (v) |s| s.len > 0 else false;
}

/// Whether the backend was chosen explicitly, by `opts.backend` or a
/// valid `ZG_PLATFORM`, so `init` must not fall back to another one.
pub fn isForced(opts: InitOptions) bool {
    if (opts.backend != null) return true;
    const env = opts.environ_map orelse return false;
    const v = env.get("ZG_PLATFORM") orelse return false;
    return std.meta.stringToEnum(Backend, v) != null;
}

/// The backend `init` will try first: `opts.backend`, else `detectBackend`
/// on `opts.environ_map` (headless when no map is given).
pub fn selectBackend(opts: InitOptions) Backend {
    if (opts.backend) |b| return b;
    const env = opts.environ_map orelse return .headless;
    return detectBackend(env);
}

test "detectBackend table" {
    const a = std.testing.allocator;
    const Case = struct {
        os: std.Target.Os.Tag,
        vars: []const [2][]const u8,
        want: Backend,
    };
    const cases = [_]Case{
        .{ .os = .linux, .vars = &.{}, .want = .headless },
        .{ .os = .linux, .vars = &.{.{ "DISPLAY", ":0" }}, .want = .x11 },
        .{ .os = .linux, .vars = &.{ .{ "DISPLAY", ":0" }, .{ "WAYLAND_DISPLAY", "wayland-0" } }, .want = .wayland },
        .{ .os = .linux, .vars = &.{ .{ "DISPLAY", ":0" }, .{ "WAYLAND_DISPLAY", "" } }, .want = .x11 },
        .{ .os = .linux, .vars = &.{.{ "DISPLAY", "" }}, .want = .headless },
        .{ .os = .linux, .vars = &.{ .{ "WAYLAND_DISPLAY", "wayland-0" }, .{ "ZG_PLATFORM", "x11" } }, .want = .x11 },
        .{ .os = .linux, .vars = &.{ .{ "WAYLAND_DISPLAY", "wayland-0" }, .{ "ZG_PLATFORM", "headless" } }, .want = .headless },
        .{ .os = .linux, .vars = &.{ .{ "WAYLAND_DISPLAY", "wayland-0" }, .{ "ZG_PLATFORM", "bogus" } }, .want = .wayland },
        .{ .os = .freebsd, .vars = &.{.{ "DISPLAY", ":1" }}, .want = .x11 },
        .{ .os = .windows, .vars = &.{.{ "DISPLAY", ":0" }}, .want = .win32 },
        .{ .os = .windows, .vars = &.{.{ "ZG_PLATFORM", "headless" }}, .want = .headless },
        .{ .os = .macos, .vars = &.{}, .want = .cocoa },
    };
    for (cases) |c| {
        var env: std.process.Environ.Map = .init(a);
        defer env.deinit();
        for (c.vars) |kv| try env.put(kv[0], kv[1]);
        try std.testing.expectEqual(c.want, detectBackendFor(c.os, &env));
    }
}

test "selectBackend prefers the explicit option" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZG_PLATFORM", "x11");
    try std.testing.expectEqual(Backend.wayland, selectBackend(.{ .backend = .wayland, .environ_map = &env }));
    try std.testing.expectEqual(Backend.headless, selectBackend(.{}));
    try std.testing.expect(isForced(.{ .environ_map = &env }));
    try env.put("ZG_PLATFORM", "bogus");
    try std.testing.expect(!isForced(.{ .environ_map = &env }));
    try std.testing.expect(isForced(.{ .backend = .x11 }));
}

test "fromImpl dispatches to the concrete type" {
    const Fake = struct {
        created: u32 = 0,
        woken: bool = false,
        hooks: native_mod.NativeHooks = undefined,

        fn createWindow(self: *@This(), _: window.WindowOptions) Error!WindowId {
            self.created += 1;
            return @enumFromInt(self.created);
        }
        fn destroyWindow(_: *@This(), _: WindowId) void {}
        fn submit(_: *@This(), _: window.Command) Error!void {
            return error.QueueFull;
        }
        fn surfaceTarget(_: *@This(), _: WindowId) Error!surface.SurfaceTarget {
            return error.Unsupported;
        }
        fn cpuPresenter(_: *@This(), _: WindowId) Error!*surface.Presenter {
            return error.Unsupported;
        }
        fn native(self: *@This()) *const native_mod.NativeHooks {
            return &self.hooks;
        }
        fn payload(_: *@This(), _: PayloadSlice) []const u8 {
            return "";
        }
        fn release(_: *@This(), _: PayloadSlice) void {}
        fn monitors(_: *@This(), _: []types.MonitorInfo) usize {
            return 0;
        }
        fn pollEvents(self: *@This(), out: []event.Event) usize {
            if (!self.woken or out.len == 0) return 0;
            out[0] = .wake;
            self.woken = false;
            return 1;
        }
        fn waitEvents(_: *@This(), _: ?u64) void {}
        fn wake(self: *@This()) void {
            self.woken = true;
        }
        fn deinit(_: *@This()) void {}
    };
    var fake: Fake = .{};
    const p = Platform.fromImpl(Fake, &fake);
    try std.testing.expectEqual(@as(WindowId, @enumFromInt(1)), try p.createWindow(.{ .title = "t", .size = .{ .w = 1, .h = 1 } }));
    try std.testing.expectError(error.QueueFull, p.submit(.{ .request_frame = @enumFromInt(1) }));
    try std.testing.expectEqual(&fake.hooks, p.native());
    var evs: [4]event.Event = undefined;
    try std.testing.expectEqual(0, p.pollEvents(&evs));
    p.wake();
    try std.testing.expectEqual(1, p.pollEvents(&evs));
    try std.testing.expect(evs[0] == .wake);
}
