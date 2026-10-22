//! `TerminalView`: what the terminal widget shows and where its input goes
//! (E06.F04.S01.T01, E06.F04.S02.T01, E06.F05.S01.T02, first cut).
//!
//! The view owns no process. Its owner feeds it output (`feed`) and gives
//! it a `Sink` for the bytes it produces: encoded keys, mouse reports,
//! pastes, focus reports and the terminal's own replies. `on_resize`
//! reports a new grid so the owner can resize its PTY.
//!
//! Input routing:
//! - Keys: Ctrl+Shift+V and Shift+Insert paste, Shift+PageUp/PageDown
//!   scroll back, `bubble` (default `input_route.defaultBubble`) leaves keys
//!   to the IDE's keymap, and everything else is encoded for the
//!   application's modes. A key that typed text swallows the text event
//!   that follows it; text without a key (IME commits) is sent as typed.
//! - Pointer: reported to the application while it enabled a mouse mode,
//!   unless the override modifier (Shift) is held; the wheel is reported,
//!   turned into cursor keys (alternate scroll) or scrolls the viewport.
//! - Paste: `encodePaste` sanitises it; a multi-line paste the application
//!   cannot bracket asks first (`zg_gui.w.dialog.confirm`).
//! - Focus: reported when the application enabled focus events.
//!
//! Single-threaded for now: the owner feeds output on the UI thread. The
//! locked session and atomically mirrored mode bits of E06.F01 replace
//! the direct `Terminal.encoderState` reads here.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_terminal = @import("zg_terminal");
const route = @import("input_route.zig");

const Allocator = std.mem.Allocator;
const Terminal = zg_terminal.Terminal;
const input = zg_terminal.input;
const KeyPress = zg_gui.input.event.KeyPress;
const TextSystem = zg_gui.paint.TextSystem;
const TextStyle = zg_gui.paint.text.TextStyle;

/// Where the view's bytes go (the PTY writer).
pub const Sink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
};

/// Called with the new grid (cells) and text-area size (pixels).
pub const ResizeHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, cols: u16, rows: u16, px_w: u16, px_h: u16) void,
};

/// Called after output or view state changed outside an input event.
pub const ChangeHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, v: *TerminalView) void,
};

/// Decides whether a key goes to the IDE (true) instead of the application.
pub const BubbleFilter = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, kp: KeyPress) bool,
};

/// View settings (`terminal.*`).
pub const Options = struct {
    font_size: f32 = 13,
    /// `terminal.padding`, around the cell grid.
    padding: f32 = 4,
    bold_is_bright: bool = true,
    /// `terminal.mouse.overrideModifier`: Shift bypasses mouse reporting.
    override_shift: bool = true,
    /// `terminal.mouse.altScrollLines`.
    alt_scroll_lines: u8 = 3,
    /// Rows the viewport moves per wheel notch.
    scroll_lines: u8 = 3,
    paste: input.paste.PasteOptions = .{},
    /// Writes larger than this go to the sink in pieces.
    write_chunk: usize = 64 << 10,
};

/// See the module doc.
pub const TerminalView = struct {
    gpa: Allocator,
    term: *Terminal,
    opts: Options,
    sink: ?Sink = null,
    on_resize: ?ResizeHook = null,
    on_change: ?ChangeHook = null,
    bubble: BubbleFilter = .{ .f = defaultBubble },
    /// Set by the widget's builder; paste confirmations open on it.
    win: ?*zg_gui.Window = null,
    /// The widget's node, set by its builder (for `Window.setFocus`).
    node: zg_gui.core.NodeId = .none,
    text_sys: ?TextSystem = null,
    /// Cell size in pixels.
    cell_w: f32 = 8,
    cell_h: f32 = 16,
    /// Bumped on every visible change (the widget's paint hash).
    generation: u64 = 0,
    focused: bool = false,
    /// The last key typed text: drop the text event that follows it.
    skip_text: bool = false,
    /// Pointer buttons held while reporting (bit 0 left, 1 middle, 2 right).
    buttons: u8 = 0,
    /// The cell of the last reported motion (dedup per cell).
    last_motion: ?[2]u16 = null,
    /// Sub-row remainder of precise (touchpad) scrolling, in rows.
    scroll_rem: f32 = 0,
    /// The encoded paste waiting for the user's confirmation.
    pending_paste: std.ArrayList(u8) = .empty,
    paste_buf: std.ArrayList(u8) = .empty,
    confirming: bool = false,
    /// Total bytes sent to the sink (tests, diagnostics).
    bytes_sent: u64 = 0,

    /// A view of `term` (which must outlive it).
    pub fn init(gpa: Allocator, term: *Terminal, opts: Options) TerminalView {
        return .{ .gpa = gpa, .term = term, .opts = opts };
    }

    /// Frees the paste buffers.
    pub fn deinit(v: *TerminalView) void {
        v.pending_paste.deinit(v.gpa);
        v.paste_buf.deinit(v.gpa);
    }

    fn defaultBubble(_: ?*anyopaque, kp: KeyPress) bool {
        return route.defaultBubble(kp);
    }

    /// The cell text style (`bold`/`italic` select the face).
    pub fn textStyle(v: *const TerminalView, bold: bool, italic: bool) TextStyle {
        return .{ .font = .mono, .size = v.opts.font_size, .weight = if (bold) 700 else 400, .italic = italic };
    }

    /// Measures the cell from the text system.
    pub fn syncMetrics(v: *TerminalView, ts: TextSystem) void {
        v.text_sys = ts;
        const st = v.textStyle(false, false);
        v.cell_w = @max(1, ts.advance(st, 'M'));
        v.cell_h = @max(1, @ceil(ts.metrics(st).line_h));
    }

    /// The grid that fits `w` x `h` pixels (at least 1x1).
    pub fn gridFor(v: *const TerminalView, w: f32, h: f32) [2]u16 {
        const pad = 2 * v.opts.padding;
        const cols = @floor(@max(0, w - pad) / v.cell_w);
        const rows = @floor(@max(0, h - pad) / v.cell_h);
        return .{ @intFromFloat(std.math.clamp(cols, 1, 4096)), @intFromFloat(std.math.clamp(rows, 1, 4096)) };
    }

    /// Resizes the terminal to fit `w` x `h` pixels; reports a new grid to
    /// `on_resize`. Returns whether the grid changed.
    pub fn fit(v: *TerminalView, w: f32, h: f32) bool {
        const g = v.gridFor(w, h);
        v.term.cell_px = .{ .w = @intFromFloat(v.cell_w), .h = @intFromFloat(v.cell_h) };
        if (g[0] == v.term.cols() and g[1] == v.term.rows()) return false;
        v.term.resize(g[0], g[1]) catch return false;
        v.generation +%= 1;
        if (v.on_resize) |h_| h_.f(h_.ctx, g[0], g[1], @intFromFloat(@as(f32, @floatFromInt(g[0])) * v.cell_w), @intFromFloat(@as(f32, @floatFromInt(g[1])) * v.cell_h));
        return true;
    }

    fn changed(v: *TerminalView) void {
        v.generation +%= 1;
        if (v.on_change) |h| h.f(h.ctx, v);
    }

    /// Applies application output, sends the terminal's replies, and
    /// reports the change.
    pub fn feed(v: *TerminalView, bytes: []const u8) void {
        v.term.feed(bytes);
        v.flushReplies();
        v.changed();
    }

    /// Sends the terminal's pending replies (DA, DSR, ...).
    pub fn flushReplies(v: *TerminalView) void {
        if (v.term.replies.items.len == 0) return;
        v.send(v.term.replies.items);
        v.term.clearReplies();
    }

    /// Writes `bytes` to the sink, in `write_chunk` pieces.
    pub fn send(v: *TerminalView, bytes: []const u8) void {
        if (bytes.len == 0) return;
        v.bytes_sent += bytes.len;
        const s = v.sink orelse return;
        var i: usize = 0;
        while (i < bytes.len) {
            const n = @min(v.opts.write_chunk, bytes.len - i);
            s.write(s.ctx, bytes[i..][0..n]);
            i += n;
        }
    }

    /// Sends typed input: the viewport returns to the bottom first.
    pub fn sendInput(v: *TerminalView, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (v.scrolledBack()) {
            v.scrollToBottom();
            v.changed();
        }
        v.send(bytes);
    }

    /// The modes the encoders read.
    pub fn encoderState(v: *const TerminalView) input.EncoderState {
        return v.term.encoderState();
    }

    // -- viewport ------------------------------------------------------------

    /// Whether the viewport shows scrollback instead of following output.
    pub fn scrolledBack(v: *TerminalView) bool {
        return v.term.screen().pages.viewport != null;
    }

    /// Moves the viewport `rows` rows back (negative: towards the bottom).
    pub fn scrollBy(v: *TerminalView, rows: i64) void {
        if (rows == 0) return;
        v.term.screen().pages.scrollViewport(rows) catch {};
        v.generation +%= 1;
    }

    /// Follows output again.
    pub fn scrollToBottom(v: *TerminalView) void {
        v.scrollBy(std.math.minInt(i32));
    }

    /// Shows the oldest scrollback row.
    pub fn scrollToTop(v: *TerminalView) void {
        v.scrollBy(std.math.maxInt(i32));
    }

    /// The viewport's first row and the total rows (scrollback included),
    /// for the scrollbar.
    pub fn scrollPosition(v: *TerminalView) struct { top: u64, total: u64 } {
        const pl = &v.term.screen().pages;
        const sb = pl.scrollbackRows();
        const top = if (pl.viewport) |p| pl.rowIndex(p.pin) else sb;
        return .{ .top = top, .total = sb + v.term.rows() };
    }

    // -- keys and text -------------------------------------------------------

    /// Routes a key event (see the module doc). Returns false when the key
    /// belongs to the IDE (it then bubbles to the keymap).
    pub fn key(v: *TerminalView, kp: KeyPress, clipboard: []const u8) bool {
        v.skip_text = false;
        const m = kp.mods;
        const st = v.encoderState();
        if (kp.action == .release) {
            // Releases are reported only with kitty flag 2 (event types).
            if (st.kitty_flags & 2 == 0) return false;
            return v.encodeAndSend(&st, kp);
        }
        const only_shift = m.shift and !m.ctrl and !m.alt and !m.super;
        if ((m.ctrl and m.shift and !m.alt and kp.key == .key_v) or (only_shift and kp.key == .insert)) {
            _ = v.paste(clipboard) catch .empty;
            return true;
        }
        if (only_shift) switch (kp.key) {
            .page_up, .page_down => {
                const page: i64 = @max(1, @as(i64, v.term.rows()) - 1);
                v.scrollBy(if (kp.key == .page_up) page else -page);
                return true;
            },
            else => {},
        };
        if (v.bubble.f(v.bubble.ctx, kp)) return false;
        return v.encodeAndSend(&st, kp);
    }

    fn encodeAndSend(v: *TerminalView, st: *const input.EncoderState, kp: KeyPress) bool {
        var tb: [4]u8 = undefined;
        const k = route.keyInput(kp, &tb);
        var out: [64]u8 = undefined;
        const bytes = input.encodeKey(st, k, &out);
        // Nothing to send (a modifier alone): the IDE may use it.
        if (bytes.len == 0) return false;
        if (kp.action != .release) v.skip_text = kp.codepoint != 0;
        v.sendInput(bytes);
        return true;
    }

    /// Committed text: dropped right after a key that typed it, else sent
    /// as typed (IME commits).
    pub fn text(v: *TerminalView, s: []const u8) void {
        if (v.skip_text) {
            v.skip_text = false;
            return;
        }
        v.sendInput(s);
    }

    // -- paste ---------------------------------------------------------------

    /// What `paste` did.
    pub const PasteResult = enum { sent, confirming, too_large, empty };

    /// Pastes `s`: sends it, or asks first for a multi-line paste the
    /// application cannot bracket (sent on OK), or refuses a huge one.
    pub fn paste(v: *TerminalView, s: []const u8) !PasteResult {
        if (s.len == 0) return .empty;
        const st = v.encoderState();
        switch (try input.encodePaste(&st, s, v.opts.paste, &v.paste_buf, v.gpa)) {
            .send => {
                v.sendInput(v.paste_buf.items);
                return .sent;
            },
            .too_large => return .too_large,
            .needs_confirmation => {
                v.pending_paste.clearRetainingCapacity();
                try v.pending_paste.appendSlice(v.gpa, v.paste_buf.items);
                if (v.confirming) return .confirming;
                const w = v.win orelse return .confirming;
                var msg: std.ArrayList(u8) = .empty;
                defer msg.deinit(v.gpa);
                try previewLines(&msg, v.gpa, s, 10);
                v.confirming = true;
                _ = zg_gui.w.dialog.confirm(w, .{
                    .title = "Paste multiple lines into the terminal?",
                    .message = msg.items,
                    .ok_label = "Paste",
                }, .{ .ctx = v, .f = onConfirm }) catch {
                    v.confirming = false;
                    return error.OutOfMemory;
                };
                return .confirming;
            },
        }
    }

    /// Answers a pending paste confirmation (the dialog calls it).
    pub fn answerPaste(v: *TerminalView, ok: bool) void {
        v.confirming = false;
        if (ok) v.sendInput(v.pending_paste.items);
        v.pending_paste.clearRetainingCapacity();
    }

    fn onConfirm(ctx: ?*anyopaque, r: zg_gui.w.dialog.Result) void {
        const v: *TerminalView = @ptrCast(@alignCast(ctx.?));
        v.answerPaste(r == .ok);
    }

    // -- pointer and focus ---------------------------------------------------

    /// Whether pointer events go to the application.
    pub fn reportsMouse(v: *const TerminalView, m: zg_gui.input.event.Pointer) bool {
        if (v.opts.override_shift and m.mods.shift) return false;
        return v.term.encoderState().mouse != .none;
    }

    /// Sends a mouse report; motion is deduplicated per cell.
    pub fn reportMouse(v: *TerminalView, ev: input.mouse.MouseInput) bool {
        const st = v.encoderState();
        if (ev.kind == .motion) {
            if (v.last_motion) |l| if (l[0] == ev.cell[0] and l[1] == ev.cell[1] and st.mouse_enc != .sgr_pixels) return true;
            v.last_motion = ev.cell;
        }
        var out: [32]u8 = undefined;
        const bytes = input.encodeMouse(&st, ev, &out);
        v.send(bytes);
        return bytes.len > 0;
    }

    /// One wheel step of `notches` (positive: up, into history). Reported,
    /// turned into cursor keys, or scrolls the viewport.
    pub fn wheel(v: *TerminalView, notches: i32, cell: [2]u16, px: [2]u32, m: input.Mods, report: bool) void {
        if (notches == 0) return;
        const st = v.encoderState();
        const up = notches > 0;
        const n: u32 = @abs(notches);
        if (report and st.mouse != .none) {
            for (0..n) |_| _ = v.reportMouse(.{ .kind = .wheel, .button = if (up) 64 else 65, .cell = cell, .px = px, .mods = m });
            return;
        }
        var buf: [256]u8 = undefined;
        if (input.mouse.altScroll(&st, up, v.opts.alt_scroll_lines, &buf).len > 0) {
            for (0..n) |_| v.send(input.mouse.altScroll(&st, up, v.opts.alt_scroll_lines, &buf));
            return;
        }
        v.scrollBy(@as(i64, notches) * v.opts.scroll_lines);
    }

    /// Focus gained or lost: reported when the application asked (1004).
    pub fn setFocused(v: *TerminalView, on: bool) void {
        if (v.focused == on) return;
        v.focused = on;
        v.generation +%= 1;
        const st = v.encoderState();
        v.send(input.encodeFocus(&st, on));
    }
};

/// The first `max` lines of `s` ("…" when there are more).
fn previewLines(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8, max: usize) !void {
    var it = std.mem.splitScalar(u8, s, '\n');
    var n: usize = 0;
    while (it.next()) |line| : (n += 1) {
        if (n == max) return out.appendSlice(gpa, "\u{2026}");
        if (n > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, std.mem.trimEnd(u8, line, "\r"));
    }
}

test "previewLines: CRLF counts once, long pastes are cut" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try previewLines(&out, gpa, "a\r\nb\nc", 10);
    try std.testing.expectEqualStrings("a\nb\nc", out.items);
    out.clearRetainingCapacity();
    try previewLines(&out, gpa, "1\n2\n3\n4", 2);
    try std.testing.expectEqualStrings("1\n2\u{2026}", out.items);
}
