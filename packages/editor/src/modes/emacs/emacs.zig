//! Emacs editing as a `ModeHandler` (GNU Emacs manual: "Moving Point",
//! "The Mark and the Region", "Killing and Moving Text", "Incremental
//! Search", "Query Replace", "Numeric Arguments", "Undo").
//!
//! Every cursor has its own point and mark; the mark is active for all of
//! them or none (transient-mark-mode), and an active region is the host
//! selection. Kills go to the kill ring with one piece per cursor and
//! append when the previous command was also a kill. `C-x` chords and
//! `M-x` ask the host for workbench commands (`Host.actions`), named as in
//! `keymap.zon`.
//!
//! As in a keyboard macro, a command that signals an error (`C-f` at the
//! end of the buffer, `C-g`) sets `failed`, and whoever feeds a sequence
//! of keys stops there. Undo follows Emacs: consecutive `C-/` walk back
//! through the history, and after any other command `C-/` first undoes
//! those undos (the history is a list of undo-tree states).

const std = @import("std");
const key_mod = @import("../key.zig");
const mode_mod = @import("../mode.zig");
const text_mod = @import("../vim/text.zig");
const document = @import("../../model/document.zig");
const cs_mod = @import("../../model/edit/change_set.zig");
const sel_mod = @import("../../model/edit/selection.zig");
const smart_edit = @import("../../model/edit/smart_edit.zig");
const undo_mod = @import("../../model/edit/undo.zig");
const find = @import("../../model/search/find.zig");
const zg_regex = @import("zg_regex");
const kill_ring_mod = @import("kill_ring.zig");
const isearch_mod = @import("isearch.zig");
const regexp = @import("regexp.zig");

const Allocator = std.mem.Allocator;
const Key = key_mod.Key;
const Host = mode_mod.Host;
const KeyResult = mode_mod.KeyResult;
const CaretShape = mode_mod.CaretShape;
const ChangeGroup = mode_mod.ChangeGroup;
const Document = document.Document;
const ChangeEvent = document.ChangeEvent;
const ChangeSet = cs_mod.ChangeSet;
const Replace = cs_mod.Replace;
const Range = cs_mod.Range;
const Selection = sel_mod.Selection;
const Text = text_mod.Text;
const NodeId = undo_mod.NodeId;
pub const KillRing = kill_ring_mod.KillRing;
pub const ISearch = isearch_mod.ISearch;

/// The workbench commands `C-x` chords and `M-x` run (E15 ids).
pub const commands = struct {
    pub const save = "file.save";
    pub const find_file = "file.open";
    pub const switch_buffer = "quickOpen.editors";
    pub const kill_buffer = "workbench.closeEditor";
    pub const execute_command = "workbench.showCommands";
    pub const split_right = "workbench.splitEditor";
};

/// The previous command, for kill appending, yank-pop, undo chains,
/// goal columns and mark toggling.
const Cmd = enum { other, kill, yank, undo, set_mark, line_move, self_insert };

/// A prefix argument (`C-u`, `C-u 3`, `M-5`, `M--`).
pub const Arg = struct {
    /// `C-u` without digits: (4), (16)...
    raw_list: bool = false,
    minus: bool = false,
    digits: ?i64 = null,
    list: i64 = 4,

    /// `prefix-numeric-value`.
    pub fn value(a: Arg) i64 {
        if (a.digits) |d| return if (a.minus) -d else d;
        if (a.minus) return -1;
        return a.list;
    }
};

const Cursor = struct {
    point: u64,
    mark: ?u64 = null,
    /// Column C-n and C-p keep.
    goal: ?u32 = null,
    /// The text the last yank inserted (for M-y).
    yank: ?Range = null,
};

const Minibuffer = struct {
    const Kind = enum { query_from, query_to };
    kind: Kind,
    regex: bool,
    text: std.ArrayList(u8) = .empty,
};

/// A query replace stepping through matches.
const Query = struct {
    session: *find.FindSession,
    template: []u8,
    from: []u8,
    regex: bool,
    current: ?Range = null,
    end: u64,
    replaced: u64 = 0,
};

const max_amalgamate = 20;

pub const EmacsState = struct {
    gpa: Allocator,
    kill_ring: KillRing,
    cursors: std.ArrayList(Cursor) = .empty,
    mark_active: bool = false,
    /// Older marks of the primary cursor (`C-u C-SPC`).
    mark_ring: std.ArrayList(u64) = .empty,
    last: Cmd = .other,
    this: Cmd = .other,
    /// A prefix argument being typed, and the one the next command gets.
    building: ?Arg = null,
    arg: ?Arg = null,
    /// `C-x` or `ESC` typed.
    prefix: enum { none, ctrl_x, meta } = .none,
    isearch: ?ISearch = null,
    last_search: std.ArrayList(u8) = .empty,
    last_search_regex: bool = false,
    minibuffer: ?Minibuffer = null,
    query: ?Query = null,
    last_query_from: std.ArrayList(u8) = .empty,
    last_query_to: std.ArrayList(u8) = .empty,
    /// Set when the last key's command signalled an error or quit; a
    /// keyboard macro (or a test script) stops there.
    failed: bool = false,
    group: ChangeGroup,
    inserts: u8 = 0,
    /// Undo-tree states in the order Emacs's undo list visits them.
    history: std.ArrayList(NodeId) = .empty,
    undo_ptr: usize = 0,
    redo_stack: std.ArrayList(NodeId) = .empty,
    doc: ?*Document = null,
    listener: ?document.ListenerId = null,
    synced: std.ArrayList(Selection) = .empty,
    scratch: std.ArrayList(Selection) = .empty,
    /// How points follow text inserted at them.
    point_bias: cs_mod.Bias = .right,
    msg_buf: [256]u8 = undefined,
    msg_len: usize = 0,
    status_buf: [320]u8 = undefined,

    pub fn init(gpa: Allocator) EmacsState {
        return .{ .gpa = gpa, .kill_ring = .init(gpa), .group = .init(gpa) };
    }

    pub fn deinit(es: *EmacsState) void {
        es.detach();
        es.endIsearch();
        es.endQuery();
        if (es.minibuffer) |*m| m.text.deinit(es.gpa);
        es.kill_ring.deinit();
        es.cursors.deinit(es.gpa);
        es.mark_ring.deinit(es.gpa);
        es.last_search.deinit(es.gpa);
        es.last_query_from.deinit(es.gpa);
        es.last_query_to.deinit(es.gpa);
        es.group.deinit();
        es.history.deinit(es.gpa);
        es.redo_stack.deinit(es.gpa);
        es.synced.deinit(es.gpa);
        es.scratch.deinit(es.gpa);
    }

    pub fn handler(es: *EmacsState) mode_mod.ModeHandler {
        return .{ .ctx = es, .handleKeyFn = handleKeyErased, .statusTextFn = statusErased, .caretShapeFn = caretErased };
    }

    fn handleKeyErased(ctx: *anyopaque, k: Key, host: *Host) anyerror!KeyResult {
        const es: *EmacsState = @ptrCast(@alignCast(ctx));
        return es.handleKey(k, host);
    }

    fn statusErased(ctx: *anyopaque) []const u8 {
        const es: *EmacsState = @ptrCast(@alignCast(ctx));
        return es.statusText();
    }

    fn caretErased(ctx: *anyopaque) CaretShape {
        const es: *EmacsState = @ptrCast(@alignCast(ctx));
        return es.caretShape();
    }

    pub fn caretShape(es: *EmacsState) CaretShape {
        return if (es.minibuffer != null or es.isearch != null) .bar else .block;
    }

    /// The echo area: a search or minibuffer prompt, a pending prefix, or
    /// the last message.
    pub fn statusText(es: *EmacsState) []const u8 {
        const b = &es.status_buf;
        if (es.isearch) |*s| return s.prompt(b);
        if (es.minibuffer) |m| {
            const what = if (m.regex) "Query replace regexp" else "Query replace";
            return switch (m.kind) {
                .query_from => if (es.last_query_from.items.len > 0 and m.text.items.len == 0)
                    std.fmt.bufPrint(b, "{s} (default {s} -> {s}): ", .{ what, es.last_query_from.items, es.last_query_to.items }) catch b[0..0]
                else
                    std.fmt.bufPrint(b, "{s}: {s}", .{ what, m.text.items }) catch b[0..0],
                .query_to => std.fmt.bufPrint(b, "{s} {s} with: {s}", .{ what, es.last_query_from.items, m.text.items }) catch b[0..0],
            };
        }
        if (es.query) |q| return std.fmt.bufPrint(b, "Query replacing {s} with {s}: (? for help) ", .{ q.from, es.last_query_to.items }) catch b[0..0];
        if (es.building) |a| {
            if (a.digits) |d| return std.fmt.bufPrint(b, "C-u {s}{d}-", .{ if (a.minus) "-" else "", d }) catch b[0..0];
            if (a.minus) return "C-u -";
            return std.fmt.bufPrint(b, "C-u {d}-", .{a.list}) catch b[0..0];
        }
        switch (es.prefix) {
            .ctrl_x => return "C-x-",
            .meta => return "ESC-",
            .none => {},
        }
        return es.msg_buf[0..es.msg_len];
    }

    fn message(es: *EmacsState, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&es.msg_buf, fmt, args) catch es.msg_buf[0..];
        es.msg_len = s.len;
    }

    /// Shows `msg` and signals an error (the command stops).
    fn fail(es: *EmacsState, comptime fmt: []const u8, args: anytype) error{Signal} {
        es.message(fmt, args);
        return error.Signal;
    }

    // -- the document ----------------------------------------------------------

    fn attach(es: *EmacsState, host: *Host) !void {
        if (es.doc == host.doc) return;
        es.detach();
        es.listener = try host.doc.subscribe(.{ .ctx = es, .onChange = onChange });
        es.doc = host.doc;
        es.cursors.clearRetainingCapacity();
        es.synced.clearRetainingCapacity();
        es.mark_ring.clearRetainingCapacity();
        es.history.clearRetainingCapacity();
        es.redo_stack.clearRetainingCapacity();
        try es.history.append(es.gpa, host.undo.current);
        es.mark_active = false;
    }

    /// Stops following the document.
    pub fn detach(es: *EmacsState) void {
        if (es.doc) |d| if (es.listener) |l| d.unsubscribe(l);
        es.doc = null;
        es.listener = null;
        es.group.cancel();
    }

    fn onChange(ctx: *anyopaque, ev: *const ChangeEvent) void {
        const es: *EmacsState = @ptrCast(@alignCast(ctx));
        const l = es.group.listener();
        l.onChange(l.ctx, ev);
        for (es.cursors.items) |*c| {
            c.point = ev.changes.mapPos(c.point, es.point_bias);
            if (c.mark) |m| c.mark = ev.changes.mapPos(m, .left);
        }
        for (es.mark_ring.items) |*m| m.* = ev.changes.mapPos(m.*, .left);
    }

    /// Takes the host's selections when something else changed them.
    fn syncIn(es: *EmacsState, host: *Host) !void {
        const sels = host.sels.slice();
        if (es.cursors.items.len > 0 and sel_mod.eql(sels, es.synced.items)) return;
        es.cursors.clearRetainingCapacity();
        var any_region = false;
        for (sels) |s| {
            if (!s.isCaret()) any_region = true;
            try es.cursors.append(es.gpa, .{ .point = s.head, .mark = if (s.isCaret()) null else s.anchor });
        }
        // A region made elsewhere (mouse, shift-select) is the active region.
        es.mark_active = any_region;
        if (host.undo.current != es.history.items[es.history.items.len - 1]) try es.history.append(es.gpa, host.undo.current);
    }

    fn syncOut(es: *EmacsState, host: *Host) !void {
        es.dedupe();
        es.scratch.clearRetainingCapacity();
        const len = host.doc.len();
        for (es.cursors.items) |*c| {
            c.point = @min(c.point, len);
            if (c.mark) |m| c.mark = @min(m, len);
            if (es.isearch) |*s| {
                if (s.match) |m| {
                    const other = if (s.backward) m.end else m.start;
                    try es.scratch.append(es.gpa, .{ .anchor = other, .head = c.point });
                    continue;
                }
            }
            if (es.mark_active and c.mark != null) {
                try es.scratch.append(es.gpa, .{ .anchor = c.mark.?, .head = c.point });
            } else try es.scratch.append(es.gpa, .caret(c.point));
        }
        try host.sels.set(es.scratch.items, 0);
        es.synced.clearRetainingCapacity();
        try es.synced.appendSlice(es.gpa, host.sels.slice());
    }

    fn dedupe(es: *EmacsState) void {
        const items = es.cursors.items;
        if (items.len <= 1) return;
        std.sort.pdq(Cursor, items, {}, struct {
            fn lt(_: void, a: Cursor, b: Cursor) bool {
                return a.point < b.point;
            }
        }.lt);
        var n: usize = 1;
        for (items[1..]) |c| {
            if (c.point == items[n - 1].point) continue;
            items[n] = c;
            n += 1;
        }
        es.cursors.shrinkRetainingCapacity(n);
    }

    fn txt(host: *Host) Text {
        return Text.init(&host.doc.tree);
    }

    fn apply(es: *EmacsState, host: *Host, edits: []const Replace) !void {
        var cs = try ChangeSet.fromEdits(es.gpa, host.doc.len(), edits);
        defer cs.deinit();
        if (cs.isIdentity()) return;
        try host.doc.applyChangeSet(&cs, host.edit.origin);
    }

    // -- keys ----------------------------------------------------------------------

    pub fn handleKey(es: *EmacsState, k: Key, host: *Host) !KeyResult {
        try es.attach(host);
        try es.syncIn(host);
        es.failed = false;
        const result = es.dispatch(k, host) catch |e| switch (e) {
            error.Signal => blk: {
                es.failed = true;
                es.this = .other;
                break :blk KeyResult.consumed;
            },
            else => return e,
        };
        try es.syncOut(host);
        return result;
    }

    fn dispatch(es: *EmacsState, k_in: Key, host: *Host) !KeyResult {
        var k = k_in;
        if (es.isearch != null) {
            if (try es.isearchKey(k, host)) return .consumed;
            // Another command ends the search and then runs.
        }
        if (es.minibuffer != null) return es.minibufferKey(k, host);
        if (es.query != null) return es.queryKey(k, host);
        if (es.prefix == .meta) {
            es.prefix = .none;
            if (k.alt) return .consumed;
            k.alt = true;
        }
        if (try es.argKey(k)) return .consumed;
        if (es.prefix == .ctrl_x) {
            es.prefix = .none;
            return es.runCommand(k, host, true);
        }
        if (k.is(.esc) and !k.alt) {
            es.prefix = .meta;
            return .consumed;
        }
        return es.runCommand(k, host, false);
    }

    /// `C-u`, digits after it, `M-<digit>`, `M--`: builds the argument.
    fn argKey(es: *EmacsState, k: Key) !bool {
        if (k.isCtrl('u') and es.prefix == .none) {
            if (es.building) |*a| {
                if (a.digits == null and !a.minus) a.list *= 4 else {
                    // C-u after digits ends the argument (Emacs).
                    es.arg = a.*;
                    es.building = null;
                }
            } else es.building = .{ .raw_list = true };
            return true;
        }
        const plain_digit = k.text() != null and k.code >= '0' and k.code <= '9';
        const meta_digit = (k.alt or k.ctrl) and k.code >= '0' and k.code <= '9';
        const minus = (k.text() == '-' and es.building != null) or ((k.alt or k.ctrl) and k.code == '-');
        if (es.prefix != .none) return false;
        if ((plain_digit and es.building != null) or meta_digit) {
            var a = es.building orelse Arg{};
            a.raw_list = false;
            a.digits = (a.digits orelse 0) * 10 + @as(i64, k.code - '0');
            es.building = a;
            return true;
        }
        if (minus) {
            var a = es.building orelse Arg{};
            if (a.digits != null) return false;
            a.raw_list = false;
            a.minus = true;
            es.building = a;
            return true;
        }
        return false;
    }

    /// Runs the command bound to `k` (after `C-x` when `cx`).
    fn runCommand(es: *EmacsState, k: Key, host: *Host, cx: bool) !KeyResult {
        const arg = es.building orelse es.arg;
        es.building = null;
        es.arg = null;
        es.this = .other;
        es.msg_len = 0;
        const result = es.command(k, host, cx, arg) catch |e| {
            es.closeGroup(host) catch {};
            es.last = .other;
            return e;
        };
        try es.closeGroup(host);
        es.last = es.this;
        return result;
    }

    fn command(es: *EmacsState, k: Key, host: *Host, cx: bool, arg: ?Arg) !KeyResult {
        const n: i64 = if (arg) |a| a.value() else 1;
        if (cx) return es.ctrlXCommand(k, host, n);
        if (k.text()) |cp| {
            try es.selfInsert(host, cp, n);
            return .consumed;
        }
        if (k.ctrl and k.alt) {
            switch (k.code) {
                's' => try es.startIsearch(host, false, true),
                'r' => try es.startIsearch(host, true, true),
                '%' => try es.startQuery(host, true),
                '_' => try es.undoRedo(host),
                else => return .passthrough,
            }
            return .consumed;
        }
        if (k.ctrl) {
            switch (k.code) {
                'f' => try es.moveChars(host, n),
                'b' => try es.moveChars(host, -n),
                'n' => try es.moveLines(host, n),
                'p' => try es.moveLines(host, -n),
                'a' => es.lineEdge(host, n, false),
                'e' => es.lineEdge(host, n, true),
                'v' => try es.moveLines(host, @as(i64, host.move.page_rows -| 2) * n),
                'd' => try es.deleteChars(host, n, arg != null),
                'k' => try es.killLine(host, arg),
                'w' => try es.killRegion(host),
                'y' => try es.yank(host, arg),
                '/', '_' => try es.undo(host),
                '?' => try es.undoRedo(host),
                't' => try es.transposeChars(host, n),
                'o' => try es.openLine(host, n),
                ' ', '@' => try es.setMark(host, arg),
                'g' => {
                    es.mark_active = false;
                    return es.fail("Quit", .{});
                },
                's' => try es.startIsearch(host, false, arg != null),
                'r' => try es.startIsearch(host, true, arg != null),
                'x' => es.prefix = .ctrl_x,
                'j', 'm' => try es.newline(host, n),
                'i' => try es.selfInsert(host, '\t', n),
                else => return .passthrough,
            }
            return .consumed;
        }
        if (k.alt) {
            switch (k.code) {
                'f' => es.moveWords(host, n),
                'b' => es.moveWords(host, -n),
                '<' => try es.bufferEdge(host, false, arg),
                '>' => try es.bufferEdge(host, true, arg),
                'v' => try es.moveLines(host, -@as(i64, host.move.page_rows -| 2) * n),
                'd' => try es.killWords(host, n),
                @intFromEnum(key_mod.Special.backspace) => try es.killWords(host, -n),
                'w' => try es.copyRegion(host),
                'y' => try es.yankPop(host, n),
                't' => try es.transposeWords(host, n),
                '%' => try es.startQuery(host, false),
                'x' => try es.action(host, .{ .command = commands.execute_command }),
                else => return .passthrough,
            }
            return .consumed;
        }
        if (k.code >= 0x11_0000) {
            const s: key_mod.Special = @enumFromInt(k.code);
            switch (s) {
                .enter => try es.newline(host, n),
                .tab => try es.selfInsert(host, '\t', n),
                .backspace => try es.deleteBackward(host, n),
                .delete => try es.deleteForward(host, n),
                .left => try es.moveChars(host, -n),
                .right => try es.moveChars(host, n),
                .up => try es.moveLines(host, -n),
                .down => try es.moveLines(host, n),
                .home => es.lineEdge(host, 1, false),
                .end => es.lineEdge(host, 1, true),
                .page_down => try es.moveLines(host, @as(i64, host.move.page_rows -| 2)),
                .page_up => try es.moveLines(host, -@as(i64, host.move.page_rows -| 2)),
                else => return .passthrough,
            }
            return .consumed;
        }
        return .passthrough;
    }

    fn ctrlXCommand(es: *EmacsState, k: Key, host: *Host, n: i64) !KeyResult {
        _ = n;
        if (k.ctrl and !k.alt) switch (k.code) {
            's' => return es.actionResult(host, .{ .command = commands.save }),
            'f' => return es.actionResult(host, .{ .command = commands.find_file }),
            'x' => {
                try es.exchangePointAndMark(host);
                return .consumed;
            },
            'g' => return es.fail("Quit", .{}),
            else => {},
        };
        if (k.text()) |c| switch (c) {
            'u' => {
                try es.undo(host);
                return .consumed;
            },
            'h' => {
                try es.markWholeBuffer(host);
                return .consumed;
            },
            'b' => return es.actionResult(host, .{ .command = commands.switch_buffer }),
            'k' => return es.actionResult(host, .{ .command = commands.kill_buffer }),
            '3' => return es.actionResult(host, .{ .command = commands.split_right }),
            else => {},
        };
        return es.fail("C-x {f} is undefined", .{fmtKey(k)});
    }

    fn actionResult(es: *EmacsState, host: *Host, a: mode_mod.Action) !KeyResult {
        try es.action(host, a);
        return .consumed;
    }

    fn action(es: *EmacsState, host: *Host, a: mode_mod.Action) !void {
        const acts = host.actions orelse return es.fail("{s} is not available here", .{a.command});
        acts.runFn(acts.ctx, a) catch |e| return es.fail("{s}: {t}", .{ a.command, e });
    }

    // -- undo groups -------------------------------------------------------------

    fn openGroup(es: *EmacsState, host: *Host) !void {
        if (es.group.active) return;
        es.scratch.clearRetainingCapacity();
        for (es.cursors.items) |c| try es.scratch.append(es.gpa, .caret(c.point));
        try es.group.begin(es.scratch.items);
        _ = host;
    }

    /// Records the open group as one undo step (and a history entry).
    /// Self-inserts join the step before while they amalgamate.
    fn closeGroup(es: *EmacsState, host: *Host) !void {
        if (es.this != .self_insert) es.inserts = 0;
        if (!es.group.active) return;
        es.scratch.clearRetainingCapacity();
        for (es.cursors.items) |c| try es.scratch.append(es.gpa, .caret(c.point));
        const before = host.undo.current;
        const join = es.this == .self_insert and es.inserts > 1;
        if (es.this == .self_insert and !join) host.undo.breakGroup();
        try es.group.commit(host.undo, es.scratch.items, .{ .label = "Emacs", .origin = host.edit.origin, .timestamp = host.now(), .coalesce_key = if (es.this == .self_insert) .amalgamate else null });
        if (host.undo.current != before) {
            try es.history.append(es.gpa, host.undo.current);
            es.redo_stack.clearRetainingCapacity();
        }
    }

    /// A buffer change: one undo step for the command, and the mark goes
    /// inactive (Emacs's `deactivate-mark`).
    fn beginEdit(es: *EmacsState, host: *Host) !void {
        try es.openGroup(host);
        es.mark_active = false;
    }

    // -- motion ----------------------------------------------------------------------

    fn nextPos(x: Text, p: u64) ?u64 {
        if (p >= x.len) return null;
        if (x.byte(p) == '\r' and p + 1 < x.len and x.byte(p + 1) == '\n') return p + 2;
        if (x.byte(p) == '\n' or x.byte(p) == '\r') return p + 1;
        return x.after(p);
    }

    fn prevPos(x: Text, p: u64) ?u64 {
        if (p == 0) return null;
        if (x.byte(p - 1) == '\n') return if (p >= 2 and x.byte(p - 2) == '\r') p - 2 else p - 1;
        const ls = x.lineStart(x.lineOf(p));
        if (p == ls) return p - 1;
        return x.before(p);
    }

    fn moveChars(es: *EmacsState, host: *Host, n: i64) !void {
        const x = txt(host);
        var hit = false;
        for (es.cursors.items) |*c| {
            var i: i64 = 0;
            while (i < @abs(n)) : (i += 1) {
                const q = if (n > 0) nextPos(x, c.point) else prevPos(x, c.point);
                c.point = q orelse {
                    hit = true;
                    break;
                };
            }
        }
        if (hit) return es.fail("{s} of buffer", .{if (n > 0) "End" else "Beginning"});
    }

    fn isWord(cp: u21) bool {
        if (cp < 0x80) return std.ascii.isAlphanumeric(@intCast(cp));
        return switch (cp) {
            0xA0, 0x2000...0x206F, 0x3000...0x303F, 0xFF00...0xFF0F => false,
            else => true,
        };
    }

    fn cpAt(x: Text, p: u64) u21 {
        if (p >= x.len) return 0;
        const b = x.byte(p);
        if (b == '\n' or b == '\r') return '\n';
        return x.cp(p);
    }

    fn cpBefore(x: Text, p: u64) u21 {
        const q = prevPos(x, p) orelse return 0;
        return cpAt(x, q);
    }

    /// Emacs `forward-word`: past non-word characters, then past a word.
    fn forwardWord(x: Text, p_in: u64) u64 {
        var p = p_in;
        while (p < x.len and !isWord(cpAt(x, p))) p = nextPos(x, p).?;
        while (p < x.len and isWord(cpAt(x, p))) p = nextPos(x, p).?;
        return p;
    }

    fn backwardWord(x: Text, p_in: u64) u64 {
        var p = p_in;
        while (p > 0 and !isWord(cpBefore(x, p))) p = prevPos(x, p).?;
        while (p > 0 and isWord(cpBefore(x, p))) p = prevPos(x, p).?;
        return p;
    }

    fn wordsFrom(x: Text, p: u64, n: i64) u64 {
        var q = p;
        var i: i64 = 0;
        while (i < @abs(n)) : (i += 1) q = if (n > 0) forwardWord(x, q) else backwardWord(x, q);
        return q;
    }

    fn moveWords(es: *EmacsState, host: *Host, n: i64) void {
        const x = txt(host);
        for (es.cursors.items) |*c| c.point = wordsFrom(x, c.point, n);
    }

    /// `C-a`/`C-e` with an argument: the start or end of the line `n - 1`
    /// lines down.
    fn lineEdge(es: *EmacsState, host: *Host, n: i64, end: bool) void {
        const x = txt(host);
        for (es.cursors.items) |*c| {
            const l = shiftLine(x, x.lineOf(c.point), n - 1);
            c.point = if (end) x.lineEnd(l) else x.lineStart(l);
        }
    }

    fn shiftLine(x: Text, l: u64, d: i64) u64 {
        const last: i64 = @intCast(x.lineCount() - 1);
        return @intCast(std.math.clamp(@as(i64, @intCast(l)) + d, 0, last));
    }

    fn moveLines(es: *EmacsState, host: *Host, n: i64) !void {
        const x = txt(host);
        var hit = false;
        for (es.cursors.items) |*c| {
            const l = x.lineOf(c.point);
            const goal = if (es.last == .line_move and c.goal != null) c.goal.? else x.column(c.point);
            c.goal = goal;
            const target: i64 = @as(i64, @intCast(l)) + n;
            const last: i64 = @intCast(x.lineCount() - 1);
            if (target < 0 or target > last) {
                hit = true;
                c.point = if (target < 0) 0 else x.len;
                continue;
            }
            c.point = x.atColumn(@intCast(target), goal, true);
        }
        es.this = .line_move;
        if (hit) return es.fail("{s} of buffer", .{if (n > 0) "End" else "Beginning"});
    }

    fn bufferEdge(es: *EmacsState, host: *Host, end: bool, arg: ?Arg) !void {
        const x = txt(host);
        if (!es.mark_active and arg == null) try es.pushMark(host, false);
        for (es.cursors.items) |*c| c.point = if (end) x.len else 0;
    }

    // -- the mark ------------------------------------------------------------------

    /// Emacs `push-mark` at each point; `activate` makes the region active.
    fn pushMark(es: *EmacsState, host: *Host, activate: bool) !void {
        _ = host;
        if (es.cursors.items.len > 0) {
            if (es.cursors.items[0].mark) |m| {
                try es.mark_ring.insert(es.gpa, 0, m);
                if (es.mark_ring.items.len > 16) _ = es.mark_ring.pop();
            }
        }
        for (es.cursors.items) |*c| c.mark = c.point;
        if (activate) es.mark_active = true;
        es.message("Mark set", .{});
    }

    fn setMark(es: *EmacsState, host: *Host, arg: ?Arg) !void {
        if (arg != null) {
            // C-u C-SPC: back to the mark, and the mark ring turns.
            const c0 = &es.cursors.items[0];
            const m = c0.mark orelse return es.fail("No mark set in this buffer", .{});
            if (c0.point == m) es.message("Mark popped", .{});
            c0.point = m;
            if (es.mark_ring.items.len > 0) {
                try es.mark_ring.append(es.gpa, m);
                c0.mark = es.mark_ring.orderedRemove(0);
            }
            es.mark_active = false;
            return;
        }
        if (es.last == .set_mark) {
            if (es.mark_active) {
                es.mark_active = false;
                es.message("Mark deactivated", .{});
            } else {
                es.mark_active = true;
                es.message("Mark activated", .{});
            }
        } else try es.pushMark(host, true);
        es.this = .set_mark;
    }

    fn exchangePointAndMark(es: *EmacsState, host: *Host) !void {
        _ = host;
        for (es.cursors.items) |*c| {
            const m = c.mark orelse return es.fail("No mark set in this buffer", .{});
            c.mark = c.point;
            c.point = m;
        }
        es.mark_active = true;
    }

    fn markWholeBuffer(es: *EmacsState, host: *Host) !void {
        const x = txt(host);
        es.cursors.shrinkRetainingCapacity(1);
        es.cursors.items[0].point = x.len;
        try es.pushMark(host, true);
        es.cursors.items[0].point = 0;
        es.message("Mark set", .{});
    }

    /// Each cursor's region, or an error when a mark is missing.
    fn regionOf(es: *EmacsState, c: Cursor) !Range {
        const m = c.mark orelse return es.fail("The mark is not set now, so there is no region", .{});
        return .{ .start = @min(m, c.point), .end = @max(m, c.point) };
    }

    // -- inserting ------------------------------------------------------------------

    fn selfInsert(es: *EmacsState, host: *Host, cp: u21, n: i64) !void {
        if (n < 0) return es.fail("Negative repetition argument {d}", .{n});
        if (n == 0) return;
        if (es.last != .self_insert or es.inserts >= max_amalgamate) es.inserts = 0;
        try es.beginEdit(host);
        try es.syncCarets(host);
        var i: i64 = 0;
        while (i < n) : (i += 1) _ = try smart_edit.typeChar(host.doc, host.sels, cp, host.edit);
        es.takeCarets(host);
        es.inserts += 1;
        es.this = .self_insert;
    }

    /// Puts the host selections on the points (for smart typing).
    fn syncCarets(es: *EmacsState, host: *Host) !void {
        es.scratch.clearRetainingCapacity();
        for (es.cursors.items) |c| try es.scratch.append(es.gpa, .caret(c.point));
        try host.sels.set(es.scratch.items, 0);
    }

    /// Takes the points back from the host selections.
    fn takeCarets(es: *EmacsState, host: *Host) void {
        const sels = host.sels.slice();
        if (sels.len == es.cursors.items.len) {
            for (es.cursors.items, sels) |*c, s| c.point = s.head;
        }
    }

    fn newline(es: *EmacsState, host: *Host, n: i64) !void {
        if (n <= 0) return;
        try es.beginEdit(host);
        try es.syncCarets(host);
        var i: i64 = 0;
        while (i < n) : (i += 1) _ = try smart_edit.newline(host.doc, host.sels, host.edit);
        es.takeCarets(host);
    }

    fn openLine(es: *EmacsState, host: *Host, n: i64) !void {
        if (n <= 0) return;
        try es.beginEdit(host);
        const nl = try es.gpa.alloc(u8, @intCast(n));
        defer es.gpa.free(nl);
        @memset(nl, '\n');
        var edits: std.ArrayList(Replace) = .empty;
        defer edits.deinit(es.gpa);
        es.dedupe();
        for (es.cursors.items) |c| try edits.append(es.gpa, .{ .range = .{ .start = c.point, .end = c.point }, .text = nl });
        es.point_bias = .left;
        defer es.point_bias = .right;
        try es.apply(host, edits.items);
    }

    // -- deleting and killing ------------------------------------------------------

    /// Deletes (or kills) one range per cursor, in one change.
    fn removeRanges(es: *EmacsState, host: *Host, ranges: []const Range, kill: ?kill_ring_mod.Append) !void {
        try es.beginEdit(host);
        if (kill) |dir| {
            var pieces: std.ArrayList([]const u8) = .empty;
            defer pieces.deinit(es.gpa);
            var owned: std.ArrayList([]u8) = .empty;
            defer {
                for (owned.items) |p| es.gpa.free(p);
                owned.deinit(es.gpa);
            }
            for (ranges) |r| {
                const t = try host.doc.tree.copyRange(es.gpa, r);
                try owned.append(es.gpa, t);
                try pieces.append(es.gpa, t);
            }
            const append: kill_ring_mod.Append = if (es.last == .kill) dir else .no;
            try es.kill_ring.killPieces(pieces.items, append);
            es.this = .kill;
        }
        var edits: std.ArrayList(Replace) = .empty;
        defer edits.deinit(es.gpa);
        var prev_end: u64 = 0;
        for (ranges) |r| {
            const s = @max(r.start, prev_end);
            if (r.end <= s) continue;
            try edits.append(es.gpa, .{ .range = .{ .start = s, .end = r.end }, .text = "" });
            prev_end = r.end;
        }
        try es.apply(host, edits.items);
    }

    fn sortedRanges(es: *EmacsState, list: *std.ArrayList(Range)) void {
        _ = es;
        std.sort.pdq(Range, list.items, {}, struct {
            fn lt(_: void, a: Range, b: Range) bool {
                return a.start < b.start;
            }
        }.lt);
    }

    fn deleteChars(es: *EmacsState, host: *Host, n: i64, kill: bool) !void {
        const x = txt(host);
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(es.gpa);
        es.dedupe();
        var hit = false;
        for (es.cursors.items) |c| {
            var q = c.point;
            var i: i64 = 0;
            while (i < @abs(n)) : (i += 1) {
                q = (if (n > 0) nextPos(x, q) else prevPos(x, q)) orelse {
                    hit = true;
                    break;
                };
            }
            if (hit) break;
            try ranges.append(es.gpa, .{ .start = @min(q, c.point), .end = @max(q, c.point) });
        }
        if (hit) return es.fail("{s} of buffer", .{if (n > 0) "End" else "Beginning"});
        try es.removeRanges(host, ranges.items, if (kill) (if (n > 0) .after else .before) else null);
    }

    /// DEL: the active region, else characters before point.
    fn deleteBackward(es: *EmacsState, host: *Host, n: i64) !void {
        if (try es.deleteActiveRegion(host)) return;
        return es.deleteChars(host, -n, false);
    }

    fn deleteForward(es: *EmacsState, host: *Host, n: i64) !void {
        if (try es.deleteActiveRegion(host)) return;
        return es.deleteChars(host, n, false);
    }

    fn deleteActiveRegion(es: *EmacsState, host: *Host) !bool {
        if (!es.mark_active) return false;
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(es.gpa);
        for (es.cursors.items) |c| {
            const r = try es.regionOf(c);
            if (r.start != r.end) try ranges.append(es.gpa, r);
        }
        if (ranges.items.len == 0) return false;
        es.sortedRanges(&ranges);
        try es.removeRanges(host, ranges.items, null);
        return true;
    }

    fn killLine(es: *EmacsState, host: *Host, arg: ?Arg) !void {
        const x = txt(host);
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(es.gpa);
        es.dedupe();
        var backward = false;
        for (es.cursors.items) |c| {
            const p = c.point;
            const l = x.lineOf(p);
            var to: u64 = undefined;
            if (arg) |a| {
                const n = a.value();
                if (n > 0) {
                    const tl = @as(i64, @intCast(l)) + n;
                    to = if (tl >= @as(i64, @intCast(x.lineCount()))) x.len else x.lineStart(@intCast(tl));
                } else {
                    backward = true;
                    to = x.lineStart(shiftLine(x, l, n));
                }
            } else {
                if (p >= x.len) return es.fail("End of buffer", .{});
                const eol = x.lineEnd(l);
                var blank = true;
                var q = p;
                while (q < eol) : (q += 1) {
                    if (!std.ascii.isWhitespace(x.byte(q))) blank = false;
                }
                to = if (blank) x.nextLineStart(l) else eol;
            }
            try ranges.append(es.gpa, .{ .start = @min(p, to), .end = @max(p, to) });
        }
        try es.removeRanges(host, ranges.items, if (backward) .before else .after);
    }

    fn killWords(es: *EmacsState, host: *Host, n: i64) !void {
        const x = txt(host);
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(es.gpa);
        es.dedupe();
        for (es.cursors.items) |c| {
            const q = wordsFrom(x, c.point, n);
            try ranges.append(es.gpa, .{ .start = @min(q, c.point), .end = @max(q, c.point) });
        }
        try es.removeRanges(host, ranges.items, if (n > 0) .after else .before);
    }

    fn killRegion(es: *EmacsState, host: *Host) !void {
        var ranges: std.ArrayList(Range) = .empty;
        defer ranges.deinit(es.gpa);
        var backward = false;
        for (es.cursors.items) |c| {
            const r = try es.regionOf(c);
            if (c.point < c.mark.?) backward = true;
            try ranges.append(es.gpa, r);
        }
        es.sortedRanges(&ranges);
        try es.removeRanges(host, ranges.items, if (backward) .before else .after);
        es.this = .kill;
    }

    fn copyRegion(es: *EmacsState, host: *Host) !void {
        var pieces: std.ArrayList([]const u8) = .empty;
        defer pieces.deinit(es.gpa);
        var owned: std.ArrayList([]u8) = .empty;
        defer {
            for (owned.items) |p| es.gpa.free(p);
            owned.deinit(es.gpa);
        }
        var backward = false;
        for (es.cursors.items) |c| {
            const r = try es.regionOf(c);
            if (c.point < c.mark.?) backward = true;
            const t = try host.doc.tree.copyRange(es.gpa, r);
            try owned.append(es.gpa, t);
            try pieces.append(es.gpa, t);
        }
        const append: kill_ring_mod.Append = if (es.last == .kill) (if (backward) .before else .after) else .no;
        try es.kill_ring.killPieces(pieces.items, append);
        es.mark_active = false;
    }

    // -- yanking -------------------------------------------------------------------

    fn yank(es: *EmacsState, host: *Host, arg: ?Arg) !void {
        const n: i64 = if (arg) |a| (if (a.raw_list) 0 else if (a.minus and a.digits == null) -2 else a.value() - 1) else 0;
        const entry = try es.kill_ring.current(n) orelse return es.fail("Kill ring is empty", .{});
        try es.pushMark(host, false);
        es.msg_len = 0;
        try es.insertEntry(host, entry, null);
        if (arg != null and arg.?.raw_list) {
            for (es.cursors.items) |*c| {
                const m = c.mark.?;
                c.mark = c.point;
                c.point = m;
            }
        }
        es.this = .yank;
    }

    /// Inserts the entry at every point (one piece each when the counts
    /// match), or in place of each cursor's last yank (`replace`).
    fn insertEntry(es: *EmacsState, host: *Host, entry: *const kill_ring_mod.Entry, replace: ?void) !void {
        try es.beginEdit(host);
        es.dedupe();
        var edits: std.ArrayList(Replace) = .empty;
        defer edits.deinit(es.gpa);
        const per = entry.pieces.len == es.cursors.items.len and es.cursors.items.len > 1;
        for (es.cursors.items, 0..) |c, i| {
            const r: Range = if (replace != null) c.yank.? else .{ .start = c.point, .end = c.point };
            try edits.append(es.gpa, .{ .range = r, .text = if (per) entry.pieces[i] else entry.joined });
        }
        std.sort.pdq(Replace, edits.items, {}, struct {
            fn lt(_: void, a: Replace, b: Replace) bool {
                return a.range.start < b.range.start;
            }
        }.lt);
        var cs = try ChangeSet.fromEdits(es.gpa, host.doc.len(), edits.items);
        defer cs.deinit();
        // The new positions of each insertion, for M-y and point.
        const starts = try es.gpa.alloc(u64, edits.items.len);
        defer es.gpa.free(starts);
        for (edits.items, 0..) |e, i| starts[i] = cs.mapPos(e.range.start, .left);
        try host.doc.applyChangeSet(&cs, host.edit.origin);
        for (es.cursors.items, 0..) |*c, i| {
            const s = starts[i];
            const len = edits.items[i].text.len;
            c.mark = s;
            c.point = s + len;
            c.yank = .{ .start = s, .end = s + len };
        }
        es.mark_active = false;
    }

    fn yankPop(es: *EmacsState, host: *Host, n: i64) !void {
        if (es.last != .yank) return es.fail("Previous command was not a yank", .{});
        for (es.cursors.items) |c| if (c.yank == null) return es.fail("Previous command was not a yank", .{});
        const before_point = es.cursors.items[0].point < es.cursors.items[0].mark.?;
        const entry = (try es.kill_ring.current(n)) orelse return es.fail("Kill ring is empty", .{});
        try es.insertEntry(host, entry, {});
        if (before_point) for (es.cursors.items) |*c| {
            const m = c.mark.?;
            c.mark = c.point;
            c.point = m;
        };
        es.this = .yank;
    }

    // -- transposing ----------------------------------------------------------------

    fn transposeChars(es: *EmacsState, host: *Host, n: i64) !void {
        var x = txt(host);
        es.dedupe();
        try es.beginEdit(host);
        for (es.cursors.items) |*c| {
            var p = c.point;
            // At the end of a line, the two characters before point.
            if (n == 1 and (p >= x.len or cpAt(x, p) == '\n')) p = prevPos(x, p) orelse return es.fail("Beginning of buffer", .{});
            var i: i64 = 0;
            while (i < @abs(n)) : (i += 1) {
                x = txt(host);
                const a = prevPos(x, p) orelse return es.fail("Beginning of buffer", .{});
                const b = nextPos(x, p) orelse return es.fail("End of buffer", .{});
                const left = try host.doc.tree.copyRange(es.gpa, .{ .start = a, .end = p });
                defer es.gpa.free(left);
                const right = try host.doc.tree.copyRange(es.gpa, .{ .start = p, .end = b });
                defer es.gpa.free(right);
                const swapped = try std.mem.concat(es.gpa, u8, &.{ right, left });
                defer es.gpa.free(swapped);
                try es.apply(host, &.{.{ .range = .{ .start = a, .end = b }, .text = swapped }});
                p = if (n > 0) b else a + right.len;
                if (n < 0) p = a;
            }
            c.point = p;
        }
    }

    fn transposeWords(es: *EmacsState, host: *Host, n: i64) !void {
        es.dedupe();
        try es.beginEdit(host);
        for (es.cursors.items) |*c| {
            var i: i64 = 0;
            while (i < @max(n, 1)) : (i += 1) {
                const x = txt(host);
                const a = backwardWord(x, c.point);
                const b = forwardWord(x, a);
                const d_end = forwardWord(x, b);
                const d = backwardWord(x, d_end);
                if (d < b or d_end == b) return es.fail("Don't have two things to transpose", .{});
                const w1 = try host.doc.tree.copyRange(es.gpa, .{ .start = a, .end = b });
                defer es.gpa.free(w1);
                const mid = try host.doc.tree.copyRange(es.gpa, .{ .start = b, .end = d });
                defer es.gpa.free(mid);
                const w2 = try host.doc.tree.copyRange(es.gpa, .{ .start = d, .end = d_end });
                defer es.gpa.free(w2);
                const t = try std.mem.concat(es.gpa, u8, &.{ w2, mid, w1 });
                defer es.gpa.free(t);
                try es.apply(host, &.{.{ .range = .{ .start = a, .end = d_end }, .text = t }});
                c.point = d_end;
            }
        }
    }

    // -- undo -------------------------------------------------------------------------

    fn travel(es: *EmacsState, host: *Host, target: NodeId) !void {
        const steps = try host.undo.travel(target);
        var sels: ?[]const Selection = null;
        for (steps) |st| {
            try host.doc.applyChangeSet(st.changes, .undo);
            sels = st.selections;
        }
        if (sels) |s| if (s.len > 0) {
            es.cursors.clearRetainingCapacity();
            for (s) |sel| try es.cursors.append(es.gpa, .{ .point = @min(sel.head, host.doc.len()) });
        };
        try es.history.append(es.gpa, target);
    }

    fn undo(es: *EmacsState, host: *Host) !void {
        try es.closeGroup(host);
        if (es.last != .undo) es.undo_ptr = es.history.items.len - 1;
        if (es.undo_ptr == 0) return es.fail("No further undo information", .{});
        es.undo_ptr -= 1;
        const from = host.undo.current;
        try es.travel(host, es.history.items[es.undo_ptr]);
        try es.redo_stack.append(es.gpa, from);
        es.mark_active = false;
        es.this = .undo;
        es.message("Undo", .{});
    }

    /// `C-?`: undoes the last undo.
    fn undoRedo(es: *EmacsState, host: *Host) !void {
        try es.closeGroup(host);
        const target = es.redo_stack.pop() orelse return es.fail("No undo to undo", .{});
        try es.travel(host, target);
        if (es.last == .undo and es.undo_ptr + 1 < es.history.items.len) es.undo_ptr += 1;
        es.this = .undo;
        es.message("Redo", .{});
    }

    // -- incremental search ---------------------------------------------------------------

    fn startIsearch(es: *EmacsState, host: *Host, backward: bool, regex: bool) !void {
        es.cursors.shrinkRetainingCapacity(1);
        es.isearch = .init(es.gpa, es.cursors.items[0].point, backward, regex);
        _ = host;
    }

    fn endIsearch(es: *EmacsState) void {
        if (es.isearch) |*s| s.deinit();
        es.isearch = null;
    }

    /// A key during a search; false when it ends the search and should
    /// run as a command.
    fn isearchKey(es: *EmacsState, k: Key, host: *Host) !bool {
        const s = &es.isearch.?;
        es.msg_len = 0;
        if (k.text()) |cp| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return true;
            try s.addText(host.doc, buf[0..len]);
            es.isearchMoved();
            return true;
        }
        const repeat_fwd = (k.isCtrl('s') or (k.ctrl and k.alt and k.code == 's'));
        const repeat_back = (k.isCtrl('r') or (k.ctrl and k.alt and k.code == 'r'));
        if (repeat_fwd or repeat_back) {
            if (s.query.items.len == 0) {
                if (es.last_search.items.len == 0) return true;
                try s.setQuery(host.doc, es.last_search.items);
            }
            try s.repeat(host.doc, repeat_back);
            es.isearchMoved();
            return true;
        }
        if (k.is(.backspace)) {
            _ = try s.pop(host.doc);
            es.isearchMoved();
            return true;
        }
        if (k.isCtrl('j')) {
            try s.addText(host.doc, "\n");
            es.isearchMoved();
            return true;
        }
        if (k.isCtrl('y')) {
            const t = try es.kill_ring.yank() orelse return true;
            try s.addText(host.doc, t);
            es.isearchMoved();
            return true;
        }
        if (k.isCtrl('g')) {
            if (s.failing) {
                // Drop what does not match.
                while (s.failing) if (!try s.pop(host.doc)) break;
                es.isearchMoved();
                return true;
            }
            es.cursors.items[0].point = s.start;
            es.endIsearch();
            return es.fail("Quit", .{});
        }
        // RET (or any other command) ends the search where it is.
        const start = s.start;
        const moved = es.cursors.items[0].point != start;
        if (s.query.items.len > 0) {
            es.last_search.clearRetainingCapacity();
            try es.last_search.appendSlice(es.gpa, s.query.items);
            es.last_search_regex = s.regex;
        }
        es.endIsearch();
        if (moved) {
            const p = es.cursors.items[0].point;
            es.cursors.items[0].point = start;
            if (!es.mark_active) try es.pushMark(host, false);
            es.cursors.items[0].point = p;
            es.message("Mark saved where search started", .{});
        }
        es.last = .other;
        if (k.is(.enter) or k.isEscape()) return true;
        return false;
    }

    fn isearchMoved(es: *EmacsState) void {
        const s = &es.isearch.?;
        es.cursors.items[0].point = s.point();
    }

    // -- query replace ----------------------------------------------------------------------

    fn startQuery(es: *EmacsState, host: *Host, regex: bool) !void {
        _ = host;
        es.minibuffer = .{ .kind = .query_from, .regex = regex };
    }

    fn minibufferKey(es: *EmacsState, k: Key, host: *Host) !KeyResult {
        const m = &es.minibuffer.?;
        if (k.text()) |cp| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return .consumed;
            try m.text.appendSlice(es.gpa, buf[0..len]);
            return .consumed;
        }
        if (k.is(.backspace)) {
            if (m.text.items.len > 0) {
                var i = m.text.items.len - 1;
                while (i > 0 and m.text.items[i] & 0xC0 == 0x80) i -= 1;
                m.text.shrinkRetainingCapacity(i);
            }
            return .consumed;
        }
        if (k.isCtrl('g') or k.is(.esc)) {
            m.text.deinit(es.gpa);
            es.minibuffer = null;
            return es.fail("Quit", .{});
        }
        if (!k.is(.enter) and !k.isCtrl('m') and !k.isCtrl('j')) return .consumed;
        switch (m.kind) {
            .query_from => {
                if (m.text.items.len == 0) {
                    if (es.last_query_from.items.len == 0) {
                        m.text.deinit(es.gpa);
                        es.minibuffer = null;
                        return .consumed;
                    }
                    // The default: the last FROM and TO.
                    const regex = m.regex;
                    m.text.deinit(es.gpa);
                    es.minibuffer = null;
                    try es.beginQuery(host, regex);
                    return .consumed;
                }
                es.last_query_from.clearRetainingCapacity();
                try es.last_query_from.appendSlice(es.gpa, m.text.items);
                m.text.clearRetainingCapacity();
                m.kind = .query_to;
            },
            .query_to => {
                es.last_query_to.clearRetainingCapacity();
                try es.last_query_to.appendSlice(es.gpa, m.text.items);
                const regex = m.regex;
                m.text.deinit(es.gpa);
                es.minibuffer = null;
                try es.beginQuery(host, regex);
            },
        }
        return .consumed;
    }

    fn beginQuery(es: *EmacsState, host: *Host, regex: bool) !void {
        const gpa = es.gpa;
        var translated: ?[]u8 = null;
        defer if (translated) |t| gpa.free(t);
        if (regex) translated = regexp.translate(gpa, es.last_query_from.items) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return es.fail("Invalid regexp: {s}", .{es.last_query_from.items}),
        };
        const pat = translated orelse es.last_query_from.items;
        const c0 = es.cursors.items[0];
        var start = c0.point;
        var end = host.doc.len();
        if (es.mark_active) if (c0.mark) |m| {
            start = @min(m, c0.point);
            end = @max(m, c0.point);
        };
        var diag: zg_regex.Error = undefined;
        const lower = for (es.last_query_from.items) |b| {
            if (std.ascii.isUpper(b)) break false;
        } else true;
        const session = find.FindSession.start(gpa, host.doc, .{
            .pattern = pat,
            .regex = regex,
            .case = if (lower) .insensitive else .sensitive,
            .preserve_case = lower and !hasUpper(es.last_query_to.items),
        }, .{ .start = 0, .end = host.doc.len() }, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return es.fail("Invalid regexp: {s}", .{es.last_query_from.items}),
        };
        errdefer session.stop();
        try session.finish();
        const template = try (if (regex) emacsTemplate(gpa, es.last_query_to.items) else gpa.dupe(u8, es.last_query_to.items));
        errdefer gpa.free(template);
        es.cursors.shrinkRetainingCapacity(1);
        es.mark_active = false;
        try es.pushMark(host, false);
        es.msg_len = 0;
        es.query = .{ .session = session, .template = template, .from = try gpa.dupe(u8, es.last_query_from.items), .regex = regex, .end = end };
        es.cursors.items[0].point = start;
        try es.queryNext(host, start);
    }

    fn hasUpper(s: []const u8) bool {
        for (s) |b| if (std.ascii.isUpper(b)) return true;
        return false;
    }

    /// Moves to the first match at or after `from`, or ends.
    fn queryNext(es: *EmacsState, host: *Host, from: u64) !void {
        const q = &es.query.?;
        const f = q.session;
        const i = f.index.rank(from);
        if (i < f.index.count()) {
            const m = f.index.nth(i);
            if (m.end <= q.end) {
                q.current = m;
                es.cursors.items[0].point = m.end;
                return;
            }
        }
        try es.finishQuery(host);
    }

    fn finishQuery(es: *EmacsState, host: *Host) !void {
        const n = es.query.?.replaced;
        es.endQuery();
        try es.closeGroup(host);
        es.message("Replaced {d} occurrence{s}", .{ n, if (n == 1) "" else "s" });
    }

    fn endQuery(es: *EmacsState) void {
        if (es.query) |q| {
            q.session.stop();
            es.gpa.free(q.template);
            es.gpa.free(q.from);
        }
        es.query = null;
    }

    fn replaceCurrent(es: *EmacsState, host: *Host) !u64 {
        const q = &es.query.?;
        const m = q.current.?;
        // Undo puts point back where the first replacement was asked
        // about (the end of its match), as Emacs's undo list records it.
        try es.openGroup(host);
        const text = try q.session.replacementFor(m, q.template, es.gpa);
        defer es.gpa.free(text);
        var cs = try ChangeSet.fromEdits(es.gpa, host.doc.len(), &.{.{ .range = m, .text = text }});
        defer cs.deinit();
        try host.doc.applyChangeSet(&cs, host.edit.origin);
        try q.session.onChangeSet(&cs);
        q.end = cs.mapPos(q.end, .right);
        q.replaced += 1;
        const after = m.start + text.len;
        es.cursors.items[0].point = after;
        return if (m.start == m.end) after + 1 else after;
    }

    fn queryKey(es: *EmacsState, k: Key, host: *Host) !KeyResult {
        const q = &es.query.?;
        const m = q.current.?;
        const c = k.text() orelse if (k.is(.backspace)) @as(u21, 'n') else if (k.is(.enter)) @as(u21, 'q') else if (k.isCtrl('g')) {
            try es.finishQuery(host);
            return es.fail("Quit", .{});
        } else 0;
        switch (c) {
            'y', ' ' => {
                const next = try es.replaceCurrent(host);
                try es.queryNext(host, next);
            },
            'n' => try es.queryNext(host, if (m.start == m.end) m.end + 1 else m.end),
            '.' => {
                _ = try es.replaceCurrent(host);
                try es.finishQuery(host);
            },
            '!' => {
                while (es.query != null) {
                    const next = try es.replaceCurrent(host);
                    try es.queryNext(host, next);
                }
            },
            'q' => try es.finishQuery(host),
            else => {},
        }
        return .consumed;
    }
};

/// An Emacs replacement (`\&`, `\N`, `\\`) as a find replacement
/// template (`$&`... per zg_editor's replace module: `$0`, `$N`, `$$`).
fn emacsTemplate(gpa: Allocator, rep: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        const c = rep[i];
        if (c == '\\' and i + 1 < rep.len) {
            i += 1;
            const e = rep[i];
            switch (e) {
                '&' => try out.appendSlice(gpa, "$&"),
                '0'...'9' => try out.print(gpa, "${{{c}}}", .{e}),
                '\\' => try out.append(gpa, '\\'),
                else => try out.append(gpa, e),
            }
        } else if (c == '$') {
            try out.appendSlice(gpa, "$$");
        } else try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

fn fmtKey(k: Key) std.fmt.Alt(Key, writeKey) {
    return .{ .data = k };
}

fn writeKey(k: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (k.ctrl) try w.writeAll("C-");
    if (k.alt) try w.writeAll("M-");
    if (k.code >= 0x11_0000) return w.writeAll(@tagName(@as(key_mod.Special, @enumFromInt(k.code))));
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(k.code, &buf) catch return;
    try w.writeAll(buf[0..n]);
}
