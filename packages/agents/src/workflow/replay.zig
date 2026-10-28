//! Resuming workflows (E13.F08.S01.T04), with the replay semantics Claude
//! Code documents for dynamic workflows. Agents are walked in start order
//! (`seq`); while every earlier agent was reused, an agent whose key
//! matches a completed result in the previous journal returns that result
//! without starting. The first agent that differs (changed prompt, tools,
//! model, schema or library text; a different agent in that position; a
//! failed, stopped or unfinished one) re-runs, and so does every agent
//! started after it.
//!
//! The engine expands plans deterministically (no wall clock or
//! randomness, `$args` captured at start, vote copies seeded by index), so
//! an unchanged definition gives the same keys in the same order.

const std = @import("std");
const JournalStore = @import("journal.zig");

pub const ReplayKey = JournalStore.ReplayKey;

pub const Replayer = struct {
    prev: ?*JournalStore,
    /// Set once an agent re-ran: nothing after it is reused.
    diverged: bool = false,
    reused: u32 = 0,

    /// Replays against `prev` (null: a fresh run, nothing is reused).
    pub fn init(prev: ?*JournalStore) Replayer {
        return .{ .prev = prev, .diverged = prev == null };
    }

    /// The saved result for agent `seq` with `key`, or null when it must
    /// run (which also makes every later lookup miss).
    pub fn lookup(r: *Replayer, seq: u32, key: ReplayKey) ?std.json.Value {
        if (r.diverged) return null;
        const e = r.prev.?.get(seq) orelse return r.diverge();
        if (!std.mem.eql(u8, &e.key, &key)) return r.diverge();
        const o = e.outcome orelse return r.diverge();
        switch (o) {
            .ok => |v| {
                r.reused += 1;
                return v;
            },
            .failed, .stopped => return r.diverge(),
        }
    }

    fn diverge(r: *Replayer) ?std.json.Value {
        r.diverged = true;
        return null;
    }
};
