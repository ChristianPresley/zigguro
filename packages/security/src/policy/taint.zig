//! Session taint tracking for the lethal-trifecta guard (E16.F02.S04.T01).
//!
//! E10 calls `note` whenever untrusted content (web pages, untrusted MCP
//! results, untrusted files, terminal output of network tools, LSP text)
//! enters a session's context. Taint is sticky: only `clear` (a new session
//! or an explicit, audited user action) removes it.
//!
//! `isTainted` is lock-free: sessions hash into a fixed open-addressing
//! table of atomic keys and flags. The event list shown in the session
//! header is guarded by a mutex.

const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts.zig");

/// Sessions tracked at once; when full, new sessions count as tainted
/// (fail closed).
pub const slots = 1024;

/// One taint event, for the UI.
pub const TaintEvent = struct { src: contracts.TaintSource, origin: []const u8, at_ms: i64 };

/// Per-process taint state.
pub const Taint = struct {
    gpa: Allocator,
    io: std.Io,
    keys: [slots]std.atomic.Value(u64) = @splat(.init(0)),
    flags: [slots]std.atomic.Value(u8) = @splat(.init(0)),
    mutex: std.Io.Mutex = .init,
    events: std.ArrayList(Stored) = .empty,

    const Stored = struct { key: u64, ev: TaintEvent };

    /// An empty table.
    pub fn init(gpa: Allocator, io: std.Io) Taint {
        return .{ .gpa = gpa, .io = io };
    }

    /// Frees the event list.
    pub fn deinit(t: *Taint) void {
        for (t.events.items) |e| t.gpa.free(e.ev.origin);
        t.events.deinit(t.gpa);
    }

    fn keyOf(session: []const u8) u64 {
        const h = std.hash.Wyhash.hash(0x7a1e, session);
        return if (h == 0) 1 else h;
    }

    /// The slot for `key`, inserting it when `insert` is set.
    fn slot(t: *Taint, key: u64, insert: bool) ?usize {
        var i: usize = @intCast(key % slots);
        var probes: usize = 0;
        while (probes < slots) : (probes += 1) {
            const cur = t.keys[i].load(.acquire);
            if (cur == key) return i;
            if (cur == 0) {
                if (!insert) return null;
                if (t.keys[i].cmpxchgStrong(0, key, .acq_rel, .acquire)) |other| {
                    if (other == key) return i;
                } else return i;
            }
            i = (i + 1) % slots;
        }
        return null;
    }

    /// Marks `session` tainted by `src` from `origin` (host, server id or
    /// path; copied).
    pub fn note(t: *Taint, session: []const u8, src: contracts.TaintSource, origin: []const u8) void {
        const key = keyOf(session);
        if (t.slot(key, true)) |i| t.flags[i].store(1, .release);
        const now = std.Io.Clock.real.now(t.io).toMilliseconds();
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const o = t.gpa.dupe(u8, origin) catch return;
        t.events.append(t.gpa, .{ .key = key, .ev = .{ .src = src, .origin = o, .at_ms = @intCast(now) } }) catch t.gpa.free(o);
    }

    /// True when untrusted content has entered `session`. When the table
    /// is full and the session is not in it, answers true (fail closed).
    pub fn isTainted(t: *const Taint, session: []const u8) bool {
        const self: *Taint = @constCast(t);
        const key = keyOf(session);
        const i = self.slot(key, false) orelse return self.full();
        return self.flags[i].load(.acquire) != 0;
    }

    fn full(t: *Taint) bool {
        for (&t.keys) |*k| if (k.load(.acquire) == 0) return false;
        return true;
    }

    /// The events recorded for `session`, oldest first (origins borrowed
    /// until the next `clear`).
    pub fn sources(t: *const Taint, gpa: Allocator, session: []const u8) ![]const TaintEvent {
        const self: *Taint = @constCast(t);
        const key = keyOf(session);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: std.ArrayList(TaintEvent) = .empty;
        errdefer out.deinit(gpa);
        for (self.events.items) |e| if (e.key == key) try out.append(gpa, e.ev);
        return out.toOwnedSlice(gpa);
    }

    /// Clears `session`'s taint (new session or explicit user reset).
    pub fn clear(t: *Taint, session: []const u8) void {
        const key = keyOf(session);
        if (t.slot(key, false)) |i| t.flags[i].store(0, .release);
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        var j: usize = 0;
        while (j < t.events.items.len) {
            if (t.events.items[j].key == key) {
                t.gpa.free(t.events.items[j].ev.origin);
                _ = t.events.orderedRemove(j);
            } else j += 1;
        }
    }
};

/// Opening and closing markers around untrusted content.
pub const Provenance = struct { open: []const u8, close: []const u8 };

/// Writes spotlighting markers into `buf`: `<untrusted source="mcp:srv"
/// id="ab12...">` and `</untrusted id="ab12...">`. The random nonce means
/// content cannot forge the closing marker. Defence in depth only; the
/// sandbox and egress policy are the containment.
pub fn provenanceMarkers(src: contracts.TaintSource, origin: []const u8, nonce: [8]u8, buf: []u8) Provenance {
    const hex = std.fmt.bytesToHex(nonce, .lower);
    var clean: [128]u8 = undefined;
    var n: usize = 0;
    for (origin) |c| {
        if (n == clean.len) break;
        // Quotes and angle brackets in the origin cannot break the marker.
        clean[n] = if (c == '"' or c == '<' or c == '>' or c < 0x20) '_' else c;
        n += 1;
    }
    const open = std.fmt.bufPrint(buf, "<untrusted source=\"{t}:{s}\" id=\"{s}\">", .{ src, clean[0..n], &hex }) catch return .{ .open = "", .close = "" };
    const close = std.fmt.bufPrint(buf[open.len..], "</untrusted id=\"{s}\">", .{&hex}) catch return .{ .open = "", .close = "" };
    return .{ .open = open, .close = close };
}

test "taint: note, sources, clear" {
    var t: Taint = .init(std.testing.allocator, std.testing.io);
    defer t.deinit();
    try std.testing.expect(!t.isTainted("s1"));
    t.note("s1", .web, "example.com");
    try std.testing.expect(t.isTainted("s1"));
    try std.testing.expect(!t.isTainted("s2"));
    const evs = try t.sources(std.testing.allocator, "s1");
    defer std.testing.allocator.free(evs);
    try std.testing.expectEqual(1, evs.len);
    try std.testing.expectEqualStrings("example.com", evs[0].origin);
    t.clear("s1");
    try std.testing.expect(!t.isTainted("s1"));
}

test "taint: concurrent note/isTainted from 8 threads" {
    const gpa = std.testing.allocator;
    var t: Taint = .init(gpa, std.testing.io);
    defer t.deinit();
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*th, k| th.* = try std.Thread.spawn(.{}, struct {
        fn run(tt: *Taint, id: usize) void {
            var buf: [32]u8 = undefined;
            for (0..200) |i| {
                const s = std.fmt.bufPrint(&buf, "s{d}-{d}", .{ id, i % 50 }) catch unreachable;
                tt.note(s, .terminal_output, "x");
                if (!tt.isTainted(s)) @panic("lost taint");
            }
        }
    }.run, .{ &t, k });
    for (threads) |th| th.join();
    try std.testing.expect(t.isTainted("s3-7"));
    try std.testing.expect(!t.isTainted("s9-0"));
}

test "taint: provenance close marker cannot be forged by content containing a different nonce" {
    var buf: [256]u8 = undefined;
    const p = provenanceMarkers(.mcp_untrusted, "srv\"><evil", .{ 1, 2, 3, 4, 5, 6, 7, 8 }, &buf);
    try std.testing.expectEqualStrings("<untrusted source=\"mcp_untrusted:srv___evil\" id=\"0102030405060708\">", p.open);
    try std.testing.expectEqualStrings("</untrusted id=\"0102030405060708\">", p.close);
    var buf2: [256]u8 = undefined;
    const q = provenanceMarkers(.mcp_untrusted, "srv", .{ 9, 9, 9, 9, 9, 9, 9, 9 }, &buf2);
    // Content carrying another item's closing marker does not close this one.
    try std.testing.expect(!std.mem.eql(u8, p.close, q.close));
}
