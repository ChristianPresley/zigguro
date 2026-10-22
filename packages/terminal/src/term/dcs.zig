//! DCS routing and the DCS queries: DECRQSS (`DCS $ q`) and XTGETTCAP
//! (`DCS + q`), plus the legacy synchronized-update DCS (`DCS = 1 s` /
//! `DCS = 2 s`). Sixel (`DCS q`) arrives with E06.F08; tmux passthrough is
//! rejected.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("Terminal.zig");
const Csi = @import("../vt/Parser.zig").Csi;
const sgr = @import("sgr.zig");

/// Longest query payload kept; longer ones are answered as invalid.
pub const max_payload = 4096;

/// The DCS in progress.
pub const State = struct {
    kind: enum { none, decrqss, xtgettcap } = .none,
    buf: std.ArrayList(u8) = .empty,
    overflow: bool = false,

    /// Frees the buffer.
    pub fn deinit(s: *State, gpa: Allocator) void {
        s.buf.deinit(gpa);
    }

    /// Drops the DCS in progress.
    pub fn reset(s: *State) void {
        s.kind = .none;
        s.buf.clearRetainingCapacity();
        s.overflow = false;
    }
};

/// Routes a DCS by its private marker, intermediates and final byte.
/// Returns whether the payload is wanted.
pub fn hook(t: *Terminal, c: *const Csi) bool {
    const st = &t.dcs_state;
    st.reset();
    const inter = c.intermediates();
    if (c.private == 0 and inter.len == 1 and c.final == 'q') {
        st.kind = switch (inter[0]) {
            '$' => .decrqss,
            '+' => .xtgettcap,
            else => return false,
        };
        return true;
    }
    if (c.private == '=' and inter.len == 0 and c.final == 's') {
        // Legacy synchronized update (iTerm2): = 1 s begins, = 2 s ends.
        switch (c.get(0, 0)) {
            1 => t.setMode(.synchronized_output, true),
            2 => t.setMode(.synchronized_output, false),
            else => {},
        }
        return false;
    }
    return false;
}

/// Buffers query payload.
pub fn put(t: *Terminal, bytes: []const u8) void {
    const st = &t.dcs_state;
    if (st.kind == .none or st.overflow) return;
    if (st.buf.items.len + bytes.len > max_payload) {
        st.overflow = true;
        return;
    }
    st.buf.appendSlice(t.gpa, bytes) catch {
        st.overflow = true;
        t.allocFailed();
    };
}

/// Answers the query.
pub fn unhook(t: *Terminal) void {
    const st = &t.dcs_state;
    defer st.reset();
    switch (st.kind) {
        .none => {},
        .decrqss => if (st.overflow) t.reply("\x1bP0$r\x1b\\") else decrqss(t, st.buf.items),
        .xtgettcap => if (!st.overflow) xtgettcap(t, st.buf.items),
    }
}

/// DECRQSS: `DCS 1 $ r <setting> ST` for known settings, `DCS 0 $ r ST`
/// otherwise. Replies are built only from terminal state.
pub fn decrqss(t: *Terminal, q: []const u8) void {
    const s = t.screen();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const ok = blk: {
        w.writeAll("\x1bP1$r") catch break :blk false;
        if (std.mem.eql(u8, q, "m")) {
            sgr.format(s.cursor.style, &w) catch break :blk false;
            w.writeAll("m") catch break :blk false;
        } else if (std.mem.eql(u8, q, "r")) {
            w.print("{d};{d}r", .{ s.region.top + 1, s.region.bottom + 1 }) catch break :blk false;
        } else if (std.mem.eql(u8, q, "s")) {
            w.print("{d};{d}s", .{ s.region.left + 1, s.region.right + 1 }) catch break :blk false;
        } else if (std.mem.eql(u8, q, "\"q")) {
            w.print("{d}\"q", .{@as(u8, if (s.cursor.protected) 1 else 0)}) catch break :blk false;
        } else if (std.mem.eql(u8, q, " q")) {
            w.print("{d} q", .{@intFromEnum(t.cursor_shape)}) catch break :blk false;
        } else if (std.mem.eql(u8, q, "\"p")) {
            w.writeAll("62;1\"p") catch break :blk false;
        } else break :blk false;
        w.writeAll("\x1b\\") catch break :blk false;
        break :blk true;
    };
    if (ok) t.reply(w.buffered()) else t.reply("\x1bP0$r\x1b\\");
}

/// The capabilities XTGETTCAP answers (see docs/xtgettcap.md).
pub const tcap = [_]struct { []const u8, []const u8 }{
    .{ "TN", "xterm-256color" },
    .{ "name", "xterm-256color" },
    .{ "Co", "256" },
    .{ "colors", "256" },
    .{ "RGB", "8/8/8" },
    .{ "Smulx", "\x1b[4:%p1%dm" },
    .{ "Setulc", "\x1b[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%dm" },
    .{ "Ms", "\x1b]52;%p1%s;%p2%s\x07" },
    .{ "Sync", "\x1b[?2026%?%p1%{1}%-%tl%eh%;" },
    .{ "kbs", "\x7f" },
};

fn lookupCap(name: []const u8) ?[]const u8 {
    for (tcap) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    return null;
}

/// XTGETTCAP: one `DCS 1 + r <hex>=<hexvalue> ST` per known name and
/// `DCS 0 + r <hex> ST` per unknown or malformed one.
pub fn xtgettcap(t: *Terminal, q: []const u8) void {
    var it = std.mem.splitScalar(u8, q, ';');
    while (it.next()) |hex| {
        var nb: [64]u8 = undefined;
        const name: ?[]const u8 = if (hex.len % 2 == 0 and hex.len / 2 <= nb.len)
            std.fmt.hexToBytes(nb[0 .. hex.len / 2], hex) catch null
        else
            null;
        // Echo the name only when it is valid hex (and so cannot inject).
        const safe_hex = name != null;
        var out: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        const val = if (name) |n| lookupCap(n) else null;
        if (val) |v| {
            w.print("\x1bP1+r{s}=", .{hex}) catch continue;
            for (v) |b| w.print("{X:0>2}", .{b}) catch continue;
            w.writeAll("\x1b\\") catch continue;
        } else if (safe_hex) {
            w.print("\x1bP0+r{s}\x1b\\", .{hex}) catch continue;
        } else {
            w.writeAll("\x1bP0+r\x1b\\") catch continue;
        }
        t.reply(w.buffered());
    }
}
