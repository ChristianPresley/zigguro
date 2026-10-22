//! The bounded multi-producer single-consumer command queue from app
//! threads to the platform thread (a Vyukov array queue with per-slot
//! sequence numbers). `push` deep-copies every slice in the command, so the
//! caller's buffers may be reused as soon as it returns; the platform thread
//! frees the copies with `release` after executing the command.

const std = @import("std");
const Command = @import("../api/window.zig").Command;

/// A bounded MPSC queue of `Command`s.
pub const CommandQueue = struct {
    /// Thread-safe allocator for command copies.
    gpa: std.mem.Allocator,
    /// The slots; the length is a power of two.
    slots: []Slot,
    /// Next position producers claim.
    enqueue_pos: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    /// Next position the consumer reads.
    dequeue_pos: usize align(std.atomic.cache_line) = 0,

    const Slot = struct {
        seq: std.atomic.Value(usize),
        cmd: Command,
    };

    /// Creates a queue for `capacity` commands (rounded up to a power of two).
    pub fn init(gpa: std.mem.Allocator, capacity: u32) std.mem.Allocator.Error!CommandQueue {
        const n = std.math.ceilPowerOfTwoAssert(usize, @max(capacity, 2));
        const slots = try gpa.alloc(Slot, n);
        for (slots, 0..) |*s, i| s.* = .{ .seq = .init(i), .cmd = undefined };
        return .{ .gpa = gpa, .slots = slots };
    }

    /// Frees the slots and any commands still queued.
    pub fn deinit(self: *CommandQueue) void {
        var buf: [16]Command = undefined;
        while (true) {
            const n = self.drain(&buf);
            if (n == 0) break;
            for (buf[0..n]) |c| self.release(c);
        }
        self.gpa.free(self.slots);
        self.* = undefined;
    }

    /// Copies `cmd` and queues it. Any thread; never blocks.
    pub fn push(self: *CommandQueue, cmd: Command) error{ Full, OutOfMemory }!void {
        const copy = try clone(Command, self.gpa, cmd);
        errdefer free(Command, self.gpa, copy);
        const mask = self.slots.len - 1;
        var pos = self.enqueue_pos.load(.monotonic);
        while (true) {
            const slot = &self.slots[pos & mask];
            const seq = slot.seq.load(.acquire);
            const dif = @as(isize, @bitCast(seq -% pos));
            if (dif == 0) {
                if (self.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                    continue;
                }
                slot.cmd = copy;
                slot.seq.store(pos +% 1, .release);
                return;
            } else if (dif < 0) {
                return error.Full;
            } else {
                pos = self.enqueue_pos.load(.monotonic);
            }
        }
    }

    /// Moves up to `out.len` queued commands into `out`; returns how many.
    /// Platform thread only. Pass each one to `release` after executing it.
    pub fn drain(self: *CommandQueue, out: []Command) usize {
        const mask = self.slots.len - 1;
        var n: usize = 0;
        while (n < out.len) : (n += 1) {
            const pos = self.dequeue_pos;
            const slot = &self.slots[pos & mask];
            if (slot.seq.load(.acquire) != pos +% 1) break;
            out[n] = slot.cmd;
            slot.seq.store(pos +% self.slots.len, .release);
            self.dequeue_pos = pos +% 1;
        }
        return n;
    }

    /// Frees the copies made by `push` for a drained command.
    pub fn release(self: *CommandQueue, cmd: Command) void {
        free(Command, self.gpa, cmd);
    }
};

/// Deep-copies every slice reachable from `v`. Other pointers (callbacks,
/// contexts) are copied as they are.
fn clone(comptime T: type, gpa: std.mem.Allocator, v: T) std.mem.Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return v;
            const out = try gpa.alloc(p.child, v.len);
            var done: usize = 0;
            errdefer {
                for (out[0..done]) |e| free(p.child, gpa, e);
                gpa.free(out);
            }
            for (v, 0..) |e, i| {
                out[i] = try clone(p.child, gpa, e);
                done = i + 1;
            }
            return out;
        },
        .optional => |o| return if (v) |x| try clone(o.child, gpa, x) else null,
        .@"struct" => |s| {
            var out: T = v;
            inline for (s.fields, 0..) |f, i| {
                errdefer inline for (s.fields[0..i]) |g| free(g.type, gpa, @field(out, g.name));
                @field(out, f.name) = try clone(f.type, gpa, @field(v, f.name));
            }
            return out;
        },
        .@"union" => switch (v) {
            inline else => |payload, tag| return @unionInit(T, @tagName(tag), try clone(@TypeOf(payload), gpa, payload)),
        },
        else => return v,
    }
}

fn free(comptime T: type, gpa: std.mem.Allocator, v: T) void {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) return;
            for (v) |e| free(p.child, gpa, e);
            gpa.free(v);
        },
        .optional => |o| if (v) |x| free(o.child, gpa, x),
        .@"struct" => |s| inline for (s.fields) |f| free(f.type, gpa, @field(v, f.name)),
        .@"union" => switch (v) {
            inline else => |payload| free(@TypeOf(payload), gpa, payload),
        },
        else => {},
    }
}

const testing = std.testing;

test "push copies slices and release frees them" {
    var q = try CommandQueue.init(testing.allocator, 4);
    defer q.deinit();
    var title = "hello".*;
    try q.push(.{ .set_title = .{ .win = @enumFromInt(1), .title = &title } });
    title[0] = 'j';
    const pats = [_][]const u8{ "*.zig", "*.zon" };
    const filters = [_]@import("../api/dialog.zig").DialogFilter{.{ .name = "Zig", .patterns = &pats }};
    try q.push(.{ .open_dialog = .{ .request = 3, .kind = .open_file, .default_path = "/tmp", .filters = &filters } });
    try q.push(.{ .clipboard_write = .{ .which = .clipboard, .items = &.{.{ .mime = .text_utf8, .data = "clip" }} } });
    var out: [8]Command = undefined;
    const n = q.drain(&out);
    try testing.expectEqual(3, n);
    try testing.expectEqualStrings("hello", out[0].set_title.title);
    try testing.expect(out[1].open_dialog.filters.ptr != &filters);
    try testing.expectEqualStrings("*.zon", out[1].open_dialog.filters[0].patterns[1]);
    try testing.expectEqualStrings("/tmp", out[1].open_dialog.default_path.?);
    try testing.expectEqualStrings("clip", out[2].clipboard_write.items[0].data);
    for (out[0..n]) |c| q.release(c);
}

test "full queue reports Full and frees the copy" {
    var q = try CommandQueue.init(testing.allocator, 2);
    defer q.deinit();
    try q.push(.{ .open_uri = "a" });
    try q.push(.{ .open_uri = "b" });
    try testing.expectError(error.Full, q.push(.{ .open_uri = "c" }));
    var out: [1]Command = undefined;
    try testing.expectEqual(1, q.drain(&out));
    q.release(out[0]);
    try q.push(.{ .open_uri = "c" });
}

test "clone frees partial copies on allocation failure" {
    const pats = [_][]const u8{ "*.a", "*.b", "*.c" };
    const filters = [_]@import("../api/dialog.zig").DialogFilter{ .{ .name = "A", .patterns = &pats }, .{ .name = "B", .patterns = &pats } };
    const cmd: Command = .{ .open_dialog = .{ .request = 1, .kind = .open_files, .title = "t", .filters = &filters } };
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(a: std.mem.Allocator, c: Command) !void {
            const copy = try clone(Command, a, c);
            free(Command, a, copy);
        }
    }.f, .{cmd});
}

test "mpsc 8 producers" {
    const per = 20_000;
    const producers = 8;
    var q = try CommandQueue.init(std.heap.smp_allocator, 256);
    defer q.deinit();
    const P = struct {
        fn run(queue: *CommandQueue, id: u32) void {
            var i: u32 = 0;
            while (i < per) {
                queue.push(.{ .request_frame = @enumFromInt(id * per + i) }) catch |err| switch (err) {
                    error.Full => {
                        std.atomic.spinLoopHint();
                        continue;
                    },
                    error.OutOfMemory => @panic("oom"),
                };
                i += 1;
            }
        }
    };
    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, id| t.* = try std.Thread.spawn(.{}, P.run, .{ &q, @as(u32, @intCast(id)) });
    var next = [_]u32{0} ** producers;
    var got: usize = 0;
    var out: [64]Command = undefined;
    while (got < per * producers) {
        const n = q.drain(&out);
        for (out[0..n]) |c| {
            const v: u32 = @intFromEnum(c.request_frame);
            const id = v / per;
            // Each producer's commands arrive in its own order.
            try testing.expectEqual(next[id], v % per);
            next[id] += 1;
        }
        got += n;
    }
    for (threads) |t| t.join();
}
