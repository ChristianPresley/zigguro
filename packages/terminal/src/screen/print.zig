//! The print path: `printAscii` (the parser's fast-path target, a memset-like
//! loop) and `print` (any code points: charsets, widths, grapheme clusters,
//! wide characters, autowrap and insert mode).
//!
//! Width modes: in legacy mode each code point has its own wcwidth and only
//! zero-width code points join the previous cell; in grapheme mode (DEC mode
//! 2027) code points join while UAX #29 finds no boundary and the cell takes
//! the cluster's width, widening in place from 1 to 2 when needed.

const std = @import("std");
const Screen = @import("Screen.zig");
const Page = @import("Page.zig");
const PageList = @import("PageList.zig");
const unicode = @import("unicode.zig");
const Cell = Page.Cell;
const Pin = PageList.Pin;

/// DEC Special Graphics for 0x5F..0x7E (VT100 line drawing).
const dec_special = [32]u21{
    0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0,
    0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C,
    0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534,
    0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
};

fn translate(s: *Screen, cp: u21) u21 {
    const which = if (s.charsets.single) |g| blk: {
        s.charsets.single = null;
        break :blk g;
    } else s.charsets.gl;
    return switch (s.charsets.g[which]) {
        .ascii => cp,
        .dec_special => if (cp >= 0x5F and cp <= 0x7E) dec_special[cp - 0x5F] else cp,
        .uk => if (cp == '#') 0x00A3 else cp,
    };
}

/// Right edge for printing: the right margin when the cursor is inside the
/// margins, else the last column.
fn rightEdge(s: *const Screen) u16 {
    return if (s.cursor.x <= s.region.right) s.region.right else s.width() - 1;
}

/// Soft-wraps: marks the row, moves to the left margin of the next row
/// (scrolling at the bottom margin).
fn wrap(s: *Screen) void {
    const p = s.rowPin(s.cursor.y);
    p.row().wrap = true;
    s.index(.{}) catch {}; // an allocation failure keeps the cursor row
    s.cursor.x = s.region.left;
    s.rowPin(s.cursor.y).row().wrap_continuation = true;
}

fn applyPendingWrap(s: *Screen) void {
    if (!s.cursor.pending_wrap) return;
    s.cursor.pending_wrap = false;
    if (s.modes.autowrap) wrap(s);
}

/// Prepares cells `[x, x+n)` of `p` for overwriting: breaks wide characters
/// cut by either edge and releases what the cells reference.
fn prepare(p: Pin, x: u16, n: u16) void {
    const cs = p.cells();
    const page = &p.node.page;
    if (cs[x].wide == .spacer_tail and x > 0) page.clearCell(&cs[x - 1], .blank);
    const end = x + n; // exclusive
    if (cs[end - 1].wide == .wide and end < cs.len) page.clearCell(&cs[end], .blank);
    const r = p.row();
    // Plain rows hold no references: the caller overwrites the cells anyway.
    if (r.styled or r.has_grapheme or r.has_hyperlink) page.clearCells(r, cs[x..end], .blank);
}

fn writeRun(s: *Screen, run: []const u8) void {
    if (run.len == 0) return;
    const p = s.rowPin(s.cursor.y);
    const n: u16 = @intCast(run.len);
    const x = s.cursor.x;
    prepare(p, x, n);
    const page = &p.node.page;
    const r = p.row();
    const id = s.styleIn(p.node, n);
    const proto: Cell = .{ .style = id, .protected = s.cursor.protected, .semantic = s.cursor.semantic };
    const cs = p.cells()[x..][0..n];
    // `content` is the low 24 bits of the packed cell: OR the byte in.
    const bits: u64 = @bitCast(proto);
    const words: []u64 = @ptrCast(cs);
    // Explicit 8-wide vectors: the scalar loop does not vectorise reliably.
    const bv: @Vector(8, u64) = @splat(bits);
    var i: usize = 0;
    while (i + 8 <= words.len) : (i += 8) {
        const bytes: @Vector(8, u8) = run[i..][0..8].*;
        words[i..][0..8].* = bv | @as(@Vector(8, u64), bytes);
    }
    while (i < words.len) : (i += 1) words[i] = bits | run[i];
    if (id != 0) r.styled = true;
    if (s.cursor.link) |l| {
        r.has_hyperlink = true;
        for (cs) |*c| {
            const lid = page.internLink(.{ .uri = l.uri, .id = l.id }) catch break;
            page.attachLink(c, lid);
        }
    }
    r.dirty = true;
}

/// Prints `run` (bytes 0x20..0x7E) at the cursor.
pub fn printAscii(s: *Screen, run_in: []const u8) void {
    if (run_in.len == 0) return;
    if (s.modes.insert or s.charsets.single != null or s.charsets.g[s.charsets.gl] != .ascii) {
        for (run_in) |b| printOne(s, b);
        return;
    }
    var run = run_in;
    while (run.len > 0) {
        applyPendingWrap(s);
        const right = rightEdge(s);
        const avail: usize = right - s.cursor.x + 1;
        if (run.len <= avail or s.modes.autowrap) {
            const n = @min(run.len, avail);
            writeRun(s, run[0..n]);
            s.cursor.x += @intCast(n);
            if (s.cursor.x > right) {
                s.cursor.x = right;
                s.cursor.pending_wrap = s.modes.autowrap;
            }
            run = run[n..];
        } else {
            // No autowrap: the rest of the line keeps overwriting the last column.
            writeRun(s, run[0 .. avail - 1]);
            s.cursor.x = right;
            writeRun(s, run[run.len - 1 ..]);
            run = run[run.len..];
        }
    }
    s.last_cluster[0] = run_in[run_in.len - 1];
    s.last_len = 1;
    s.pages.dirty_generation +%= 1;
}

/// Prints code points at the cursor.
pub fn print(s: *Screen, cps: []const u21) void {
    var i: usize = 0;
    while (i < cps.len) {
        const n = fastRun(s, cps[i..]);
        if (n > 0) {
            i += n;
        } else {
            printOne(s, cps[i]);
            i += 1;
        }
    }
    s.pages.dirty_generation +%= 1;
}

/// Writes the longest prefix of `cps` that needs none of the general
/// path's work: legacy width mode, no insert mode or single shift, code
/// points of width 1 or 2 that fit before the right edge, and ASCII only
/// while GL holds ASCII (no charset maps it). Returns how many code points
/// were written (0 to fall back).
fn fastRun(s: *Screen, cps: []const u21) usize {
    if (s.modes.grapheme or s.modes.insert or s.charsets.single != null) return 0;
    const ascii_ok = s.charsets.g[s.charsets.gl] == .ascii;
    const wo = s.widthOptions();
    // Only wrap once the first code point is known to print here: a
    // zero-width mark after the last column must join it, not wrap.
    if (cps.len == 0 or (cps[0] < 0x80 and !ascii_ok)) return 0;
    const w0 = unicode.wcwidth(cps[0], wo);
    if (w0 != 1 and w0 != 2) return 0;
    applyPendingWrap(s);
    const right = rightEdge(s);
    var x = s.cursor.x;
    var n: usize = 0;
    var cells: u16 = 0;
    // Widths from the scan, so the write loop does not look them up again.
    var widths: [256]u8 = undefined;
    const limit = @min(cps.len, widths.len);
    while (n < limit) : (n += 1) {
        const cp = cps[n];
        if (cp < 0x80 and !ascii_ok) break;
        const w = unicode.wcwidth(cp, wo);
        if (w != 1 and w != 2) break;
        const wu: u16 = @intCast(w);
        if (x + wu > right + 1) break;
        widths[n] = @intCast(w);
        x += wu;
        cells += wu;
    }
    if (n == 0) return 0;
    const p = s.rowPin(s.cursor.y);
    const x0 = s.cursor.x;
    prepare(p, x0, cells);
    const r = p.row();
    const page = &p.node.page;
    const id = s.styleIn(p.node, cells);
    const proto: Cell = .{ .style = id, .protected = s.cursor.protected, .semantic = s.cursor.semantic };
    const cs = p.cells();
    var cx = x0;
    for (cps[0..n], widths[0..n]) |cp, w| {
        var c = proto;
        c.content = @intCast(cp);
        if (w == 2) {
            c.wide = .wide;
            cs[cx] = c;
            var t = proto;
            t.wide = .spacer_tail;
            cs[cx + 1] = t;
            cx += 2;
        } else {
            cs[cx] = c;
            cx += 1;
        }
    }
    if (id != 0) r.styled = true;
    if (s.cursor.link) |l| {
        r.has_hyperlink = true;
        var k = x0;
        while (k < cx) : (k += 1) {
            if (cs[k].wide == .spacer_tail) continue;
            const lid = page.internLink(.{ .uri = l.uri, .id = l.id }) catch break;
            page.attachLink(&cs[k], lid);
        }
    }
    r.dirty = true;
    if (cx > right) {
        s.cursor.x = right;
        s.cursor.pending_wrap = s.modes.autowrap;
    } else s.cursor.x = cx;
    s.last_cluster[0] = cps[n - 1];
    s.last_len = 1;
    return n;
}

/// The cell the next code point may join: the last written cell before the
/// cursor (following a soft wrap back to the previous row).
fn previousCell(s: *Screen) ?struct { pin: Pin, x: u16 } {
    const c = s.cursor;
    var p = s.rowPin(c.y);
    var x: u16 = undefined;
    if (c.pending_wrap) {
        x = c.x;
    } else if (c.x > 0) {
        x = c.x - 1;
    } else {
        if (c.y == 0 or !p.row().wrap_continuation) return null;
        p = s.rowPin(c.y - 1);
        x = s.width() - 1;
    }
    const cs = p.cells();
    if (cs[x].wide == .spacer_tail and x > 0) x -= 1;
    if (cs[x].wide == .spacer_head and x > 0) {
        x -= 1;
        if (cs[x].wide == .spacer_tail and x > 0) x -= 1;
    }
    if (cs[x].isEmpty()) return null;
    return .{ .pin = p, .x = x };
}

fn clusterOf(page: *const Page, c: *const Cell, out: *[17]u21) []const u21 {
    out[0] = c.codepoint();
    var n: usize = 1;
    if (page.grapheme(c)) |extra| {
        @memcpy(out[1..][0..extra.len], extra);
        n += extra.len;
    }
    return out[0..n];
}

fn printOne(s: *Screen, cp_in: u21) void {
    const cp = translate(s, cp_in);
    const wo = s.widthOptions();
    const w = unicode.wcwidth(cp, wo);
    if (w < 0) return;

    // In legacy mode only zero-width code points join the previous cell.
    if ((s.modes.grapheme or w == 0) and previousCell(s) != null) {
        const prev = previousCell(s).?;
        const page = &prev.pin.node.page;
        const cell = &prev.pin.cells()[prev.x];
        var buf: [17]u21 = undefined;
        const cluster = clusterOf(page, cell, &buf);
        const join = if (s.modes.grapheme) blk: {
            var st: unicode.BreakState = .{};
            _ = unicode.isBreak(&st, 0, cluster[0]);
            for (cluster[1..], 0..) |x, i| _ = unicode.isBreak(&st, cluster[i], x);
            break :blk !unicode.isBreak(&st, cluster[cluster.len - 1], cp);
        } else w == 0;
        if (join) {
            attach(s, prev.pin, prev.x, cp);
            return;
        }
    }
    if (w == 0) return; // nothing to attach to (xterm ignores it)
    writeCell(s, cp, @intCast(w));
    s.last_cluster[0] = cp;
    s.last_len = 1;
}

fn attach(s: *Screen, p: Pin, x: u16, cp: u21) void {
    const page = &p.node.page;
    const cs = p.cells();
    page.appendGrapheme(&cs[x], cp) catch return;
    p.row().has_grapheme = true;
    p.row().dirty = true;
    if (s.last_len > 0 and s.last_len < s.last_cluster.len) {
        s.last_cluster[s.last_len] = cp;
        s.last_len += 1;
    }
    if (!s.modes.grapheme or cs[x].wide != .narrow) return;
    var buf: [17]u21 = undefined;
    if (unicode.graphemeWidth(clusterOf(page, &cs[x], &buf), s.widthOptions()) < 2) return;
    // Widen in place when the next column is available.
    const right = rightEdge(s);
    if (x + 1 > right or x + 1 >= cs.len) return;
    if (cs[x + 1].wide == .wide) s.splitWide(p, x + 1);
    page.clearCell(&cs[x + 1], .blank);
    cs[x].wide = .wide;
    cs[x + 1] = .{ .wide = .spacer_tail, .style = cs[x].style, .semantic = cs[x].semantic };
    page.retainStyle(cs[x].style, 1);
    if (cs[x].style != 0) p.row().styled = true;
    // The cursor moves past the new tail.
    if (p.node == s.rowPin(s.cursor.y).node and p.y == s.rowPin(s.cursor.y).y and !s.cursor.pending_wrap and s.cursor.x == x + 1) {
        if (x + 2 > right) {
            s.cursor.x = right;
            s.cursor.pending_wrap = s.modes.autowrap;
        } else s.cursor.x = x + 2;
    }
}

fn writeCell(s: *Screen, cp: u21, w: u2) void {
    applyPendingWrap(s);
    var right = rightEdge(s);
    if (w == 2 and s.cursor.x == right) {
        if (s.modes.autowrap and right > s.region.left) {
            const p = s.rowPin(s.cursor.y);
            prepare(p, s.cursor.x, 1);
            p.cells()[s.cursor.x] = .{ .wide = .spacer_head };
            wrap(s);
            right = rightEdge(s);
        } else if (right == 0 or right <= s.region.left) {
            return; // a one-column region cannot hold a wide character
        } else {
            s.cursor.x = right - 1;
        }
    }
    if (s.modes.insert) s.insertCells(s.cursor.y, s.cursor.x, w, right, .{});
    const p = s.rowPin(s.cursor.y);
    const x = s.cursor.x;
    prepare(p, x, w);
    const page = &p.node.page;
    const r = p.row();
    const id = s.styleIn(p.node, w);
    const cs = p.cells();
    cs[x] = .{ .content = @intCast(cp), .style = id, .protected = s.cursor.protected, .semantic = s.cursor.semantic, .wide = if (w == 2) .wide else .narrow };
    if (w == 2) cs[x + 1] = .{ .style = id, .protected = s.cursor.protected, .semantic = s.cursor.semantic, .wide = .spacer_tail };
    if (id != 0) r.styled = true;
    if (s.cursor.link) |l| {
        r.has_hyperlink = true;
        if (page.internLink(.{ .uri = l.uri, .id = l.id })) |lid| page.attachLink(&cs[x], lid) else |_| {}
    }
    r.dirty = true;
    const nx = x + w;
    if (nx > right) {
        s.cursor.x = right;
        s.cursor.pending_wrap = s.modes.autowrap;
    } else s.cursor.x = nx;
}

/// REP: prints the last printed cluster `n` more times.
pub fn repeat(s: *Screen, n: u16) void {
    if (s.last_len == 0) return;
    var cl: [17]u21 = undefined;
    const len = s.last_len;
    @memcpy(cl[0..len], s.last_cluster[0..len]);
    for (0..n) |_| {
        // Bypass charset translation: the stored cluster is already translated.
        const saved = s.charsets;
        s.charsets = .{};
        defer s.charsets = saved;
        for (cl[0..len]) |cp| printOne(s, cp);
    }
    s.pages.dirty_generation +%= 1;
}
