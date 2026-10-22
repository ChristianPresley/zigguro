//! Text field tests (E04.F05.S02.T01): gap buffer, commands, undo and the
//! widget driven through a headless window.

const std = @import("std");
const zg_core = @import("zg_core");
const model = @import("model.zig");
const undo_mod = @import("undo.zig");
const commands = @import("commands.zig");
const view = @import("view.zig");
const prompt_hooks = @import("prompt_hooks.zig");
const ui_mod = @import("../../core/ui.zig");
const view_mod = @import("../../core/view.zig");
const geom = @import("../../core/geom.zig");
const TestApp = @import("../../testing/test_app.zig").TestApp;

const testing = std.testing;
const gpa = testing.allocator;
const TextBuffer = model.TextBuffer;
const Selection = model.Selection;
const Editor = commands.Editor;
const Ui = ui_mod.Ui;

/// A buffer, selection and undo stack with an editor over them.
const Fixture = struct {
    buf: TextBuffer,
    sel: Selection = .{},
    undo: undo_mod.UndoStack = .{},
    opts: commands.Options = .{},
    now: u64 = 0,

    fn init(s: []const u8) !Fixture {
        return .{ .buf = try .init(gpa, s) };
    }

    fn deinit(f: *Fixture) void {
        f.buf.deinit();
        f.undo.deinit();
    }

    fn ed(f: *Fixture) Editor {
        return .{ .buf = &f.buf, .sel = &f.sel, .undo = &f.undo, .opts = f.opts, .now_ms = f.now };
    }

    fn text(f: *Fixture) []const u8 {
        return f.buf.slice();
    }
};

// -- buffer -------------------------------------------------------------------

fn applyRandom(buf: *TextBuffer, naive: *std.ArrayList(u8), r: std.Random) !void {
    const n: u32 = @intCast(naive.items.len);
    const a = r.uintAtMost(u32, n);
    const b = a + r.uintAtMost(u32, @min(n - a, 8));
    var ins: [12]u8 = undefined;
    const k = r.uintAtMost(usize, ins.len);
    for (ins[0..k]) |*c| c.* = 'a' + r.uintLessThan(u8, 26);
    try buf.replace(.{ a, b }, ins[0..k]);
    try naive.replaceRange(gpa, a, b - a, ins[0..k]);
    if (r.uintLessThan(u8, 4) == 0) try testing.expectEqualStrings(naive.items, buf.slice());
    try testing.expectEqual(@as(u32, @intCast(naive.items.len)), buf.len());
    if (naive.items.len > 0) {
        const i = r.uintLessThan(u32, @intCast(naive.items.len));
        try testing.expectEqual(naive.items[i], buf.byteAt(i));
    }
}

test "gap buffer random edits vs naive" {
    var buf: TextBuffer = try .init(gpa, "hello");
    defer buf.deinit();
    var naive: std.ArrayList(u8) = .empty;
    defer naive.deinit(gpa);
    try naive.appendSlice(gpa, "hello");
    var prng = std.Random.DefaultPrng.init(0x7e47);
    for (0..5000) |_| try applyRandom(&buf, &naive, prng.random());
    try testing.expectEqualStrings(naive.items, buf.slice());
}

fn fuzzBuffer(_: void, s: *std.testing.Smith) anyerror!void {
    var buf: TextBuffer = try .init(gpa, "");
    defer buf.deinit();
    var naive: std.ArrayList(u8) = .empty;
    defer naive.deinit(gpa);
    var seed: [8]u8 = undefined;
    s.bytes(&seed);
    var prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));
    const steps = s.valueRangeAtMost(u16, 1, 2000);
    for (0..steps) |_| try applyRandom(&buf, &naive, prng.random());
    try testing.expectEqualStrings(naive.items, buf.slice());
}

test "fuzz: textbuffer" {
    try std.testing.fuzz({}, fuzzBuffer, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "textbuffer") });
}

// -- commands -----------------------------------------------------------------

test "backspace removes grapheme cluster" {
    const cases = [_][]const u8{
        "ae\u{0301}", // e + combining acute
        "a\u{1F469}\u{200D}\u{1F4BB}", // woman technologist (ZWJ sequence)
        "a\u{1F1EF}\u{1F1F5}", // regional indicators (flag)
    };
    for (cases) |c| {
        var f: Fixture = try .init(c);
        defer f.deinit();
        f.sel = .caret(f.buf.len());
        try testing.expect(try f.ed().backspace(false));
        try testing.expectEqualStrings("a", f.text());
        // Delete forward from the start removes the "a" only.
        f.sel = .caret(0);
        try testing.expect(try f.ed().deleteForward(false));
        try testing.expectEqualStrings("", f.text());
    }
}

test "caret moves by grapheme and snaps inside clusters" {
    var f: Fixture = try .init("e\u{0301}x");
    defer f.deinit();
    f.ed().move(.char_right, false);
    try testing.expectEqual(@as(u32, 3), f.sel.head);
    f.ed().moveTo(2, false); // inside the cluster
    try testing.expectEqual(@as(u32, 0), f.sel.head);
}

test "word navigation UAX29" {
    var f: Fixture = try .init("foo.bar  baz_1 42");
    defer f.deinit();
    const e = f.ed();
    var stops: [8]u32 = undefined;
    var n: usize = 0;
    while (f.sel.head < f.buf.len()) : (n += 1) {
        e.move(.word_right, false);
        stops[n] = f.sel.head;
    }
    // UAX #29 keeps "foo.bar" and "baz_1" together (MidNumLet, ExtendNumLet).
    try testing.expectEqualSlices(u32, &.{ 7, 14, 17 }, stops[0..n]);
    e.move(.word_left, false);
    try testing.expectEqual(@as(u32, 15), f.sel.head);
    e.move(.word_left, false);
    try testing.expectEqual(@as(u32, 9), f.sel.head);
    // Ctrl+Backspace removes a word.
    f.sel = .caret(14);
    try testing.expect(try e.backspace(true));
    try testing.expectEqualStrings("foo.bar   42", f.text());
}

test "shift extends and plain arrows collapse" {
    var f: Fixture = try .init("abcdef");
    defer f.deinit();
    const e = f.ed();
    e.moveTo(2, false);
    e.move(.char_right, true);
    e.move(.char_right, true);
    try testing.expectEqualStrings("cd", e.selected());
    e.move(.char_left, false);
    try testing.expectEqual(Selection.caret(2), f.sel);
    e.selectAll();
    e.move(.char_right, false);
    try testing.expectEqual(Selection.caret(6), f.sel);
    e.move(.line_start, true);
    try testing.expectEqualStrings("abcdef", e.selected());
}

test "insert sanitises text" {
    var f: Fixture = try .init("");
    defer f.deinit();
    _ = try f.ed().insert("a\r\nb\nc\x01\xffd");
    try testing.expectEqualStrings("a b c\u{FFFD}d", f.text());
    f.opts.multiline = true;
    _ = try f.ed().insert("\r\nx\ry");
    try testing.expectEqualStrings("a b c\u{FFFD}d\nx\ny", f.text());
}

test "max_len truncates at a grapheme boundary" {
    var f: Fixture = try .init("ab");
    defer f.deinit();
    f.opts.max_len = 5;
    f.sel = .caret(2);
    _ = try f.ed().insert("xe\u{0301}z");
    // "x" fits, "é" (3 bytes) would make 6.
    try testing.expectEqualStrings("abx", f.text());
    try testing.expect(!try f.ed().insert(""));
}

test "read-only refuses edits" {
    var f: Fixture = try .init("keep");
    defer f.deinit();
    f.opts.read_only = true;
    f.sel = .caret(4);
    try testing.expect(!try f.ed().insert("x"));
    try testing.expect(!try f.ed().backspace(false));
    try testing.expectEqualStrings("keep", f.text());
}

// -- undo ---------------------------------------------------------------------

fn typeChars(f: *Fixture, s: []const u8) !void {
    for (0..s.len) |i| {
        _ = try f.ed().insert(s[i .. i + 1]);
        f.now += 50;
    }
}

test "undo coalescing rules" {
    var f: Fixture = try .init("");
    defer f.deinit();
    try typeChars(&f, "hello world");
    try testing.expectEqual(@as(usize, 2), f.undo.depth());
    try testing.expect(try f.ed().undoStep());
    try testing.expectEqualStrings("hello ", f.text());
    try testing.expectEqual(Selection.caret(6), f.sel);
    try testing.expect(try f.ed().undoStep());
    try testing.expectEqualStrings("", f.text());
    try testing.expect(!try f.ed().undoStep());
    try testing.expect(try f.ed().redoStep());
    try testing.expect(try f.ed().redoStep());
    try testing.expectEqualStrings("hello world", f.text());
    try testing.expect(!try f.ed().redoStep());

    // A pause longer than a second starts a new step.
    f.now += 5000;
    try typeChars(&f, "!");
    try testing.expectEqual(@as(usize, 3), f.undo.depth());
    // A caret move starts a new step.
    f.ed().move(.char_left, false);
    try typeChars(&f, "?");
    try testing.expectEqual(@as(usize, 4), f.undo.depth());

    // Backspaces coalesce; a new edit clears the redo stack.
    f.ed().move(.doc_end, false);
    for (0..3) |_| _ = try f.ed().backspace(false);
    try testing.expectEqual(@as(usize, 5), f.undo.depth());
    try testing.expect(try f.ed().undoStep());
    try testing.expectEqualStrings("hello world?!", f.text());
}

test "commitText is a single undo step" {
    var f: Fixture = try .init("ab");
    defer f.deinit();
    f.sel = .caret(1);
    try typeChars(&f, "x");
    _ = try f.ed().commitText("日本");
    try typeChars(&f, "y");
    try testing.expectEqualStrings("ax日本yb", f.text());
    try testing.expectEqual(@as(usize, 3), f.undo.depth());
    _ = try f.ed().undoStep();
    _ = try f.ed().undoStep();
    try testing.expectEqualStrings("axb", f.text());
}

test "undo restores replaced selection" {
    var f: Fixture = try .init("one two");
    defer f.deinit();
    f.sel = .{ .anchor = 4, .head = 7 };
    try typeChars(&f, "2");
    try testing.expectEqualStrings("one 2", f.text());
    _ = try f.ed().undoStep();
    try testing.expectEqualStrings("one two", f.text());
    try testing.expectEqual(Selection{ .anchor = 4, .head = 7 }, f.sel);
}

test "undo keeps at most max_steps" {
    var f: Fixture = try .init("");
    defer f.deinit();
    for (0..undo_mod.UndoStack.max_steps + 10) |_| _ = try f.ed().commitText("a");
    try testing.expectEqual(@as(usize, undo_mod.UndoStack.max_steps), f.undo.depth());
}

// -- widget -------------------------------------------------------------------

const Form = struct {
    name: *TextBuffer,
    notes: *TextBuffer,
    password: bool = false,
    prompt: ?*const prompt_hooks.PromptHooks = null,
    changed: u32 = 0,
    submitted: u32 = 0,

    pub fn build(self: *Form, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 8, .padding = .all(8) } });
        defer ui.close();
        ui.with(.{ .w = .{ .px = 200 } });
        const r = view.textField(ui, .{ .buffer = self.name, .placeholder = "Name", .password = self.password, .prompt = self.prompt });
        if (r.changed) self.changed += 1;
        if (r.submitted) self.submitted += 1;
        ui.with(.{ .w = .{ .px = 200 } });
        _ = view.textField(ui, .{ .buffer = self.notes, .placeholder = "Notes", .multiline = true, .min_rows = 2, .max_rows = 4 });
    }
};

const Harness = struct {
    name: TextBuffer,
    notes: TextBuffer,
    form: Form = undefined,
    t: *TestApp = undefined,

    fn init(h: *Harness) !void {
        h.name = try .init(gpa, "");
        h.notes = try .init(gpa, "");
        h.form = .{ .name = &h.name, .notes = &h.notes };
        h.t = try TestApp.init(gpa, .{ .root = view_mod.AnyView.of(&h.form) });
        _ = h.t.settle();
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.name.deinit();
        h.notes.deinit();
    }

    fn state(h: *Harness, name: []const u8) *view.TextField.State {
        const n = h.t.find(.{ .name = name }).?;
        return @ptrCast(@alignCast(h.t.win.store.hot.items(.state)[n.index].?));
    }

    fn ctrl(h: *Harness, k: anytype) void {
        h.t.press(k, .{ .ctrl = true });
    }
};

test "typing, navigation, clipboard and submit" {
    var h: Harness = .{ .name = undefined, .notes = undefined };
    try h.init();
    defer h.deinit();
    const t = h.t;
    try t.click(.{ .name = "Name" });
    t.typeText("hello");
    t.typeText(" world");
    try testing.expectEqualStrings("hello world", h.name.slice());
    try testing.expectEqual(@as(u32, 2), h.form.changed);

    // Ctrl+Left twice, then Shift+End selects "hello world".
    h.ctrl(.arrow_left);
    h.ctrl(.arrow_left);
    t.press(.end, .{ .shift = true });
    const st = h.state("Name");
    try testing.expectEqual(Selection{ .anchor = 0, .head = 11 }, st.sel);
    h.ctrl(.key_c);
    try testing.expectEqualStrings("hello world", t.app.clipboard.get());
    try testing.expect(t.app.clipboard.pending_write);

    // Space and printable keys are claimed (no activation); typing
    // replaces the selection.
    t.press(.space, .{});
    t.typeText("x");
    try testing.expectEqualStrings("x", h.name.slice());
    h.ctrl(.key_v);
    try testing.expectEqualStrings("xhello world", h.name.slice());
    h.ctrl(.key_z);
    try testing.expectEqualStrings("x", h.name.slice());
    h.t.press(.key_z, .{ .ctrl = true, .shift = true });
    try testing.expectEqualStrings("xhello world", h.name.slice());

    // Ctrl+A, Ctrl+X empties the field and fills the clipboard.
    h.ctrl(.key_a);
    h.ctrl(.key_x);
    try testing.expectEqualStrings("", h.name.slice());
    try testing.expectEqualStrings("xhello world", t.app.clipboard.get());

    // Enter submits a single-line field.
    t.press(.enter, .{});
    try testing.expectEqual(@as(u32, 1), h.form.submitted);

    // Tab moves to the notes field.
    t.press(.tab, .{});
    t.typeText("a\nb");
    try testing.expectEqualStrings("a\nb", h.notes.slice());
    t.press(.enter, .{ .shift = true });
    t.typeText("c");
    try testing.expectEqualStrings("a\nb\nc", h.notes.slice());
    t.press(.arrow_up, .{});
    try testing.expectEqual(@as(u32, 3), h.state("Notes").sel.head);
}

test "pointer: click places caret, double-click selects a word, drag extends" {
    var h: Harness = .{ .name = undefined, .notes = undefined };
    try h.init();
    defer h.deinit();
    const t = h.t;
    try h.state("Name").setText(&h.name, "alpha beta gamma");
    t.win.markAllDirty();
    _ = t.settle();
    const r = try t.rectOf(.{ .name = "Name" });
    // Content starts 8 px in; MonoText advances 7.8 px per character.
    const y = r.y + r.h / 2;
    const at = struct {
        fn x(rect: anytype, chars: f32) f32 {
            return rect.x + 8 + chars * 7.8;
        }
    }.x;
    t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = at(r, 7.2), .y = y } } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = at(r, 7.2), .y = y } } });
    _ = t.settle();
    const st = h.state("Name");
    try testing.expectEqual(Selection.caret(7), st.sel);
    t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = at(r, 7.2), .y = y }, .clicks = 2 } });
    t.win.dispatch(.{ .pointer_move = .{ .pos = .{ .x = at(r, 12.5), .y = y } } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = at(r, 12.5), .y = y }, .clicks = 2 } });
    _ = t.settle();
    try testing.expectEqual(Selection{ .anchor = 6, .head = 16 }, st.sel);
    t.win.dispatch(.{ .pointer_down = .{ .pos = .{ .x = at(r, 2), .y = y }, .clicks = 3 } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = .{ .x = at(r, 2), .y = y }, .clicks = 3 } });
    _ = t.settle();
    try testing.expectEqual(Selection{ .anchor = 0, .head = 16 }, st.sel);
}

test "PRIMARY: a new selection is published, middle click pastes it" {
    var h: Harness = .{ .name = undefined, .notes = undefined };
    try h.init();
    defer h.deinit();
    const t = h.t;
    t.app.has_primary = true;
    try t.click(.{ .name = "Name" });
    t.typeText("alpha beta");
    try testing.expectEqualStrings("", t.app.primary.get());
    // Shift+Ctrl+Left selects "beta"; it becomes PRIMARY, not the clipboard.
    t.press(.arrow_left, .{ .ctrl = true, .shift = true });
    try testing.expectEqualStrings("beta", t.app.primary.get());
    try testing.expect(t.app.primary.pending_write);
    try testing.expectEqualStrings("", t.app.clipboard.get());
    // Moving the caret keeps PRIMARY; selecting again republishes.
    t.app.primary.pending_write = false;
    t.press(.arrow_left, .{});
    try testing.expect(!t.app.primary.pending_write);
    try testing.expectEqualStrings("beta", t.app.primary.get());
    t.press(.arrow_right, .{ .shift = true, .ctrl = true });
    try testing.expect(t.app.primary.pending_write);

    // Middle click in the notes field pastes PRIMARY at the click, as one
    // undo step, and focuses the field.
    t.app.primary.replace(gpa, "from elsewhere");
    const r = try t.rectOf(.{ .name = "Notes" });
    const p: geom.Vec2 = .{ .x = r.x + 8, .y = r.y + 10 };
    t.win.dispatch(.{ .pointer_down = .{ .pos = p, .button = .middle } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = p, .button = .middle } });
    _ = t.settle();
    try testing.expectEqualStrings("from elsewhere", h.notes.slice());
    try testing.expectEqual(t.find(.{ .name = "Notes" }).?, t.win.focus);
    h.ctrl(.key_z);
    try testing.expectEqualStrings("", h.notes.slice());

    // Without a PRIMARY selection (Windows) the middle button is ignored.
    t.app.has_primary = false;
    t.win.dispatch(.{ .pointer_down = .{ .pos = p, .button = .middle } });
    t.win.dispatch(.{ .pointer_up = .{ .pos = p, .button = .middle } });
    _ = t.settle();
    try testing.expectEqualStrings("", h.notes.slice());
}

test "prompt hooks: @ and / at a word start report offset and caret" {
    var h: Harness = .{ .name = undefined, .notes = undefined };
    try h.init();
    defer h.deinit();
    const Rec = struct {
        hits: [4]struct { ch: u8, off: u32, x: f32 } = undefined,
        n: usize = 0,
        fn on(ctx: *anyopaque, ch: u8, off: u32, caret: geom.Rect) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            r.hits[r.n] = .{ .ch = ch, .off = off, .x = caret.x };
            r.n += 1;
        }
    };
    var rec: Rec = .{};
    const hooks: prompt_hooks.PromptHooks = .{ .ctx = &rec, .on_trigger = Rec.on };
    h.form.prompt = &hooks;
    h.t.win.markAllDirty();
    const t = h.t;
    try t.click(.{ .name = "Name" });
    t.typeText("@");
    t.typeText("me");
    t.typeText("@");
    t.typeText(" ");
    t.typeText("/");
    // A paste never triggers.
    t.app.clipboard.replace(gpa, "@x");
    h.ctrl(.key_v);
    try testing.expectEqual(@as(usize, 2), rec.n);
    try testing.expectEqual(@as(u8, '@'), rec.hits[0].ch);
    try testing.expectEqual(@as(u32, 0), rec.hits[0].off);
    try testing.expectEqual(@as(u8, '/'), rec.hits[1].ch);
    try testing.expectEqual(@as(u32, 5), rec.hits[1].off);
    // The caret rect is after the trigger character.
    try testing.expect(rec.hits[1].x > rec.hits[0].x);
}

test "password copy blocked" {
    var h: Harness = .{ .name = undefined, .notes = undefined };
    try h.init();
    defer h.deinit();
    h.form.password = true;
    h.t.win.markAllDirty();
    try h.t.click(.{ .name = "Name" });
    h.t.typeText("secret");
    h.ctrl(.key_a);
    h.ctrl(.key_c);
    h.ctrl(.key_x);
    try testing.expectEqualStrings("", h.t.app.clipboard.get());
    try testing.expectEqualStrings("", h.t.app.primary.get());
    try testing.expectEqualStrings("secret", h.name.slice());
    // The text is drawn as bullets, never as itself.
    try testing.expect(std.mem.indexOf(u8, h.t.paintSnapshot(), "secret") == null);
}

test "multiline grows then scrolls" {
    var h: Harness = .{ .name = undefined, .notes = undefined };
    try h.init();
    defer h.deinit();
    const t = h.t;
    const r0 = try t.rectOf(.{ .name = "Notes" });
    // min_rows 2 at 17 px lines plus 3 px padding top and bottom.
    try testing.expectEqual(@as(f32, 2 * 17 + 6), r0.h);
    try t.click(.{ .name = "Notes" });
    t.typeText("1\n2\n3");
    try testing.expectEqual(@as(f32, 3 * 17 + 6), (try t.rectOf(.{ .name = "Notes" })).h);
    t.typeText("\n4\n5\n6");
    try testing.expectEqual(@as(f32, 4 * 17 + 6), (try t.rectOf(.{ .name = "Notes" })).h);
    // Six rows in a four-row field: scrolled so the caret row shows.
    try testing.expectEqual(@as(f32, 2 * 17), h.state("Notes").scroll.y);
    t.press(.home, .{ .ctrl = true });
    try testing.expectEqual(@as(f32, 0), h.state("Notes").scroll.y);
    // Long lines wrap at the content width (184 px = 23 characters).
    try h.state("Notes").setText(&h.notes, "abcdefghij abcdefghij abcdefghij");
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expectEqual(@as(f32, 2 * 17 + 6), (try t.rectOf(.{ .name = "Notes" })).h);
}

test "idle after editing" {
    var h: Harness = .{ .name = undefined, .notes = undefined };
    try h.init();
    defer h.deinit();
    try h.t.click(.{ .name = "Name" });
    h.t.typeText("abc");
    // No caret blink yet: once settled, frames do nothing.
    try testing.expect(h.t.frame().idle);
}
