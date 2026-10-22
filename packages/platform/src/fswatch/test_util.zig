//! Helpers shared by the platform watchers' behavioural tests.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const api = @import("api.zig");
const FsEvent = api.FsEvent;
const RootId = api.RootId;

/// Events collected across batches, with their paths copied.
pub const Seen = struct {
    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    list: std.ArrayList(FsEvent) = .empty,

    /// Frees the copies.
    pub fn deinit(s: *Seen) void {
        s.arena.deinit();
    }

    /// Whether an event of `kind` for `path` was seen.
    pub fn has(s: *const Seen, kind: FsEvent.Kind, path: []const u8) bool {
        for (s.list.items) |e| if (e.kind == kind and std.mem.eql(u8, e.path, path)) return true;
        return false;
    }

    /// Whether any event for `path` was seen.
    pub fn hasPath(s: *const Seen, path: []const u8) bool {
        for (s.list.items) |e| if (std.mem.eql(u8, e.path, path)) return true;
        return false;
    }
};

/// Collects batches until `want` is satisfied or 3 s pass.
pub fn collect(w: *api.Watcher, s: *Seen, comptime want: fn (*const Seen) bool) !void {
    var out: [256]FsEvent = undefined;
    var rounds: u32 = 0;
    while (!want(s)) : (rounds += 1) {
        if (rounds > 300) return error.Timeout;
        _ = w.wait(10 * std.time.ns_per_ms);
        const n = w.poll(&out);
        const a = s.arena.allocator();
        for (out[0..n]) |e| {
            var c = e;
            c.path = try a.dupe(u8, e.path);
            if (e.old_path) |o| c.old_path = try a.dupe(u8, o);
            try s.list.append(a, c);
        }
    }
}

/// A temporary directory watched as one root.
pub const Fixture = struct {
    tmp: testing.TmpDir,
    abs: []u8,
    w: api.Watcher,
    root: RootId,

    /// Creates the directory, runs `setup` in it, then starts watching.
    pub fn init(filter: *const api.IgnoreFilter, setup: ?*const fn (Io.Dir) anyerror!void) !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        if (setup) |f| try f(tmp.dir);
        var buf: [4096]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);
        const abs = try testing.allocator.dupe(u8, buf[0..n]);
        errdefer testing.allocator.free(abs);
        var w = try api.Watcher.init(testing.allocator, testing.io, .{ .debounce_ms = 5 });
        errdefer w.deinit();
        const root = try w.addRoot(abs, filter);
        return .{ .tmp = tmp, .abs = abs, .w = w, .root = root };
    }

    /// Stops the watcher and deletes the directory.
    pub fn deinit(f: *Fixture) void {
        f.w.deinit();
        testing.allocator.free(f.abs);
        f.tmp.cleanup();
    }
};
