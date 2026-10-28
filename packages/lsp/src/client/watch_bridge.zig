//! The `workspace/didChangeWatchedFiles` bridge (E07.F01.S02.T07): file
//! system changes from the app-wide watcher go to the servers whose
//! registered `FileSystemWatcher`s match them. Each watcher's glob is
//! matched against the path relative to each workspace folder (or to the
//! `RelativePattern` base, or the whole path when absolute) for the event
//! kinds it asked for. Changes are buffered per server for 50 ms and
//! coalesced (create+delete is nothing, create+change a create,
//! change+delete a delete); `changed` events for open documents with
//! unsaved edits are dropped at send time, their state flows through
//! `didChange`. A lost-events notice (`rescan_required`) sends `Changed`
//! for the workspace folder. Paths under `.git`, `zig-cache`,
//! `.zig-cache`, `zig-out` and `node_modules` reach only watchers whose
//! pattern names that directory.
//!
//! `setWatchers`, `removeWatchers` and `onFsEvents` may run on any thread;
//! `flush` sends on the calling thread, which also answers `DirtyCheck`.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const protocol = @import("../gen/protocol.zig");
const Glob = @import("../proto/glob.zig").Glob;
const uri_mod = @import("../proto/uri.zig");
const host_mod = @import("host.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ServerId = host_mod.ServerId;
const log = std.log.scoped(.lsp_watch);

/// The kinds of change a watcher wants (LSP `WatchKind` bits).
pub const WatchKind = packed struct(u8) {
    create: bool = true,
    change: bool = true,
    delete: bool = true,
    _pad: u5 = 0,

    /// From the protocol value (null: all three).
    pub fn fromProtocol(k: ?protocol.WatchKind) WatchKind {
        const bits: u32 = if (k) |x| @intFromEnum(x) else 7;
        return .{ .create = bits & 1 != 0, .change = bits & 2 != 0, .delete = bits & 4 != 0 };
    }

    fn has(k: WatchKind, c: Change) bool {
        return switch (c) {
            .created => k.create,
            .changed => k.change,
            .deleted => k.delete,
        };
    }
};

/// One change from the watcher fan-out.
pub const FsEvent = struct {
    /// Absolute path.
    path: []const u8,
    kind: Kind,

    pub const Kind = enum { created, changed, deleted, rescan_required };
};

/// Sends one batch to a server.
pub const Sender = struct {
    ctx: ?*anyopaque,
    send: *const fn (ctx: ?*anyopaque, server: ServerId, params: protocol.DidChangeWatchedFilesParams) void,
};

/// Whether `path` is open with unsaved changes.
pub const DirtyCheck = struct {
    ctx: ?*anyopaque,
    isDirty: *const fn (ctx: ?*anyopaque, path: []const u8) bool,
};

pub const default_ignored = [_][]const u8{ ".git", "zig-cache", ".zig-cache", "zig-out", "node_modules" };

pub const Options = struct {
    sender: Sender,
    dirty: ?DirtyCheck = null,
    /// How long a server's changes are held before they are sent.
    debounce_ns: u64 = 50 * std.time.ns_per_ms,
    /// Asked for a `flush` when a server's first change is buffered.
    waker: zg_core.runtime.Waker = .noop,
    /// Windows paths: `\` separators and case-insensitive matching.
    windows: bool = builtin.os.tag == .windows,
    /// Directory names whose contents only explicit patterns see.
    ignored: []const []const u8 = &default_ignored,
};

const Change = enum { created, changed, deleted };

/// `next` after `prev` for the same path; null cancels both.
fn merge(prev: Change, next: Change) ?Change {
    return switch (prev) {
        .created => switch (next) {
            .created, .changed => .created,
            .deleted => null,
        },
        .changed => switch (next) {
            .created, .changed => .changed,
            .deleted => .deleted,
        },
        .deleted => switch (next) {
            .created, .changed => .changed,
            .deleted => .deleted,
        },
    };
}

pub const WatchBridge = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    /// Workspace folders, normalized, without a trailing separator.
    roots: []const []const u8,
    mutex: Io.Mutex = .init,
    regs: std.ArrayList(*Registration) = .empty,
    pending: std.ArrayList(Pending) = .empty,

    const Base = union(enum) {
        /// Relative to each workspace folder.
        roots,
        /// The pattern is absolute.
        absolute,
        /// A `RelativePattern` base, normalized.
        dir: []const u8,
    };

    const Watcher = struct {
        glob: Glob,
        base: Base,
        kind: WatchKind,
        /// A literal tail every match ends with ("" when none).
        suffix: []const u8,
        /// The pattern names an ignored directory.
        unignore: bool,
    };

    const Registration = struct {
        arena: std.heap.ArenaAllocator,
        server: ServerId,
        id: []const u8,
        watchers: []Watcher,
    };

    const Pending = struct {
        server: ServerId,
        since_ns: i96,
        /// Normalized path to its coalesced change.
        changes: std.StringArrayHashMapUnmanaged(Change) = .empty,

        fn deinit(p: *Pending, gpa: Allocator) void {
            for (p.changes.keys()) |k| gpa.free(k);
            p.changes.deinit(gpa);
        }
    };

    pub fn init(gpa: Allocator, io: Io, roots: []const []const u8, opts: Options) Allocator.Error!WatchBridge {
        const rs = try gpa.alloc([]const u8, roots.len);
        var n: usize = 0;
        errdefer {
            for (rs[0..n]) |r| gpa.free(r);
            gpa.free(rs);
        }
        for (roots) |r| {
            rs[n] = try normalize(gpa, r, opts.windows);
            n += 1;
        }
        return .{ .gpa = gpa, .io = io, .opts = opts, .roots = rs };
    }

    pub fn deinit(b: *WatchBridge) void {
        for (b.regs.items) |r| b.freeReg(r);
        b.regs.deinit(b.gpa);
        for (b.pending.items) |*p| p.deinit(b.gpa);
        b.pending.deinit(b.gpa);
        for (b.roots) |r| b.gpa.free(r);
        b.gpa.free(b.roots);
    }

    /// The registration hook for `Client` services.
    pub fn host(b: *WatchBridge) host_mod.WatchBridge {
        return .{ .ctx = b, .set = hostSet, .clear = hostClear };
    }

    fn hostSet(ctx: ?*anyopaque, server: ServerId, reg_id: []const u8, watchers: []const protocol.FileSystemWatcher) void {
        const b: *WatchBridge = @ptrCast(@alignCast(ctx.?));
        b.setWatchers(server, reg_id, watchers) catch |e| log.warn("watchers of server {d}: {t}", .{ server, e });
    }

    fn hostClear(ctx: ?*anyopaque, server: ServerId, reg_id: []const u8) void {
        const b: *WatchBridge = @ptrCast(@alignCast(ctx.?));
        b.removeWatchers(server, reg_id);
    }

    /// Adds (or replaces) registration `reg_id` of `server`. Patterns
    /// that do not compile are skipped with a warning.
    pub fn setWatchers(b: *WatchBridge, server: ServerId, reg_id: []const u8, watchers: []const protocol.FileSystemWatcher) !void {
        const r = try b.gpa.create(Registration);
        r.* = .{ .arena = .init(b.gpa), .server = server, .id = &.{}, .watchers = &.{} };
        errdefer b.freeReg(r);
        const a = r.arena.allocator();
        r.id = try a.dupe(u8, reg_id);
        var list: std.ArrayList(Watcher) = .empty;
        for (watchers) |fw| {
            const pattern, const base: Base = switch (fw.globPattern) {
                .pattern => |p| .{ p, if (isAbsolute(p)) .absolute else .roots },
                .relative_pattern => |rp| base: {
                    const u = switch (rp.baseUri) {
                        .uri => |u| u,
                        .workspace_folder => |f| f.uri,
                    };
                    const path = (uri_mod.pathFromUriStyle(a, u, b.style()) catch null) orelse {
                        log.warn("watcher base {s} is not a file URI", .{u});
                        continue;
                    };
                    break :base .{ rp.pattern, .{ .dir = try normalize(a, path, b.opts.windows) } };
                },
            };
            var g = Glob.compile(b.gpa, pattern, .{ .case_insensitive = b.opts.windows }) catch |e| switch (e) {
                error.InvalidGlob => {
                    log.warn("server {d}: bad watcher glob {s}", .{ server, pattern });
                    continue;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            list.append(a, .{
                .glob = g,
                .base = base,
                .kind = .fromProtocol(fw.kind),
                .suffix = try a.dupe(u8, literalTail(pattern)),
                .unignore = b.namesIgnored(pattern),
            }) catch |e| {
                g.deinit(b.gpa);
                return e;
            };
        }
        r.watchers = list.items;

        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        if (b.indexOfReg(server, reg_id)) |i| {
            b.freeReg(b.regs.items[i]);
            b.regs.items[i] = r;
        } else try b.regs.append(b.gpa, r);
    }

    /// Drops registration `reg_id` of `server`.
    pub fn removeWatchers(b: *WatchBridge, server: ServerId, reg_id: []const u8) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const i = b.indexOfReg(server, reg_id) orelse return;
        b.freeReg(b.regs.orderedRemove(i));
        if (!b.hasRegs(server)) b.dropPending(server);
    }

    /// Forgets everything of `server` (its client went away).
    pub fn removeServer(b: *WatchBridge, server: ServerId) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var i: usize = 0;
        while (i < b.regs.items.len) {
            if (b.regs.items[i].server == server) b.freeReg(b.regs.orderedRemove(i)) else i += 1;
        }
        b.dropPending(server);
    }

    /// Whether any server watches anything.
    pub fn active(b: *WatchBridge) bool {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        return b.regs.items.len > 0;
    }

    /// Takes changes from the watcher fan-out.
    pub fn onFsEvents(b: *WatchBridge, events: []const FsEvent) void {
        b.onFsEventsAt(events, b.now());
    }

    /// `onFsEvents` at time `now_ns` (`.awake` clock).
    pub fn onFsEventsAt(b: *WatchBridge, events: []const FsEvent, now_ns: i96) void {
        var wake = false;
        {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            if (b.regs.items.len == 0) return;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            for (events) |e| {
                if (e.path.len > buf.len) continue;
                const path = buf[0..e.path.len];
                @memcpy(path, e.path);
                if (b.opts.windows) std.mem.replaceScalar(u8, path, '\\', '/');
                wake = (b.route(path, e.kind, now_ns) catch {
                    log.err("watch bridge: out of memory", .{});
                    return;
                }) or wake;
            }
        }
        if (wake) b.opts.waker.wake();
    }

    /// Sends every batch that has waited `debounce_ns`.
    pub fn flush(b: *WatchBridge) void {
        b.flushAt(b.now());
    }

    /// `flush` at `now_ns`.
    pub fn flushAt(b: *WatchBridge, now_ns: i96) void {
        var due: std.ArrayList(Pending) = .empty;
        defer due.deinit(b.gpa);
        {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            var i: usize = 0;
            while (i < b.pending.items.len) {
                const p = b.pending.items[i];
                if (now_ns - p.since_ns >= b.opts.debounce_ns) {
                    due.append(b.gpa, p) catch break;
                    _ = b.pending.orderedRemove(i);
                } else i += 1;
            }
        }
        for (due.items) |*p| {
            defer p.deinit(b.gpa);
            b.send(p) catch log.err("watch bridge: out of memory", .{});
        }
    }

    /// When the next batch is due, if one is waiting (`.awake` ns).
    pub fn nextDue(b: *WatchBridge) ?i96 {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        var due: ?i96 = null;
        for (b.pending.items) |p| {
            const d = p.since_ns + b.opts.debounce_ns;
            due = if (due) |x| @min(x, d) else d;
        }
        return due;
    }

    fn style(b: *const WatchBridge) uri_mod.Style {
        return if (b.opts.windows) .windows else .posix;
    }

    fn now(b: *const WatchBridge) i96 {
        return Io.Clock.Timestamp.now(b.io, .awake).raw.nanoseconds;
    }

    fn send(b: *WatchBridge, p: *const Pending) !void {
        var arena: std.heap.ArenaAllocator = .init(b.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var out: std.ArrayList(protocol.FileEvent) = .empty;
        for (p.changes.keys(), p.changes.values()) |path, c| {
            if (c == .changed) if (b.opts.dirty) |d| if (d.isDirty(d.ctx, path)) continue;
            try out.append(a, .{ .uri = try uri_mod.uriFromPathStyle(a, path, b.style()), .type = switch (c) {
                .created => .Created,
                .changed => .Changed,
                .deleted => .Deleted,
            } });
        }
        if (out.items.len == 0) return;
        b.opts.sender.send(b.opts.sender.ctx, p.server, .{ .changes = out.items });
    }

    /// Buffers `path`'s change for each server that watches it; true when
    /// a server's first change was buffered. Locked.
    fn route(b: *WatchBridge, path: []const u8, kind: FsEvent.Kind, now_ns: i96) !bool {
        var first = false;
        const c: Change = switch (kind) {
            .created => .created,
            .changed => .changed,
            .deleted => .deleted,
            .rescan_required => {
                log.warn("file events lost under {s}; asking the servers to rescan", .{path});
                const root = for (b.roots) |r| {
                    if (b.under(path, r) != null or b.eqlPath(path, r)) break r;
                } else if (b.roots.len > 0) b.roots[0] else return false;
                for (b.regs.items, 0..) |r, i| {
                    if (b.seenBefore(i, r.server)) continue;
                    first = (try b.add(r.server, root, .changed, now_ns)) or first;
                }
                return first;
            },
        };
        const ignored = b.isIgnored(path);
        // Servers this event already went to (one change per server).
        var sent: [64]ServerId = undefined;
        var n_sent: usize = 0;
        regs: for (b.regs.items) |r| {
            if (std.mem.indexOfScalar(ServerId, sent[0..n_sent], r.server) != null) continue;
            for (r.watchers) |*w| {
                if (!w.kind.has(c) or (ignored and !w.unignore)) continue;
                if (!b.matches(w, path)) continue;
                first = (try b.add(r.server, path, c, now_ns)) or first;
                if (n_sent < sent.len) {
                    sent[n_sent] = r.server;
                    n_sent += 1;
                }
                continue :regs;
            }
        }
        return first;
    }

    /// Whether a registration before `i` belongs to `server`.
    fn seenBefore(b: *const WatchBridge, i: usize, server: ServerId) bool {
        for (b.regs.items[0..i]) |r| if (r.server == server) return true;
        return false;
    }

    fn add(b: *WatchBridge, server: ServerId, path: []const u8, c: Change, now_ns: i96) !bool {
        const p, const first = for (b.pending.items) |*p| {
            if (p.server == server) break .{ p, false };
        } else blk: {
            try b.pending.append(b.gpa, .{ .server = server, .since_ns = now_ns });
            break :blk .{ &b.pending.items[b.pending.items.len - 1], true };
        };
        if (p.changes.getIndex(path)) |i| {
            if (merge(p.changes.values()[i], c)) |m| {
                p.changes.values()[i] = m;
            } else {
                const k = p.changes.keys()[i];
                p.changes.orderedRemoveAt(i);
                b.gpa.free(k);
            }
            return first;
        }
        const k = try b.gpa.dupe(u8, path);
        errdefer b.gpa.free(k);
        try p.changes.put(b.gpa, k, c);
        return first;
    }

    fn matches(b: *const WatchBridge, w: *const Watcher, path: []const u8) bool {
        if (w.suffix.len > 0) {
            const ok = if (b.opts.windows) std.ascii.endsWithIgnoreCase(path, w.suffix) else std.mem.endsWith(u8, path, w.suffix);
            if (!ok) return false;
        }
        switch (w.base) {
            .absolute => return w.glob.match(path),
            .dir => |d| return w.glob.match(b.under(path, d) orelse return false),
            .roots => {
                for (b.roots) |r| if (b.under(path, r)) |rel| if (w.glob.match(rel)) return true;
                return false;
            },
        }
    }

    /// Whether a directory of `path` below its workspace folder is on the
    /// ignore list.
    fn isIgnored(b: *const WatchBridge, path: []const u8) bool {
        const rel = for (b.roots) |r| {
            if (b.under(path, r)) |x| break x;
        } else path;
        var it = std.mem.splitScalar(u8, rel, '/');
        while (it.next()) |part| {
            if (it.peek() == null) break;
            for (b.opts.ignored) |n| if (b.eqlPath(part, n)) return true;
        }
        return false;
    }

    fn namesIgnored(b: *const WatchBridge, pattern: []const u8) bool {
        for (b.opts.ignored) |n| if (std.mem.indexOf(u8, pattern, n) != null) return true;
        return false;
    }

    /// `path` relative to directory `dir`, if it is below it.
    fn under(b: *const WatchBridge, path: []const u8, dir: []const u8) ?[]const u8 {
        if (path.len <= dir.len) return null;
        if (!b.eqlPath(path[0..dir.len], dir)) return null;
        if (dir.len > 0 and dir[dir.len - 1] == '/') return path[dir.len..];
        if (path[dir.len] != '/') return null;
        return path[dir.len + 1 ..];
    }

    fn eqlPath(b: *const WatchBridge, x: []const u8, y: []const u8) bool {
        return if (b.opts.windows) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
    }

    fn indexOfReg(b: *const WatchBridge, server: ServerId, reg_id: []const u8) ?usize {
        for (b.regs.items, 0..) |r, i| if (r.server == server and std.mem.eql(u8, r.id, reg_id)) return i;
        return null;
    }

    fn hasRegs(b: *const WatchBridge, server: ServerId) bool {
        for (b.regs.items) |r| if (r.server == server) return true;
        return false;
    }

    fn dropPending(b: *WatchBridge, server: ServerId) void {
        for (b.pending.items, 0..) |*p, i| if (p.server == server) {
            p.deinit(b.gpa);
            _ = b.pending.orderedRemove(i);
            return;
        };
    }

    fn freeReg(b: *WatchBridge, r: *Registration) void {
        for (r.watchers) |*w| w.glob.deinit(b.gpa);
        r.arena.deinit();
        b.gpa.destroy(r);
    }
};

/// `path` with `/` separators and no trailing one (but a lone root).
fn normalize(gpa: Allocator, path: []const u8, windows: bool) Allocator.Error![]u8 {
    var n = path.len;
    while (n > 1 and isSep(path[n - 1], windows) and !(n == 3 and path[1] == ':')) n -= 1;
    const out = try gpa.dupe(u8, path[0..n]);
    if (windows) std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn isSep(c: u8, windows: bool) bool {
    return c == '/' or (windows and c == '\\');
}

fn isAbsolute(p: []const u8) bool {
    if (p.len > 0 and p[0] == '/') return true;
    return p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '/' or p[2] == '\\');
}

/// The literal characters every match of `pattern` ends with, without a
/// leading `/` (a `**/` before it may match nothing).
fn literalTail(pattern: []const u8) []const u8 {
    if (pattern.len == 0 or pattern[pattern.len - 1] == '/') return "";
    var i = pattern.len;
    while (i > 0) : (i -= 1) switch (pattern[i - 1]) {
        '*', '?', ']', '}', '\\', ',' => break,
        else => {},
    };
    var t = pattern[i..];
    while (t.len > 0 and t[0] == '/') t = t[1..];
    return t;
}

test literalTail {
    try std.testing.expectEqualStrings(".zig", literalTail("**/*.zig"));
    try std.testing.expectEqualStrings("build.zig.zon", literalTail("**/build.zig.zon"));
    try std.testing.expectEqualStrings("", literalTail("**/*.{zig,zon}"));
    try std.testing.expectEqualStrings("", literalTail("src/"));
    try std.testing.expectEqualStrings("a.c", literalTail("a.c"));
}
