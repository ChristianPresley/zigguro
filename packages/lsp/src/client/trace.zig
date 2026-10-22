//! The protocol trace ring of one client: the last N messages (direction,
//! kind, method, size, latency, and with `verbose` the JSON body) for the
//! logs view (E07.F01.S02.T06), bug reports and `zg-transcript`.
//!
//! Thread-safe; `record` copies what it keeps. Bodies are capped at
//! `max_body` bytes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Direction = enum {
    /// Client to server.
    send,
    /// Server to client.
    recv,
};

pub const Kind = enum { request, response, notification, error_response };

pub const Entry = struct {
    dir: Direction,
    kind: Kind,
    /// Method (requests, notifications, and the request a response answers).
    method: []const u8,
    /// Request id, if any.
    id: ?i64 = null,
    /// Serialized size in bytes.
    size: usize = 0,
    /// For responses: time since the request was sent.
    latency_ns: ?u64 = null,
    /// Monotonic timestamp (`.awake` clock).
    at_ns: i96,
    /// The JSON body (verbose mode only).
    body: ?[]const u8 = null,
};

pub const Trace = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    entries: []Entry,
    head: usize = 0,
    len: usize = 0,
    verbose: bool,
    max_body: usize = 64 << 10,

    pub fn init(gpa: Allocator, io: Io, capacity: usize, verbose: bool) !Trace {
        return .{ .gpa = gpa, .io = io, .entries = try gpa.alloc(Entry, @max(capacity, 1)), .verbose = verbose };
    }

    pub fn deinit(t: *Trace) void {
        for (0..t.len) |i| t.freeEntry(t.at(i));
        t.gpa.free(t.entries);
        t.* = undefined;
    }

    fn at(t: *Trace, i: usize) *Entry {
        return &t.entries[(t.head + i) % t.entries.len];
    }

    fn freeEntry(t: *Trace, e: *const Entry) void {
        t.gpa.free(e.method);
        if (e.body) |b| t.gpa.free(b);
    }

    /// Records `e` (copying `method` and, in verbose mode, `body`),
    /// evicting the oldest entry when full. Drops the entry on OOM.
    pub fn record(t: *Trace, e: Entry) void {
        var copy = e;
        copy.method = t.gpa.dupe(u8, e.method) catch return;
        copy.body = null;
        if (t.verbose) if (e.body) |b| {
            copy.body = t.gpa.dupe(u8, b[0..@min(b.len, t.max_body)]) catch null;
        };
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        if (t.len == t.entries.len) {
            t.freeEntry(t.at(0));
            t.head = (t.head + 1) % t.entries.len;
            t.len -= 1;
        }
        t.at(t.len).* = copy;
        t.len += 1;
    }

    /// Number of entries held.
    pub fn count(t: *Trace) usize {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        return t.len;
    }

    /// Copies the entries, oldest first, into `arena`.
    pub fn snapshot(t: *Trace, arena: Allocator) ![]Entry {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const out = try arena.alloc(Entry, t.len);
        for (out, 0..) |*o, i| {
            const e = t.at(i);
            o.* = e.*;
            o.method = try arena.dupe(u8, e.method);
            if (e.body) |b| o.body = try arena.dupe(u8, b);
        }
        return out;
    }

    /// Writes the entries, oldest first, as `zg-transcript` trace lines
    /// (see transcript.zig). `scratch` holds the snapshot.
    pub fn dump(t: *Trace, scratch: Allocator, w: *std.Io.Writer) !void {
        const transcript = @import("transcript.zig");
        for (try t.snapshot(scratch)) |e| try transcript.writeEntry(scratch, w, e);
    }
};

test "trace: ring evicts oldest and copies" {
    var t = try Trace.init(std.testing.allocator, std.testing.io, 3, true);
    defer t.deinit();
    var name: [16]u8 = undefined;
    for (0..5) |i| {
        const m = try std.fmt.bufPrint(&name, "m{d}", .{i});
        t.record(.{ .dir = .send, .kind = .request, .method = m, .id = @intCast(i), .at_ns = @intCast(i), .body = "{}" });
    }
    try std.testing.expectEqual(@as(usize, 3), t.count());
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const snap = try t.snapshot(arena.allocator());
    try std.testing.expectEqualStrings("m2", snap[0].method);
    try std.testing.expectEqualStrings("m4", snap[2].method);
    try std.testing.expectEqualStrings("{}", snap[2].body.?);
}
