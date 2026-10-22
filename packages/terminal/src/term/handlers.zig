//! C0 controls, ESC functions and CSI dispatch: cursor movement, erase,
//! insert/delete, scrolling, margins, tabs, charsets, modes and resets, with
//! DEC VT510 / xterm semantics. Reports and queries are in `reports.zig`.

const std = @import("std");
const Terminal = @import("Terminal.zig");
const Parser = @import("../vt/Parser.zig");
const Csi = Parser.Csi;
const Esc = Parser.Esc;
const Screen = @import("../screen/Screen.zig");
const modes_mod = @import("modes.zig");
const ModeId = modes_mod.ModeId;
const Modes = modes_mod.Modes;
const sgr = @import("sgr.zig");
const charset = @import("charset.zig");
const reports = @import("reports.zig");

fn eraseOpts(s: *const Screen) Screen.EraseOpts {
    return .{ .bce = s.cursor.style };
}

fn origin(t: *const Terminal) bool {
    return t.modes.get(.origin);
}

/// Bounds for absolute cursor addressing (the margins in origin mode).
const Bounds = struct { top: u16, bottom: u16, left: u16, right: u16 };

fn bounds(t: *Terminal) Bounds {
    const s = t.screen();
    if (origin(t)) return .{ .top = s.region.top, .bottom = s.region.bottom, .left = s.region.left, .right = s.region.right };
    return .{ .top = 0, .bottom = s.height() - 1, .left = 0, .right = s.width() - 1 };
}

/// Moves the cursor to 1-based (row, col), origin-aware and clamped.
pub fn cursorTo(t: *Terminal, row: u16, col: u16) void {
    const s = t.screen();
    const b = bounds(t);
    s.cursor.y = @min(b.top +| (@max(row, 1) - 1), b.bottom);
    s.cursor.x = @min(b.left +| (@max(col, 1) - 1), b.right);
    s.cursor.pending_wrap = false;
}

fn setColumn(t: *Terminal, col: u16) void {
    const s = t.screen();
    const b = bounds(t);
    s.cursor.x = @min(b.left +| (@max(col, 1) - 1), b.right);
    s.cursor.pending_wrap = false;
}

fn setRow(t: *Terminal, row: u16) void {
    const s = t.screen();
    const b = bounds(t);
    s.cursor.y = @min(b.top +| (@max(row, 1) - 1), b.bottom);
    s.cursor.pending_wrap = false;
}

fn cursorUp(s: *Screen, n: u16) void {
    const lim: u16 = if (s.cursor.y >= s.region.top) s.region.top else 0;
    s.cursor.y = @max(s.cursor.y -| n, lim);
    s.cursor.pending_wrap = false;
}

fn cursorDown(s: *Screen, n: u16) void {
    const lim: u16 = if (s.cursor.y <= s.region.bottom) s.region.bottom else s.height() - 1;
    s.cursor.y = @min(s.cursor.y +| n, lim);
    s.cursor.pending_wrap = false;
}

fn cursorRight(s: *Screen, n: u16) void {
    const lim: u16 = if (s.cursor.x <= s.region.right) s.region.right else s.width() - 1;
    s.cursor.x = @min(s.cursor.x +| n, lim);
    s.cursor.pending_wrap = false;
}

fn cursorLeft(s: *Screen, n: u16) void {
    const lim: u16 = if (s.cursor.x >= s.region.left) s.region.left else 0;
    s.cursor.x = @max(s.cursor.x -| n, lim);
    s.cursor.pending_wrap = false;
}

fn carriageReturn(t: *Terminal) void {
    const s = t.screen();
    s.cursor.x = if (s.cursor.x >= s.region.left or origin(t)) s.region.left else 0;
    s.cursor.pending_wrap = false;
}

fn index(t: *Terminal) void {
    const s = t.screen();
    s.index(eraseOpts(s)) catch t.allocFailed();
}

fn reverseIndex(t: *Terminal) void {
    const s = t.screen();
    s.reverseIndex(eraseOpts(s)) catch t.allocFailed();
}

fn backspace(t: *Terminal) void {
    const s = t.screen();
    const rw = t.modes.get(.reverse_wrap);
    if (s.cursor.pending_wrap) {
        s.cursor.pending_wrap = false;
        // With reverse wrap the pending wrap absorbs the backspace.
        if (rw) return;
    }
    const lim: u16 = if (s.cursor.x >= s.region.left) s.region.left else 0;
    if (s.cursor.x > lim) {
        s.cursor.x -= 1;
    } else if (rw and s.cursor.y > 0 and s.rowPin(s.cursor.y - 1).row().wrap) {
        s.cursor.y -= 1;
        s.cursor.x = s.region.right;
    }
}

fn tabRightEdge(s: *const Screen) u16 {
    return if (s.cursor.x <= s.region.right) s.region.right else s.width() - 1;
}

fn tabForward(t: *Terminal, n: u16) void {
    const s = t.screen();
    for (0..n) |_| s.cursor.x = t.tabs.next(s.cursor.x, tabRightEdge(s));
    s.cursor.pending_wrap = false;
}

fn tabBack(t: *Terminal, n: u16) void {
    const s = t.screen();
    const lim: u16 = if (s.cursor.x >= s.region.left) s.region.left else 0;
    for (0..n) |_| s.cursor.x = t.tabs.prev(s.cursor.x, lim);
    s.cursor.pending_wrap = false;
}

/// C0 controls.
pub fn execute(t: *Terminal, c: u8) void {
    const s = t.screen();
    s.last_len = 0;
    switch (c) {
        0x07 => t.bell(),
        0x08 => backspace(t),
        0x09 => tabForward(t, 1),
        0x0A, 0x0B, 0x0C => {
            index(t);
            if (t.modes.get(.linefeed)) carriageReturn(t);
        },
        0x0D => carriageReturn(t),
        0x0E => s.charsets.gl = 1,
        0x0F => s.charsets.gl = 0,
        // 8-bit C1 equivalents, when the parser delivers them.
        0x84 => index(t),
        0x85 => {
            index(t);
            carriageReturn(t);
        },
        0x88 => t.tabs.set(s.cursor.x),
        0x8D => reverseIndex(t),
        0x8E => s.charsets.single = 2,
        0x8F => s.charsets.single = 3,
        else => {},
    }
}

/// ESC functions.
pub fn escDispatch(t: *Terminal, e: Esc) void {
    const s = t.screen();
    s.last_len = 0;
    const inter = e.intermediates();
    if (inter.len == 1) {
        if (charset.slot(inter[0])) |g| {
            if (charset.fromFinal(e.final)) |cs| s.charsets.g[g] = cs;
            return;
        }
        if (inter[0] == '#' and e.final == '8') return decaln(t);
        return;
    }
    if (inter.len != 0) return;
    switch (e.final) {
        'D' => index(t),
        'E' => {
            index(t);
            carriageReturn(t);
        },
        'H' => t.tabs.set(s.cursor.x),
        'M' => reverseIndex(t),
        'N' => s.charsets.single = 2,
        'O' => s.charsets.single = 3,
        'n' => s.charsets.gl = 2,
        'o' => s.charsets.gl = 3,
        '~' => s.charsets.gr = 1,
        '}' => s.charsets.gr = 2,
        '|' => s.charsets.gr = 3,
        '7' => s.saveCursor(origin(t)),
        '8' => restoreCursor(t),
        '=' => t.keypad_application = true,
        '>' => t.keypad_application = false,
        'c' => t.fullReset(),
        '6' => backIndex(t),
        '9' => forwardIndex(t),
        else => {},
    }
}

fn restoreCursor(t: *Terminal) void {
    const s = t.screen();
    const o = s.restoreCursor();
    t.modes.set(.origin, o);
    t.modes.set(.autowrap, s.modes.autowrap);
    t.syncScreenModes();
}

/// DECALN: fills the screen with 'E', resets the margins and homes the cursor.
fn decaln(t: *Terminal) void {
    const s = t.screen();
    s.region = s.fullRegion();
    t.modes.set(.origin, false);
    const saved_style = s.cursor.style;
    const saved_insert = s.modes.insert;
    s.setStyle(.{});
    s.modes.insert = false;
    const es: [256]u8 = @splat('E');
    for (0..s.height()) |y| {
        s.cursor.y = @intCast(y);
        s.cursor.x = 0;
        s.cursor.pending_wrap = false;
        var left: usize = s.width();
        while (left > 0) {
            const n = @min(left, es.len);
            s.printAscii(es[0..n]);
            left -= n;
        }
    }
    s.setStyle(saved_style);
    s.modes.insert = saved_insert;
    s.cursor.x = 0;
    s.cursor.y = 0;
    s.cursor.pending_wrap = false;
    s.last_len = 0;
}

/// DECBI: back index; at the left margin the region scrolls right.
fn backIndex(t: *Terminal) void {
    const s = t.screen();
    s.cursor.pending_wrap = false;
    if (s.cursor.x == s.region.left and s.cursor.y >= s.region.top and s.cursor.y <= s.region.bottom) {
        s.insertColumns(s.region.left, 1, s.region, eraseOpts(s));
    } else if (s.cursor.x > 0) s.cursor.x -= 1;
}

/// DECFI: forward index; at the right margin the region scrolls left.
fn forwardIndex(t: *Terminal) void {
    const s = t.screen();
    s.cursor.pending_wrap = false;
    if (s.cursor.x == s.region.right and s.cursor.y >= s.region.top and s.cursor.y <= s.region.bottom) {
        s.deleteColumns(s.region.left, 1, s.region, eraseOpts(s));
    } else if (s.cursor.x < s.width() - 1) s.cursor.x += 1;
}

/// The first param with 0 treated as 1 (cursor counts).
fn count(c: *const Csi) u16 {
    return @max(c.get(0, 1), 1);
}

/// CSI dispatch.
pub fn csiDispatch(t: *Terminal, c: *const Csi) void {
    const s = t.screen();
    if (c.final != 'b') s.last_len = 0;
    const inter = c.intermediates();
    if (inter.len > 0) return csiIntermediate(t, c, inter);
    switch (c.private) {
        0 => {},
        '?' => return csiPrivate(t, c),
        '>' => return csiGreater(t, c),
        '<' => if (c.final == 'u') {
            s.kitty_kb.pop(count(c));
            return;
        } else return,
        '=' => switch (c.final) {
            'c' => return reports.da3(t),
            'u' => {
                s.kitty_kb.set(@intCast(@min(c.get(0, 0), 31)), @intCast(@min(c.get(1, 1), 255)));
                return;
            },
            else => return,
        },
        else => return,
    }
    switch (c.final) {
        'A' => cursorUp(s, count(c)),
        'B', 'e' => if (c.final == 'B') cursorDown(s, count(c)) else {
            // VPR: relative row, clamped like VPA.
            const b = bounds(t);
            s.cursor.y = @min(s.cursor.y +| count(c), b.bottom);
            s.cursor.pending_wrap = false;
        },
        'C' => cursorRight(s, count(c)),
        'D' => cursorLeft(s, count(c)),
        'E' => {
            cursorDown(s, count(c));
            carriageReturn(t);
        },
        'F' => {
            cursorUp(s, count(c));
            carriageReturn(t);
        },
        'G', '`' => setColumn(t, c.get(0, 1)),
        'a' => {
            const b = bounds(t);
            s.cursor.x = @min(s.cursor.x +| count(c), b.right);
            s.cursor.pending_wrap = false;
        },
        'H', 'f' => cursorTo(t, c.get(0, 1), c.get(1, 1)),
        'd' => setRow(t, c.get(0, 1)),
        'I' => tabForward(t, count(c)),
        'Z' => tabBack(t, count(c)),
        'J' => eraseDisplay(t, c.get(0, 0), false),
        'K' => eraseLine(t, c.get(0, 0), false),
        'X' => {
            const n = count(c);
            const end: u16 = if (s.cursor.x <= s.region.right) s.region.right + 1 else s.width();
            s.eraseCells(s.cursor.y, s.cursor.x, @min(s.cursor.x +| n, end), eraseOpts(s));
            s.cursor.pending_wrap = false;
        },
        '@' => if (inMargins(s)) {
            s.insertCells(s.cursor.y, s.cursor.x, count(c), s.region.right, eraseOpts(s));
            s.cursor.pending_wrap = false;
        },
        'P' => if (inMargins(s)) {
            s.deleteCells(s.cursor.y, s.cursor.x, count(c), s.region.right, eraseOpts(s));
            s.cursor.pending_wrap = false;
        },
        'L', 'M' => if (inMargins(s) and s.cursor.y >= s.region.top and s.cursor.y <= s.region.bottom) {
            const o = eraseOpts(s);
            const r = if (c.final == 'L') s.insertLines(s.cursor.y, count(c), s.region, o) else s.deleteLines(s.cursor.y, count(c), s.region, o);
            r catch t.allocFailed();
            s.cursor.x = s.region.left;
            s.cursor.pending_wrap = false;
        },
        'S' => s.scrollUp(s.region, count(c), eraseOpts(s)) catch t.allocFailed(),
        'T' => if (c.count <= 1) s.scrollDown(s.region, count(c), eraseOpts(s)) catch t.allocFailed(),
        'b' => s.repeat(count(c)),
        'g' => switch (c.get(0, 0)) {
            0 => t.tabs.clear(s.cursor.x),
            3 => t.tabs.clearAll(),
            else => {},
        },
        'r' => setTopBottom(t, c),
        's' => if (t.modes.get(.left_right_margins)) setLeftRight(t, c) else if (c.count == 0) s.saveCursor(origin(t)),
        'u' => if (c.count == 0) restoreCursor(t),
        'h', 'l' => for (0..c.count) |i| {
            if (Modes.lookup(.ansi, c.get(i, 0))) |id| t.setMode(id, c.final == 'h');
        },
        'm' => {
            var st = s.cursor.style;
            sgr.applySgr(&st, c);
            s.setStyle(st);
        },
        'c' => if (c.get(0, 0) == 0) reports.da1(t),
        'n' => reports.dsr(t, c),
        't' => reports.xtwinops(t, c),
        else => {},
    }
}

fn inMargins(s: *const Screen) bool {
    return s.cursor.x >= s.region.left and s.cursor.x <= s.region.right;
}

fn eraseDisplay(t: *Terminal, mode: u16, selective: bool) void {
    const s = t.screen();
    var o = eraseOpts(s);
    o.selective = selective;
    switch (mode) {
        0 => s.eraseDisplay(.below, o) catch t.allocFailed(),
        1 => s.eraseDisplay(.above, o) catch t.allocFailed(),
        2 => {
            if (!selective and !t.alt_active and t.opts.clear_pushes_to_scrollback) {
                pushToScrollback(t, o);
            } else s.eraseDisplay(.all, o) catch t.allocFailed();
        },
        3 => if (!selective) s.eraseDisplay(.scrollback, o) catch t.allocFailed(),
        else => {},
    }
}

/// ED 2 with `clear_pushes_to_scrollback`: scrolls the rows up to the last
/// non-blank one into scrollback; the cursor does not move.
fn pushToScrollback(t: *Terminal, o: Screen.EraseOpts) void {
    const s = t.screen();
    var last: ?u16 = null;
    var y: u16 = s.height();
    while (y > 0) {
        y -= 1;
        for (s.rowPin(y).cells()) |cell| if (@as(u64, @bitCast(cell)) != 0) {
            last = y;
            break;
        };
        if (last != null) break;
    }
    const n = if (last) |l| l + 1 else 0;
    if (n > 0) s.scrollUp(s.fullRegion(), n, o) catch t.allocFailed();
    // Rows that were already blank still take the BCE colour.
    s.eraseDisplay(.all, o) catch t.allocFailed();
}

fn eraseLine(t: *Terminal, mode: u16, selective: bool) void {
    const s = t.screen();
    var o = eraseOpts(s);
    o.selective = selective;
    const x = s.cursor.x;
    switch (mode) {
        0 => s.eraseCells(s.cursor.y, x, s.width(), o),
        1 => s.eraseCells(s.cursor.y, 0, x + 1, o),
        2 => s.eraseCells(s.cursor.y, 0, s.width(), o),
        else => {},
    }
    s.cursor.pending_wrap = false;
}

/// DECSTBM.
fn setTopBottom(t: *Terminal, c: *const Csi) void {
    const s = t.screen();
    const top = @max(c.get(0, 1), 1);
    var bottom = c.get(1, s.height());
    if (bottom == 0 or bottom > s.height()) bottom = s.height();
    if (top >= bottom) return;
    s.region.top = top - 1;
    s.region.bottom = bottom - 1;
    cursorTo(t, 1, 1);
}

/// DECSLRM (only with DECLRMM).
fn setLeftRight(t: *Terminal, c: *const Csi) void {
    const s = t.screen();
    const left = @max(c.get(0, 1), 1);
    var right = c.get(1, s.width());
    if (right == 0 or right > s.width()) right = s.width();
    if (left >= right) return;
    s.region.left = left - 1;
    s.region.right = right - 1;
    cursorTo(t, 1, 1);
}

fn csiPrivate(t: *Terminal, c: *const Csi) void {
    const s = t.screen();
    switch (c.final) {
        'h', 'l' => for (0..c.count) |i| {
            if (Modes.lookup(.dec, c.get(i, 0))) |id| t.setMode(id, c.final == 'h');
        },
        's' => for (0..c.count) |i| {
            if (Modes.lookup(.dec, c.get(i, 0))) |id| t.modes.save(id);
        },
        'r' => for (0..c.count) |i| {
            if (Modes.lookup(.dec, c.get(i, 0))) |id| t.setMode(id, t.modes.savedValue(id));
        },
        'J' => eraseDisplay(t, c.get(0, 0), true),
        'K' => eraseLine(t, c.get(0, 0), true),
        'n' => reports.dsrPrivate(t, c),
        'u' => t.replyFmt("\x1b[?{d}u", .{s.kitty_kb.current()}),
        else => {},
    }
}

fn csiGreater(t: *Terminal, c: *const Csi) void {
    const s = t.screen();
    switch (c.final) {
        'c' => if (c.get(0, 0) == 0) reports.da2(t),
        'q' => if (c.get(0, 0) == 0) reports.xtversion(t),
        'u' => s.kitty_kb.push(@intCast(@min(c.get(0, 0), 31))),
        // XTMODKEYS: only modifyOtherKeys (resource 4) affects encoding.
        'm' => if (c.get(0, 0) == 4) {
            t.modify_other_keys = if (c.count >= 2) @intCast(@min(c.get(1, 0), 2)) else 0;
        },
        else => {},
    }
}

fn csiIntermediate(t: *Terminal, c: *const Csi, inter: []const u8) void {
    const s = t.screen();
    if (inter.len != 1) return;
    switch (inter[0]) {
        '!' => if (c.final == 'p' and c.private == 0) softReset(t),
        ' ' => if (c.final == 'q' and c.private == 0) {
            const ps = c.get(0, 0);
            if (ps > 6) return;
            t.cursor_shape = @enumFromInt(@max(ps, 1));
            t.effects.push(.cursor_shape_changed);
        },
        '"' => if (c.final == 'q' and c.private == 0) {
            s.cursor.protected = c.get(0, 0) == 1;
        },
        '\'' => if (c.private == 0 and (c.final == '}' or c.final == '~') and inMargins(s) and
            s.cursor.y >= s.region.top and s.cursor.y <= s.region.bottom)
        {
            if (c.final == '}') {
                s.insertColumns(s.cursor.x, count(c), s.region, eraseOpts(s));
            } else s.deleteColumns(s.cursor.x, count(c), s.region, eraseOpts(s));
        },
        '$' => if (c.final == 'p') reports.decrqm(t, if (c.private == '?') .dec else .ansi, c.get(0, 0)),
        else => {},
    }
}

/// DECSTR (VT510 soft reset).
pub fn softReset(t: *Terminal) void {
    const s = t.screen();
    t.setMode(.cursor_visible, true);
    t.setMode(.insert, false);
    t.modes.set(.origin, false); // no homing, unlike DECRST 6
    t.setMode(.autowrap, true);
    t.setMode(.cursor_keys, false);
    t.keypad_application = false;
    s.region = s.fullRegion();
    s.setStyle(.{});
    s.cursor.protected = false;
    s.charsets = .{};
    s.saved = null;
    s.cursor.pending_wrap = false;
}

/// Side effects of a mode change (called by `Terminal.setMode` before the
/// screens' mode copies are refreshed).
pub fn onModeChanged(t: *Terminal, id: ModeId, on: bool, was: bool) void {
    const s = t.screen();
    switch (id) {
        .origin => cursorTo(t, 1, 1),
        .column_132 => if (t.modes.get(.allow_column_132)) {
            s.region = s.fullRegion();
            s.eraseDisplay(.all, eraseOpts(s)) catch t.allocFailed();
            s.cursor.x = 0;
            s.cursor.y = 0;
            s.cursor.pending_wrap = false;
        },
        .left_right_margins => if (!on) {
            s.region.left = 0;
            s.region.right = s.width() - 1;
        },
        .alt_screen_legacy => t.switchScreen(on),
        .alt_screen => {
            if (!on and t.alt_active) {
                // 1047 clears the alternate screen when leaving it.
                t.alternate.eraseDisplay(.all, .{}) catch t.allocFailed();
            }
            t.switchScreen(on);
        },
        .save_cursor => if (on) s.saveCursor(origin(t)) else restoreCursor(t),
        .alt_screen_save => if (on and !t.alt_active) {
            t.primary.saveCursor(origin(t));
            t.switchScreen(true);
            t.alternate.eraseDisplay(.all, eraseOpts(&t.alternate)) catch t.allocFailed();
        } else if (!on and t.alt_active) {
            t.switchScreen(false);
            const o = t.primary.restoreCursor();
            t.modes.set(.origin, o);
            t.modes.set(.autowrap, t.primary.modes.autowrap);
        },
        .mouse_x10, .mouse_normal, .mouse_button, .mouse_any => if (on) {
            // Tracking modes are exclusive: the last one set wins.
            inline for (.{ ModeId.mouse_x10, ModeId.mouse_normal, ModeId.mouse_button, ModeId.mouse_any }) |m| {
                if (m != id) t.modes.set(m, false);
            }
        },
        .in_band_resize => if (on and !was) reports.inBandSize(t),
        else => {},
    }
}
