//! The notification policy (E13.F01.S03.T01): where a notification goes
//! (nowhere, an in-app toast, or the OS) given focus, visibility, Do Not
//! Disturb and per-severity settings; and the coalescer that turns repeats
//! of a key into in-place updates and bursts of a group into one "N
//! updates" notification. Pure; the router calls both under its lock.

const std = @import("std");
const n_mod = @import("notification.zig");

const Allocator = std.mem.Allocator;
const Notification = n_mod.Notification;
const Severity = n_mod.Severity;
const RunId = n_mod.RunId;

/// `agents.notifications.*` settings.
pub const Policy = struct {
    os_enabled: bool = true,
    toast_enabled: bool = true,
    dnd: bool = false,
    per_severity: std.EnumArray(Severity, bool) = .initFill(true),
    group_window_ms: u32 = 3_000,
    per_key_min_interval_ms: u32 = 10_000,
};

/// What the UI shows. `visible_runs` are the Mission Control rows on
/// screen and the attached panes.
pub const FocusState = struct {
    window_focused: bool = false,
    visible_runs: []const RunId = &.{},
};

pub const Route = enum { none, toast, os };

/// Where `n` goes. The user already sees a visible run in a focused
/// window, so it gets nothing; a focused window gets a toast; otherwise
/// the OS (and the notification center).
pub fn route(p: Policy, focus: FocusState, n: *const Notification) Route {
    if (p.dnd or !p.per_severity.get(n.severity)) return .none;
    if (focus.window_focused) {
        if (n.run) |r| for (focus.visible_runs) |v| if (v.eql(r)) return .none;
        return if (p.toast_enabled) .toast else .none;
    }
    return if (p.os_enabled) .os else if (p.toast_enabled) .toast else .none;
}

/// The outcome of `Coalescer.admit`.
pub const Admit = struct {
    /// Names the shown notification across updates.
    slot: u32,
    /// Update the notification shown for `slot` instead of a new one.
    replace: bool,
    /// Notifications merged into this one (1 when not grouped).
    count: u32 = 1,
};

pub const Coalescer = struct {
    gpa: Allocator,
    keys: std.StringHashMapUnmanaged(State) = .empty,
    groups: std.StringHashMapUnmanaged(State) = .empty,
    next_slot: u32 = 1,

    const State = struct { last_ms: i64, slot: u32, count: u32 = 1 };

    pub fn init(gpa: Allocator) Coalescer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Coalescer) void {
        freeKeys(c.gpa, &c.keys);
        freeKeys(c.gpa, &c.groups);
    }

    fn freeKeys(gpa: Allocator, m: *std.StringHashMapUnmanaged(State)) void {
        var it = m.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        m.deinit(gpa);
    }

    /// Decides whether `key`/`group` posted at `now_ms` is new, an update
    /// of a recent one with the same key, or merges into its group.
    pub fn admit(c: *Coalescer, p: Policy, key: []const u8, group: ?[]const u8, now_ms: i64) Allocator.Error!Admit {
        if (c.keys.count() + c.groups.count() > 512) c.sweep(p, now_ms);
        if (group) |g| {
            const gop = try c.groups.getOrPut(c.gpa, g);
            if (gop.found_existing and now_ms - gop.value_ptr.last_ms <= p.group_window_ms) {
                gop.value_ptr.last_ms = now_ms;
                gop.value_ptr.count += 1;
                return .{ .slot = gop.value_ptr.slot, .replace = true, .count = gop.value_ptr.count };
            }
            if (!gop.found_existing) {
                gop.key_ptr.* = c.gpa.dupe(u8, g) catch |e| {
                    c.groups.removeByPtr(gop.key_ptr);
                    return e;
                };
            }
            gop.value_ptr.* = .{ .last_ms = now_ms, .slot = c.newSlot() };
            return .{ .slot = gop.value_ptr.slot, .replace = false };
        }
        const gop = try c.keys.getOrPut(c.gpa, key);
        if (gop.found_existing and now_ms - gop.value_ptr.last_ms < p.per_key_min_interval_ms) {
            gop.value_ptr.last_ms = now_ms;
            return .{ .slot = gop.value_ptr.slot, .replace = true };
        }
        if (!gop.found_existing) {
            gop.key_ptr.* = c.gpa.dupe(u8, key) catch |e| {
                c.keys.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        gop.value_ptr.* = .{ .last_ms = now_ms, .slot = c.newSlot() };
        return .{ .slot = gop.value_ptr.slot, .replace = false };
    }

    fn newSlot(c: *Coalescer) u32 {
        const s = c.next_slot;
        c.next_slot +%= 1;
        if (c.next_slot == 0) c.next_slot = 1;
        return s;
    }

    /// Forgets keys and groups older than both windows.
    fn sweep(c: *Coalescer, p: Policy, now_ms: i64) void {
        const horizon = now_ms - @max(p.group_window_ms, p.per_key_min_interval_ms);
        inline for (.{ &c.keys, &c.groups }) |m| {
            var stale: [64][]const u8 = undefined;
            var n: usize = 0;
            var it = m.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.last_ms >= horizon) continue;
                stale[n] = e.key_ptr.*;
                n += 1;
                if (n == stale.len) break;
            }
            for (stale[0..n]) |k| {
                _ = m.remove(k);
                c.gpa.free(k);
            }
        }
    }
};
