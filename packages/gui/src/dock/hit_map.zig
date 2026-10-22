//! The window-chrome hit map (E04.F07.S02.T03): which part of a
//! client-decorated window a point is (title bar, resize border, caption
//! button, content), answered on the platform's thread.
//!
//! The UI thread builds a `HitMap` after a frame (`chrome.buildHitMap`)
//! and `ChromeState.publish`es it when it changed: the map is copied,
//! then swapped in with one atomic store. The platform's `HitTestFn`
//! (`ChromeState.hitTestFn`) loads the current map and looks the point
//! up: no locks, no allocation, no UI state.
//!
//! Reclamation: a lookup counts itself in `readers` around its load and
//! read. A replaced map is retired, and retired maps are freed by a
//! later publish that sees no reader after its own swap: any reader that
//! starts after the swap loads the new map. Readers never wait; a
//! publish that sees readers just keeps the retired maps a little longer.

const std = @import("std");
const zg_platform = @import("zg_platform");

const HitRegion = zg_platform.types.HitRegion;
const PxPoint = zg_platform.types.PxPoint;

/// An immutable map of window regions, physical pixels.
pub const HitMap = struct {
    size_px: [2]u32 = .{ 0, 0 },
    /// Width of the resize border inside the window edge (0: none).
    resize_border_px: u16 = 0,
    /// Later entries win.
    rects: []const Entry = &.{},

    pub const Entry = struct {
        /// x, y, w, h.
        rect: [4]i32,
        region: HitRegion,
    };

    /// The region at `p`: the resize border first, then the last entry
    /// containing `p`, else `client`.
    pub fn lookup(m: *const HitMap, p: PxPoint) HitRegion {
        if (m.resize_border_px > 0) if (m.edge(p)) |r| return r;
        var i = m.rects.len;
        while (i > 0) {
            i -= 1;
            const r = m.rects[i].rect;
            if (p.x >= r[0] and p.y >= r[1] and p.x < r[0] + r[2] and p.y < r[1] + r[3]) return m.rects[i].region;
        }
        return .client;
    }

    fn edge(m: *const HitMap, p: PxPoint) ?HitRegion {
        const b: i32 = m.resize_border_px;
        const w: i32 = @intCast(m.size_px[0]);
        const h: i32 = @intCast(m.size_px[1]);
        // Corners reach twice the border along each edge.
        const c = 2 * b;
        const left = p.x < b;
        const right = p.x >= w - b;
        const top = p.y < b;
        const bottom = p.y >= h - b;
        if (!left and !right and !top and !bottom) return null;
        const near_left = p.x < c;
        const near_right = p.x >= w - c;
        const near_top = p.y < c;
        const near_bottom = p.y >= h - c;
        if ((top and near_left) or (left and near_top)) return .resize_top_left;
        if ((top and near_right) or (right and near_top)) return .resize_top_right;
        if ((bottom and near_left) or (left and near_bottom)) return .resize_bottom_left;
        if ((bottom and near_right) or (right and near_bottom)) return .resize_bottom_right;
        if (top) return .resize_top;
        if (bottom) return .resize_bottom;
        if (left) return .resize_left;
        return .resize_right;
    }

    /// Same regions and size.
    pub fn eql(a: *const HitMap, b: *const HitMap) bool {
        if (!std.mem.eql(u32, &a.size_px, &b.size_px) or a.resize_border_px != b.resize_border_px or a.rects.len != b.rects.len) return false;
        for (a.rects, b.rects) |x, y| if (x.region != y.region or !std.mem.eql(i32, &x.rect, &y.rect)) return false;
        return true;
    }
};

/// The published map of one window.
pub const ChromeState = struct {
    gpa: std.mem.Allocator,
    published: std.atomic.Value(?*const HitMap) = .init(null),
    /// Lookups in progress.
    readers: std.atomic.Value(u32) = .init(0),
    /// Replaced maps not yet freed (UI thread).
    retired: std.ArrayList(*HitMap) = .empty,
    /// The `set_hit_test` command was sent.
    installed: bool = false,

    pub fn init(gpa: std.mem.Allocator) ChromeState {
        return .{ .gpa = gpa };
    }

    /// Frees every map. The platform must no longer call `hitTestFn`
    /// (the window is destroyed).
    pub fn deinit(s: *ChromeState) void {
        if (s.published.swap(null, .acq_rel)) |m| s.free(@constCast(m));
        for (s.retired.items) |m| s.free(m);
        s.retired.deinit(s.gpa);
    }

    /// The function to install with `Command.set_hit_test` (ctx = `s`).
    pub fn hitTestFn() zg_platform.window.HitTestFn {
        return lookupErased;
    }

    fn lookupErased(ctx: *anyopaque, p: PxPoint) HitRegion {
        const s: *ChromeState = @ptrCast(@alignCast(ctx));
        _ = s.readers.fetchAdd(1, .seq_cst);
        defer _ = s.readers.fetchSub(1, .release);
        const m = s.published.load(.seq_cst) orelse return .client;
        return m.lookup(p);
    }

    /// The current map, if any (UI thread).
    pub fn current(s: *const ChromeState) ?*const HitMap {
        return s.published.load(.acquire);
    }

    /// Publishes a copy of `m` unless it equals the current map. Returns
    /// whether it published.
    pub fn publish(s: *ChromeState, m: HitMap) !bool {
        if (s.current()) |cur| if (cur.eql(&m)) return false;
        const copy = try s.gpa.create(HitMap);
        errdefer s.gpa.destroy(copy);
        copy.* = m;
        copy.rects = try s.gpa.dupe(HitMap.Entry, m.rects);
        errdefer s.gpa.free(copy.rects);
        try s.retired.ensureUnusedCapacity(s.gpa, 1);
        const old = s.published.swap(copy, .seq_cst);
        if (old) |o| s.retired.appendAssumeCapacity(@constCast(o));
        // No reader now: none can still hold a retired map.
        if (s.readers.load(.seq_cst) == 0) {
            for (s.retired.items) |r| s.free(r);
            s.retired.clearRetainingCapacity();
        }
        return true;
    }

    fn free(s: *ChromeState, m: *HitMap) void {
        s.gpa.free(m.rects);
        s.gpa.destroy(m);
    }
};

test {
    std.testing.refAllDecls(@This());
}
