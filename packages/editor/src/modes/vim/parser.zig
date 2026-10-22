//! The Vim command parser: keys in, complete commands out.
//!
//! Grammar: `["x] [count] operator [count] (motion | text-object)`,
//! `["x] [count] command`, or `[count] motion`. Counts multiply (`2d3w`
//! is `d6w`); a doubled operator (`dd`, `>>`, `gUU`, `gUgU`) works on
//! count lines; `v`, `V` and `Ctrl-V` after an operator force the motion
//! type. In Visual mode operators apply to the selection at once. The
//! parser keeps no allocations: a command is a value.

const std = @import("std");
const key_mod = @import("../key.zig");
const motions = @import("motions.zig");
const objects = @import("text_objects.zig");

const Key = key_mod.Key;
const Motion = motions.Motion;
const Object = objects.Object;

pub const Operator = enum {
    delete,
    change,
    yank,
    indent,
    outdent,
    lower,
    upper,
    toggle_case,

    fn fromKey(c: u21, g: bool) ?Operator {
        if (g) return switch (c) {
            'u' => .lower,
            'U' => .upper,
            '~' => .toggle_case,
            else => null,
        };
        return switch (c) {
            'd' => .delete,
            'c' => .change,
            'y' => .yank,
            '>' => .indent,
            '<' => .outdent,
            else => null,
        };
    }

    /// The key that doubles the operator (`dd`, `guu`).
    fn doubleKey(op: Operator) u21 {
        return switch (op) {
            .delete => 'd',
            .change => 'c',
            .yank => 'y',
            .indent => '>',
            .outdent => '<',
            .lower => 'u',
            .upper => 'U',
            .toggle_case => '~',
        };
    }

    fn isG(op: Operator) bool {
        return op == .lower or op == .upper or op == .toggle_case;
    }
};

/// A motion type forced with `v`, `V` or `Ctrl-V` after an operator.
pub const Force = enum { charwise, linewise, blockwise };

pub const Command = enum {
    delete_char,
    delete_char_before,
    substitute_char,
    substitute_line,
    change_to_eol,
    delete_to_eol,
    yank_line,
    put_after,
    put_before,
    join,
    join_raw,
    replace_char,
    toggle_case_char,
    insert,
    append,
    insert_line_start,
    insert_column_0,
    append_line_end,
    open_below,
    open_above,
    replace_mode,
    undo,
    redo,
    visual_char,
    visual_line,
    visual_block,
    reselect,
    escape,
    repeat,
    /// `q{reg}` (the register is `char`) and the `q` that ends it.
    record_macro,
    stop_record,
    /// `@{reg}`; `@@` has `char` '@'.
    play_macro,
    /// `m{a-zA-Z'`}`.
    set_mark,
    /// `Ctrl-O` and `Ctrl-I` (`<Tab>`).
    jump_older,
    jump_newer,
    /// `:`: the command line.
    cmdline,
    // Visual mode only.
    swap_ends,
    swap_ends_block,
    block_insert,
    block_append,
};

pub const Target = union(enum) {
    motion: struct { m: Motion, char: u21 = 0 },
    object: struct { obj: Object, around: bool },
    /// A doubled operator: count lines.
    lines,
    /// The Visual selection.
    visual,
};

/// A complete command, as dot repeat (E05.F09.S01.T02) records it.
pub const VimCommand = struct {
    register: ?u8 = null,
    /// The product of the counts; 0 when none was typed.
    count: u32 = 0,
    op: ?Operator = null,
    force: ?Force = null,
    target: Target = .visual,
    command: ?Command = null,
    /// The character argument of `r`.
    char: u21 = 0,
};

pub const Action = union(enum) {
    /// More keys needed.
    pending,
    /// Not a command: beep and start over.
    invalid,
    /// Passed on to the editor's own bindings.
    passthrough,
    run: VimCommand,
};

const Prefix = enum { none, g, register, find, replace_char, object_inner, object_around, macro_reg, play_reg, mark_set };

pub const Pending = struct {
    register: ?u8 = null,
    count1: u32 = 0,
    op: ?Operator = null,
    count2: u32 = 0,
    force: ?Force = null,
    prefix: Prefix = .none,
    /// `g` was typed after an operator (`dgg`, `gUgU`).
    op_g: bool = false,
    find: Motion = .find_forward,
    /// A macro is being recorded (`q` then ends it). Kept across resets.
    recording: bool = false,
    /// Keys typed so far, for the status line ("showcmd").
    shown: [24]u8 = undefined,
    shown_len: u8 = 0,

    pub fn reset(p: *Pending) void {
        p.* = .{ .recording = p.recording };
    }

    /// The keys of the command being typed.
    pub fn showcmd(p: *const Pending) []const u8 {
        return p.shown[0..p.shown_len];
    }

    /// Whether an operator waits for its motion.
    pub fn opPending(p: *const Pending) bool {
        return p.op != null;
    }

    fn show(p: *Pending, k: Key) void {
        var buf: [8]u8 = undefined;
        const s: []const u8 = if (k.text()) |c| buf[0 .. std.unicode.utf8Encode(c, &buf) catch 0] else if (k.ctrl) blk: {
            buf[0] = '^';
            buf[1] = std.ascii.toUpper(@intCast(@min(k.code, 0x7F)));
            break :blk buf[0..2];
        } else "";
        if (p.shown_len + s.len > p.shown.len) return;
        @memcpy(p.shown[p.shown_len..][0..s.len], s);
        p.shown_len += @intCast(s.len);
    }

    fn count(p: *const Pending) u32 {
        const a = if (p.count1 == 0) 1 else p.count1;
        const b = if (p.count2 == 0) 1 else p.count2;
        return if (p.count1 == 0 and p.count2 == 0) 0 else a *| b;
    }

    fn done(p: *Pending, c: VimCommand) Action {
        var cmd = c;
        cmd.register = p.register;
        cmd.count = p.count();
        if (p.op != null) cmd.op = p.op;
        if (p.force != null) cmd.force = p.force;
        p.reset();
        return .{ .run = cmd };
    }

    fn fail(p: *Pending) Action {
        p.reset();
        return .invalid;
    }

    /// Feeds one key; `visual`: Visual mode is active.
    pub fn feed(p: *Pending, k: Key, visual: bool) Action {
        p.show(k);
        if (k.isEscape()) {
            const was = p.prefix != .none or p.op != null or p.count1 != 0 or p.register != null;
            p.reset();
            return if (was) .invalid else .{ .run = .{ .command = .escape } };
        }
        switch (p.prefix) {
            .none => {},
            .register => {
                p.prefix = .none;
                const c = k.text() orelse return p.fail();
                if (c > 0x7F) return p.fail();
                p.register = @intCast(c);
                return .pending;
            },
            .find => {
                p.prefix = .none;
                const c = k.text() orelse (if (k.is(.enter)) @as(u21, '\r') else return p.fail());
                return p.done(.{ .target = .{ .motion = .{ .m = p.find, .char = c } } });
            },
            .macro_reg, .play_reg, .mark_set => {
                const which = p.prefix;
                p.prefix = .none;
                const c = k.text() orelse return p.fail();
                return p.done(.{ .command = switch (which) {
                    .macro_reg => .record_macro,
                    .play_reg => .play_macro,
                    else => .set_mark,
                }, .char = c });
            },
            .replace_char => {
                p.prefix = .none;
                const c = k.text() orelse (if (k.is(.enter)) @as(u21, '\n') else return p.fail());
                return p.done(.{ .command = .replace_char, .char = c });
            },
            .object_inner, .object_around => {
                const around = p.prefix == .object_around;
                p.prefix = .none;
                const c = k.text() orelse return p.fail();
                const obj = Object.fromChar(c) orelse return p.fail();
                return p.done(.{ .target = .{ .object = .{ .obj = obj, .around = around } } });
            },
            .g => {
                p.prefix = .none;
                return p.afterG(k, visual);
            },
        }

        if (k.isCtrl('v')) {
            if (p.op != null) {
                p.force = .blockwise;
                return .pending;
            }
            return p.done(.{ .command = .visual_block });
        }
        if (k.isCtrl('r')) return if (p.op == null) p.done(.{ .command = .redo }) else p.fail();
        if (k.isCtrl('h')) return p.motionKey(.back_wrap);
        if (k.isCtrl('o')) return if (p.op == null) p.done(.{ .command = .jump_older }) else p.fail();
        if (k.isCtrl('i') or k.is(.tab)) return if (p.op == null) p.done(.{ .command = .jump_newer }) else p.fail();
        if (k.is(.backspace)) return p.motionKey(.back_wrap);
        if (k.is(.enter)) return p.motionKey(.down_first_non_blank);
        if (k.is(.left)) return p.motionKey(.left);
        if (k.is(.right)) return p.motionKey(.right);
        if (k.is(.up)) return p.motionKey(.up);
        if (k.is(.down)) return p.motionKey(.down);
        if (k.is(.home)) return p.motionKey(.line_start);
        if (k.is(.end)) return p.motionKey(.line_end);
        if (k.is(.delete)) return if (p.op == null) p.done(.{ .command = .delete_char }) else p.fail();
        const c = k.text() orelse {
            if (p.op == null and p.count1 == 0 and p.register == null) {
                p.reset();
                return .passthrough;
            }
            return p.fail();
        };

        // Counts.
        if (c >= '1' and c <= '9' or (c == '0' and (if (p.op == null) p.count1 else p.count2) != 0)) {
            const d = c - '0';
            if (p.op == null) p.count1 = p.count1 *| 10 +| d else p.count2 = p.count2 *| 10 +| d;
            return .pending;
        }
        if (c == '"' and p.op == null) {
            p.prefix = .register;
            return .pending;
        }

        // Operators.
        if (Operator.fromKey(c, false)) |op| {
            if (visual) return p.done(.{ .op = op, .target = .visual });
            if (p.op) |cur| {
                if (cur == op and !cur.isG()) return p.done(.{ .target = .lines });
                return p.fail();
            }
            p.op = op;
            return .pending;
        }
        if (p.op) |cur| {
            if (cur.isG() and c == cur.doubleKey()) return p.done(.{ .target = .lines });
            switch (c) {
                'v' => {
                    p.force = .charwise;
                    return .pending;
                },
                'V' => {
                    p.force = .linewise;
                    return .pending;
                },
                'i', 'a' => {
                    p.prefix = if (c == 'i') .object_inner else .object_around;
                    return .pending;
                },
                else => {},
            }
        }
        if (visual) switch (c) {
            'i', 'a' => {
                p.prefix = if (c == 'i') .object_inner else .object_around;
                return .pending;
            },
            'x' => return p.withOp(.delete),
            'X', 'D' => return p.withOpLines(.delete),
            's' => return p.withOp(.change),
            'S', 'R', 'C' => return p.withOpLines(.change),
            'Y' => return p.withOpLines(.yank),
            'u' => return p.withOp(.lower),
            'U' => return p.withOp(.upper),
            '~' => return p.withOp(.toggle_case),
            'o' => return p.done(.{ .command = .swap_ends }),
            'O' => return p.done(.{ .command = .swap_ends_block }),
            'I' => return p.done(.{ .command = .block_insert }),
            'A' => return p.done(.{ .command = .block_append }),
            else => {},
        };

        if (motionFor(c)) |m| {
            if (m.takesChar()) {
                p.find = m;
                p.prefix = .find;
                return .pending;
            }
            return p.motionKey(m);
        }
        if (c == 'g') {
            p.prefix = .g;
            return .pending;
        }
        if (c == ':') return if (p.op == null) p.done(.{ .command = .cmdline }) else p.fail();
        if (p.op != null) return p.fail();
        switch (c) {
            'q' => {
                if (p.recording and p.count1 == 0 and p.register == null) return p.done(.{ .command = .stop_record });
                if (visual) return p.fail();
                p.prefix = .macro_reg;
                return .pending;
            },
            '@' => {
                p.prefix = .play_reg;
                return .pending;
            },
            'm' => {
                if (visual) return p.fail();
                p.prefix = .mark_set;
                return .pending;
            },
            else => {},
        }
        const cmd: Command = switch (c) {
            'x' => .delete_char,
            'X' => .delete_char_before,
            's' => .substitute_char,
            'S' => .substitute_line,
            'C' => .change_to_eol,
            'D' => .delete_to_eol,
            'Y' => .yank_line,
            'p' => .put_after,
            'P' => .put_before,
            'J' => .join,
            'r' => {
                p.prefix = .replace_char;
                return .pending;
            },
            '~' => .toggle_case_char,
            'i' => .insert,
            'a' => .append,
            'I' => .insert_line_start,
            'A' => .append_line_end,
            'o' => .open_below,
            'O' => .open_above,
            'R' => .replace_mode,
            'u' => .undo,
            'v' => .visual_char,
            'V' => .visual_line,
            '.' => .repeat,
            else => return p.fail(),
        };
        return p.done(.{ .command = cmd });
    }

    fn afterG(p: *Pending, k: Key, visual: bool) Action {
        const c = k.text() orelse return p.fail();
        if (Operator.fromKey(c, true)) |op| {
            if (visual) return p.done(.{ .op = op, .target = .visual });
            if (p.op) |cur| {
                if (cur == op) return p.done(.{ .target = .lines });
                return p.fail();
            }
            p.op = op;
            return .pending;
        }
        const m: ?Motion = switch (c) {
            'g' => .goto_first_line,
            'e' => .back_end_word,
            'E' => .back_end_big_word,
            '_' => .last_non_blank,
            else => null,
        };
        if (m) |mm| return p.motionKey(mm);
        if (p.op != null) return p.fail();
        return switch (c) {
            'J' => p.done(.{ .command = .join_raw }),
            'I' => p.done(.{ .command = .insert_column_0 }),
            'v' => p.done(.{ .command = .reselect }),
            else => p.fail(),
        };
    }

    fn motionKey(p: *Pending, m: Motion) Action {
        return p.done(.{ .target = .{ .motion = .{ .m = m } } });
    }

    fn withOp(p: *Pending, op: Operator) Action {
        p.op = op;
        return p.done(.{ .target = .visual });
    }

    fn withOpLines(p: *Pending, op: Operator) Action {
        p.op = op;
        p.force = .linewise;
        return p.done(.{ .target = .visual });
    }
};

fn motionFor(c: u21) ?Motion {
    return switch (c) {
        'h' => .left,
        'l' => .right,
        ' ' => .space_wrap,
        'j' => .down,
        'k' => .up,
        'w' => .word,
        'W' => .big_word,
        'b' => .back_word,
        'B' => .back_big_word,
        'e' => .end_word,
        'E' => .end_big_word,
        '0' => .line_start,
        '^' => .first_non_blank,
        '$' => .line_end,
        '|' => .column,
        'G' => .goto_line,
        'f' => .find_forward,
        'F' => .find_backward,
        't' => .till_forward,
        'T' => .till_backward,
        ';' => .repeat_find,
        ',' => .repeat_find_reverse,
        '%' => .match_pair,
        '{' => .paragraph_back,
        '}' => .paragraph_forward,
        '(' => .sentence_back,
        ')' => .sentence_forward,
        '+' => .down_first_non_blank,
        '-' => .up_first_non_blank,
        '_' => .current_line_first_non_blank,
        '*' => .search_word_forward,
        '#' => .search_word_backward,
        'n' => .search_next,
        'N' => .search_prev,
        '\'' => .mark_line,
        '`' => .mark_exact,
        '/' => .search_prompt_forward,
        '?' => .search_prompt_backward,
        else => null,
    };
}

fn feedAll(p: *Pending, notation: []const u8, visual: bool) Action {
    var keys: [32]Key = undefined;
    const n = key_mod.parse(notation, &keys) catch unreachable;
    var last: Action = .pending;
    for (keys[0..n]) |k| last = p.feed(k, visual);
    return last;
}

test "vim parser: counts multiply and operators double" {
    var p: Pending = .{};
    const a = feedAll(&p, "2d3w", false).run;
    try std.testing.expectEqual(@as(u32, 6), a.count);
    try std.testing.expectEqual(Operator.delete, a.op.?);
    try std.testing.expectEqual(Motion.word, a.target.motion.m);
    const b = feedAll(&p, "\"a3dd", false).run;
    try std.testing.expectEqual(@as(?u8, 'a'), b.register);
    try std.testing.expectEqual(Target.lines, b.target);
    try std.testing.expectEqual(@as(u32, 3), b.count);
    const c = feedAll(&p, "gUgU", false).run;
    try std.testing.expectEqual(Operator.upper, c.op.?);
    try std.testing.expectEqual(Target.lines, c.target);
    const d = feedAll(&p, "g~~", false).run;
    try std.testing.expectEqual(Target.lines, d.target);
    const e = feedAll(&p, "dvj", false).run;
    try std.testing.expectEqual(Force.charwise, e.force.?);
    const f = feedAll(&p, "ci(", false).run;
    try std.testing.expectEqual(Object.paren, f.target.object.obj);
    const g = feedAll(&p, "3fx", false).run;
    try std.testing.expectEqual(@as(u21, 'x'), g.target.motion.char);
    try std.testing.expectEqual(Action.invalid, feedAll(&p, "dy", false));
    try std.testing.expectEqual(@as(u32, 10), feedAll(&p, "10x", false).run.count);
    try std.testing.expectEqual(Command.escape, feedAll(&p, "<Esc>", false).run.command.?);
    try std.testing.expectEqual(Action.passthrough, feedAll(&p, "<C-p>", false));
    const q = feedAll(&p, "qa", false).run;
    try std.testing.expectEqual(Command.record_macro, q.command.?);
    try std.testing.expectEqual(@as(u21, 'a'), q.char);
    p.recording = true;
    try std.testing.expectEqual(Command.stop_record, feedAll(&p, "q", false).run.command.?);
    try std.testing.expect(p.recording);
    const at = feedAll(&p, "3@b", false).run;
    try std.testing.expectEqual(Command.play_macro, at.command.?);
    try std.testing.expectEqual(@as(u32, 3), at.count);
    try std.testing.expectEqual(Command.set_mark, feedAll(&p, "mx", false).run.command.?);
    const dm = feedAll(&p, "d'x", false).run;
    try std.testing.expectEqual(Motion.mark_line, dm.target.motion.m);
    try std.testing.expectEqual(@as(u21, 'x'), dm.target.motion.char);
    try std.testing.expectEqual(Motion.search_prompt_forward, feedAll(&p, "d/", false).run.target.motion.m);
    try std.testing.expectEqual(Command.jump_older, feedAll(&p, "<C-o>", false).run.command.?);
    try std.testing.expectEqual(Command.jump_newer, feedAll(&p, "<Tab>", false).run.command.?);
    try std.testing.expectEqual(Command.cmdline, feedAll(&p, ":", false).run.command.?);
}
