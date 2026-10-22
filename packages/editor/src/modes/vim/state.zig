//! Vim mode: the mode machine and command execution.
//!
//! `VimState` keeps its own cursors (one per selection) and writes them to
//! the host's selections after every key: carets in normal mode, the
//! inclusive Visual area in Visual modes. In insert and replace mode the
//! host's selections are the cursors, and smart typing does the edits.
//! Every command runs once per cursor, last cursor first, and the cursors
//! not yet run follow the document through each edit. Undo groups follow
//! Vim: one step per change, including the whole insert session.

const std = @import("std");
const key_mod = @import("../key.zig");
const mode_mod = @import("../mode.zig");
const text_mod = @import("text.zig");
const motions = @import("motions.zig");
const objects = @import("text_objects.zig");
const parser = @import("parser.zig");
const ops = @import("operators.zig");
const visual_mod = @import("visual.zig");
const document = @import("../../model/document.zig");
const sel_mod = @import("../../model/edit/selection.zig");
const smart_edit = @import("../../model/edit/smart_edit.zig");
const commands_move = @import("../../model/edit/commands_move.zig");
const runner = @import("../../model/edit/runner.zig");
const cs_mod = @import("../../model/edit/change_set.zig");

const Allocator = std.mem.Allocator;
const Key = key_mod.Key;
const Host = mode_mod.Host;
const Text = text_mod.Text;
const Motion = motions.Motion;
const Kind = motions.Kind;
const Selection = sel_mod.Selection;
const Document = document.Document;
const ChangeEvent = document.ChangeEvent;
pub const Operator = parser.Operator;
pub const VimCommand = parser.VimCommand;
pub const Register = ops.Register;

pub const Mode = enum {
    normal,
    insert,
    replace,
    visual,
    visual_line,
    visual_block,
    op_pending,

    pub fn isVisual(m: Mode) bool {
        return m == .visual or m == .visual_line or m == .visual_block;
    }
};

/// One cursor: where it is, the Visual anchor, and the remembered column
/// (`null` after `$`: the end of every line).
pub const Cursor = struct {
    pos: u64,
    anchor: u64 = 0,
    want: ?u32 = 0,
};

/// How an insert session started, for counts (`3ix<Esc>`) and the
/// cursor at its end.
const InsertKind = enum { insert, open_below, open_above, block };

/// A Visual block `I`, `A` or `c`: what is typed on the first line is
/// copied to the others when insert mode ends.
const BlockIns = struct {
    l0: u64,
    l1: u64,
    col: u32,
    left: u32,
    where: enum { insert, append, eol },
};

pub const VimState = struct {
    gpa: Allocator,
    mode: Mode = .normal,
    cursors: std.ArrayList(Cursor) = .empty,
    pending: parser.Pending = .{},
    /// The unnamed register (E05.F09.S01.T02 adds the others).
    reg: Register = .{},
    group: mode_mod.ChangeGroup,
    last_find: ?motions.LastFind = null,
    last_search: motions.LastSearch = .{},
    /// The last command, for dot repeat (E05.F09.S01.T02).
    last_change: ?VimCommand = null,
    // Insert session.
    ins_count: u32 = 1,
    ins_kind: InsertKind = .insert,
    ins_text: std.ArrayList(u8) = .empty,
    blocks: std.ArrayList(BlockIns) = .empty,
    /// Replace mode: what each typed character replaced (null: appended).
    replaced: std.ArrayList(struct { pos: u64, old: ?u21 }) = .empty,
    /// The last Visual area, for `gv`.
    last_visual: ?struct { mode: Mode, anchor: u64, pos: u64 } = null,
    /// Selections as last written to the host, to notice outside moves.
    synced: std.ArrayList(Selection) = .empty,
    doc: ?*Document = null,
    listener: ?document.ListenerId = null,
    status: [48]u8 = undefined,
    status_len: usize = 0,
    /// Set when the last key was refused (Vim beeps).
    bell: bool = false,
    scratch: std.ArrayList(Selection) = .empty,

    pub fn init(gpa: Allocator) VimState {
        return .{ .gpa = gpa, .group = .init(gpa) };
    }

    pub fn deinit(vs: *VimState) void {
        vs.detach();
        vs.cursors.deinit(vs.gpa);
        vs.reg.deinit(vs.gpa);
        vs.group.deinit();
        vs.ins_text.deinit(vs.gpa);
        vs.blocks.deinit(vs.gpa);
        vs.replaced.deinit(vs.gpa);
        vs.synced.deinit(vs.gpa);
        vs.scratch.deinit(vs.gpa);
    }

    /// The `ModeHandler` for this state.
    pub fn handler(vs: *VimState) mode_mod.ModeHandler {
        return .{ .ctx = vs, .handleKeyFn = handleKeyFn, .statusTextFn = statusTextFn, .caretShapeFn = caretShapeFn };
    }

    fn handleKeyFn(ctx: *anyopaque, k: Key, host: *Host) anyerror!mode_mod.KeyResult {
        const vs: *VimState = @ptrCast(@alignCast(ctx));
        return vs.handleKey(k, host);
    }

    fn statusTextFn(ctx: *anyopaque) []const u8 {
        const vs: *VimState = @ptrCast(@alignCast(ctx));
        return vs.statusText();
    }

    fn caretShapeFn(ctx: *anyopaque) mode_mod.CaretShape {
        const vs: *VimState = @ptrCast(@alignCast(ctx));
        return vs.caretShape();
    }

    /// The mode line: "-- INSERT --" and so on, then the pending keys.
    pub fn statusText(vs: *VimState) []const u8 {
        const m: []const u8 = switch (vs.mode) {
            .insert => "-- INSERT --",
            .replace => "-- REPLACE --",
            .visual => "-- VISUAL --",
            .visual_line => "-- VISUAL LINE --",
            .visual_block => "-- VISUAL BLOCK --",
            .normal, .op_pending => "",
        };
        const cmd = vs.pending.showcmd();
        const s = std.fmt.bufPrint(&vs.status, "{s}{s}{s}", .{ m, if (m.len > 0 and cmd.len > 0) " " else "", cmd }) catch m;
        vs.status_len = s.len;
        return s;
    }

    pub fn caretShape(vs: *const VimState) mode_mod.CaretShape {
        return switch (vs.mode) {
            .insert => .bar,
            .replace => .underline,
            .op_pending => .half_block,
            else => if (vs.pending.opPending()) .half_block else .block,
        };
    }

    // -- document tracking ------------------------------------------------------

    fn attach(vs: *VimState, doc: *Document) !void {
        if (vs.doc == doc) return;
        vs.detach();
        vs.listener = try doc.subscribe(.{ .ctx = vs, .onChange = onChange });
        vs.doc = doc;
        vs.cursors.clearRetainingCapacity();
        vs.synced.clearRetainingCapacity();
        vs.mode = .normal;
        vs.pending.reset();
    }

    /// Stops following the document.
    pub fn detach(vs: *VimState) void {
        if (vs.doc) |d| if (vs.listener) |l| d.unsubscribe(l);
        vs.doc = null;
        vs.listener = null;
        vs.group.cancel();
    }

    fn onChange(ctx: *anyopaque, ev: *const ChangeEvent) void {
        const vs: *VimState = @ptrCast(@alignCast(ctx));
        // Undo grouping, then the cursors not being run follow the edit.
        const l = vs.group.listener();
        l.onChange(l.ctx, ev);
        for (vs.cursors.items) |*c| {
            c.pos = ev.changes.mapPos(c.pos, .left);
            c.anchor = ev.changes.mapPos(c.anchor, .left);
        }
    }

    /// Reads the host's selections into the cursors when something else
    /// moved them (a click, another command).
    fn syncIn(vs: *VimState, host: *Host) !void {
        const sels = host.sels.slice();
        if (vs.cursors.items.len > 0 and sel_mod.eql(sels, vs.synced.items)) return;
        if (vs.cursors.items.len > 0 and vs.synced.items.len == sels.len) {
            var same = true;
            for (sels, vs.synced.items) |a, b| {
                if (a.anchor != b.anchor or a.head != b.head) same = false;
            }
            if (same) return;
        }
        const x = ops.txt(host);
        vs.cursors.clearRetainingCapacity();
        for (sels) |s| {
            const p = if (vs.mode == .insert or vs.mode == .replace) s.head else x.clampNormal(s.head);
            try vs.cursors.append(vs.gpa, .{ .pos = p, .anchor = s.anchor, .want = x.column(p) });
        }
        if (vs.mode.isVisual()) vs.mode = .normal;
    }

    /// Writes the cursors to the host's selections.
    fn syncOut(vs: *VimState, host: *Host) !void {
        if (vs.mode == .insert or vs.mode == .replace) {
            vs.synced.clearRetainingCapacity();
            try vs.synced.appendSlice(vs.gpa, host.sels.slice());
            return;
        }
        const x = ops.txt(host);
        vs.scratch.clearRetainingCapacity();
        const primary = 0;
        for (vs.cursors.items) |c| {
            if (vs.mode.isVisual()) {
                try visual_mod.display(x, vs.mode == .visual_line, vs.mode == .visual_block, c, &vs.scratch, vs.gpa);
            } else try vs.scratch.append(vs.gpa, .caret(x.clampNormal(c.pos)));
        }
        if (vs.scratch.items.len == 0) try vs.scratch.append(vs.gpa, .caret(0));
        try host.sels.set(vs.scratch.items, primary);
        host.sels.normalize(.for_display);
        vs.synced.clearRetainingCapacity();
        try vs.synced.appendSlice(vs.gpa, host.sels.slice());
    }

    // -- keys -------------------------------------------------------------------

    pub fn handleKey(vs: *VimState, k: Key, host: *Host) !mode_mod.KeyResult {
        try vs.attach(host.doc);
        try vs.syncIn(host);
        vs.bell = false;
        const r: mode_mod.KeyResult = switch (vs.mode) {
            .insert => try vs.insertKey(k, host),
            .replace => try vs.replaceKey(k, host),
            else => try vs.normalKey(k, host),
        };
        try vs.syncOut(host);
        return r;
    }

    fn normalKey(vs: *VimState, k: Key, host: *Host) !mode_mod.KeyResult {
        const visual = vs.mode.isVisual();
        switch (vs.pending.feed(k, visual)) {
            .pending => {
                if (!visual) vs.mode = if (vs.pending.opPending()) .op_pending else .normal;
                return .consumed;
            },
            .invalid => {
                if (vs.mode == .op_pending) vs.mode = .normal;
                vs.bell = true;
                return .consumed;
            },
            .passthrough => return .passthrough,
            .run => |cmd| {
                if (vs.mode == .op_pending) vs.mode = .normal;
                vs.run(cmd, host) catch |e| switch (e) {
                    error.Beep => vs.bell = true,
                    else => return e,
                };
                return .consumed;
            },
        }
    }

    /// Runs a parsed command.
    pub fn run(vs: *VimState, cmd: VimCommand, host: *Host) !void {
        if (vs.mode.isVisual()) return vs.runVisual(cmd, host);
        if (cmd.command) |c| return vs.runCommand(c, cmd, host);
        if (cmd.op) |op| return vs.runOperator(op, cmd, host);
        switch (cmd.target) {
            .motion => |m| try vs.moveAll(m.m, m.char, cmd.count, host),
            else => return error.Beep,
        }
    }

    fn motionContext(vs: *VimState, c: Cursor, count: u32, ch: u21) motions.Context {
        return .{
            .count = count,
            .visual = vs.mode.isVisual(),
            .want = c.want,
            .char = ch,
            .last_find = vs.last_find,
            .last_search = &vs.last_search,
        };
    }

    fn noteMotion(vs: *VimState, m: Motion, ch: u21, host: *Host, pos: u64) void {
        if (m.takesChar()) vs.last_find = .{ .motion = m, .char = ch };
        if (m == .search_word_forward or m == .search_word_backward) {
            const x = ops.txt(host);
            if (motions.wordUnderCursor(x, pos)) |w| {
                const n: u8 = @intCast(@min(w.end - w.start, vs.last_search.buf.len));
                for (0..n) |i| vs.last_search.buf[i] = x.byte(w.start + i);
                vs.last_search.len = n;
                vs.last_search.whole_word = w.keyword;
                vs.last_search.backward = m == .search_word_backward;
            }
        }
    }

    fn moveAll(vs: *VimState, m: Motion, ch: u21, count: u32, host: *Host) !void {
        if (vs.cursors.items.len > 0) vs.noteMotion(m, ch, host, vs.cursors.items[0].pos);
        const x = ops.txt(host);
        var moved = false;
        for (vs.cursors.items) |*c| {
            const r = motions.eval(x, c.pos, m, vs.motionContext(c.*, count, ch)) orelse continue;
            moved = true;
            c.pos = if (vs.mode.isVisual()) r.pos else x.clampNormal(r.pos);
            if (r.want_eol) {
                c.want = null;
            } else if (!r.keep_want) c.want = x.column(c.pos);
        }
        vs.dedupe();
        if (!moved) return error.Beep;
    }

    fn dedupe(vs: *VimState) void {
        const items = vs.cursors.items;
        if (items.len <= 1) return;
        std.sort.pdq(Cursor, items, {}, struct {
            fn lt(_: void, a: Cursor, b: Cursor) bool {
                return a.pos < b.pos;
            }
        }.lt);
        var out: usize = 1;
        for (items[1..]) |c| {
            if (c.pos == items[out - 1].pos) continue;
            items[out] = c;
            out += 1;
        }
        vs.cursors.shrinkRetainingCapacity(out);
    }

    fn caretsOf(vs: *VimState) ![]const Selection {
        vs.scratch.clearRetainingCapacity();
        for (vs.cursors.items) |c| try vs.scratch.append(vs.gpa, .caret(c.pos));
        return vs.scratch.items;
    }

    fn beginChange(vs: *VimState, host: *Host) !void {
        try vs.group.begin(try vs.caretsOf());
        _ = host;
    }

    /// Undo puts the cursor back where Vim had it when the change began:
    /// the start of the operated text (column 0 when linewise).
    fn noteStart(vs: *VimState, i: usize, pos: u64) void {
        if (!vs.group.active) return;
        const before = vs.group.sel_before.items;
        if (i < before.len) before[i] = .caret(pos);
    }

    fn commitChange(vs: *VimState, host: *Host) !void {
        try vs.group.commit(host.undo, try vs.caretsOf(), .{ .label = "Vim", .origin = host.edit.origin, .timestamp = host.now() });
    }

    // -- operators -----------------------------------------------------------

    /// A range an operator works on.
    const Span = struct {
        start: u64,
        /// Exclusive end (charwise) or last line (linewise).
        end: u64,
        linewise: bool,
        /// The cursor moved backward (the range ends where it started).
        backward: bool = false,
    };

    fn runOperator(vs: *VimState, op: Operator, cmd: VimCommand, host: *Host) !void {
        if (cmd.target == .motion) vs.noteMotion(cmd.target.motion.m, cmd.target.motion.char, host, vs.cursors.items[0].pos);
        try vs.beginChange(host);
        // A change goes on in insert mode and is committed when that ends.
        var insert_after = false;
        defer if (!insert_after) vs.commitChange(host) catch {};
        var any = false;
        var i = vs.cursors.items.len;
        vs.reg.clear(.charwise);
        var reg_kind: ?ops.RegKind = null;
        while (i > 0) {
            i -= 1;
            const span = (try vs.spanFor(op, cmd, i, host)) orelse continue;
            any = true;
            if (reg_kind == null) reg_kind = if (span.linewise) .linewise else .charwise;
            const sx = ops.txt(host);
            vs.noteStart(i, if (span.linewise) sx.lineStart(span.start) else span.start);
            insert_after = try vs.applyOperator(op, span, i, cmd.count, host) or insert_after;
        }
        vs.reg.kind = reg_kind orelse .charwise;
        vs.dedupe();
        if (!any) return error.Beep;
        if (insert_after) {
            try vs.enterInsert(host, .insert, 1);
        }
    }

    /// The range of an operator with its motion or object, for cursor `i`.
    fn spanFor(vs: *VimState, op: Operator, cmd: VimCommand, i: usize, host: *Host) !?Span {
        const x = ops.txt(host);
        const c = vs.cursors.items[i];
        const n = if (cmd.count == 0) 1 else cmd.count;
        switch (cmd.target) {
            .lines => {
                const l0 = x.lineOf(c.pos);
                if (l0 + n - 1 >= x.lineCount()) return null;
                return .{ .start = l0, .end = l0 + n - 1, .linewise = true };
            },
            .object => |o| {
                const sel = objects.select(x, c.pos, o.obj, o.around, cmd.count, null) orelse return null;
                if (sel.linewise) return .{ .start = x.lineOf(sel.start), .end = x.lineOf(sel.cursor), .linewise = true };
                var e = sel.cursor;
                if (sel.inclusive) e = inclEnd(x, e);
                return .{ .start = sel.start, .end = @max(e, sel.start), .linewise = false };
            },
            .motion => |mm| {
                var ctx = vs.motionContext(c, cmd.count, mm.char);
                ctx.op_pending = true;
                ctx.op_change = op == .change;
                const r = motions.eval(x, c.pos, mm.m, ctx) orelse return null;
                var kind = r.kind;
                if (cmd.force) |f| switch (f) {
                    .charwise => kind = switch (kind) {
                        .linewise => .exclusive,
                        .exclusive => .inclusive,
                        .inclusive => .exclusive,
                    },
                    .linewise => kind = .linewise,
                    .blockwise => {},
                };
                var s = c.pos;
                var e = r.pos;
                const backward = e < s;
                if (backward) std.mem.swap(u64, &s, &e);
                if (kind == .linewise) return .{ .start = x.lineOf(s), .end = x.lineOf(e), .linewise = true, .backward = backward };
                const ls = x.lineOf(s);
                var le = x.lineOf(e);
                // An exclusive motion ending in column 0 ends on the line
                // before; from within the indent it becomes linewise.
                if (kind == .exclusive and cmd.force == null and !r.no_adjust_end and le > ls and e == x.lineStart(le)) {
                    le -= 1;
                    if (inIndent(x, s)) return .{ .start = ls, .end = le, .linewise = true, .backward = backward };
                    e = x.lineEnd(le);
                    if (e > x.lineStart(le)) {
                        kind = .inclusive;
                        e = x.before(e);
                    }
                }
                if (kind == .inclusive) e = x.after(e);
                // "d" over lines from the indent to trailing white space is linewise.
                if (op == .delete and cmd.force == null and le > ls and inIndent(x, s) and onlyWhiteAfter(x, e)) {
                    return .{ .start = ls, .end = le, .linewise = true, .backward = backward };
                }
                return .{ .start = s, .end = e, .linewise = false, .backward = backward };
            },
            .visual => return null,
        }
    }

    /// Applies `op` to `span` for cursor `i`; true when insert mode follows.
    fn applyOperator(vs: *VimState, op: Operator, span: Span, i: usize, count: u32, host: *Host) !bool {
        const gpa = vs.gpa;
        var x = ops.txt(host);
        const c = &vs.cursors.items[i];
        var piece: std.ArrayList(u8) = .empty;
        defer piece.deinit(gpa);
        _ = count;
        if (span.linewise) {
            const l0 = span.start;
            const l1 = span.end;
            switch (op) {
                .yank, .delete, .change => try ops.yankLines(x, l0, l1, &piece, gpa),
                else => {},
            }
            if (op == .yank or op == .delete or op == .change) try vs.reg.prepend(gpa, piece.items);
            switch (op) {
                .yank => {
                    if (span.backward) c.pos = x.atColumn(l0, x.column(c.pos), false);
                },
                .delete => {
                    const sp = ops.lineSpan(x, l0, l1);
                    try ops.replace(host, sp.start, sp.end, "");
                    x = ops.txt(host);
                    const l = @min(l0, x.lineCount() - 1);
                    c.pos = x.firstNonBlank(l);
                    c.want = x.column(x.clampNormal(c.pos));
                },
                .change => {
                    var buf: [256]u8 = undefined;
                    const ind_end = x.firstNonBlank(l0);
                    const ind_len = @min(ind_end - x.lineStart(l0), buf.len);
                    for (0..ind_len) |k| buf[k] = x.byte(x.lineStart(l0) + k);
                    try ops.replace(host, x.lineStart(l0), x.lineEnd(l1), buf[0..ind_len]);
                    c.pos = x.lineStart(l0) + ind_len;
                    return true;
                },
                .indent, .outdent => {
                    try ops.shift(host, l0, l1, op == .indent, 1);
                    x = ops.txt(host);
                    c.pos = x.firstNonBlank(l0);
                },
                .lower, .upper, .toggle_case => {
                    try ops.changeCase(host, x.lineStart(l0), x.lineEnd(l1), caseOf(op));
                    x = ops.txt(host);
                    if (span.backward) c.pos = x.atColumn(l0, x.column(c.pos), false);
                },
            }
            c.pos = ops.txt(host).clampNormal(c.pos);
            return false;
        }
        const s = span.start;
        const e = span.end;
        switch (op) {
            .yank, .delete, .change => {
                try ops.copyRange(x, s, e, &piece, gpa);
                try vs.reg.prepend(gpa, piece.items);
            },
            else => {},
        }
        switch (op) {
            .yank => c.pos = s,
            .delete => {
                try ops.replace(host, s, e, "");
                c.pos = s;
            },
            .change => {
                try ops.replace(host, s, e, "");
                c.pos = s;
                return true;
            },
            .indent, .outdent => {
                try ops.shift(host, x.lineOf(s), x.lineOf(if (e > s) e - 1 else e), op == .indent, 1);
                x = ops.txt(host);
                c.pos = x.firstNonBlank(x.lineOf(s));
            },
            .lower, .upper, .toggle_case => {
                try ops.changeCase(host, s, e, caseOf(op));
                c.pos = s;
            },
        }
        x = ops.txt(host);
        c.pos = x.clampNormal(c.pos);
        c.want = x.column(c.pos);
        return false;
    }

    // -- commands ---------------------------------------------------------------

    fn runCommand(vs: *VimState, command: parser.Command, cmd: VimCommand, host: *Host) !void {
        const n = if (cmd.count == 0) 1 else cmd.count;
        switch (command) {
            .escape => {},
            .repeat => {},
            .delete_char => return vs.runOperator(.delete, withMotion(cmd, .right), host),
            .delete_char_before => return vs.runOperator(.delete, withMotion(cmd, .left), host),
            .substitute_char => return vs.runOperator(.change, withMotion(cmd, .right), host),
            .substitute_line => return vs.runOperator(.change, withLines(cmd), host),
            .change_to_eol => return vs.runOperator(.change, withMotion(cmd, .line_end), host),
            .delete_to_eol => return vs.runOperator(.delete, withMotion(cmd, .line_end), host),
            .yank_line => return vs.runOperator(.yank, withLines(cmd), host),
            .put_after, .put_before => try vs.put(command == .put_after, n, host),
            .join, .join_raw => {
                try vs.beginChange(host);
                defer vs.commitChange(host) catch {};
                var i = vs.cursors.items.len;
                var ok = false;
                while (i > 0) {
                    i -= 1;
                    const x = ops.txt(host);
                    const c = &vs.cursors.items[i];
                    if (try ops.join(host, x.lineOf(c.pos), n, command == .join)) |p| {
                        c.pos = p;
                        ok = true;
                    }
                }
                if (!ok) return error.Beep;
            },
            .replace_char => {
                try vs.beginChange(host);
                defer vs.commitChange(host) catch {};
                var i = vs.cursors.items.len;
                var ok = false;
                while (i > 0) {
                    i -= 1;
                    const c = &vs.cursors.items[i];
                    if (try ops.replaceChars(host, c.pos, n, cmd.char)) |p| {
                        c.pos = p;
                        ok = true;
                    }
                }
                if (!ok) return error.Beep;
            },
            .toggle_case_char => {
                try vs.beginChange(host);
                defer vs.commitChange(host) catch {};
                var i = vs.cursors.items.len;
                while (i > 0) {
                    i -= 1;
                    const x = ops.txt(host);
                    const c = &vs.cursors.items[i];
                    if (x.atEol(c.pos)) continue;
                    var e = c.pos;
                    for (0..n) |_| {
                        if (x.atEol(e)) break;
                        e = x.after(e);
                    }
                    try ops.changeCase(host, c.pos, e, .toggle);
                    c.pos = ops.txt(host).clampNormal(e);
                    c.want = ops.txt(host).column(c.pos);
                }
            },
            .insert, .append, .insert_line_start, .insert_column_0, .append_line_end => {
                const x = ops.txt(host);
                for (vs.cursors.items) |*c| {
                    const l = x.lineOf(c.pos);
                    c.pos = switch (command) {
                        .append => if (x.atEol(c.pos)) c.pos else x.after(c.pos),
                        .insert_line_start => x.firstNonBlank(l),
                        .insert_column_0 => x.lineStart(l),
                        .append_line_end => x.lineEnd(l),
                        else => c.pos,
                    };
                }
                try vs.beginChange(host);
                try vs.enterInsert(host, .insert, n);
            },
            .open_below, .open_above => {
                try vs.beginChange(host);
                try vs.openLines(command == .open_below, host);
                try vs.enterInsert(host, if (command == .open_below) .open_below else .open_above, n);
            },
            .replace_mode => {
                try vs.beginChange(host);
                try vs.enterInsert(host, .insert, n);
                vs.mode = .replace;
                vs.replaced.clearRetainingCapacity();
            },
            .undo, .redo => try vs.undoRedo(command == .undo, n, host),
            .visual_char, .visual_line, .visual_block => {
                vs.mode = switch (command) {
                    .visual_char => .visual,
                    .visual_line => .visual_line,
                    else => .visual_block,
                };
                for (vs.cursors.items) |*c| c.anchor = c.pos;
            },
            .reselect => {
                const lv = vs.last_visual orelse return error.Beep;
                const x = ops.txt(host);
                vs.cursors.clearRetainingCapacity();
                try vs.cursors.append(vs.gpa, .{ .pos = @min(lv.pos, x.len), .anchor = @min(lv.anchor, x.len), .want = x.column(@min(lv.pos, x.len)) });
                vs.mode = lv.mode;
            },
            else => return error.Beep,
        }
    }

    fn openLines(vs: *VimState, below: bool, host: *Host) !void {
        var i = vs.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const x = ops.txt(host);
            const c = &vs.cursors.items[i];
            const l = x.lineOf(c.pos);
            var buf: [256]u8 = undefined;
            const ind_len = @min(x.firstNonBlank(l) - x.lineStart(l), buf.len - 1);
            if (below) {
                buf[0] = '\n';
                for (0..ind_len) |k| buf[1 + k] = x.byte(x.lineStart(l) + k);
                const at = x.lineEnd(l);
                try ops.replace(host, at, at, buf[0 .. ind_len + 1]);
                c.pos = at + 1 + ind_len;
            } else {
                for (0..ind_len) |k| buf[k] = x.byte(x.lineStart(l) + k);
                buf[ind_len] = '\n';
                const at = x.lineStart(l);
                try ops.replace(host, at, at, buf[0 .. ind_len + 1]);
                c.pos = at + ind_len;
            }
        }
    }

    fn put(vs: *VimState, after: bool, count: u32, host: *Host) !void {
        if (vs.reg.pieceCount() == 0) return error.Beep;
        try vs.beginChange(host);
        defer vs.commitChange(host) catch {};
        const per_cursor = vs.reg.pieceCount() == vs.cursors.items.len;
        const all = try vs.reg.joined(vs.gpa);
        defer vs.gpa.free(all);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(vs.gpa);
        var i = vs.cursors.items.len;
        while (i > 0) {
            i -= 1;
            const x = ops.txt(host);
            const c = &vs.cursors.items[i];
            const t = if (per_cursor) vs.reg.piece(i) else all;
            buf.clearRetainingCapacity();
            for (0..count) |_| try buf.appendSlice(vs.gpa, t);
            const l = x.lineOf(c.pos);
            if (vs.reg.kind == .linewise) {
                var at: u64 = undefined;
                if (after) {
                    at = x.nextLineStart(l);
                    if (at == x.len and !(x.lineEnd(l) < at)) {
                        // The last line has no break: add one before.
                        try buf.insert(vs.gpa, 0, '\n');
                        _ = buf.pop();
                        at = x.lineEnd(l);
                    }
                } else at = x.lineStart(l);
                try ops.replace(host, at, at, buf.items);
                const nx = ops.txt(host);
                const first = if (after) l + 1 else l;
                c.pos = nx.firstNonBlank(first);
            } else {
                const at = if (after and !x.atEol(c.pos)) x.after(c.pos) else c.pos;
                try ops.replace(host, at, at, buf.items);
                const nx = ops.txt(host);
                if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) {
                    c.pos = at;
                } else c.pos = nx.before(at + buf.items.len);
            }
            const nx = ops.txt(host);
            c.pos = nx.clampNormal(c.pos);
            c.want = nx.column(c.pos);
        }
    }

    fn undoRedo(vs: *VimState, undo: bool, count: u32, host: *Host) !void {
        vs.group.cancel();
        var done: u32 = 0;
        var cursor: ?u64 = null;
        while (done < count) : (done += 1) {
            const step = (if (undo) host.undo.undo() else host.undo.redo()) orelse break;
            try host.doc.applyChangeSet(step.changes, .undo);
            const x = ops.txt(host);
            const top = if (step.changes.replaces.len > 0) step.changes.replaces[0].range.start else 0;
            const tl = x.lineOf(@min(top, x.len));
            var p = x.firstNonBlank(tl);
            if (step.selections.len > 0) {
                const sp = @min(step.selections[0].head, x.len);
                if (x.lineOf(sp) == tl) p = sp;
            }
            cursor = p;
        }
        if (done == 0) return error.Beep;
        const x = ops.txt(host);
        vs.cursors.clearRetainingCapacity();
        const p = x.clampNormal(cursor.?);
        try vs.cursors.append(vs.gpa, .{ .pos = p, .want = x.column(p) });
    }

    // -- insert and replace mode ---------------------------------------------

    fn enterInsert(vs: *VimState, host: *Host, kind: InsertKind, count: u32) !void {
        vs.mode = .insert;
        vs.ins_kind = kind;
        vs.ins_count = count;
        vs.ins_text.clearRetainingCapacity();
        vs.scratch.clearRetainingCapacity();
        for (vs.cursors.items) |c| try vs.scratch.append(vs.gpa, .caret(c.pos));
        try host.sels.set(vs.scratch.items, 0);
        host.sels.normalize(.for_edit);
    }

    fn insertKey(vs: *VimState, k: Key, host: *Host) !mode_mod.KeyResult {
        const ctx = host.edit;
        if (k.isEscape()) return vs.leaveInsert(host);
        if (k.is(.enter) or k.isCtrl('j') or k.isCtrl('m')) {
            _ = try smart_edit.newline(host.doc, host.sels, ctx);
            try vs.ins_text.append(vs.gpa, '\n');
            return .consumed;
        }
        if (k.is(.backspace) or k.isCtrl('h')) {
            _ = try smart_edit.deleteLeft(host.doc, host.sels, ctx, false);
            popChar(&vs.ins_text);
            return .consumed;
        }
        if (k.is(.delete)) {
            _ = try commands_move.deleteBy(host.doc, host.sels, .grapheme, .forward, .{}, ctx.origin);
            return .consumed;
        }
        if (k.isCtrl('w')) {
            _ = try commands_move.deleteBy(host.doc, host.sels, .word, .backward, .{}, ctx.origin);
            return .consumed;
        }
        if (k.isCtrl('u')) {
            _ = try commands_move.deleteBy(host.doc, host.sels, .line_boundary, .backward, .{}, ctx.origin);
            return .consumed;
        }
        if (k.is(.left) or k.is(.right) or k.is(.up) or k.is(.down) or k.is(.home) or k.is(.end)) {
            // Moving starts a new undo step and insert session.
            try vs.group.commit(host.undo, host.sels.slice(), .{ .label = "Vim", .origin = ctx.origin, .timestamp = host.now() });
            var snap = host.doc.snapshot();
            defer snap.release();
            const unit: @import("../../model/edit/movement.zig").Unit = if (k.is(.up) or k.is(.down)) .buffer_line else if (k.is(.home) or k.is(.end)) .line_boundary else .grapheme;
            const dir: @import("../../model/edit/movement.zig").Dir = if (k.is(.left) or k.is(.up) or k.is(.home)) .backward else .forward;
            commands_move.moveSelections(&snap, host.sels, unit, dir, false, host.move);
            vs.ins_count = 1;
            vs.ins_text.clearRetainingCapacity();
            try vs.group.begin(host.sels.slice());
            return .consumed;
        }
        if (k.is(.tab)) {
            _ = try smart_edit.typeChar(host.doc, host.sels, '\t', ctx);
            try vs.ins_text.append(vs.gpa, '\t');
            return .consumed;
        }
        const cp = k.text() orelse return .passthrough;
        _ = try smart_edit.typeChar(host.doc, host.sels, cp, ctx);
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        try vs.ins_text.appendSlice(vs.gpa, buf[0..n]);
        return .consumed;
    }

    fn leaveInsert(vs: *VimState, host: *Host) !mode_mod.KeyResult {
        if (vs.ins_kind == .block and vs.mode == .insert) return vs.leaveBlockInsert(host);
        // A count repeats what was typed.
        if (vs.ins_count > 1 and vs.ins_text.items.len > 0 and vs.mode == .insert) {
            var rep: std.ArrayList(u8) = .empty;
            defer rep.deinit(vs.gpa);
            for (1..vs.ins_count) |_| {
                if (vs.ins_kind == .open_below or vs.ins_kind == .open_above) try rep.append(vs.gpa, '\n');
                try rep.appendSlice(vs.gpa, vs.ins_text.items);
            }
            if (vs.ins_kind == .open_above) {
                // Further copies go below the first one.
                _ = try runner.typeText(host.doc, host.sels, rep.items, host.edit.origin);
            } else _ = try runner.typeText(host.doc, host.sels, rep.items, host.edit.origin);
        }
        const x = ops.txt(host);
        vs.cursors.clearRetainingCapacity();
        for (host.sels.slice()) |s| {
            const p = x.clampNormal(x.before(s.head));
            try vs.cursors.append(vs.gpa, .{ .pos = p, .want = x.column(p) });
        }
        vs.dedupe();
        vs.mode = .normal;
        try vs.commitChange(host);
        return .consumed;
    }

    /// Copies the text typed on each block's first line to its other
    /// lines (not when it holds a line break), then leaves the cursor at
    /// the block's top-left.
    fn leaveBlockInsert(vs: *VimState, host: *Host) !mode_mod.KeyResult {
        const typed = vs.ins_text.items;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(vs.gpa);
        if (typed.len > 0 and std.mem.indexOfScalar(u8, typed, '\n') == null) {
            var b = vs.blocks.items.len;
            while (b > 0) {
                b -= 1;
                const blk = vs.blocks.items[b];
                var l = blk.l1;
                while (l > blk.l0) : (l -= 1) {
                    const x = ops.txt(host);
                    const len = x.column(x.lineEnd(l));
                    buf.clearRetainingCapacity();
                    const at = switch (blk.where) {
                        .eol => x.lineEnd(l),
                        .insert => if (len < blk.col) continue else x.atColumn(l, blk.col, true),
                        .append => at: {
                            if (len < blk.col) try buf.appendNTimes(vs.gpa, ' ', blk.col - len);
                            break :at x.atColumn(l, blk.col, true);
                        },
                    };
                    try buf.appendSlice(vs.gpa, typed);
                    try ops.replace(host, at, at, buf.items);
                }
            }
        }
        const x = ops.txt(host);
        vs.cursors.clearRetainingCapacity();
        for (vs.blocks.items) |blk| {
            const p = x.clampNormal(x.atColumn(blk.l0, blk.left, false));
            try vs.cursors.append(vs.gpa, .{ .pos = p, .want = x.column(p) });
        }
        vs.blocks.clearRetainingCapacity();
        vs.dedupe();
        vs.mode = .normal;
        try vs.commitChange(host);
        return .consumed;
    }

    fn replaceKey(vs: *VimState, k: Key, host: *Host) !mode_mod.KeyResult {
        if (k.isEscape()) {
            vs.mode = .insert;
            vs.ins_text.clearRetainingCapacity();
            return vs.leaveInsert(host);
        }
        if (k.is(.backspace) or k.isCtrl('h')) {
            // Back over what this session typed, restoring it.
            const last = vs.replaced.pop() orelse {
                var snap = host.doc.snapshot();
                defer snap.release();
                commands_move.moveSelections(&snap, host.sels, .grapheme, .backward, false, host.move);
                return .consumed;
            };
            const x = ops.txt(host);
            const end = x.after(last.pos);
            if (last.old) |old| {
                var buf: [4]u8 = undefined;
                const n = try std.unicode.utf8Encode(old, &buf);
                try ops.replace(host, last.pos, end, buf[0..n]);
            } else try ops.replace(host, last.pos, end, "");
            try host.sels.set(&.{.caret(last.pos)}, 0);
            return .consumed;
        }
        if (k.is(.enter)) {
            _ = try smart_edit.newline(host.doc, host.sels, host.edit);
            return .consumed;
        }
        const cp = k.text() orelse return .passthrough;
        var buf: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &buf);
        const x = ops.txt(host);
        vs.scratch.clearRetainingCapacity();
        var edits: std.ArrayList(cs_mod.Replace) = .empty;
        defer edits.deinit(vs.gpa);
        for (host.sels.slice()) |s| {
            const p = s.head;
            const old: ?u21 = if (x.atEol(p)) null else x.cp(p);
            const end = if (x.atEol(p)) p else x.after(p);
            try edits.append(vs.gpa, .{ .range = .{ .start = p, .end = end }, .text = buf[0..n] });
            if (host.sels.count() == 1) try vs.replaced.append(vs.gpa, .{ .pos = p, .old = old });
        }
        var cs = try cs_mod.ChangeSet.fromEdits(vs.gpa, host.doc.len(), edits.items);
        defer cs.deinit();
        try host.doc.applyChangeSet(&cs, host.edit.origin);
        for (host.sels.items.items, edits.items) |*s, e| {
            const at = cs.mapPos(e.range.start, .left) + n;
            s.* = .{ .anchor = at, .head = at, .id = s.id };
        }
        return .consumed;
    }

    // -- Visual mode -----------------------------------------------------------

    fn runVisual(vs: *VimState, cmd: VimCommand, host: *Host) !void {
        const x = ops.txt(host);
        if (cmd.command) |c| switch (c) {
            .escape => return vs.leaveVisual(host),
            .visual_char, .visual_line, .visual_block => {
                const m: Mode = switch (c) {
                    .visual_char => .visual,
                    .visual_line => .visual_line,
                    else => .visual_block,
                };
                if (m == vs.mode) return vs.leaveVisual(host);
                vs.mode = m;
                return;
            },
            .swap_ends, .swap_ends_block => {
                for (vs.cursors.items) |*cur| {
                    if (c == .swap_ends_block and vs.mode == .visual_block) {
                        // The other corner on the same line.
                        const ca = x.column(cur.anchor);
                        const cp = x.column(cur.pos);
                        cur.pos = x.atColumn(x.lineOf(cur.pos), ca, true);
                        cur.anchor = x.atColumn(x.lineOf(cur.anchor), cp, true);
                    } else std.mem.swap(u64, &cur.pos, &cur.anchor);
                    cur.want = x.column(cur.pos);
                }
                return;
            },
            .block_insert, .block_append => return vs.blockInsert(c == .block_append, host),
            .join, .join_raw => {
                try vs.beginChange(host);
                defer vs.commitChange(host) catch {};
                var i = vs.cursors.items.len;
                while (i > 0) {
                    i -= 1;
                    const cur = &vs.cursors.items[i];
                    const lx = ops.txt(host);
                    const l0 = lx.lineOf(@min(cur.pos, cur.anchor));
                    const l1 = lx.lineOf(@max(cur.pos, cur.anchor));
                    if (try ops.join(host, l0, @intCast(@max(l1 - l0 + 1, 2)), c == .join)) |p| cur.pos = p;
                }
                return vs.endVisual(host);
            },
            .replace_char => {
                try vs.beginChange(host);
                defer vs.commitChange(host) catch {};
                var i = vs.cursors.items.len;
                while (i > 0) {
                    i -= 1;
                    const lx = ops.txt(host);
                    const cur = &vs.cursors.items[i];
                    var it = visual_mod.Ranges.init(lx, vs.mode, cur.*);
                    var start: ?u64 = null;
                    var ranges: [512]struct { u64, u64 } = undefined;
                    var nr: usize = 0;
                    while (it.next()) |r| : (nr += 1) {
                        if (nr == ranges.len) break;
                        ranges[nr] = .{ r.start, r.end };
                        if (start == null) start = r.start;
                    }
                    var k = nr;
                    while (k > 0) {
                        k -= 1;
                        try replaceAllChars(host, ranges[k][0], ranges[k][1], c == .replace_char, cmd.char, vs.gpa);
                    }
                    cur.pos = start orelse cur.pos;
                }
                return vs.endVisual(host);
            },
            .put_after, .put_before => {
                // Replace the selection with the register.
                const saved_kind = vs.reg.kind;
                const saved = try vs.gpa.dupe(u8, vs.reg.text.items);
                defer vs.gpa.free(saved);
                const saved_ends = try vs.gpa.dupe(u32, vs.reg.ends.items);
                defer vs.gpa.free(saved_ends);
                try vs.beginChange(host);
                defer vs.commitChange(host) catch {};
                const linewise = vs.mode == .visual_line;
                const c0 = vs.cursors.items[0];
                const op_start = @min(c0.pos, c0.anchor);
                const start_line = x.lineOf(op_start);
                try vs.visualOperator(.delete, cmd, host, false);
                vs.reg.kind = saved_kind;
                vs.reg.text.clearRetainingCapacity();
                try vs.reg.text.appendSlice(vs.gpa, saved);
                vs.reg.ends.clearRetainingCapacity();
                try vs.reg.ends.appendSlice(vs.gpa, saved_ends);
                // Vim puts after the cursor only when the delete left it
                // before where the area started (the area ended a line or
                // the buffer).
                const px = ops.txt(host);
                const p0 = vs.cursors.items[0].pos;
                const forward = if (linewise) px.lineOf(p0) < start_line else p0 < op_start;
                try vs.put(forward, 1, host);
                return;
            },
            else => return error.Beep,
        };
        if (cmd.op) |op| return vs.visualOperator(op, cmd, host, true);
        switch (cmd.target) {
            .motion => |m| return vs.moveAll(m.m, m.char, cmd.count, host),
            .object => |o| {
                for (vs.cursors.items) |*cur| {
                    const sel = objects.select(x, cur.pos, o.obj, o.around, cmd.count, cur.anchor) orelse return error.Beep;
                    if (sel.linewise) {
                        if (vs.mode == .visual) vs.mode = .visual_line;
                    } else if (vs.mode == .visual_line and o.obj != .paragraph) vs.mode = .visual;
                    cur.anchor = sel.start;
                    cur.pos = sel.cursor;
                    cur.want = x.column(cur.pos);
                }
                return;
            },
            else => return error.Beep,
        }
    }

    fn leaveVisual(vs: *VimState, host: *Host) !void {
        if (vs.cursors.items.len > 0) {
            const c = vs.cursors.items[0];
            vs.last_visual = .{ .mode = vs.mode, .anchor = c.anchor, .pos = c.pos };
        }
        vs.mode = .normal;
        const x = ops.txt(host);
        for (vs.cursors.items) |*c| c.pos = x.clampNormal(c.pos);
    }

    fn endVisual(vs: *VimState, host: *Host) !void {
        const was = vs.mode;
        if (vs.cursors.items.len > 0) {
            const c = vs.cursors.items[0];
            vs.last_visual = .{ .mode = was, .anchor = c.anchor, .pos = c.pos };
        }
        vs.mode = .normal;
        const x = ops.txt(host);
        for (vs.cursors.items) |*c| {
            c.pos = x.clampNormal(c.pos);
            c.want = x.column(c.pos);
        }
        vs.dedupe();
    }

    fn visualOperator(vs: *VimState, op: Operator, cmd: VimCommand, host: *Host, own_group: bool) !void {
        if (own_group) try vs.beginChange(host);
        var insert_after = false;
        defer if (own_group and !insert_after and vs.blocks.items.len == 0) vs.commitChange(host) catch {};
        var mode = vs.mode;
        if (cmd.force == .linewise) mode = .visual_line;
        vs.reg.clear(switch (mode) {
            .visual_line => .linewise,
            .visual_block => .blockwise,
            else => .charwise,
        });
        vs.blocks.clearRetainingCapacity();
        const amount = if (cmd.count == 0) 1 else cmd.count;
        var i = vs.cursors.items.len;
        while (i > 0) {
            i -= 1;
            var x = ops.txt(host);
            const cur = &vs.cursors.items[i];
            const lo = @min(cur.pos, cur.anchor);
            const hi = @max(cur.pos, cur.anchor);
            switch (mode) {
                .visual_line => {
                    const l0 = x.lineOf(lo);
                    const l1 = x.lineOf(hi);
                    if (op == .indent or op == .outdent) {
                        try ops.shift(host, l0, l1, op == .indent, amount);
                        cur.pos = ops.txt(host).firstNonBlank(l0);
                        continue;
                    }
                    const keep = cur.*;
                    vs.noteStart(i, x.lineStart(l0));
                    cur.pos = lo;
                    insert_after = try vs.applyOperator(op, .{ .start = l0, .end = l1, .linewise = true, .backward = true }, i, 0, host) or insert_after;
                    // Vim leaves the cursor where the area starts: column 0
                    // when that is the Visual start, else where it was.
                    if (op == .yank) cur.pos = if (keep.pos < keep.anchor) keep.pos else x.lineStart(l0);
                },
                .visual_block => {
                    var it = visual_mod.Ranges.init(x, mode, cur.*);
                    var ranges: std.ArrayList(struct { u64, u64 }) = .empty;
                    defer ranges.deinit(vs.gpa);
                    while (it.next()) |r| try ranges.append(vs.gpa, .{ r.start, r.end });
                    if (op == .indent or op == .outdent) {
                        try ops.shift(host, x.lineOf(lo), x.lineOf(hi), op == .indent, amount);
                        cur.pos = ops.txt(host).firstNonBlank(x.lineOf(lo));
                        continue;
                    }
                    // Yank the pieces as lines of a block.
                    var piece: std.ArrayList(u8) = .empty;
                    defer piece.deinit(vs.gpa);
                    if (op == .yank or op == .delete or op == .change) {
                        for (ranges.items, 0..) |r, n| {
                            if (n > 0) try piece.append(vs.gpa, '\n');
                            try ops.copyRange(x, r[0], r[1], &piece, vs.gpa);
                        }
                        try vs.reg.prepend(vs.gpa, piece.items);
                    }
                    const top = if (ranges.items.len > 0) ranges.items[0][0] else lo;
                    vs.noteStart(i, top);
                    const cols = visual_mod.blockColumns(x, cur.*);
                    const bl0 = x.lineOf(lo);
                    const bl1 = x.lineOf(hi);
                    var k = ranges.items.len;
                    while (k > 0) {
                        k -= 1;
                        const r = ranges.items[k];
                        switch (op) {
                            .delete, .change => try ops.replace(host, r[0], r[1], ""),
                            .lower, .upper, .toggle_case => try ops.changeCase(host, r[0], r[1], caseOf(op)),
                            else => {},
                        }
                    }
                    if (op == .change) {
                        // Typing on the first line is copied to the rest.
                        try vs.blocks.insert(vs.gpa, 0, .{ .l0 = bl0, .l1 = bl1, .col = cols.left, .left = cols.left, .where = .insert });
                    }
                    cur.pos = top;
                },
                else => {
                    if (op == .indent or op == .outdent) {
                        try ops.shift(host, x.lineOf(lo), x.lineOf(hi), op == .indent, amount);
                        cur.pos = ops.txt(host).firstNonBlank(x.lineOf(lo));
                        continue;
                    }
                    const e = inclEnd(x, hi);
                    vs.noteStart(i, lo);
                    insert_after = try vs.applyOperator(op, .{ .start = lo, .end = e, .linewise = false }, i, 0, host) or insert_after;
                },
            }
        }
        if (vs.cursors.items.len > 0) {
            const c = vs.cursors.items[0];
            vs.last_visual = .{ .mode = vs.mode, .anchor = c.anchor, .pos = c.pos };
        }
        vs.mode = .normal;
        if (vs.blocks.items.len > 0) return vs.enterBlockInsert(host);
        if (insert_after) return vs.enterInsert(host, .insert, 1);
        const x = ops.txt(host);
        for (vs.cursors.items) |*c| {
            c.pos = x.clampNormal(c.pos);
            c.want = x.column(c.pos);
        }
        vs.dedupe();
    }

    /// `I`/`A` in Visual block mode: a caret on every line of the block.
    fn blockInsert(vs: *VimState, append: bool, host: *Host) !void {
        const x = ops.txt(host);
        if (vs.mode != .visual_block) {
            // Characterwise or linewise: insert before or after the area.
            for (vs.cursors.items) |*c| {
                const lo = @min(c.pos, c.anchor);
                const hi = @max(c.pos, c.anchor);
                c.pos = if (append) (if (vs.mode == .visual_line) x.lineEnd(x.lineOf(hi)) else inclEnd(x, hi)) else (if (vs.mode == .visual_line) x.firstNonBlank(x.lineOf(lo)) else lo);
            }
            vs.mode = .normal;
            try vs.beginChange(host);
            return vs.enterInsert(host, .insert, 1);
        }
        try vs.beginChange(host);
        vs.blocks.clearRetainingCapacity();
        for (vs.cursors.items) |c| {
            const cols = visual_mod.blockColumns(x, c);
            try vs.blocks.append(vs.gpa, .{
                .l0 = x.lineOf(@min(c.pos, c.anchor)),
                .l1 = x.lineOf(@max(c.pos, c.anchor)),
                .col = if (!append) cols.left else cols.right + 1,
                .left = cols.left,
                .where = if (!append) .insert else if (cols.to_eol) .eol else .append,
            });
        }
        try vs.enterBlockInsert(host);
    }

    /// Insert mode with a caret on each block's first line, padding a
    /// short first line for `A`.
    fn enterBlockInsert(vs: *VimState, host: *Host) !void {
        var b = vs.blocks.items.len;
        while (b > 0) {
            b -= 1;
            const blk = vs.blocks.items[b];
            const x = ops.txt(host);
            const len = x.column(x.lineEnd(blk.l0));
            if (blk.where == .append and len < blk.col) {
                var pad: [256]u8 = @splat(' ');
                const at = x.lineEnd(blk.l0);
                try ops.replace(host, at, at, pad[0..@min(blk.col - len, pad.len)]);
            }
        }
        const x = ops.txt(host);
        vs.cursors.clearRetainingCapacity();
        for (vs.blocks.items) |blk| {
            const p = if (blk.where == .eol) x.lineEnd(blk.l0) else x.atColumn(blk.l0, blk.col, true);
            try vs.cursors.append(vs.gpa, .{ .pos = p });
        }
        try vs.enterInsert(host, .block, 1);
    }
};

fn withMotion(cmd: VimCommand, m: Motion) VimCommand {
    var c = cmd;
    c.command = null;
    c.target = .{ .motion = .{ .m = m } };
    return c;
}

fn withLines(cmd: VimCommand) VimCommand {
    var c = cmd;
    c.command = null;
    c.target = .lines;
    return c;
}

fn caseOf(op: Operator) ops.Case {
    return switch (op) {
        .lower => .lower,
        .upper => .upper,
        else => .toggle,
    };
}

/// The end of an inclusive range ending on the character at `p` (a line
/// end includes its line break).
pub fn inclEnd(x: Text, p: u64) u64 {
    if (!x.atEol(p)) return x.after(p);
    const l = x.lineOf(p);
    return x.nextLineStart(l);
}

fn inIndent(x: Text, p: u64) bool {
    return x.firstNonBlank(x.lineOf(p)) >= p;
}

fn onlyWhiteAfter(x: Text, p: u64) bool {
    var q = p;
    while (!x.atEol(q)) : (q = x.after(q)) {
        if (!text_mod.isBlank(x.byte(q))) return false;
    }
    return true;
}

fn popChar(buf: *std.ArrayList(u8)) void {
    while (buf.items.len > 0) {
        const b = buf.pop().?;
        if ((b & 0xC0) != 0x80) break;
    }
}

/// Replaces every character of `[start, end)` (not line breaks) with `ch`.
fn replaceAllChars(host: *Host, start: u64, end: u64, _: bool, ch: u21, gpa: Allocator) !void {
    const x = ops.txt(host);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(ch, &buf);
    var p = start;
    while (p < end) {
        if (x.atEol(p)) {
            try out.append(gpa, x.byte(p));
            p += 1;
            continue;
        }
        try out.appendSlice(gpa, buf[0..n]);
        p = x.after(p);
    }
    try ops.replace(host, start, end, out.items);
}
