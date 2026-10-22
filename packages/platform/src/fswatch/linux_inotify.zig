//! The Linux watcher: one inotify watch per directory, maintained as the
//! tree changes, read on a dedicated thread and fed through the coalescer.

const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;
const api = @import("api.zig");
const Coalescer = @import("coalesce.zig").Coalescer;
const isUnder = @import("coalesce.zig").isUnder;
const Wake = @import("../queue/wake.zig").Wake;
const NativeHandle = @import("../queue/wake.zig").NativeHandle;

const FsEvent = api.FsEvent;
const RootId = api.RootId;

const watch_mask: u32 = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY | linux.IN.CLOSE_WRITE |
    linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF |
    linux.IN.ONLYDIR | linux.IN.EXCL_UNLINK;

/// How long an unmatched `IN_MOVED_FROM` waits for its `IN_MOVED_TO`.
const move_pair_ns: u64 = 10 * std.time.ns_per_ms;

const Dir = struct { root: RootId, rel: []u8 };
const Root = struct { abs: []u8, filter: *const api.IgnoreFilter, wd: i32 };
const PendingMove = struct { root: RootId, path: []u8, is_dir: bool, at_ns: u64, wd: ?i32 };

/// The inotify watcher state behind `api.Watcher`.
pub const Inotify = struct {
    gpa: std.mem.Allocator,
    io: Io,
    opts: api.WatchOptions,
    fd: i32,
    thread: std.Thread = undefined,
    stop: Wake,
    ready_wake: Wake,
    mutex: Io.Mutex = .init,
    dirs: std.AutoHashMapUnmanaged(i32, Dir) = .empty,
    roots: std.AutoArrayHashMapUnmanaged(u32, Root) = .empty,
    next_root: u32 = 0,
    // Reader-thread state.
    coalescer: Coalescer,
    moves: std.AutoHashMapUnmanaged(u32, PendingMove) = .empty,
    // Shared ready batch (mutex).
    ready: std.ArrayList(FsEvent) = .empty,
    ready_arena: std.heap.ArenaAllocator,
    delivered_arena: std.heap.ArenaAllocator,

    /// Creates the inotify instance and starts the reader thread.
    pub fn init(gpa: std.mem.Allocator, io: Io, opts: api.WatchOptions) api.Error!*Inotify {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        const self = try gpa.create(Inotify);
        errdefer gpa.destroy(self);
        var stop = Wake.init(io) catch return error.SystemResources;
        errdefer stop.deinit();
        var ready_wake = Wake.init(io) catch return error.SystemResources;
        errdefer ready_wake.deinit();
        self.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .fd = fd,
            .stop = stop,
            .ready_wake = ready_wake,
            .coalescer = .init(gpa, opts.debounce_ms),
            .ready_arena = .init(gpa),
            .delivered_arena = .init(gpa),
        };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return error.SystemResources;
        return self;
    }

    /// Stops the thread and frees all state.
    pub fn deinit(self: *Inotify) void {
        self.stop.signal();
        self.thread.join();
        const gpa = self.gpa;
        var it = self.dirs.valueIterator();
        while (it.next()) |d| gpa.free(d.rel);
        self.dirs.deinit(gpa);
        for (self.roots.values()) |r| gpa.free(r.abs);
        self.roots.deinit(gpa);
        var mit = self.moves.valueIterator();
        while (mit.next()) |m| gpa.free(m.path);
        self.moves.deinit(gpa);
        self.coalescer.deinit();
        self.ready.deinit(gpa);
        self.ready_arena.deinit();
        self.delivered_arena.deinit();
        _ = linux.close(self.fd);
        self.stop.deinit();
        self.ready_wake.deinit();
        gpa.destroy(self);
    }

    /// See `api.Watcher.addRoot`.
    pub fn addRoot(self: *Inotify, root: []const u8, filter: *const api.IgnoreFilter) api.Error!RootId {
        const abs = try self.gpa.dupe(u8, std.mem.trimEnd(u8, root, "/"));
        errdefer self.gpa.free(abs);
        self.lock();
        defer self.unlock();
        const id: RootId = @enumFromInt(self.next_root);
        const wd = self.addWatch(id, abs, "") catch |e| return switch (e) {
            error.WatchLimit => error.WatchLimit,
            error.NotFound => error.NotFound,
            else => error.SystemResources,
        };
        try self.roots.put(self.gpa, self.next_root, .{ .abs = abs, .filter = filter, .wd = wd });
        self.next_root += 1;
        var lost = false;
        self.scanTree(id, "", null, &lost) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (lost) try self.publishLocked(&.{.{ .root = id, .kind = .rescan_required, .path = "", .is_dir = true, .reason = .watch_limit }});
        return id;
    }

    /// See `api.Watcher.removeRoot`.
    pub fn removeRoot(self: *Inotify, id: RootId) void {
        self.lock();
        defer self.unlock();
        const kv = self.roots.fetchSwapRemove(@intFromEnum(id)) orelse return;
        self.gpa.free(kv.value.abs);
        var doomed: std.ArrayList(i32) = .empty;
        defer doomed.deinit(self.gpa);
        var it = self.dirs.iterator();
        while (it.next()) |e| if (e.value_ptr.root == id) doomed.append(self.gpa, e.key_ptr.*) catch {};
        for (doomed.items) |wd| self.dropWatch(wd, true);
    }

    /// See `api.Watcher.poll`.
    pub fn poll(self: *Inotify, out: []FsEvent) usize {
        self.lock();
        defer self.unlock();
        _ = self.delivered_arena.reset(.retain_capacity);
        const a = self.delivered_arena.allocator();
        var n: usize = 0;
        while (n < out.len and n < self.ready.items.len) : (n += 1) {
            const e = self.ready.items[n];
            out[n] = e;
            out[n].path = a.dupe(u8, e.path) catch break;
            if (e.old_path) |o| out[n].old_path = a.dupe(u8, o) catch break;
        }
        self.ready.replaceRangeAssumeCapacity(0, n, &.{});
        if (self.ready.items.len == 0) {
            self.ready.clearRetainingCapacity();
            _ = self.ready_arena.reset(.retain_capacity);
            self.ready_wake.consume();
        }
        return n;
    }

    /// See `api.Watcher.waitHandle`.
    pub fn waitHandle(self: *Inotify) NativeHandle {
        return self.ready_wake.handle();
    }

    /// See `api.Watcher.wait`.
    pub fn wait(self: *Inotify, timeout_ns: ?u64) bool {
        return self.ready_wake.wait(timeout_ns);
    }

    /// See `api.Watcher.limits`.
    pub fn limits(self: *Inotify) api.Limits {
        self.lock();
        const used = self.dirs.count();
        self.unlock();
        return .{ .max_user_watches = readProcU64("/proc/sys/fs/inotify/max_user_watches"), .watches_in_use = used };
    }

    fn lock(self: *Inotify) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Inotify) void {
        self.mutex.unlock(self.io);
    }

    // ---- watch management (mutex held) ----

    fn absPath(self: *Inotify, root: RootId, rel: []const u8, buf: []u8) ?[:0]const u8 {
        const r = self.roots.get(@intFromEnum(root)) orelse return null;
        return pathZ(buf, r.abs, rel);
    }

    fn addWatch(self: *Inotify, root: RootId, abs_root: []const u8, rel: []const u8) error{ WatchLimit, NotFound, SystemResources, OutOfMemory }!i32 {
        var buf: [4096]u8 = undefined;
        const p = pathZ(&buf, abs_root, rel) orelse return error.SystemResources;
        var rc = linux.inotify_add_watch(self.fd, p, watch_mask | linux.IN.MASK_CREATE);
        if (linux.errno(rc) == .INVAL) rc = linux.inotify_add_watch(self.fd, p, watch_mask);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            // MASK_CREATE: this directory is already watched (hard link or
            // a rename we already followed). Keep the existing mapping.
            .EXIST => {
                const again = linux.inotify_add_watch(self.fd, p, watch_mask);
                if (linux.errno(again) != .SUCCESS) return error.SystemResources;
                return @intCast(again);
            },
            .NOSPC => return error.WatchLimit,
            .NOENT, .NOTDIR => return error.NotFound,
            else => return error.SystemResources,
        }
        const wd: i32 = @intCast(rc);
        const gop = try self.dirs.getOrPut(self.gpa, wd);
        if (gop.found_existing) self.gpa.free(gop.value_ptr.rel);
        gop.value_ptr.* = .{ .root = root, .rel = try self.gpa.dupe(u8, rel) };
        return wd;
    }

    fn dropWatch(self: *Inotify, wd: i32, rm: bool) void {
        if (self.dirs.fetchRemove(wd)) |kv| self.gpa.free(kv.value.rel);
        if (rm) _ = linux.inotify_rm_watch(self.fd, wd);
    }

    /// Breadth-first: watches every non-ignored directory under `rel`
    /// (already watched itself) and, when `emit` is set, records a
    /// `created` event for each entry found.
    fn scanTree(self: *Inotify, root: RootId, rel: []const u8, found_out: ?*std.ArrayList(FsEvent), lost: *bool) error{OutOfMemory}!void {
        const r = self.roots.get(@intFromEnum(root)) orelse return;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var queue: std.ArrayList([]const u8) = .empty;
        try queue.append(arena, try arena.dupe(u8, rel));
        var qi: usize = 0;
        var buf: [4096]u8 = undefined;
        while (qi < queue.items.len) : (qi += 1) {
            const dir_rel = queue.items[qi];
            const p = pathZ(&buf, r.abs, dir_rel) orelse continue;
            var dir = Io.Dir.openDirAbsolute(self.io, p, .{ .iterate = true }) catch continue;
            defer dir.close(self.io);
            var it = dir.iterate();
            while (it.next(self.io) catch null) |ent| {
                const child = if (dir_rel.len == 0) try arena.dupe(u8, ent.name) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_rel, ent.name });
                const is_dir = ent.kind == .directory;
                if (r.filter.ignored(child, is_dir)) continue;
                if (found_out) |list| try list.append(self.gpa, .{ .root = root, .kind = .created, .path = try self.gpa.dupe(u8, child), .is_dir = is_dir });
                if (!is_dir) continue;
                if (lost.*) continue;
                _ = self.addWatch(root, r.abs, child) catch |e| switch (e) {
                    error.WatchLimit => {
                        lost.* = true;
                        continue;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                try queue.append(arena, child);
            }
        }
    }

    fn renameSubtree(self: *Inotify, root: RootId, old: []const u8, new: []const u8) error{OutOfMemory}!void {
        var it = self.dirs.valueIterator();
        while (it.next()) |d| {
            if (d.root != root or !isUnder(d.rel, old)) continue;
            const updated = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ new, d.rel[old.len..] });
            self.gpa.free(d.rel);
            d.rel = updated;
        }
    }

    fn dropSubtree(self: *Inotify, root: RootId, rel: []const u8) void {
        var doomed: [256]i32 = undefined;
        while (true) {
            var n: usize = 0;
            var it = self.dirs.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.root == root and isUnder(e.value_ptr.rel, rel)) {
                    doomed[n] = e.key_ptr.*;
                    n += 1;
                    if (n == doomed.len) break;
                }
            }
            if (n == 0) return;
            for (doomed[0..n]) |wd| self.dropWatch(wd, true);
        }
    }

    // ---- reader thread ----

    fn now(self: *Inotify) u64 {
        return @intCast(@max(0, Io.Clock.awake.now(self.io).nanoseconds));
    }

    fn run(self: *Inotify) void {
        var buf: [64 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        const stop_fd = self.stop.handle().fd;
        while (true) {
            const t = self.now();
            var timeout: ?u64 = self.coalescer.timeUntilReady(t);
            if (self.moves.count() > 0) timeout = @min(timeout orelse move_pair_ns, move_pair_ns);
            var fds = [2]linux.pollfd{
                .{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = stop_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            var ts: linux.timespec = undefined;
            const tsp: ?*linux.timespec = if (timeout) |ns| blk: {
                ts = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
                break :blk &ts;
            } else null;
            _ = linux.ppoll(&fds, 2, tsp, null);
            if (fds[1].revents & linux.POLL.IN != 0) return;
            while (true) {
                const n = linux.read(self.fd, &buf, buf.len);
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                self.process(buf[0..n]) catch {};
            }
            self.flushMoves(self.now(), false) catch {};
            self.deliver(self.now()) catch {};
        }
    }

    /// Parses a read buffer of `inotify_event` records.
    pub fn process(self: *Inotify, bytes: []const u8) error{OutOfMemory}!void {
        var off: usize = 0;
        const t = self.now();
        while (off + @sizeOf(linux.inotify_event) <= bytes.len) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(bytes[off..].ptr));
            const name_len = ev.len;
            if (off + @sizeOf(linux.inotify_event) + name_len > bytes.len) break;
            const raw_name = bytes[off + @sizeOf(linux.inotify_event) ..][0..name_len];
            const name = std.mem.sliceTo(raw_name, 0);
            off += @sizeOf(linux.inotify_event) + name_len;
            try self.handle(ev.wd, ev.mask, ev.cookie, name, t);
        }
    }

    fn emit(self: *Inotify, ev: FsEvent, t: u64) error{OutOfMemory}!void {
        try self.coalescer.add(ev, t);
    }

    fn handle(self: *Inotify, wd: i32, mask: u32, cookie: u32, name: []const u8, t: u64) error{OutOfMemory}!void {
        if (mask & linux.IN.Q_OVERFLOW != 0) {
            self.lock();
            const keys = try self.gpa.dupe(u32, self.roots.keys());
            self.unlock();
            defer self.gpa.free(keys);
            for (keys) |k| try self.emit(.{ .root = @enumFromInt(k), .kind = .rescan_required, .path = "", .is_dir = true, .reason = .overflow }, t);
            return;
        }
        self.lock();
        var locked = true;
        defer if (locked) self.unlock();
        const dir = self.dirs.get(wd) orelse return;
        if (mask & linux.IN.IGNORED != 0) {
            self.dropWatch(wd, false);
            return;
        }
        const root = self.roots.get(@intFromEnum(dir.root)) orelse return;
        const is_dir = mask & linux.IN.ISDIR != 0;
        var path_buf: [4096]u8 = undefined;
        const path = if (name.len == 0) dir.rel else if (dir.rel.len == 0) name else std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir.rel, name }) catch return;
        if (name.len > 0 and root.filter.ignored(path, is_dir)) return;

        if (mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) {
            if (wd == root.wd) try self.emit(.{ .root = dir.root, .kind = .rescan_required, .path = "", .is_dir = true, .reason = .root_gone }, t);
            return;
        }
        if (mask & linux.IN.CREATE != 0) {
            try self.emit(.{ .root = dir.root, .kind = .created, .path = path, .is_dir = is_dir }, t);
            if (is_dir) try self.watchNewDir(dir.root, root.abs, path, t);
        }
        if (mask & (linux.IN.MODIFY | linux.IN.CLOSE_WRITE) != 0) try self.emit(.{ .root = dir.root, .kind = .modified, .path = path, .is_dir = is_dir }, t);
        if (mask & linux.IN.ATTRIB != 0) try self.emit(.{ .root = dir.root, .kind = .attrib, .path = path, .is_dir = is_dir }, t);
        if (mask & linux.IN.DELETE != 0) try self.emit(.{ .root = dir.root, .kind = .removed, .path = path, .is_dir = is_dir }, t);
        if (mask & linux.IN.MOVED_FROM != 0) {
            const owned = try self.gpa.dupe(u8, path);
            errdefer self.gpa.free(owned);
            try self.moves.put(self.gpa, cookie, .{ .root = dir.root, .path = owned, .is_dir = is_dir, .at_ns = t, .wd = null });
        }
        if (mask & linux.IN.MOVED_TO != 0) {
            if (self.moves.fetchRemove(cookie)) |kv| {
                defer self.gpa.free(kv.value.path);
                if (kv.value.root == dir.root) {
                    try self.emit(.{ .root = dir.root, .kind = .renamed, .path = path, .old_path = kv.value.path, .is_dir = is_dir }, t);
                    if (is_dir) try self.renameSubtree(dir.root, kv.value.path, path);
                    return;
                }
                // Moved between roots: out of one, into the other.
                try self.emit(.{ .root = kv.value.root, .kind = .removed, .path = kv.value.path, .is_dir = is_dir }, t);
                if (is_dir) self.dropSubtree(kv.value.root, kv.value.path);
            }
            try self.emit(.{ .root = dir.root, .kind = .created, .path = path, .is_dir = is_dir }, t);
            if (is_dir) try self.watchNewDir(dir.root, root.abs, path, t);
        }
        self.unlock();
        locked = false;
    }

    /// Watches a directory that just appeared, then scans it: files created
    /// between the event and the new watch would otherwise be missed.
    fn watchNewDir(self: *Inotify, root: RootId, abs_root: []const u8, rel: []const u8, t: u64) error{OutOfMemory}!void {
        _ = self.addWatch(root, abs_root, rel) catch |e| switch (e) {
            error.WatchLimit => return self.emit(.{ .root = root, .kind = .rescan_required, .path = rel, .is_dir = true, .reason = .watch_limit }, t),
            error.OutOfMemory => return error.OutOfMemory,
            else => return,
        };
        var found: std.ArrayList(FsEvent) = .empty;
        defer {
            for (found.items) |f| self.gpa.free(f.path);
            found.deinit(self.gpa);
        }
        var lost = false;
        try self.scanTree(root, rel, &found, &lost);
        for (found.items) |f| try self.emit(f, t);
        if (lost) try self.emit(.{ .root = root, .kind = .rescan_required, .path = rel, .is_dir = true, .reason = .watch_limit }, t);
    }

    /// Turns `IN_MOVED_FROM`s that found no partner within 10 ms (or all of
    /// them with `all`) into removals.
    fn flushMoves(self: *Inotify, t: u64, all: bool) error{OutOfMemory}!void {
        var expired: std.ArrayList(u32) = .empty;
        defer expired.deinit(self.gpa);
        var it = self.moves.iterator();
        while (it.next()) |e| if (all or t -| e.value_ptr.at_ns >= move_pair_ns) try expired.append(self.gpa, e.key_ptr.*);
        for (expired.items) |cookie| {
            const kv = self.moves.fetchRemove(cookie).?;
            defer self.gpa.free(kv.value.path);
            try self.emit(.{ .root = kv.value.root, .kind = .removed, .path = kv.value.path, .is_dir = kv.value.is_dir }, t);
            if (kv.value.is_dir) {
                self.lock();
                self.dropSubtree(kv.value.root, kv.value.path);
                self.unlock();
            }
        }
    }

    fn deliver(self: *Inotify, t: u64) error{OutOfMemory}!void {
        if (!self.coalescer.ready(t)) return;
        self.lock();
        defer self.unlock();
        // The list lives in gpa memory; only the paths go in the arena, which
        // `poll` resets once the list is drained.
        var batch: std.ArrayList(FsEvent) = .empty;
        defer batch.deinit(self.gpa);
        try self.coalescer.take(self.ready_arena.allocator(), self.gpa, &batch);
        try self.ready.appendSlice(self.gpa, batch.items);
        if (self.ready.items.len > 0) self.ready_wake.signal();
    }

    fn publishLocked(self: *Inotify, evs: []const FsEvent) error{OutOfMemory}!void {
        const a = self.ready_arena.allocator();
        for (evs) |e| {
            var c = e;
            c.path = try a.dupe(u8, e.path);
            try self.ready.append(self.gpa, c);
        }
        self.ready_wake.signal();
    }
};

fn pathZ(buf: []u8, abs: []const u8, rel: []const u8) ?[:0]const u8 {
    if (rel.len == 0) return std.fmt.bufPrintZ(buf, "{s}", .{abs}) catch null;
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ abs, rel }) catch null;
}

fn readProcU64(path: [*:0]const u8) ?u64 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [32]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..n], " \n"), 10) catch null;
}

const testing = std.testing;
const NameList = @import("ignore.zig").NameList;

const tu = @import("test_util.zig");
const Seen = tu.Seen;
const collect = tu.collect;
const Fixture = tu.Fixture;

test "create/modify/delete" {
    var f = try Fixture.init(&.none, null);
    defer f.deinit();
    const io = testing.io;
    try f.tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "1" });
    var s: Seen = .{};
    defer s.deinit();
    try collect(&f.w, &s, struct {
        fn ok(x: *const Seen) bool {
            return x.has(.created, "a.txt");
        }
    }.ok);
    try f.tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "22" });
    try collect(&f.w, &s, struct {
        fn ok(x: *const Seen) bool {
            return x.has(.modified, "a.txt");
        }
    }.ok);
    try f.tmp.dir.deleteFile(io, "a.txt");
    try collect(&f.w, &s, struct {
        fn ok(x: *const Seen) bool {
            return x.has(.removed, "a.txt");
        }
    }.ok);
}

test "mkdir -p deep then files immediately (race)" {
    var f = try Fixture.init(&.none, null);
    defer f.deinit();
    const io = testing.io;
    try f.tmp.dir.createDirPath(io, "x/y/z");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "x/y/z/deep.txt", .data = "d" });
    var s: Seen = .{};
    defer s.deinit();
    try collect(&f.w, &s, struct {
        fn ok(x: *const Seen) bool {
            return x.hasPath("x") and x.hasPath("x/y") and x.hasPath("x/y/z") and x.hasPath("x/y/z/deep.txt");
        }
    }.ok);
    // The new directories are watched too.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "x/y/later.txt", .data = "l" });
    try collect(&f.w, &s, struct {
        fn ok(x: *const Seen) bool {
            return x.hasPath("x/y/later.txt");
        }
    }.ok);
}

fn setupRename(d: Io.Dir) !void {
    try d.createDirPath(testing.io, "sub/inner");
    try d.writeFile(testing.io, .{ .sub_path = "old.txt", .data = "o" });
}

test "rename within root → renamed" {
    var f = try Fixture.init(&.none, setupRename);
    defer f.deinit();
    const io = testing.io;
    try f.tmp.dir.rename("old.txt", f.tmp.dir, "new.txt", io);
    try f.tmp.dir.rename("sub", f.tmp.dir, "moved", io);
    var s: Seen = .{};
    defer s.deinit();
    try collect(&f.w, &s, struct {
        fn ok(x: *const Seen) bool {
            return x.has(.renamed, "new.txt") and x.has(.renamed, "moved");
        }
    }.ok);
    for (s.list.items) |e| if (e.kind == .renamed and std.mem.eql(u8, e.path, "new.txt")) try testing.expectEqualStrings("old.txt", e.old_path.?);
    // The renamed directory's subtree reports its new paths.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "moved/inner/f", .data = "x" });
    try collect(&f.w, &s, struct {
        fn ok(x: *const Seen) bool {
            return x.hasPath("moved/inner/f");
        }
    }.ok);
}

test "move out → removed, move dir in → created + contents" {
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    const io = testing.io;
    try outside.dir.createDirPath(io, "incoming/deep");
    try outside.dir.writeFile(io, .{ .sub_path = "incoming/deep/file", .data = "x" });
    var f = try Fixture.init(&.none, setupRename);
    defer f.deinit();
    try f.tmp.dir.rename("old.txt", outside.dir, "gone.txt", io);
    try outside.dir.rename("incoming", f.tmp.dir, "incoming", io);
    var s: Seen = .{};
    defer s.deinit();
    try collect(&f.w, &s, struct {
        fn ok(x: *const Seen) bool {
            return x.has(.removed, "old.txt") and x.has(.created, "incoming") and x.hasPath("incoming/deep/file");
        }
    }.ok);
}

fn setupIgnored(d: Io.Dir) !void {
    try d.createDirPath(testing.io, ".git/objects");
    try d.createDirPath(testing.io, "src");
}

test "ignored dir not watched" {
    var nl: NameList = .{ .names = &.{".git"} };
    const filter = nl.filter();
    var f = try Fixture.init(&filter, setupIgnored);
    defer f.deinit();
    const io = testing.io;
    try testing.expectEqual(@as(u32, 2), f.w.limits().watches_in_use); // root and src
    try f.tmp.dir.writeFile(io, .{ .sub_path = ".git/objects/x", .data = "x" });
    try f.tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "x" });
    var s: Seen = .{};
    defer s.deinit();
    try collect(&f.w, &s, struct {
        fn ok(x: *const Seen) bool {
            return x.hasPath("src/main.zig");
        }
    }.ok);
    for (s.list.items) |e| try testing.expect(!std.mem.startsWith(u8, e.path, ".git"));
    try testing.expect(f.w.limits().max_user_watches != null);
}

test "overflow simulation" {
    var f = try Fixture.init(&.none, null);
    defer f.deinit();
    var rec: [@sizeOf(linux.inotify_event)]u8 align(@alignOf(linux.inotify_event)) = undefined;
    const ev: *linux.inotify_event = @ptrCast(&rec);
    ev.* = .{ .wd = -1, .mask = linux.IN.Q_OVERFLOW, .cookie = 0, .len = 0 };
    // The reader thread owns the coalescer, so feed a private instance.
    var c = f.w.impl;
    _ = &c;
    var probe: Inotify = c.*;
    probe.coalescer = .init(testing.allocator, 5);
    defer probe.coalescer.deinit();
    try probe.process(&rec);
    var out: std.ArrayList(FsEvent) = .empty;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try probe.coalescer.take(arena.allocator(), arena.allocator(), &out);
    try testing.expectEqual(1, out.items.len);
    try testing.expectEqual(FsEvent.Kind.rescan_required, out.items[0].kind);
    try testing.expectEqual(api.RescanReason.overflow, out.items[0].reason);
    try testing.expectEqualStrings("", out.items[0].path);
}

test "10k file writes coalesce into few batches with the final state" {
    var f = try Fixture.init(&.none, null);
    defer f.deinit();
    const io = testing.io;
    try f.tmp.dir.createDirPath(io, "tree");
    var name_buf: [64]u8 = undefined;
    for (0..10_000) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "tree/f{d}", .{i});
        try f.tmp.dir.writeFile(io, .{ .sub_path = name, .data = "v1" });
        if (i % 2 == 0) try f.tmp.dir.writeFile(io, .{ .sub_path = name, .data = "v2" });
        if (i % 5 == 0) try f.tmp.dir.deleteFile(io, name);
    }
    var out: [4096]FsEvent = undefined;
    var live: std.StringHashMapUnmanaged(FsEvent.Kind) = .empty;
    defer {
        var it = live.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        live.deinit(testing.allocator);
    }
    var batches: u32 = 0;
    var idle: u32 = 0;
    while (idle < 30) {
        if (!f.w.wait(10 * std.time.ns_per_ms)) {
            idle += 1;
            continue;
        }
        const n = f.w.poll(&out);
        if (n == 0) continue;
        idle = 0;
        batches += 1;
        for (out[0..n]) |e| {
            if (!std.mem.startsWith(u8, e.path, "tree/")) continue;
            const gop = try live.getOrPut(testing.allocator, e.path);
            if (!gop.found_existing) gop.key_ptr.* = try testing.allocator.dupe(u8, e.path);
            gop.value_ptr.* = e.kind;
        }
    }
    var present: usize = 0;
    var it = live.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* != .removed) present += 1;
    }
    // 10k files, every fifth deleted: 8000 remain.
    try testing.expectEqual(@as(usize, 8000), present);
    try testing.expect(batches <= 50);
}
