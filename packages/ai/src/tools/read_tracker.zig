//! `ReadTracker` (E10.F06.S01.T02): which files each agent has read, at
//! which version and which lines. `edit_file` requires a prior read, and
//! compaction (F07) re-reads what was tracked.

const std = @import("std");
const proto = @import("zg_ai_proto");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// 1-based, inclusive.
pub const Lines = struct { first: u64, last: u64 };

pub const Entry = struct {
    version: u64,
    ranges: std.ArrayList(Lines) = .empty,
};

const Key = struct { session: u128, agent: u32, path: []const u8 };

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Key) u64 {
        var h: std.hash.Wyhash = .init(0);
        h.update(std.mem.asBytes(&k.session));
        h.update(std.mem.asBytes(&k.agent));
        h.update(k.path);
        return h.final();
    }
    pub fn eql(_: KeyContext, a: Key, b: Key) bool {
        return a.session == b.session and a.agent == b.agent and std.mem.eql(u8, a.path, b.path);
    }
};

pub const ReadTracker = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    map: std.HashMapUnmanaged(Key, Entry, KeyContext, 80) = .empty,

    pub fn init(gpa: Allocator, io: Io) ReadTracker {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    }

    pub fn deinit(t: *ReadTracker) void {
        t.map.deinit(t.gpa);
        t.arena.deinit();
    }

    /// Records a read of `lines` of `path` at version `at`. A new version
    /// forgets the ranges read before it.
    pub fn record(t: *ReadTracker, agent: proto.AgentRef, path: []const u8, at: u64, lines: Lines) Allocator.Error!void {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const a = t.arena.allocator();
        const key: Key = .{ .session = agent.session, .agent = agent.agent, .path = path };
        const gop = try t.map.getOrPut(t.gpa, key);
        if (!gop.found_existing) {
            gop.key_ptr.path = try a.dupe(u8, path);
            gop.value_ptr.* = .{ .version = at };
        } else if (gop.value_ptr.version != at) {
            gop.value_ptr.version = at;
            gop.value_ptr.ranges.clearRetainingCapacity();
        }
        try gop.value_ptr.ranges.append(a, lines);
    }

    /// The version `agent` last read of `path`, if any.
    pub fn version(t: *ReadTracker, agent: proto.AgentRef, path: []const u8) ?u64 {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const e = t.map.get(.{ .session = agent.session, .agent = agent.agent, .path = path }) orelse return null;
        return e.version;
    }

    /// The line ranges read at the current version (copied into `arena`).
    pub fn ranges(t: *ReadTracker, arena: Allocator, agent: proto.AgentRef, path: []const u8) Allocator.Error![]const Lines {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const e = t.map.get(.{ .session = agent.session, .agent = agent.agent, .path = path }) orelse return &.{};
        return arena.dupe(Lines, e.ranges.items);
    }

    /// After the agent's own write, its knowledge is current.
    pub fn wrote(t: *ReadTracker, agent: proto.AgentRef, path: []const u8, new_version: u64, total_lines: u64) Allocator.Error!void {
        try t.record(agent, path, new_version, .{ .first = 1, .last = @max(total_lines, 1) });
    }
};
