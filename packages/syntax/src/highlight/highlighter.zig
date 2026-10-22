//! Incremental tier-1 highlighting (the VS Code line-state model).
//!
//! Each line stores its tokens and its interned end state. After an edit,
//! lines are relexed from the first changed line, each starting in the
//! previous line's end state, until a line past the edit ends in the same
//! state as before: from there on nothing can change (convergence). Lines
//! still to be relexed are kept as a sorted set of ranges; `onEdit` works
//! within a budget, `ensure` makes the viewport exact, and `idle` finishes
//! the rest in time slices.
//!
//! The highlighter knows lines, not documents: the editor maps its change
//! events to `LineEdit`s and serves text through a `LineSource`.

const std = @import("std");
const language = @import("../language.zig");
const state_mod = @import("../lex/state.zig");
const scanner_mod = @import("../lex/scanner.zig");
const lexer = @import("../lex/lexer.zig");
const Registry = @import("../registry.zig").Registry;
const TokenStore = @import("token_store.zig").TokenStore;

const Allocator = std.mem.Allocator;
const Language = language.Language;
const ContextKind = language.ContextKind;
const LexState = state_mod.LexState;
const StateId = state_mod.StateId;
const StateTable = state_mod.StateTable;
const Token = scanner_mod.Token;
const TokenSink = scanner_mod.TokenSink;

/// Read access to a document's lines (text without EOL).
pub const LineSource = struct {
    ctx: *const anyopaque,
    /// Number of lines (an empty document has one empty line).
    lines: u64,
    /// The text of `line`; may use `scratch` (owned by the caller) for
    /// lines that are not contiguous in memory.
    getFn: *const fn (ctx: *const anyopaque, line: u64, scratch: *std.ArrayList(u8), gpa: Allocator) Allocator.Error![]const u8,

    /// The text of `line`.
    pub fn get(src: LineSource, line: u64, scratch: *std.ArrayList(u8), gpa: Allocator) Allocator.Error![]const u8 {
        return src.getFn(src.ctx, line, scratch, gpa);
    }

    /// A source over a slice of lines.
    pub fn fromSlice(lines: *const []const []const u8) LineSource {
        return .{ .ctx = @ptrCast(lines), .lines = lines.len, .getFn = sliceGet };
    }

    fn sliceGet(ctx: *const anyopaque, line: u64, _: *std.ArrayList(u8), _: Allocator) Allocator.Error![]const u8 {
        const lines: *const []const []const u8 = @ptrCast(@alignCast(ctx));
        return lines.*[@intCast(line)];
    }
};

/// An edit in line terms: lines `[first, first + removed)` of the old text
/// became lines `[first, first + inserted)` of the new text (every line the
/// edit touched, so typing inside one line is `{ n, 1, 1 }`).
pub const LineEdit = struct { first: u64, removed: u64, inserted: u64 };

/// A wall-clock limit for one call.
pub const Deadline = struct {
    io: std.Io,
    at: std.Io.Timestamp,

    /// `ns` nanoseconds from now.
    pub fn after(io: std.Io, ns: u64) Deadline {
        const now = std.Io.Timestamp.now(io, .awake);
        return .{ .io = io, .at = .{ .nanoseconds = now.nanoseconds + ns } };
    }

    fn passed(d: Deadline) bool {
        return std.Io.Timestamp.now(d.io, .awake).nanoseconds >= d.at.nanoseconds;
    }
};

const Range = struct { start: u64, end: u64 };

pub const Highlighter = struct {
    /// `onEdit` relexes at most this many lines (on top of its deadline).
    pub const edit_line_budget = 4096;
    /// `ensure` approximates from a resync line when the nearest exact line
    /// is further than this above the viewport.
    pub const resync_distance = 5000;
    /// How far above the viewport `ensure` looks for a resync line.
    pub const resync_search = 2000;

    gpa: Allocator,
    reg: *const Registry,
    lang: *const Language,
    states: StateTable,
    store: TokenStore = .{},
    /// Lines to relex, sorted and disjoint.
    pending: std.ArrayList(Range) = .empty,
    sink: TokenSink = .{},
    scratch: std.ArrayList(u8) = .empty,
    /// Counters for tests and benches.
    stats: struct { lines_lexed: u64 = 0, resets: u64 = 0 } = .{},

    /// A highlighter for a document in `lang`. Call `reset` with the
    /// document's lines before use.
    pub fn init(gpa: Allocator, lang: *const Language, reg: *const Registry) Allocator.Error!Highlighter {
        return .{ .gpa = gpa, .reg = reg, .lang = lang, .states = try .init(gpa, lang.id) };
    }

    /// Frees everything.
    pub fn deinit(h: *Highlighter) void {
        h.states.deinit(h.gpa);
        h.store.deinit(h.gpa);
        h.pending.deinit(h.gpa);
        h.sink.deinit(h.gpa);
        h.scratch.deinit(h.gpa);
    }

    /// Forgets all tokens and marks every line of `src` for relexing.
    pub fn reset(h: *Highlighter, src: LineSource) Allocator.Error!void {
        try h.store.spliceLines(h.gpa, 0, h.store.lineCount(), src.lines);
        h.pending.clearRetainingCapacity();
        if (src.lines > 0) try h.pending.append(h.gpa, .{ .start = 0, .end = src.lines });
    }

    /// Number of lines.
    pub fn lineCount(h: *const Highlighter) u64 {
        return h.store.lineCount();
    }

    /// The tokens of `line` (possibly stale; see `isExact`).
    pub fn tokens(h: *const Highlighter, line: u64) []const Token {
        return h.store.tokens(line);
    }

    /// The end state of `line` (the initial state for lines not lexed yet).
    pub fn endState(h: *const Highlighter, line: u64) *const LexState {
        const id = h.store.rec(line).end_state;
        return h.states.get(if (id == .unknown) .initial else id);
    }

    /// Whether `line`'s tokens are final (every line up to it is relexed).
    pub fn isExact(h: *const Highlighter, line: u64) bool {
        return h.pending.items.len == 0 or h.pending.items[0].start > line;
    }

    /// Whether `line`'s tokens came from a resync approximation.
    pub fn isApprox(h: *const Highlighter, line: u64) bool {
        return h.store.rec(line).flags.approx;
    }

    /// Whether everything is relexed.
    pub fn done(h: *const Highlighter) bool {
        return h.pending.items.len == 0;
    }

    /// Applies an edit and relexes from it until convergence, `deadline`
    /// (if any), or `edit_line_budget` lines; the rest is left to `ensure`
    /// and `idle`.
    pub fn onEdit(h: *Highlighter, e: LineEdit, src: LineSource, deadline: ?Deadline) Allocator.Error!void {
        return h.onEdits(&.{e}, src, deadline);
    }

    /// `onEdit` for several edits at once (multi-cursor): sorted by `first`,
    /// non-overlapping, all in old-text line coordinates.
    pub fn onEdits(h: *Highlighter, edits: []const LineEdit, src: LineSource, deadline: ?Deadline) Allocator.Error!void {
        // Back to front, so each edit's coordinates are still valid.
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            if (i > 0) std.debug.assert(edits[i - 1].first + edits[i - 1].removed <= edits[i].first);
            try h.splice(edits[i]);
        }
        std.debug.assert(h.store.lineCount() == src.lines);
        try h.run(src, std.math.maxInt(u64), deadline, edit_line_budget);
    }

    fn splice(h: *Highlighter, e: LineEdit) Allocator.Error!void {
        std.debug.assert(e.first + e.removed <= h.store.lineCount());
        try h.store.spliceLines(h.gpa, e.first, e.removed, e.inserted);
        // Shift pending ranges into new coordinates.
        const old_end = e.first + e.removed;
        var out: usize = 0;
        for (h.pending.items) |r| {
            var a = r.start;
            var b = r.end;
            if (b <= e.first) {} else if (a >= old_end) {
                a = a - e.removed + e.inserted;
                b = b - e.removed + e.inserted;
            } else {
                // Overlaps the removed lines: keep the parts outside them.
                a = @min(a, e.first);
                b = if (b > old_end) b - e.removed + e.inserted else e.first;
            }
            if (a < b) {
                h.pending.items[out] = .{ .start = a, .end = b };
                out += 1;
            }
        }
        h.pending.items.len = out;
        // The edited lines, or the line after a pure deletion.
        const n = h.store.lineCount();
        const mark_end = @min(n, e.first + @max(e.inserted, 1));
        if (e.first < mark_end) try h.addPending(e.first, mark_end);
    }

    /// Makes lines `[first, last]` exact, or approximate when the nearest
    /// exact line is more than `resync_distance` lines above and the
    /// language can resync (then `idle` makes them exact later).
    pub fn ensure(h: *Highlighter, src: LineSource, first: u64, last_in: u64) Allocator.Error!void {
        const n = h.store.lineCount();
        if (n == 0) return;
        const last = @min(last_in, n - 1);
        if (h.isExact(last)) return;
        const front = h.pending.items[0].start;
        if (h.lang.resync) |resync| if (first > front and first - front > resync_distance) {
            if (try h.findResync(src, resync, first, front)) |r| {
                try h.approximate(src, r, last);
                return;
            }
        };
        try h.run(src, last, null, std.math.maxInt(u64));
    }

    /// Relexes until done or `deadline`. Returns whether everything is done.
    pub fn idle(h: *Highlighter, src: LineSource, deadline: ?Deadline) Allocator.Error!bool {
        try h.run(src, std.math.maxInt(u64), deadline, std.math.maxInt(u64));
        if (!h.done()) return false;
        try h.store.maintain(h.gpa);
        return true;
    }

    /// The context at byte `col` of `line` (`line_len` bytes long): the
    /// context of the token holding the byte at `col`. At the end of the
    /// line it is the last token's context only when the line ends inside
    /// a multi-line construct; otherwise code.
    pub fn kindAt(h: *const Highlighter, line: u64, col: u32, line_len: u32) ContextKind {
        const toks = h.tokens(line);
        if (toks.len == 0) return .code;
        if (col >= line_len) {
            const st = h.endState(line);
            if (st.mode == 0 and !st.injected()) return .code;
        }
        // Last token with start <= col.
        var lo: usize = 0;
        var hi: usize = toks.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (toks[mid].start <= col) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return .code;
        const t = toks[lo - 1];
        const lang = if (t.kind & Token.injected_bit != 0) h.reg.getOrPlain(h.endState(line).top()) else h.lang;
        return lang.contextOf(t.kind, t.hl);
    }

    fn addPending(h: *Highlighter, a: u64, b: u64) Allocator.Error!void {
        // Insert keeping order, then merge overlapping or adjacent ranges.
        var i: usize = 0;
        while (i < h.pending.items.len and h.pending.items[i].start < a) i += 1;
        try h.pending.insert(h.gpa, i, .{ .start = a, .end = b });
        var j: usize = if (i > 0) i - 1 else 0;
        while (j + 1 < h.pending.items.len) {
            const x = &h.pending.items[j];
            const y = h.pending.items[j + 1];
            if (y.start <= x.end) {
                x.end = @max(x.end, y.end);
                _ = h.pending.orderedRemove(j + 1);
            } else if (j >= i) break else j += 1;
        }
    }

    fn startState(h: *const Highlighter, line: u64) StateId {
        return if (line == 0) .initial else h.store.rec(line - 1).end_state;
    }

    const Relexed = enum { same, changed, reset };

    /// Lexes `line` from `start` and stores it. `reset` means the state
    /// table overflowed and everything was marked for relexing.
    fn relex(h: *Highlighter, src: LineSource, line: u64, start: StateId, approx: bool) Allocator.Error!Relexed {
        const text = try src.get(line, &h.scratch, h.gpa);
        var st = h.states.get(start).*;
        try h.sink.begin(h.gpa, text.len);
        lexer.lexLine(h.reg, &st, text, &h.sink);
        h.stats.lines_lexed += 1;
        const end = h.states.intern(h.gpa, &st) catch |e| switch (e) {
            error.OutOfMemory => |x| return x,
            error.StateTableFull => {
                // Too many distinct states: start over with a fresh table.
                h.states.reset();
                h.stats.resets += 1;
                const n = h.store.lineCount();
                var i: u64 = 0;
                while (i < n) : (i += 1) h.store.rec(i).end_state = .unknown;
                h.pending.clearRetainingCapacity();
                if (n > 0) try h.pending.append(h.gpa, .{ .start = 0, .end = n });
                return .reset;
            },
        };
        const changed = try h.store.setLine(h.gpa, line, h.sink.tokens(), end, .{
            .approx = approx,
            .long_line = text.len > lexer.max_tokenized_line,
        });
        return if (changed) .changed else .same;
    }

    /// Relexes pending lines in order while the front is at most `until`,
    /// within `deadline` and `max_lines`.
    fn run(h: *Highlighter, src: LineSource, until: u64, deadline: ?Deadline, max_lines: u64) Allocator.Error!void {
        var count: u64 = 0;
        while (h.pending.items.len > 0) {
            const front = &h.pending.items[0];
            const line = front.start;
            if (line > until or count >= max_lines) return;
            if (deadline) |d| if (count % 32 == 31 and d.passed()) return;
            const r = try h.relex(src, line, h.startState(line), false);
            count += 1;
            if (r == .reset) continue;
            const changed = r == .changed;
            front.start += 1;
            if (front.start == front.end) _ = h.pending.orderedRemove(0);
            // A changed end state invalidates the next line.
            if (changed and line + 1 < h.store.lineCount()) {
                if (h.pending.items.len == 0 or h.pending.items[0].start > line + 1) {
                    try h.pending.insert(h.gpa, 0, .{ .start = line + 1, .end = line + 2 });
                    if (h.pending.items.len > 1 and h.pending.items[1].start == line + 2) {
                        h.pending.items[0].end = h.pending.items[1].end;
                        _ = h.pending.orderedRemove(1);
                    }
                }
            }
        }
    }

    fn findResync(h: *Highlighter, src: LineSource, resync: *const fn ([]const u8) bool, first: u64, floor: u64) Allocator.Error!?u64 {
        var line = first;
        const stop = @max(floor, first -| resync_search);
        while (line > stop) : (line -= 1) {
            if (resync(try src.get(line, &h.scratch, h.gpa))) return line;
        }
        return null;
    }

    /// Lexes `[from, last]` assuming `from` starts in the initial state and
    /// marks the lines approximate; they stay pending.
    fn approximate(h: *Highlighter, src: LineSource, from: u64, last: u64) Allocator.Error!void {
        var st: StateId = .initial;
        var line = from;
        while (line <= last) : (line += 1) {
            if (try h.relex(src, line, st, true) == .reset) return;
            st = h.store.rec(line).end_state;
        }
        try h.addPending(from, last + 1);
    }
};
