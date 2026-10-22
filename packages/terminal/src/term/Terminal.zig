//! The terminal: two screens (primary with scrollback, alternate without),
//! the mode table, palette, tab stops, title and the reply and effect queues,
//! driven by the VT parser. `feed` is the only entry point for host output;
//! the parser calls the handler methods below, which dispatch to
//! `handlers.zig` (C0/ESC/CSI), `reports.zig`, `dcs.zig` and `osc.zig`.
//!
//! The terminal is headless and single-threaded: the session (E06.F01) owns
//! locking, drains `replies` back to the PTY and hands `effects` to the view.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("../vt/Parser.zig");
const Csi = Parser.Csi;
const Esc = Parser.Esc;
const StringTerm = Parser.StringTerm;
const Screen = @import("../screen/Screen.zig");
const modes_mod = @import("modes.zig");
const Modes = modes_mod.Modes;
const ModeId = modes_mod.ModeId;
const color = @import("color.zig");
const Palette = color.Palette;
const Tabstops = @import("tabstops.zig");
const effects_mod = @import("effects.zig");
const EffectQueue = effects_mod.EffectQueue;
const Effect = effects_mod.Effect;
const handlers = @import("handlers.zig");
const reports = @import("reports.zig");
const dcs = @import("dcs.zig");
const osc = @import("osc.zig");
const mark = @import("../shell/mark.zig");

const log = std.log.scoped(.terminal);

const Terminal = @This();

/// Construction options.
pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    /// Byte cap of the primary screen's pages (scrollback included).
    max_scrollback_bytes: usize = 64 << 20,
    /// `terminal.risClearsScrollback`: RIS also erases scrollback.
    ris_clears_scrollback: bool = false,
    /// `terminal.clearPushesToScrollback`: ED 2 on the primary screen moves
    /// the cleared rows into scrollback instead of discarding them.
    clear_pushes_to_scrollback: bool = true,
    /// `terminal.clipboard.maxBytes`: larger OSC 52 writes are dropped.
    clipboard_max: usize = 8 << 20,
    /// Reported by XTVERSION as `zigguro(<version>)`.
    version: []const u8 = "0.1.0",
    /// This machine's host name, for OSC 7 host classification.
    hostname: []const u8 = "",
    /// The shell-integration nonce (hex) that marks OSC 633;E as trusted.
    shell_nonce: ?[]const u8 = null,
    parser: Parser.Options = .{},
};

/// DECSCUSR cursor shapes (Ps 1-6; 0 means 1).
pub const CursorShape = enum(u8) {
    blinking_block = 1,
    steady_block = 2,
    blinking_underline = 3,
    steady_underline = 4,
    blinking_bar = 5,
    steady_bar = 6,
};

/// Counters for diagnostics.
pub const Stats = struct {
    /// Operations dropped because an allocation failed.
    alloc_failures: u32 = 0,
    bells_suppressed: u32 = 0,
    notifications_suppressed: u32 = 0,
};

/// XTWINOPS 22/23 title stack depth.
pub const title_stack_max = 10;
/// Maximum title and icon length in bytes.
pub const title_max = 1024;
/// Minimum interval between bells.
pub const bell_interval_ms = 100;
/// Minimum interval between notifications.
pub const notify_interval_ms = 1000;

const TitleEntry = struct { title: []u8, icon: []u8 };

gpa: Allocator,
opts: Options,
parser: Parser,
primary: Screen,
alternate: Screen,
alt_active: bool = false,
modes: Modes = .initial,
palette: Palette = .{},
/// The theme palette restored by RIS and the colour reset OSCs.
default_palette: Palette = .{},
tabs: Tabstops,
/// Bytes to write back to the host (drain with `clearReplies`).
replies: std.ArrayList(u8) = .empty,
limiter: reports.ReplyLimiter = .{},
effects: EffectQueue,
cursor_shape: CursorShape = .blinking_block,
/// DECKPAM (application keypad), consulted by key encoding (F04).
keypad_application: bool = false,
title: std.ArrayList(u8) = .empty,
icon: std.ArrayList(u8) = .empty,
title_stack: std.ArrayList(TitleEntry) = .empty,
/// Cell size in pixels from the view (0 when headless), for XTWINOPS.
cell_px: struct { w: u16 = 0, h: u16 = 0 } = .{},
/// Monotonic time in ms, set by the owner before `feed` (rate limits).
now_ms: u64 = 0,
last_bell_ms: ?u64 = null,
last_notify_ms: ?u64 = null,
mark_sink: ?mark.MarkSink = null,
/// OSC 1337 SetUserVar values.
user_vars: std.StringArrayHashMapUnmanaged([]u8) = .empty,
/// The OSC 52 read awaiting a decision, if any.
clip_read: ?StringTerm = null,
dcs_state: dcs.State = .{},
stats: Stats = .{},

/// Creates a blank terminal.
pub fn init(gpa: Allocator, o: Options) !Terminal {
    var primary: Screen = try .init(gpa, o.cols, o.rows, .{ .max_bytes = o.max_scrollback_bytes });
    errdefer primary.deinit();
    var alternate: Screen = try .init(gpa, o.cols, o.rows, .{ .scrollback = false, .max_bytes = 0 });
    errdefer alternate.deinit();
    var tabs: Tabstops = try .init(gpa, o.cols);
    errdefer tabs.deinit(gpa);
    var t: Terminal = .{
        .gpa = gpa,
        .opts = o,
        .parser = .init(gpa, o.parser),
        .primary = primary,
        .alternate = alternate,
        .tabs = tabs,
        .effects = .init(gpa),
    };
    t.syncScreenModes();
    return t;
}

/// Frees everything.
pub fn deinit(t: *Terminal) void {
    t.parser.deinit();
    t.primary.deinit();
    t.alternate.deinit();
    t.tabs.deinit(t.gpa);
    t.replies.deinit(t.gpa);
    t.effects.deinit();
    t.title.deinit(t.gpa);
    t.icon.deinit(t.gpa);
    for (t.title_stack.items) |e| {
        t.gpa.free(e.title);
        t.gpa.free(e.icon);
    }
    t.title_stack.deinit(t.gpa);
    t.clearUserVars();
    t.user_vars.deinit(t.gpa);
    t.dcs_state.deinit(t.gpa);
    t.* = undefined;
}

/// The active screen.
pub inline fn screen(t: *Terminal) *Screen {
    return if (t.alt_active) &t.alternate else &t.primary;
}

/// Columns.
pub fn cols(t: *const Terminal) u16 {
    return t.primary.width();
}

/// Rows.
pub fn rows(t: *const Terminal) u16 {
    return t.primary.height();
}

/// Input is accounted to the reply limiter in chunks of this size.
const feed_chunk = 64 * 1024;

/// Processes host output.
pub fn feed(t: *Terminal, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = @min(rest.len, feed_chunk);
        t.limiter.onInput(n);
        t.parser.feed(rest[0..n], t);
        rest = rest[n..];
    }
}

/// Drops the queued replies (after the owner wrote them to the host).
pub fn clearReplies(t: *Terminal) void {
    t.replies.clearRetainingCapacity();
}

/// Resizes both screens and the tab stops.
pub fn resize(t: *Terminal, new_cols: u16, new_rows: u16) !void {
    try t.primary.resize(new_cols, new_rows);
    try t.alternate.resize(new_cols, new_rows);
    try t.tabs.resize(t.gpa, new_cols);
    if (t.modes.get(.in_band_resize)) reports.inBandSize(t);
}

// ---------------------------------------------------------------------------
// Parser handler interface.

/// See `Parser`.
pub fn printAscii(t: *Terminal, run: []const u8) void {
    t.screen().printAscii(run);
}

/// See `Parser`.
pub fn printCodepoints(t: *Terminal, cps: []const u21) void {
    t.screen().print(cps);
}

/// See `Parser`.
pub fn execute(t: *Terminal, c: u8) void {
    handlers.execute(t, c);
}

/// See `Parser`.
pub fn escDispatch(t: *Terminal, e: Esc) void {
    handlers.escDispatch(t, e);
}

/// See `Parser`.
pub fn csiDispatch(t: *Terminal, c: *const Csi) void {
    handlers.csiDispatch(t, c);
}

/// See `Parser`.
pub fn oscDispatch(t: *Terminal, data: []const u8, term: StringTerm) void {
    osc.dispatch(t, data, term);
}

/// See `Parser`.
pub fn dcsHook(t: *Terminal, c: *const Csi) bool {
    return dcs.hook(t, c);
}

/// See `Parser`.
pub fn dcsPut(t: *Terminal, bytes: []const u8) void {
    dcs.put(t, bytes);
}

/// See `Parser`.
pub fn dcsUnhook(t: *Terminal) void {
    dcs.unhook(t);
}

/// See `Parser`. Kitty graphics (APC G) arrive with E06.F08; until then
/// every APC is discarded.
pub fn apcStart(t: *Terminal) bool {
    _ = t;
    return false;
}

/// See `Parser`.
pub fn apcPut(t: *Terminal, bytes: []const u8) void {
    _ = t;
    _ = bytes;
}

/// See `Parser`.
pub fn apcEnd(t: *Terminal) void {
    _ = t;
}

// ---------------------------------------------------------------------------
// Shared helpers for the handler modules.

/// Queues a reply, subject to the reply limiter.
pub fn reply(t: *Terminal, bytes: []const u8) void {
    if (!t.limiter.allow(bytes.len)) {
        if (t.limiter.dropped == 1) {
            log.warn("reply limit reached; dropping terminal replies", .{});
            t.effects.push(.replies_dropped);
        }
        return;
    }
    t.replies.appendSlice(t.gpa, bytes) catch {
        t.stats.alloc_failures += 1;
    };
}

/// Formats and queues a reply of at most 512 bytes.
pub fn replyFmt(t: *Terminal, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    t.reply(s);
}

/// The string terminator matching a requester's.
pub fn stBytes(term: StringTerm) []const u8 {
    return if (term == .bel) "\x07" else "\x1b\\";
}

/// Counts a failed allocation (handlers cannot return errors).
pub fn allocFailed(t: *Terminal) void {
    t.stats.alloc_failures += 1;
}

/// Rings the bell, at most once per `bell_interval_ms`.
pub fn bell(t: *Terminal) void {
    if (t.last_bell_ms) |last| if (t.now_ms -% last < bell_interval_ms) {
        t.stats.bells_suppressed += 1;
        return;
    };
    t.last_bell_ms = t.now_ms;
    t.effects.push(.bell);
}

/// Whether a notification may be shown now (1 per second).
pub fn notifyAllowed(t: *Terminal) bool {
    if (t.last_notify_ms) |last| if (t.now_ms -% last < notify_interval_ms) {
        t.stats.notifications_suppressed += 1;
        return false;
    };
    t.last_notify_ms = t.now_ms;
    return true;
}

/// Copies the mode bits the screens consult into both screens.
pub fn syncScreenModes(t: *Terminal) void {
    inline for (.{ &t.primary, &t.alternate }) |s| {
        s.modes.autowrap = t.modes.get(.autowrap);
        s.modes.insert = t.modes.get(.insert);
        s.modes.grapheme = t.modes.get(.grapheme_cluster);
    }
}

/// Sets mode `id` with its side effects.
pub fn setMode(t: *Terminal, id: ModeId, on: bool) void {
    if (modes_mod.def(id).report != .normal) return;
    const was = t.modes.get(id);
    t.modes.set(id, on);
    handlers.onModeChanged(t, id, on, was);
    t.syncScreenModes();
    if (was != on) t.effects.push(.{ .mode = .{ .id = id, .on = on } });
}

/// Switches between the primary and alternate screen. The cursor position,
/// attributes and margins carry over, as in xterm.
pub fn switchScreen(t: *Terminal, to_alt: bool) void {
    if (t.alt_active == to_alt) return;
    const from = t.screen();
    const to = if (to_alt) &t.alternate else &t.primary;
    to.cursor.x = @min(from.cursor.x, to.width() - 1);
    to.cursor.y = @min(from.cursor.y, to.height() - 1);
    to.cursor.pending_wrap = from.cursor.pending_wrap;
    to.setStyle(from.cursor.style);
    to.cursor.protected = from.cursor.protected;
    to.charsets = from.charsets;
    to.region = from.region;
    if (from.cursor.link) |l| to.setLink(.{ .uri = l.uri, .id = l.id }) catch t.allocFailed() else to.setLink(null) catch {};
    t.alt_active = to_alt;
}

/// Replaces the title (or icon) with sanitised `text` (invalid UTF-8 as
/// U+FFFD, C0/C1 removed, at most `title_max` bytes).
pub fn setTitle(t: *Terminal, which: enum { title, icon, both }, text: []const u8) void {
    if (which != .icon) {
        sanitizeText(&t.title, t.gpa, text, title_max) catch t.allocFailed();
        t.effects.push(.title_changed);
    }
    if (which != .title) {
        sanitizeText(&t.icon, t.gpa, text, title_max) catch t.allocFailed();
        t.effects.push(.icon_changed);
    }
}

/// Replaces `out` with `text` as valid UTF-8 (invalid bytes as U+FFFD) with
/// C0/C1 controls removed, truncated to `max` bytes.
pub fn sanitizeText(out: *std.ArrayList(u8), gpa: Allocator, text: []const u8, max: usize) !void {
    out.clearRetainingCapacity();
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        var cp: u21 = 0xFFFD;
        var adv: usize = 1;
        if (n > 0 and i + n <= text.len) {
            if (std.unicode.utf8Decode(text[i..][0..n])) |c| {
                cp = c;
                adv = n;
            } else |_| {}
        }
        i += adv;
        if (cp < 0x20 or cp == 0x7F or (cp >= 0x80 and cp < 0xA0)) continue;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch continue;
        if (out.items.len + len > max) break;
        try out.appendSlice(gpa, buf[0..len]);
    }
}

/// XTWINOPS 22: pushes the title and icon (the oldest is dropped when full).
pub fn pushTitle(t: *Terminal) void {
    const title = t.gpa.dupe(u8, t.title.items) catch return t.allocFailed();
    const icon = t.gpa.dupe(u8, t.icon.items) catch {
        t.gpa.free(title);
        return t.allocFailed();
    };
    if (t.title_stack.items.len == title_stack_max) {
        const old = t.title_stack.orderedRemove(0);
        t.gpa.free(old.title);
        t.gpa.free(old.icon);
    }
    t.title_stack.append(t.gpa, .{ .title = title, .icon = icon }) catch {
        t.gpa.free(title);
        t.gpa.free(icon);
        t.allocFailed();
    };
}

/// XTWINOPS 23: pops the title and icon.
pub fn popTitle(t: *Terminal) void {
    const e = t.title_stack.pop() orelse return;
    defer {
        t.gpa.free(e.title);
        t.gpa.free(e.icon);
    }
    t.title.clearRetainingCapacity();
    t.title.appendSlice(t.gpa, e.title) catch t.allocFailed();
    t.icon.clearRetainingCapacity();
    t.icon.appendSlice(t.gpa, e.icon) catch t.allocFailed();
    t.effects.push(.title_changed);
}

/// Sets an OSC 1337 user variable (max 64 variables of 4 KiB).
pub fn setUserVar(t: *Terminal, key: []const u8, value: []const u8) !void {
    if (value.len > 4096 or key.len > 256) return error.TooLarge;
    if (t.user_vars.getPtr(key)) |v| {
        const nv = try t.gpa.dupe(u8, value);
        t.gpa.free(v.*);
        v.* = nv;
        return;
    }
    if (t.user_vars.count() >= 64) return error.TooMany;
    const k = try t.gpa.dupe(u8, key);
    errdefer t.gpa.free(k);
    const v = try t.gpa.dupe(u8, value);
    errdefer t.gpa.free(v);
    try t.user_vars.put(t.gpa, k, v);
}

fn clearUserVars(t: *Terminal) void {
    var it = t.user_vars.iterator();
    while (it.next()) |e| {
        t.gpa.free(e.key_ptr.*);
        t.gpa.free(e.value_ptr.*);
    }
    t.user_vars.clearRetainingCapacity();
}

/// Answers the pending OSC 52 read after the policy decision: `data` is the
/// clipboard text on approval, null on denial (nothing is sent).
pub fn answerClipboardRead(t: *Terminal, data: ?[]const u8) void {
    const term = t.clip_read orelse return;
    t.clip_read = null;
    const d = data orelse return;
    const enc = std.base64.standard.Encoder;
    const buf = t.gpa.alloc(u8, enc.calcSize(d.len)) catch return t.allocFailed();
    defer t.gpa.free(buf);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.gpa);
    out.print(t.gpa, "\x1b]52;c;{s}{s}", .{ enc.encode(buf, d), stBytes(term) }) catch return t.allocFailed();
    t.reply(out.items);
}

/// Delivers a shell mark at the cursor.
pub fn emitMark(t: *Terminal, m: mark.Mark) void {
    const s = t.screen();
    if (t.mark_sink) |sink| sink.onMark(m, s.rowPin(s.cursor.y));
}

/// RIS: full reset of both screens, modes, palette, tabs and titles.
pub fn fullReset(t: *Terminal) void {
    t.alt_active = false;
    inline for (.{ &t.primary, &t.alternate }) |s| {
        s.setLink(null) catch {};
        s.cursor = .{};
        s.saved = null;
        s.charsets = .{};
        s.region = s.fullRegion();
        s.kitty_kb = .{};
        s.last_len = 0;
        s.eraseDisplay(.all, .{}) catch t.allocFailed();
    }
    if (t.opts.ris_clears_scrollback) t.primary.eraseDisplay(.scrollback, .{}) catch t.allocFailed();
    t.modes = .initial;
    t.syncScreenModes();
    t.palette = t.default_palette;
    t.effects.push(.palette_changed);
    t.tabs.reset();
    t.cursor_shape = .blinking_block;
    t.keypad_application = false;
    t.title.clearRetainingCapacity();
    t.icon.clearRetainingCapacity();
    t.effects.push(.title_changed);
    t.dcs_state.reset();
    t.clip_read = null;
}

/// The active screen as text (tests and captures).
pub fn dump(t: *Terminal, gpa: Allocator) ![]u8 {
    return t.screen().dump(gpa);
}

test {
    _ = @import("Terminal_test.zig");
}
