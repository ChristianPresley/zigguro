//! `Lazy(T)` (E14.F05.S01.T02): thread-safe init on first use, the
//! replacement for `std.once` (gone in 0.16). The fast path is one
//! acquire load; the first `get` runs the init function inside the trace
//! zone `init.<name>` under a mutex. A failed init stays failed unless
//! `retry` is set. On the UI thread, use `peek` and `getAsync` for values
//! whose init blocks.

const std = @import("std");
const zg_core = @import("zg_core");

const uninit = 0;
const initialising = 1;
const ready = 2;
const failed = 3;

pub fn Lazy(comptime T: type) type {
    return struct {
        const Self = @This();

        state: std.atomic.Value(u8) = .init(uninit),
        value: T = undefined,
        mutex: std.Io.Mutex = .init,
        err: anyerror = error.Unexpected,
        /// After a failed init, the next `get` tries again.
        retry: bool = false,

        /// The value, running `initFn(args...)` (returning `T` or `!T`)
        /// the first time.
        pub inline fn get(self: *Self, io: std.Io, comptime name: []const u8, initFn: anytype, args: anytype) !*T {
            if (self.state.load(.acquire) == ready) return &self.value;
            return self.slow(io, name, initFn, args);
        }

        noinline fn slow(self: *Self, io: std.Io, comptime name: []const u8, initFn: anytype, args: anytype) !*T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            switch (self.state.load(.acquire)) {
                ready => return &self.value,
                failed => if (!self.retry) return self.err,
                else => {},
            }
            self.state.store(initialising, .monotonic);
            const zone = zg_core.trace.zone(@src(), "init." ++ name);
            defer zone.end();
            const r = @call(.auto, initFn, args);
            self.value = if (@typeInfo(@TypeOf(r)) == .error_union) r catch |e| {
                self.err = e;
                self.state.store(failed, .release);
                return e;
            } else r;
            self.state.store(ready, .release);
            return &self.value;
        }

        /// The value if it is ready; never blocks.
        pub fn peek(self: *Self) ?*T {
            return if (self.state.load(.acquire) == ready) &self.value else null;
        }

        /// Starts the init on `group` (a worker) unless it ran; read the
        /// result later with `peek`.
        pub fn getAsync(self: *Self, io: std.Io, group: *std.Io.Group, comptime name: []const u8, initFn: anytype, args: anytype) void {
            if (self.state.load(.acquire) != uninit) return;
            const Task = struct {
                fn run(s: *Self, i: std.Io, a: @TypeOf(args)) std.Io.Cancelable!void {
                    _ = s.get(i, name, initFn, a) catch {};
                }
            };
            group.concurrent(io, Task.run, .{ self, io, args }) catch {
                _ = self.get(io, name, initFn, args) catch {};
            };
        }
    };
}

test "lazy: concurrent get initialises once" {
    const io = std.testing.io;
    const S = struct {
        var calls: std.atomic.Value(u32) = .init(0);
        fn make(v: u32) u32 {
            _ = calls.fetchAdd(1, .monotonic);
            return v * 2;
        }
        fn worker(l: *Lazy(u32), out: *u32) void {
            out.* = (l.get(std.testing.io, "test", make, .{21}) catch unreachable).*;
        }
    };
    S.calls.store(0, .monotonic);
    var l: Lazy(u32) = .{};
    var outs: [16]u32 = @splat(0);
    var threads: [16]std.Thread = undefined;
    for (&threads, &outs) |*t, *o| t.* = try std.Thread.spawn(.{}, S.worker, .{ &l, o });
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u32, 1), S.calls.load(.monotonic));
    for (outs) |o| try std.testing.expectEqual(@as(u32, 42), o);
    _ = io;
}

test "lazy: error then retry" {
    const io = std.testing.io;
    const S = struct {
        var fail = true;
        fn make() !u8 {
            if (fail) return error.NotYet;
            return 7;
        }
    };
    S.fail = true;
    var l: Lazy(u8) = .{};
    try std.testing.expectError(error.NotYet, l.get(io, "t", S.make, .{}));
    S.fail = false;
    // Without retry the failure sticks.
    try std.testing.expectError(error.NotYet, l.get(io, "t", S.make, .{}));
    l.retry = true;
    try std.testing.expectEqual(@as(u8, 7), (try l.get(io, "t", S.make, .{})).*);
}

test "lazy: peek null until ready" {
    const io = std.testing.io;
    const S = struct {
        fn make() u16 {
            std.Io.sleep(std.testing.io, .fromMilliseconds(20), .awake) catch {};
            return 5;
        }
    };
    var l: Lazy(u16) = .{};
    try std.testing.expect(l.peek() == null);
    var group: std.Io.Group = .init;
    l.getAsync(io, &group, "t", S.make, .{});
    group.await(io) catch {};
    try std.testing.expectEqual(@as(u16, 5), l.peek().?.*);
}
