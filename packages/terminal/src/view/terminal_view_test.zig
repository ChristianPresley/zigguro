//! The terminal widget in a headless zg_gui window: output painting, grid
//! fitting, key routing and encoding, IDE keys, IME text, mouse reporting
//! and its override, wheel, paste with confirmation, focus reports and
//! terminal replies.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_terminal = @import("zg_terminal");
const view_mod = @import("terminal_view.zig");
const widget = @import("widget.zig");
const pal = @import("palette.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Ui = zg_gui.Ui;
const TestApp = zg_gui.testing.TestApp;
const TerminalView = view_mod.TerminalView;
const KeyPress = zg_gui.input.event.KeyPress;

const Page = struct {
    view: *TerminalView,

    pub fn build(self: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        defer ui.close();
        _ = widget.terminal(ui, .{ .view = self.view });
    }
};

const Fx = struct {
    term: zg_terminal.Terminal,
    view: TerminalView,
    page: Page,
    t: *TestApp,
    out: std.ArrayList(u8),
    resized: ?[2]u16,
    keys_seen: u32,

    fn init(f: *Fx) !void {
        f.out = .empty;
        f.resized = null;
        f.keys_seen = 0;
        f.term = try .init(gpa, .{ .cols = 80, .rows = 24 });
        f.view = .init(gpa, &f.term, .{});
        f.view.sink = .{ .ctx = f, .write = write };
        f.view.on_resize = .{ .ctx = f, .f = onResize };
        f.page = .{ .view = &f.view };
        f.t = try TestApp.init(gpa, .{ .root = .of(&f.page), .size = .{ .w = 400, .h = 200 } });
        f.t.win.key_handler = .{ .ptr = f, .handle = onKey };
        _ = f.t.settle();
        try f.t.click(.{ .role = .textbox });
        f.out.clearRetainingCapacity();
    }

    fn deinit(f: *Fx) void {
        f.t.deinit();
        f.view.deinit();
        f.term.deinit();
        f.out.deinit(gpa);
    }

    fn write(ctx: *anyopaque, bytes: []const u8) void {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.out.appendSlice(gpa, bytes) catch {};
    }

    fn onResize(ctx: *anyopaque, cols: u16, rows: u16, _: u16, _: u16) void {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.resized = .{ cols, rows };
    }

    fn onKey(ptr: *anyopaque, k: KeyPress, _: []const []const u8) bool {
        const f: *Fx = @ptrCast(@alignCast(ptr));
        if (k.action == .release) return false;
        f.keys_seen += 1;
        return true;
    }

    fn feed(f: *Fx, s: []const u8) void {
        f.view.feed(s);
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    /// Presses and releases a key, typing its text when it has any.
    fn key(f: *Fx, kp: KeyPress) void {
        f.t.win.dispatch(.{ .key = kp });
        if (kp.codepoint != 0) {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(kp.codepoint, &buf) catch 0;
            f.t.win.dispatch(.{ .text = buf[0..n] });
        }
        var up = kp;
        up.action = .release;
        f.t.win.dispatch(.{ .key = up });
        _ = f.t.settle();
    }

    fn expectOut(f: *Fx, want: []const u8) !void {
        try testing.expectEqualStrings(want, f.out.items);
        f.out.clearRetainingCapacity();
    }

    /// The window point at the centre of cell (x, y).
    fn cellPoint(f: *Fx, x: u16, y: u16) !zg_gui.core.Vec2 {
        const r = try f.t.rectOf(.{ .role = .textbox });
        const v = &f.view;
        return .{
            .x = r.x + v.opts.padding + (@as(f32, @floatFromInt(x)) + 0.5) * v.cell_w,
            .y = r.y + v.opts.padding + (@as(f32, @floatFromInt(y)) + 0.5) * v.cell_h,
        };
    }
};

fn hexOf(c: zg_gui.core.Color, buf: *[16]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a });
}

test "terminal: the grid fits the widget and output paints" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const want = f.view.gridFor(400, 200);
    try testing.expectEqual(want[0], f.term.cols());
    try testing.expectEqual(want[1], f.term.rows());
    try testing.expectEqual(want, f.resized.?);
    f.feed("plain \x1b[31mred\x1b[0m \x1b[44mbg\x1b[0m \x1b[4:3mcurly\x1b[0m");
    const snap = f.t.paintSnapshot();
    var buf: [16]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, snap, try hexOf(pal.fromRgb(f.term.palette.ansi[1]), &buf)) != null);
    try testing.expect(std.mem.indexOf(u8, snap, try hexOf(pal.fromRgb(f.term.palette.ansi[4]), &buf)) != null);
    try testing.expect(std.mem.indexOf(u8, snap, "glyphs") != null);
    // The cursor is a block in the default foreground while focused.
    try testing.expect(f.view.focused);
}

test "terminal: keys encode for the application's modes" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.key(.{ .key = .key_a, .codepoint = 'a' });
    try f.expectOut("a");
    f.key(.{ .key = .key_a, .codepoint = 'A', .mods = .{ .shift = true } });
    try f.expectOut("A");
    f.key(.{ .key = .key_c, .mods = .{ .ctrl = true } });
    try f.expectOut("\x03");
    f.key(.{ .key = .enter });
    try f.expectOut("\r");
    f.key(.{ .key = .arrow_up });
    try f.expectOut("\x1b[A");
    f.feed("\x1b[?1h");
    f.key(.{ .key = .arrow_up });
    try f.expectOut("\x1bOA");
    f.key(.{ .key = .key_x, .codepoint = 'x', .mods = .{ .alt = true } });
    try f.expectOut("\x1bx");
    // Kitty flags 1|2: Ctrl+Shift+A disambiguated, releases reported.
    f.feed("\x1b[>3u");
    f.view.bubble = .{ .f = struct {
        fn never(_: ?*anyopaque, _: KeyPress) bool {
            return false;
        }
    }.never };
    f.key(.{ .key = .key_a, .codepoint = 'A', .mods = .{ .ctrl = true, .shift = true } });
    try f.expectOut("\x1b[97;6u\x1b[97;6:3u");
    try testing.expectEqual(@as(u32, 0), f.keys_seen);
}

test "terminal: IDE keys bubble to the keymap, IME text is typed" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.key(.{ .key = .key_p, .mods = .{ .ctrl = true, .shift = true } });
    f.key(.{ .key = .backquote, .mods = .{ .ctrl = true } });
    try f.expectOut("");
    try testing.expect(f.keys_seen >= 2);
    f.t.typeText("\u{e9}\u{4e16}");
    try f.expectOut("\u{e9}\u{4e16}");
}

test "terminal: mouse reports, Shift overrides, motion dedups per cell" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b[?1002h\x1b[?1006h");
    const p = try f.cellPoint(2, 1);
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = p } });
    var q = p;
    q.x += 1;
    f.t.win.dispatch(.{ .pointer_move = .{ .pos = q } });
    f.t.win.dispatch(.{ .pointer_move = .{ .pos = try f.cellPoint(3, 1) } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = try f.cellPoint(3, 1) } });
    _ = f.t.settle();
    try f.expectOut("\x1b[<0;3;2M\x1b[<32;4;2M\x1b[<0;4;2m");
    f.t.win.dispatch(.{ .pointer_down = .{ .pos = p, .mods = .{ .shift = true } } });
    f.t.win.dispatch(.{ .pointer_up = .{ .pos = p, .mods = .{ .shift = true } } });
    _ = f.t.settle();
    try f.expectOut("");
    // The wheel is reported too.
    f.t.win.dispatch(.{ .scroll = .{ .pos = p, .dx = 0, .dy = 1 } });
    _ = f.t.settle();
    try f.expectOut("\x1b[<64;3;2M");
}

test "terminal: the wheel scrolls back, typing returns, alternate scroll" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (0..200) |i| try buf.print(gpa, "line {d}\r\n", .{i});
    f.feed(buf.items);
    const p = try f.cellPoint(1, 1);
    f.t.win.dispatch(.{ .scroll = .{ .pos = p, .dx = 0, .dy = 2 } });
    _ = f.t.settle();
    try testing.expect(f.view.scrolledBack());
    try testing.expectEqual(@as(u64, 6), f.view.scrollPosition().total - f.term.rows() - f.view.scrollPosition().top);
    try f.expectOut("");
    f.key(.{ .key = .page_up, .mods = .{ .shift = true } });
    try f.expectOut("");
    f.key(.{ .key = .key_q, .codepoint = 'q' });
    try f.expectOut("q");
    try testing.expect(!f.view.scrolledBack());
    // Alternate screen with 1007: the wheel becomes cursor keys.
    f.feed("\x1b[?1049h\x1b[?1007h");
    f.t.win.dispatch(.{ .scroll = .{ .pos = p, .dx = 0, .dy = -1 } });
    _ = f.t.settle();
    try f.expectOut("\x1b[B\x1b[B\x1b[B");
}

test "terminal: paste is bracketed, a multi-line paste asks first" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b[?2004h");
    f.t.app.clipboard.set(gpa, "ls\n\x1b[201~rm");
    f.key(.{ .key = .key_v, .mods = .{ .ctrl = true, .shift = true } });
    try f.expectOut("\x1b[200~ls\r[201~rm\x1b[201~");
    f.feed("\x1b[?2004l");
    try testing.expectEqual(view_mod.TerminalView.PasteResult.confirming, try f.view.paste("one\ntwo"));
    _ = f.t.settle();
    try f.expectOut("");
    try f.t.click(.{ .role = .button, .name = "Paste" });
    try f.expectOut("one\rtwo");
    try testing.expectEqual(view_mod.TerminalView.PasteResult.sent, try f.view.paste("single"));
    try f.expectOut("single");
}

test "terminal: focus reports and replies reach the sink" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.feed("\x1b[?1004h");
    f.t.win.dispatch(.focus_lost);
    f.t.win.dispatch(.focus_gained);
    _ = f.t.settle();
    try f.expectOut("\x1b[O\x1b[I");
    f.feed("\x1b[6n");
    try f.expectOut("\x1b[1;1R");
}
