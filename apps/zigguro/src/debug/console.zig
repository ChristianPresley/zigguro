//! The Debug Console (E07.F07.S01.T02): the sessions' output and a REPL.
//!
//! - **Output.** Each session's console (zg_dap's `Console`, filled from
//!   `output` events) is read as it grows: text is split into lines, a
//!   chunk without a newline continues the line, ANSI SGR styling is
//!   kept (zg_dap's `sgr`, mapped onto the theme's colours) and other
//!   escapes dropped. stderr shows in the error colour, adapter messages
//!   in the info colour, `important` ones in the warning colour.
//!   `group` start/end nest lines under a header row (collapsed for
//!   `startCollapsed`).
//! - **REPL.** Enter evaluates the input (`context: repl`) in the selected
//!   frame of the active session, echoing `> input` and then the result
//!   when it arrives; a result with children opens into them. Up/Down go
//!   through the history, Ctrl+Space asks the adapter for completions.
//! - Lines arrive in the order the UI thread sees them, so results and
//!   output interleave as they happened. At most `max_lines` are kept,
//!   the oldest dropped.
//! - A filter keeps the lines containing its text (case-insensitive);
//!   Clear empties the console.
//!
//! UI thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_dap = @import("zg_dap");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const Token = zg_gui.theme.Token;
const virtual = zg_gui.virtual;
const TreeView = virtual.TreeView;
const TreeSource = virtual.TreeSource;
const ChildCount = virtual.tree_view.ChildCount;
const RowInfo = virtual.tree_view.RowInfo;
const LoadDone = virtual.tree_view.LoadDone;
const sgr = zg_dap.inspect.sgr;
const Inspector = zg_dap.inspect.Inspector;
const Evaluator = zg_dap.inspect.Evaluator;
const ReplHistory = zg_dap.inspect.ReplHistory;
const VariablesModel = zg_dap.inspect.VariablesModel;
const NodeId = VariablesModel.NodeId;
const ConsoleEntry = zg_dap.session.DebugSession.Console;
const console_events = zg_dap.session.console_events;

/// Most lines kept; past it the oldest `drop_lines` go.
pub const max_lines = 10_000;
const drop_lines = 1_000;
/// Line rows: `line_base + seq`; other rows are model node ids.
const line_base: u64 = 1 << 62;
/// Most completions listed.
const max_completions = 30;

pub const Kind = enum {
    console,
    important,
    stdout,
    stderr,
    /// The REPL's echo of what was typed.
    input,
    result,
    result_error,
    /// The console's own notices ("no debug session").
    notice,
};

const Line = struct {
    kind: Kind,
    session: u32,
    /// The text without escapes, and its styled runs.
    text: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(sgr.Span) = .empty,
    /// The style at the end (the next chunk starts in it).
    end_style: sgr.Style = .{},
    /// More of the line may follow (no newline yet).
    partial: bool = false,
    /// A group's header row: its children, open unless collapsed.
    group: ?struct { kids: std.ArrayList(u64) = .empty, collapsed: bool } = null,
    /// A REPL result's (or an output's) children in the session's model.
    node: ?NodeId = null,

    fn deinit(l: *Line, gpa: Allocator) void {
        l.text.deinit(gpa);
        l.spans.deinit(gpa);
        if (l.group) |*g| g.kids.deinit(gpa);
    }
};

/// What the console asks of its owner (the debug service).
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Something to repaint.
    changed: *const fn (ctx: *anyopaque) void,
    /// The session REPL input goes to: its models and id (null: none).
    target: *const fn (ctx: *anyopaque) ?Target,
    /// Session `id`'s models, while it runs.
    inspector: *const fn (ctx: *anyopaque, id: u32) ?*Inspector,
};

pub const Target = struct {
    insp: *Inspector,
    id: u32,
    /// The adapter runs `repl` text as its own commands (GDB): input is
    /// evaluated as an expression, and `-exec <command>` sends a command.
    repl_is_command: bool = false,
};

/// The prefix that sends the rest of the input to the debugger as a
/// command (as in VS Code's C/C++ debugger).
pub const exec_prefix = "-exec ";

pub const ConsoleView = struct {
    gpa: Allocator,
    hooks: Hooks,
    lines: std.ArrayList(Line) = .empty,
    /// The seq of `lines[0]`, and the next one.
    first: u64 = 0,
    next: u64 = 0,
    /// Top-level rows, and the open groups (seqs).
    roots: std.ArrayList(u64) = .empty,
    open: std.ArrayList(u64) = .empty,
    /// Rows matching the filter (when there is one).
    filtered: std.ArrayList(u64) = .empty,
    filter_buf: zg_gui.w.TextBuffer,
    filter_seen: std.ArrayList(u8) = .empty,
    input: zg_gui.w.TextBuffer,
    history: ReplHistory,
    tv: TreeView = undefined,
    /// Group headers to open after the next reload.
    to_open: std.ArrayList(u64) = .empty,
    loading: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    done: ?LoadDone = null,
    /// Reloaded at the next build.
    dirty: bool = false,
    /// The last row was in view: new lines keep it so.
    follow: bool = true,
    /// REPL input sent; answers to input from before `clear` are
    /// dropped.
    eval_token: u64 = 0,
    cleared_at: u64 = 0,
    /// The session whose model rows show (the newest result's).
    var_session: u32 = 0,
    input_node: zg_gui.core.NodeId = .none,
    focus_input: bool = false,
    menu: zg_gui.w.menu.MenuHandle = .{},
    compl_arena: std.heap.ArenaAllocator,
    compl: []Completion = &.{},
    label_arena: std.heap.ArenaAllocator,

    const Completion = struct { text: []const u8, start: usize, end: usize };

    /// `cv` must not move afterwards.
    pub fn init(cv: *ConsoleView, gpa: Allocator, hooks: Hooks) !void {
        cv.* = .{
            .gpa = gpa,
            .hooks = hooks,
            .filter_buf = try .init(gpa, ""),
            .input = undefined,
            .history = .init(gpa),
            .compl_arena = .init(gpa),
            .label_arena = .init(gpa),
        };
        errdefer cv.filter_buf.deinit();
        cv.input = try .init(gpa, "");
        errdefer cv.input.deinit();
        cv.tv = try TreeView.init(gpa, cv.source(), .{
            .label = "Debug Console",
            .test_id = "debug-console",
            .expand_on_click = true,
            .on_toggle = .{ .ctx = cv, .f = onToggle },
        });
    }

    pub fn deinit(cv: *ConsoleView) void {
        if (cv.tv.win) |w| cv.menu.close(w);
        cv.tv.deinit();
        for (cv.lines.items) |*l| l.deinit(cv.gpa);
        cv.lines.deinit(cv.gpa);
        cv.roots.deinit(cv.gpa);
        cv.open.deinit(cv.gpa);
        cv.filtered.deinit(cv.gpa);
        cv.filter_buf.deinit();
        cv.filter_seen.deinit(cv.gpa);
        cv.input.deinit();
        cv.history.deinit();
        cv.to_open.deinit(cv.gpa);
        cv.loading.deinit(cv.gpa);
        cv.compl_arena.deinit();
        cv.label_arena.deinit();
    }

    fn self(ptr: *anyopaque) *ConsoleView {
        return @ptrCast(@alignCast(ptr));
    }

    fn lineOf(cv: *ConsoleView, seq: u64) ?*Line {
        if (seq < cv.first or seq >= cv.next) return null;
        return &cv.lines.items[@intCast(seq - cv.first)];
    }

    /// The number of lines kept.
    pub fn lineCount(cv: *const ConsoleView) usize {
        return cv.lines.items.len;
    }

    /// Line `i`'s text (0: the oldest kept), for tests and copying.
    pub fn lineText(cv: *const ConsoleView, i: usize) []const u8 {
        return cv.lines.items[i].text.items;
    }

    pub fn lineKind(cv: *const ConsoleView, i: usize) Kind {
        return cv.lines.items[i].kind;
    }

    // -- adding lines -------------------------------------------------------------

    fn newLine(cv: *ConsoleView, kind: Kind, session: u32, style: sgr.Style) Allocator.Error!*Line {
        if (cv.lines.items.len >= max_lines) cv.dropOldest();
        try cv.lines.append(cv.gpa, .{ .kind = kind, .session = session, .end_style = style });
        const seq = cv.next;
        cv.next += 1;
        errdefer {
            var l = cv.lines.pop().?;
            l.deinit(cv.gpa);
            cv.next -= 1;
        }
        if (cv.open.items.len > 0) {
            const g = cv.lineOf(cv.open.items[cv.open.items.len - 1]).?;
            try g.group.?.kids.append(cv.gpa, seq);
        } else try cv.roots.append(cv.gpa, seq);
        cv.dirty = true;
        return &cv.lines.items[cv.lines.items.len - 1];
    }

    /// Appends `text` (raw, with escapes) as lines of `kind`; a line left
    /// without a newline takes the next chunk of the same kind.
    fn addText(cv: *ConsoleView, kind: Kind, session: u32, text: []const u8) Allocator.Error!void {
        var rest = text;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n');
            const piece = if (nl) |i| rest[0..i] else rest;
            rest = if (nl) |i| rest[i + 1 ..] else "";
            const last: ?*Line = if (cv.lines.items.len > 0) &cv.lines.items[cv.lines.items.len - 1] else null;
            const l = if (last) |x| (if (x.partial and x.kind == kind and x.session == session and x.group == null) x else null) else null;
            const line = l orelse try cv.newLine(kind, session, if (last) |x| (if (x.kind == kind and x.session == session) x.end_style else .{}) else .{});
            line.end_style = try sgr.parse(cv.gpa, std.mem.trimEnd(u8, piece, "\r"), line.end_style, &line.text, &line.spans);
            line.partial = nl == null;
            cv.dirty = true;
        }
    }

    /// A session console entry.
    pub fn addEntry(cv: *ConsoleView, session: u32, e: console_events.Entry) Allocator.Error!void {
        const kind: Kind = switch (e.category) {
            .console, .other, .telemetry => .console,
            .important => .important,
            .stdout => .stdout,
            .stderr => .stderr,
        };
        switch (e.group) {
            .none => try cv.addText(kind, session, e.text),
            .start, .start_collapsed => {
                const line = try cv.newLine(kind, session, .{});
                const head = std.mem.trimEnd(u8, e.text, "\r\n");
                line.end_style = try sgr.parse(cv.gpa, head, .{}, &line.text, &line.spans);
                line.group = .{ .collapsed = e.group == .start_collapsed };
                try cv.open.append(cv.gpa, cv.next - 1);
                if (e.group == .start) try cv.to_open.append(cv.gpa, cv.next - 1);
            },
            .end => {
                _ = cv.open.pop();
                if (std.mem.trimEnd(u8, e.text, "\r\n").len > 0) try cv.addText(kind, session, e.text);
            },
        }
    }

    /// One of the console's own lines.
    pub fn notice(cv: *ConsoleView, text: []const u8) void {
        cv.endPartial();
        cv.addText(.notice, 0, text) catch {};
        cv.endPartial();
        cv.hooks.changed(cv.hooks.ctx);
    }

    fn endPartial(cv: *ConsoleView) void {
        if (cv.lines.items.len > 0) cv.lines.items[cv.lines.items.len - 1].partial = false;
    }

    /// Reads the entries of `c` (session `session`'s console) from its
    /// `read`-th on (counting dropped ones); returns the count seen. It
    /// runs under the session's lock, so it does not call `hooks.changed`:
    /// the caller does once the lock is released.
    pub fn pull(cv: *ConsoleView, session: u32, c: *const ConsoleEntry, read: u64) u64 {
        const total = c.dropped + c.entries.items.len;
        var i = @max(read, c.dropped);
        while (i < total) : (i += 1) cv.addEntry(session, c.entries.items[@intCast(i - c.dropped)]) catch break;
        return total;
    }

    fn dropOldest(cv: *ConsoleView) void {
        const n = @min(drop_lines, cv.lines.items.len);
        for (cv.lines.items[0..n]) |*l| l.deinit(cv.gpa);
        cv.lines.replaceRangeAssumeCapacity(0, n, &.{});
        cv.first += n;
        // Groups that went lose their rows; their kept children become
        // top-level.
        var keep: std.ArrayList(u64) = .empty;
        for (cv.lines.items, 0..) |l, i| {
            const seq = cv.first + i;
            if (!cv.isChild(seq)) keep.append(cv.gpa, seq) catch {};
            _ = l;
        }
        cv.roots.deinit(cv.gpa);
        cv.roots = keep;
        var j: usize = 0;
        for (cv.open.items) |s| if (s >= cv.first) {
            cv.open.items[j] = s;
            j += 1;
        };
        cv.open.shrinkRetainingCapacity(j);
        cv.dirty = true;
    }

    /// Whether some kept group lists `seq`.
    fn isChild(cv: *ConsoleView, seq: u64) bool {
        for (cv.lines.items) |l| if (l.group) |g| {
            if (std.mem.indexOfScalar(u64, g.kids.items, seq) != null) return true;
        };
        return false;
    }

    /// Clear Console.
    pub fn clear(cv: *ConsoleView) void {
        for (cv.lines.items) |*l| l.deinit(cv.gpa);
        cv.lines.clearRetainingCapacity();
        cv.roots.clearRetainingCapacity();
        cv.open.clearRetainingCapacity();
        cv.filtered.clearRetainingCapacity();
        cv.to_open.clearRetainingCapacity();
        cv.loading.clearRetainingCapacity();
        cv.first = cv.next;
        cv.cleared_at = cv.eval_token;
        cv.dirty = true;
        cv.hooks.changed(cv.hooks.ctx);
    }

    // -- the REPL ------------------------------------------------------------------

    /// Evaluates the input (Enter).
    pub fn submit(cv: *ConsoleView) void {
        const text = std.mem.trim(u8, cv.input.slice(), " \t\r\n");
        if (text.len == 0) return;
        cv.history.push(text);
        cv.endPartial();
        const echo = std.fmt.allocPrint(cv.gpa, "> {s}", .{text}) catch return;
        defer cv.gpa.free(echo);
        cv.addText(.input, 0, echo) catch {};
        cv.endPartial();
        if (cv.hooks.target(cv.hooks.ctx)) |t| {
            cv.eval_token += 1;
            const frame = if (t.insp.stopped()) t.insp.vars.frame_id else null;
            // The session id rides in the token's high bits.
            const user = (@as(u64, t.id) << 40) | (cv.eval_token & 0xff_ffff_ffff);
            const cmd = std.mem.startsWith(u8, text, exec_prefix);
            const expr = if (cmd) std.mem.trimStart(u8, text[exec_prefix.len..], " \t") else text;
            const ctx: Evaluator.EvalContext = if (t.repl_is_command and !cmd) .watch else .repl;
            t.insp.eval.evaluate(expr, ctx, frame, .{ .ctx = cv, .user = user, .func = onResult });
        } else cv.addText(.result_error, 0, "No debug session is running") catch {};
        cv.endPartial();
        cv.input.setText("") catch {};
        cv.follow = true;
        cv.hooks.changed(cv.hooks.ctx);
    }

    fn onResult(ctx: ?*anyopaque, user: u64, r: *const Evaluator.EvalResult) void {
        const cv = self(ctx.?);
        if ((user & 0xff_ffff_ffff) <= (cv.cleared_at & 0xff_ffff_ffff)) return;
        const session: u32 = @intCast(user >> 40);
        cv.endPartial();
        cv.addText(if (r.err) .result_error else .result, session, if (r.value.len > 0) r.value else "(no value)") catch return;
        cv.endPartial();
        if (!r.err) if (r.node) |n| {
            cv.lines.items[cv.lines.items.len - 1].node = n;
        };
        cv.hooks.changed(cv.hooks.ctx);
    }

    /// Up: the previous input.
    pub fn historyPrev(cv: *ConsoleView) void {
        if (cv.history.prev()) |t| cv.input.setText(t) catch {};
    }

    /// Down: the next input (empty past the newest).
    pub fn historyNext(cv: *ConsoleView) void {
        cv.input.setText(cv.history.next() orelse "") catch {};
    }

    /// Ctrl+Space: the adapter's completions for the input, in a menu.
    pub fn complete(cv: *ConsoleView) void {
        const t = cv.hooks.target(cv.hooks.ctx) orelse return;
        const text = cv.input.slice();
        const frame = if (t.insp.stopped()) t.insp.vars.frame_id else null;
        t.insp.eval.completions(text, @intCast(text.len), frame, .{ .ctx = cv, .func = onCompletions });
    }

    fn onCompletions(ctx: ?*anyopaque, items: []const Evaluator.ComplItem) void {
        const cv = self(ctx.?);
        const w = cv.tv.win orelse return;
        if (items.len == 0) return;
        _ = cv.compl_arena.reset(.retain_capacity);
        const a = cv.compl_arena.allocator();
        const text = cv.input.slice();
        const n = @min(items.len, max_completions);
        const list = a.alloc(Completion, n) catch return;
        const rows = a.alloc(zg_gui.w.menu.MenuItem, n) catch return;
        // The word before the end, for items without a start.
        var ws = text.len;
        while (ws > 0 and (std.ascii.isAlphanumeric(text[ws - 1]) or text[ws - 1] == '_')) ws -= 1;
        for (items[0..n], list, rows, 0..) |it, *c, *row, i| {
            const start = if (it.start) |s| @min(s, text.len) else ws;
            const end = if (it.start != null) @min(text.len, start + it.length) else text.len;
            c.* = .{ .text = a.dupe(u8, it.text) catch return, .start = start, .end = end };
            const title = std.mem.replaceOwned(u8, a, it.label, "&", "&&") catch return;
            row.* = .{ .action = .{ .label = title, .action = "debug.consoleCompletion", .arg = std.fmt.allocPrint(a, "{d}", .{i}) catch return } };
        }
        cv.compl = list;
        cv.menu.close(w);
        const anchor: zg_gui.w.menu.MenuAnchor = if (!cv.input_node.isNone() and w.store.valid(cv.input_node)) .{ .node = cv.input_node } else .{ .pointer = .{} };
        cv.menu = zg_gui.w.menu.openMenu(w, rows, anchor, .{ .on_action = .{ .ctx = cv, .f = onPick }, .keyboard = true, .test_id = "debug-console-completions" }) catch return;
    }

    fn onPick(ctx: ?*anyopaque, _: zg_gui.w.menu.ActionId, arg: ?[]const u8) void {
        const cv = self(ctx.?);
        const i = std.fmt.parseInt(usize, arg orelse return, 10) catch return;
        cv.applyCompletion(i);
    }

    /// Puts completion `i` into the input.
    pub fn applyCompletion(cv: *ConsoleView, i: usize) void {
        if (i >= cv.compl.len) return;
        const c = cv.compl[i];
        const text = cv.input.slice();
        if (c.start > text.len or c.end > text.len or c.start > c.end) return;
        const out = std.mem.concat(cv.gpa, u8, &.{ text[0..c.start], c.text, text[c.end..] }) catch return;
        defer cv.gpa.free(out);
        cv.input.setText(out) catch {};
        cv.focus_input = true;
        cv.hooks.changed(cv.hooks.ctx);
    }

    /// The completions offered (tests).
    pub fn completionTexts(cv: *const ConsoleView, a: Allocator) ![]const []const u8 {
        const out = try a.alloc([]const u8, cv.compl.len);
        for (cv.compl, out) |c, *o| o.* = c.text;
        return out;
    }

    // -- the tree ------------------------------------------------------------------

    fn source(cv: *ConsoleView) TreeSource {
        return .{ .ptr = cv, .vtable = &vtable };
    }

    const vtable: TreeSource.VTable = .{
        .root_count = rootCount,
        .child_count = childCount,
        .child = child,
        .load = load,
        .label = label,
        .build_row = buildRow,
    };

    fn filtering(cv: *const ConsoleView) bool {
        return cv.filter_seen.items.len > 0;
    }

    fn rootCount(ptr: *anyopaque) u32 {
        const cv = self(ptr);
        return @intCast(if (cv.filtering()) cv.filtered.items.len else cv.roots.items.len);
    }

    /// The session model and node under row `id`.
    fn varOf(cv: *ConsoleView, id: u64) ?struct { m: *VariablesModel, n: NodeId } {
        if (id >= line_base) {
            const l = cv.lineOf(id - line_base) orelse return null;
            const n = l.node orelse return null;
            const insp = cv.hooks.inspector(cv.hooks.ctx, l.session) orelse return null;
            return .{ .m = &insp.vars, .n = n };
        }
        // A model row: its session is the one asked last (`var_session`).
        const insp = cv.hooks.inspector(cv.hooks.ctx, cv.var_session) orelse return null;
        return .{ .m = &insp.vars, .n = @enumFromInt(id) };
    }

    fn childCount(ptr: *anyopaque, id: u64) ChildCount {
        const cv = self(ptr);
        if (id >= line_base) {
            const l = cv.lineOf(id - line_base) orelse return .leaf;
            if (cv.filtering()) return .leaf;
            if (l.group) |g| return if (g.kids.items.len == 0) .leaf else .{ .known = @intCast(g.kids.items.len) };
            if (l.node == null) return .leaf;
            cv.var_session = l.session;
        }
        const x = cv.varOf(id) orelse return .leaf;
        const v = x.m.node(x.n) orelse return .leaf;
        switch (v.kind) {
            .more => return .leaf,
            .variable => if (v.child_count == null and !v.lazy) return .leaf,
            .scope, .bucket => {},
        }
        const p = x.m.peekChildren(x.n) orelse return .unknown_loading;
        if (p.ids.len == 0) return .leaf;
        return .{ .known = @intCast(p.ids.len) };
    }

    fn child(ptr: *anyopaque, parent: ?u64, i: u32) u64 {
        const cv = self(ptr);
        const p = parent orelse return line_base + (if (cv.filtering()) cv.filtered.items[i] else cv.roots.items[i]);
        if (p >= line_base) if (cv.lineOf(p - line_base)) |l| if (l.group) |g| return line_base + g.kids.items[i];
        const x = cv.varOf(p).?;
        return @intFromEnum(x.m.peekChildren(x.n).?.ids[i]);
    }

    fn load(ptr: *anyopaque, id: u64, done: LoadDone) void {
        const cv = self(ptr);
        const x = cv.varOf(id) orelse return;
        cv.done = done;
        cv.loading.put(cv.gpa, id, {}) catch return;
        x.m.expand(x.n, true);
        cv.hooks.changed(cv.hooks.ctx);
    }

    fn onToggle(ctx: *anyopaque, id: u64, expanded: bool) void {
        const cv = self(ctx);
        if (id >= line_base) if (cv.lineOf(id - line_base)) |l| if (l.group != null) return;
        const x = cv.varOf(id) orelse return;
        x.m.expand(x.n, expanded);
        cv.hooks.changed(cv.hooks.ctx);
    }

    fn label(ptr: *anyopaque, id: u64) []const u8 {
        const cv = self(ptr);
        if (id >= line_base) {
            const l = cv.lineOf(id - line_base) orelse return "";
            return l.text.items;
        }
        const x = cv.varOf(id) orelse return "";
        const v = x.m.node(x.n) orelse return "";
        if (v.value.len == 0) return v.name;
        return std.fmt.allocPrint(cv.label_arena.allocator(), "{s}, {s}", .{ v.name, v.value }) catch v.name;
    }

    fn kindColor(k: Kind) Token {
        return switch (k) {
            .stdout, .result => .fg,
            .stderr, .result_error => .danger,
            .console => .info,
            .important => .warning,
            .input, .notice => .fg_muted,
        };
    }

    /// The theme colour nearest an ANSI colour.
    pub fn tokenOf(c: sgr.Color) ?Token {
        const rgb = c.toRgb() orelse return null;
        const r: i32 = rgb[0];
        const g: i32 = rgb[1];
        const b: i32 = rgb[2];
        const hi = @max(r, @max(g, b));
        const lo = @min(r, @min(g, b));
        // Greys.
        if (hi - lo < 40) return if (hi < 150) .fg_muted else .fg;
        if (r == hi and g >= b + 60 and g > r - 70) return .warning; // yellow, orange
        if (r == hi and b > g + 40) return .accent; // magenta, pink
        if (r == hi) return .danger;
        if (g == hi and b > r + 60 and b > g - 60) return .info; // cyan
        if (g == hi) return .success;
        if (r > g + 60) return .accent; // violet
        return .info;
    }

    fn buildRow(ptr: *anyopaque, ui: *Ui, id: u64, _: RowInfo) void {
        const cv = self(ptr);
        ui.open(.{ .style = .{ .dir = .row, .gap = 0, .align_items = .center, .grow = 1, .shrink = 1 } });
        defer ui.close();
        if (id < line_base) {
            const x = cv.varOf(id) orelse return;
            const v = x.m.node(x.n) orelse return;
            ui.text(v.name, .{ .color = .fg, .wrap = false, .style = .{ .font = .mono } });
            if (v.value.len == 0) return;
            ui.text(": ", .{ .color = .fg_muted, .wrap = false, .style = .{ .font = .mono } });
            ui.text(if (v.lazy) VariablesModel.lazy_label else v.value, .{ .color = if (v.err) .danger else .info, .wrap = false, .style = .{ .font = .mono } });
            return;
        }
        const l = cv.lineOf(id - line_base) orelse return;
        const base = kindColor(l.kind);
        const text = l.text.items;
        if (text.len == 0) {
            ui.text(" ", .{ .wrap = false, .style = .{ .font = .mono } });
            return;
        }
        var at: usize = 0;
        for (l.spans.items) |s| {
            if (s.start > at) ui.text(text[at..s.start], .{ .color = base, .wrap = false, .style = .{ .font = .mono } });
            const st = s.style;
            const fg = (if (st.inverse) tokenOf(st.bg) else tokenOf(st.fg)) orelse (if (st.faint) Token.fg_muted else base);
            ui.text(text[s.start..s.end], .{ .color = fg, .wrap = false, .style = .{ .font = .mono, .weight = if (st.bold) 700 else 400, .italic = st.italic } });
            at = s.end;
        }
        if (at < text.len) ui.text(text[at..], .{ .color = base, .wrap = false, .style = .{ .font = .mono } });
    }

    /// Re-reads the lines and the models (after they changed).
    pub fn update(cv: *ConsoleView) void {
        // The filter changed: the matching lines.
        const f = cv.filter_buf.slice();
        if (!std.mem.eql(u8, f, cv.filter_seen.items)) {
            cv.filter_seen.clearRetainingCapacity();
            cv.filter_seen.appendSlice(cv.gpa, f) catch {};
            cv.dirty = true;
        }
        if (cv.filtering() and cv.dirty) {
            cv.filtered.clearRetainingCapacity();
            for (cv.lines.items, 0..) |l, i| {
                if (l.group != null) continue;
                if (std.ascii.indexOfIgnoreCase(l.text.items, cv.filter_seen.items) == null) continue;
                cv.filtered.append(cv.gpa, cv.first + i) catch break;
            }
        }
        const at_end = if (cv.tv.flat.len() == 0) true else (cv.tv.active == null or cv.tv.activeRow() == cv.tv.flat.len() - 1);
        _ = cv.label_arena.reset(.retain_capacity);
        cv.tv.reload() catch {};
        for (cv.to_open.items) |seq| if (cv.tv.flat.rowOf(line_base + seq)) |row| {
            _ = cv.tv.expandRow(row) catch {};
        };
        cv.to_open.clearRetainingCapacity();
        var i: usize = 0;
        while (i < cv.loading.count()) {
            const id = cv.loading.keys()[i];
            switch (childCount(cv, id)) {
                .unknown_loading => i += 1,
                else => {
                    cv.loading.swapRemoveAt(i);
                    if (cv.done) |d| d.call(id);
                },
            }
        }
        if (cv.dirty and (cv.follow or at_end) and cv.tv.flat.len() > 0) {
            const last = cv.tv.flat.len() - 1;
            cv.tv.reveal(last);
            cv.follow = false;
        }
        cv.dirty = false;
    }

    // -- the view --------------------------------------------------------------------

    pub fn build(cv: *ConsoleView, ui: *Ui) void {
        cv.tv.win = ui.window();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } } });
        defer ui.close();
        // Filter and Clear.
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center, .padding = .xy(8, 2), .shrink = 0 }, .role = .toolbar, .label = "Debug console actions" });
        ui.open(.{ .style = .{ .w = .{ .px = 220 }, .shrink = 1 } });
        const fr = zg_gui.w.textField(ui, .{ .buffer = &cv.filter_buf, .placeholder = "Filter", .a11y_label = "Filter the debug console" });
        ui.close();
        if (fr.changed) cv.update();
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (zg_gui.w.button(ui, .{ .label = "Clear Console", .variant = .ghost }).clicked) cv.clear();
        ui.close();
        // The lines.
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "debugConsoleFocus" });
        cv.tv.build(ui);
        ui.close();
        // The REPL input.
        ui.open(.{ .style = .{ .dir = .row, .gap = 4, .align_items = .center, .padding = .xy(8, 4), .shrink = 0 }, .key_context = "debugConsoleInputFocus" });
        ui.text(">", .{ .color = .fg_muted, .wrap = false, .style = .{ .font = .mono } });
        ui.open(.{ .style = .{ .grow = 1, .shrink = 1, .basis = .{ .px = 0 } } });
        const r = zg_gui.w.textField(ui, .{ .buffer = &cv.input, .font = .mono, .placeholder = "Evaluate an expression", .a11y_label = "Debug console input" });
        cv.input_node = ui.lastNode();
        ui.close();
        ui.close();
        if (r.submitted) cv.submit();
        if (cv.focus_input) {
            cv.focus_input = false;
            ui.window().afterNextFrame(.{ .ctx = cv, .f = focusInputNow });
        }
    }

    fn focusInputNow(ctx: *anyopaque, w: *Window) void {
        const cv = self(ctx);
        if (!cv.input_node.isNone() and w.store.valid(cv.input_node)) w.setFocus(cv.input_node, true);
    }

    /// Focuses the input.
    pub fn focus(cv: *ConsoleView) void {
        cv.focus_input = true;
        if (cv.tv.win) |w| w.markAllDirty();
    }
};

test "console: lines, partial chunks, ANSI and categories" {
    const testing = std.testing;
    const Owner = struct {
        n: u32 = 0,
        fn changed(ctx: *anyopaque) void {
            const o: *@This() = @ptrCast(@alignCast(ctx));
            o.n += 1;
        }
        fn target(_: *anyopaque) ?Target {
            return null;
        }
        fn inspector(_: *anyopaque, _: u32) ?*Inspector {
            return null;
        }
    };
    var o: Owner = .{};
    var cv: ConsoleView = undefined;
    try cv.init(testing.allocator, .{ .ctx = &o, .changed = Owner.changed, .target = Owner.target, .inspector = Owner.inspector });
    defer cv.deinit();
    try cv.addEntry(1, .{ .category = .stdout, .text = "hello\nwor", .depth = 0, .group = .none });
    try cv.addEntry(1, .{ .category = .stdout, .text = "ld \x1b[31mred\x1b[0m\n", .depth = 0, .group = .none });
    try cv.addEntry(1, .{ .category = .stderr, .text = "oops\r\n", .depth = 0, .group = .none });
    try testing.expectEqual(@as(usize, 3), cv.lineCount());
    try testing.expectEqualStrings("hello", cv.lineText(0));
    try testing.expectEqualStrings("world red", cv.lineText(1));
    try testing.expectEqual(@as(usize, 1), cv.lines.items[1].spans.items.len);
    try testing.expectEqual(Kind.stderr, cv.lineKind(2));
    try testing.expectEqualStrings("oops", cv.lineText(2));
    // Groups nest their lines.
    try cv.addEntry(1, .{ .category = .console, .text = "Group", .depth = 0, .group = .start_collapsed });
    try cv.addEntry(1, .{ .category = .console, .text = "inside\n", .depth = 1, .group = .none });
    try cv.addEntry(1, .{ .category = .console, .text = "", .depth = 1, .group = .end });
    try cv.addEntry(1, .{ .category = .console, .text = "after\n", .depth = 0, .group = .none });
    try testing.expectEqual(@as(usize, 5), cv.roots.items.len);
    try testing.expectEqual(@as(usize, 1), cv.lines.items[3].group.?.kids.items.len);
    cv.update();
    // The collapsed group shows its header only.
    try testing.expectEqual(@as(usize, 5), cv.tv.flat.len());
    // The filter keeps matching lines.
    try cv.filter_buf.setText("ins");
    cv.update();
    try testing.expectEqual(@as(usize, 1), cv.tv.flat.len());
    try cv.filter_buf.setText("");
    cv.update();
    // No session: the REPL says so.
    try cv.input.setText("x + 1");
    cv.submit();
    try testing.expectEqualStrings("> x + 1", cv.lineText(cv.lineCount() - 2));
    try testing.expectEqual(Kind.result_error, cv.lineKind(cv.lineCount() - 1));
    cv.historyPrev();
    try testing.expectEqualStrings("x + 1", cv.input.slice());
    cv.clear();
    try testing.expectEqual(@as(usize, 0), cv.lineCount());
}

test "console: the colour nearest an ANSI colour" {
    const testing = std.testing;
    try testing.expectEqual(Token.danger, ConsoleView.tokenOf(.{ .palette = 1 }).?);
    try testing.expectEqual(Token.success, ConsoleView.tokenOf(.{ .palette = 2 }).?);
    try testing.expectEqual(Token.warning, ConsoleView.tokenOf(.{ .palette = 3 }).?);
    try testing.expectEqual(Token.info, ConsoleView.tokenOf(.{ .palette = 4 }).?);
    try testing.expectEqual(Token.accent, ConsoleView.tokenOf(.{ .palette = 5 }).?);
    try testing.expectEqual(Token.info, ConsoleView.tokenOf(.{ .palette = 6 }).?);
    try testing.expectEqual(Token.fg, ConsoleView.tokenOf(.{ .palette = 7 }).?);
    try testing.expectEqual(Token.fg_muted, ConsoleView.tokenOf(.{ .palette = 8 }).?);
    try testing.expect(ConsoleView.tokenOf(.default) == null);
}
