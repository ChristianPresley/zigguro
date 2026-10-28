//! Command blocks (E06.F06.S02.T01): the shell-integration marks of one
//! terminal turned into prompt / command / output blocks.
//!
//! `Blocks` is the terminal's `MarkSink`. Each OSC 133 / 633 mark moves the
//! newest block through `prompt` -> `typing` -> `running` -> `finished`:
//!
//! | Mark | Effect |
//! |---|---|
//! | A | A block still at the prompt or typing is `abandoned` (Ctrl+C at the prompt); a running one finishes with no exit code (no D support, or the shell died). A new block starts at the prompt row. |
//! | B | Input starts here; state `typing`. |
//! | E | The command line (trusted when its nonce matched). |
//! | C | Output starts here; state `running`; the command line is read from the screen when no E came. Emits `started`. |
//! | D | The block finishes with the exit code (null when not a number). A D with no running block is ignored (Windows Terminal's bash recipe sends one before the first prompt). Emits `finished`. |
//! | cwd | The working folder blocks copy at C (or at A when no C comes). |
//!
//! Positions are absolute rows (`PageList.evicted + rowIndex`), so they do
//! not move as output scrolls or old rows are compacted. The prompt row,
//! output row and end row also carry a `Row.mark`, which reflow keeps on
//! the first row of each logical line: after a resize `resync` puts the
//! blocks back on the rows that now carry their marks. Rows evicted from
//! the top drop the blocks that ended there and truncate the one that
//! started there; ED 3 does the same for everything above the screen.
//! Marks on the alternate screen are ignored.
//!
//! Events (`started`, `output`, `finished`, `abandoned`) queue while the
//! terminal parses and reach the listeners from `flush`, which the owner
//! calls after `feed` (outside any terminal lock). `output` reports each
//! row the cursor moved below while a block runs; a progress bar redrawn
//! with CR commits only its last state.
//!
//! At most `max_blocks` blocks are kept; command lines and folders live in
//! one string arena that is compacted when half of it is dead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mark = @import("mark.zig");
const Terminal = @import("../term/Terminal.zig");
const PageList = @import("../screen/PageList.zig");
const Pin = PageList.Pin;

pub const BlockId = u32;

pub const State = enum { prompt, typing, running, finished, abandoned };

/// Who ran the command: the user at the prompt, or an agent through the
/// terminal service (E06.F07 sets it before writing the command).
pub const Owner = enum { user, agent };

/// A row and column (absolute row, as `Blocks` counts them).
pub const Pos = struct { row: u64, col: u16 = 0 };

/// A slice of the string arena.
const Str = struct { off: u32 = 0, len: u32 = 0 };

pub const Block = struct {
    id: BlockId,
    state: State = .prompt,
    owner: Owner = .user,
    /// The row the prompt starts on.
    prompt: u64,
    /// Where typing starts (B), if it came.
    input: ?Pos = null,
    /// The first output row (C), if the command ran.
    output: ?u64 = null,
    /// The row after the output (D), once finished.
    end: ?u64 = null,
    exit: ?i32 = null,
    /// `Terminal.now_ms` at C and D.
    started_ms: ?u64 = null,
    finished_ms: ?u64 = null,
    command: Str = .{},
    /// The command line came from E with the session's nonce.
    trusted: bool = false,
    /// Whether `command` was set (E or the screen).
    has_command: bool = false,
    cwd: Str = .{},
    /// The top of the block was evicted; `prompt` is the oldest kept row.
    truncated: bool = false,

    pub fn running(b: *const Block) bool {
        return b.state == .running;
    }
};

pub const BlockEvent = union(enum) {
    started: BlockId,
    /// `row` (absolute) is complete: the cursor moved below it.
    output: struct { id: BlockId, row: u64 },
    finished: struct { id: BlockId, exit: ?i32 },
    abandoned: BlockId,
};

/// Receives events from `flush`; must not block.
pub const BlockListener = struct {
    ctx: *anyopaque,
    onEvent: *const fn (ctx: *anyopaque, ev: BlockEvent) void,
};

pub const Options = struct {
    /// `terminal.blocks.max`.
    max_blocks: u32 = 10_000,
    /// Longest command line kept (bytes).
    max_command: u32 = 4096,
};

pub const Blocks = struct {
    gpa: Allocator,
    term: *Terminal,
    opts: Options,
    /// Oldest first; ids increase.
    list: std.ArrayList(Block) = .empty,
    next_id: BlockId = 1,
    strings: std.ArrayList(u8) = .empty,
    /// Bytes of `strings` no block refers to any more.
    dead: usize = 0,
    /// The working folder from the latest cwd mark.
    current_cwd: std.ArrayList(u8) = .empty,
    pending: std.ArrayList(BlockEvent) = .empty,
    listeners: std.ArrayList(BlockListener) = .empty,
    /// The cursor's absolute row after the last `afterFeed`.
    last_row: u64 = 0,

    pub fn init(gpa: Allocator, term: *Terminal, opts: Options) Blocks {
        return .{ .gpa = gpa, .term = term, .opts = opts };
    }

    pub fn deinit(b: *Blocks) void {
        if (b.term.mark_sink) |s| if (s.ctx == @as(*anyopaque, b)) {
            b.term.mark_sink = null;
        };
        b.list.deinit(b.gpa);
        b.strings.deinit(b.gpa);
        b.current_cwd.deinit(b.gpa);
        b.pending.deinit(b.gpa);
        b.listeners.deinit(b.gpa);
    }

    /// Makes `b` the terminal's mark sink.
    pub fn attach(b: *Blocks) void {
        b.term.mark_sink = .{ .ctx = b, .onMarkFn = onMarkErased };
        b.last_row = b.cursorRow();
    }

    pub fn addListener(b: *Blocks, l: BlockListener) !void {
        try b.listeners.append(b.gpa, l);
    }

    pub fn removeListener(b: *Blocks, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < b.listeners.items.len) {
            if (b.listeners.items[i].ctx == ctx) _ = b.listeners.orderedRemove(i) else i += 1;
        }
    }

    // -- queries --------------------------------------------------------------

    pub fn items(b: *const Blocks) []const Block {
        return b.list.items;
    }

    /// The newest block, if any.
    pub fn current(b: *const Blocks) ?*const Block {
        if (b.list.items.len == 0) return null;
        return &b.list.items[b.list.items.len - 1];
    }

    pub fn get(b: *const Blocks, id: BlockId) ?*const Block {
        const i = b.indexOf(id) orelse return null;
        return &b.list.items[i];
    }

    /// The block whose rows include absolute `row`, if any.
    pub fn at(b: *const Blocks, row: u64) ?*const Block {
        const i = b.indexAt(row) orelse return null;
        const blk = &b.list.items[i];
        if (blk.end) |e| if (row >= e and e > blk.prompt) return null;
        return blk;
    }

    /// The index of the last block starting at or before `row`.
    pub fn indexAt(b: *const Blocks, row: u64) ?usize {
        const xs = b.list.items;
        var lo: usize = 0;
        var hi: usize = xs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (xs[mid].prompt <= row) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) null else lo - 1;
    }

    /// The command line of `id` (empty when unknown).
    pub fn commandText(b: *const Blocks, id: BlockId) []const u8 {
        const blk = b.get(id) orelse return "";
        return b.str(blk.command);
    }

    /// The working folder `id` ran in (empty when unknown).
    pub fn cwdOf(b: *const Blocks, id: BlockId) []const u8 {
        const blk = b.get(id) orelse return "";
        return b.str(blk.cwd);
    }

    /// The output rows of `id`: [first, end) absolute rows; null while it
    /// has not run. A running block's output ends at the cursor row + 1.
    pub fn outputRange(b: *const Blocks, id: BlockId) ?[2]u64 {
        const i = b.indexOf(id) orelse return null;
        const blk = &b.list.items[i];
        const first = blk.output orelse return null;
        const end = blk.end orelse if (i + 1 < b.list.items.len) b.list.items[i + 1].prompt else b.cursorRow() + 1;
        return .{ first, @max(first, end) };
    }

    /// The index of the first block starting after `row` / the last one
    /// starting before it (navigation).
    pub fn nextAfter(b: *const Blocks, row: u64) ?*const Block {
        for (b.list.items) |*blk| if (blk.prompt > row) return blk;
        return null;
    }

    pub fn prevBefore(b: *const Blocks, row: u64) ?*const Block {
        var i = b.list.items.len;
        while (i > 0) {
            i -= 1;
            if (b.list.items[i].prompt < row) return &b.list.items[i];
        }
        return null;
    }

    /// Marks the newest block as run by an agent (E06.F07).
    pub fn setOwner(b: *Blocks, id: BlockId, owner: Owner) void {
        const i = b.indexOf(id) orelse return;
        b.list.items[i].owner = owner;
    }

    // -- the owner's hooks ----------------------------------------------------

    /// After `Terminal.feed`: drops evicted blocks and queues `output`
    /// events for rows the cursor moved below.
    pub fn afterFeed(b: *Blocks) void {
        b.prune();
        if (b.term.alt_active) return;
        const row = b.cursorRow();
        defer b.last_row = row;
        if (row <= b.last_row) return;
        const blk = b.lastMut() orelse return;
        if (blk.state == .running) b.commitRows(blk, row);
    }

    /// Queues `output` for the rows of `blk` from `last_row` up to `row`.
    fn commitRows(b: *Blocks, blk: *const Block, row: u64) void {
        var r = @max(b.last_row, blk.output orelse return);
        while (r < row) : (r += 1) b.queue(.{ .output = .{ .id = blk.id, .row = r } });
        b.last_row = @max(b.last_row, row);
    }

    /// Delivers the queued events.
    pub fn flush(b: *Blocks) void {
        if (b.pending.items.len == 0) return;
        // Listeners may add marks of their own; deliver a stable copy.
        var evs = b.pending;
        b.pending = .empty;
        defer {
            evs.clearRetainingCapacity();
            if (b.pending.items.len == 0) {
                b.pending.deinit(b.gpa);
                b.pending = evs;
            } else evs.deinit(b.gpa);
        }
        for (evs.items) |ev| for (b.listeners.items) |l| l.onEvent(l.ctx, ev);
    }

    /// After a resize (reflow) or decoding cold rows: puts each block back
    /// on the rows that now carry its marks.
    pub fn resync(b: *Blocks) void {
        b.prune();
        const pl = &b.term.primary.pages;
        const first_hot = pl.evicted + pl.coldRows();
        // The marked hot rows, in order.
        var prompts: std.ArrayList(u64) = .empty;
        defer prompts.deinit(b.gpa);
        var outs: std.ArrayList(u64) = .empty;
        defer outs.deinit(b.gpa);
        var ends: std.ArrayList(u64) = .empty;
        defer ends.deinit(b.gpa);
        var p: ?Pin = pl.firstHot();
        var row = first_hot;
        while (p) |pin| : ({
            p = PageList.next(pin);
            row += 1;
        }) {
            const list = switch (pin.row().mark) {
                .prompt => &prompts,
                .output_start => &outs,
                .output_end => &ends,
                else => continue,
            };
            list.append(b.gpa, row) catch return;
        }
        // The newest blocks take the newest prompt marks.
        const xs = b.list.items;
        const n = @min(xs.len, prompts.items.len);
        const base = xs.len - n;
        const pbase = prompts.items.len - n;
        var old: std.ArrayList(u64) = .empty;
        defer old.deinit(b.gpa);
        for (xs[base..]) |blk| old.append(b.gpa, blk.prompt) catch return;
        for (xs[base..], 0..) |*blk, k| {
            const old_prompt = old.items[k];
            const old_next = if (k + 1 < n) old.items[k + 1] else null;
            blk.prompt = prompts.items[pbase + k];
            const limit = if (k + 1 < n) prompts.items[pbase + k + 1] else std.math.maxInt(u64);
            if (blk.input) |*in| in.row = blk.prompt + (in.row -| old_prompt);
            if (blk.output) |o| blk.output = firstIn(outs.items, blk.prompt, limit) orelse blk.prompt + (o -| old_prompt);
            if (blk.end) |e| {
                // An end on the next prompt's row lost its mark to it.
                blk.end = firstIn(ends.items, blk.prompt, limit) orelse
                    if (old_next != null and e == old_next.?) limit else blk.prompt + (e -| old_prompt);
            }
        }
        b.last_row = b.cursorRow();
    }

    // -- marks -----------------------------------------------------------------

    fn onMarkErased(ctx: *anyopaque, m: mark.Mark, at_pin: Pin) void {
        const b: *Blocks = @ptrCast(@alignCast(ctx));
        b.onMark(m, at_pin) catch b.term.allocFailed();
    }

    /// Applies one mark (the `MarkSink` callback).
    pub fn onMark(b: *Blocks, m: mark.Mark, at_pin: Pin) !void {
        if (b.term.alt_active) return;
        const pl = &b.term.primary.pages;
        const row = pl.evicted + pl.rowIndex(at_pin);
        const col = b.term.primary.cursor.x;
        switch (m) {
            .prompt_start => |o| {
                if (o.kind != .initial) return;
                if (b.lastMut()) |last| switch (last.state) {
                    .prompt, .typing => {
                        last.state = .abandoned;
                        last.end = row;
                        b.queue(.{ .abandoned = last.id });
                    },
                    .running => b.finish(last, row, null),
                    .finished, .abandoned => {},
                };
                try b.startBlock(row);
                setRowMark(at_pin, .prompt, true);
            },
            .input_start => {
                const last = b.lastMut() orelse return;
                if (last.state != .prompt) return;
                last.input = .{ .row = row, .col = col };
                last.state = .typing;
            },
            .command_line => |c| {
                const last = b.lastMut() orelse return;
                if (last.state != .prompt and last.state != .typing) return;
                b.release(last.command);
                last.command = try b.dupe(c.text[0..@min(c.text.len, b.opts.max_command)]);
                last.trusted = c.trusted;
                last.has_command = true;
            },
            .command_executed => {
                const last = b.lastMut() orelse return;
                if (last.state != .prompt and last.state != .typing) return;
                if (!last.has_command) if (last.input) |in| {
                    var text: std.ArrayList(u8) = .empty;
                    defer text.deinit(b.gpa);
                    try b.readScreen(in, row, &text);
                    last.command = try b.dupe(text.items);
                    last.trusted = false;
                    last.has_command = true;
                };
                b.release(last.cwd);
                last.cwd = try b.dupe(b.current_cwd.items);
                last.output = row;
                last.started_ms = b.term.now_ms;
                last.state = .running;
                b.last_row = row;
                setRowMark(at_pin, .output_start, false);
                b.queue(.{ .started = last.id });
            },
            .command_finished => |code| {
                const last = b.lastMut() orelse return;
                if (last.state != .running) return;
                b.finish(last, row, code);
                setRowMark(at_pin, .output_end, false);
            },
            .cwd => |path| {
                b.current_cwd.clearRetainingCapacity();
                try b.current_cwd.appendSlice(b.gpa, path);
            },
            .property, .bookmark => {},
        }
    }

    fn startBlock(b: *Blocks, row: u64) !void {
        if (b.list.items.len >= b.opts.max_blocks) b.dropFront(b.list.items.len + 1 - b.opts.max_blocks);
        try b.list.append(b.gpa, .{ .id = b.next_id, .prompt = row, .cwd = try b.dupe(b.current_cwd.items) });
        b.next_id +%= 1;
    }

    fn finish(b: *Blocks, blk: *Block, row: u64, code: ?i32) void {
        b.commitRows(blk, row);
        blk.end = row;
        blk.exit = code;
        blk.finished_ms = b.term.now_ms;
        blk.state = .finished;
        b.queue(.{ .finished = .{ .id = blk.id, .exit = code } });
    }

    fn queue(b: *Blocks, ev: BlockEvent) void {
        b.pending.append(b.gpa, ev) catch b.term.allocFailed();
    }

    // -- eviction ---------------------------------------------------------------

    /// Drops blocks that ended above the oldest kept row and truncates the
    /// one that started there.
    fn prune(b: *Blocks) void {
        const lowest = b.term.primary.pages.evicted;
        var n: usize = 0;
        for (b.list.items) |*blk| {
            const gone = if (blk.end) |e| e <= lowest and blk.state != .running else false;
            if (!gone) break;
            n += 1;
        }
        if (n < b.list.items.len) {
            const first = &b.list.items[n];
            if (first.prompt < lowest) {
                first.prompt = lowest;
                first.truncated = true;
                if (first.input) |in| if (in.row < lowest) {
                    first.input = null;
                };
                if (first.output) |o| first.output = @max(o, lowest);
            }
        }
        if (n > 0) b.dropFront(n);
    }

    fn dropFront(b: *Blocks, n: usize) void {
        for (b.list.items[0..n]) |blk| {
            b.release(blk.command);
            b.release(blk.cwd);
        }
        const rest = b.list.items.len - n;
        std.mem.copyForwards(Block, b.list.items[0..rest], b.list.items[n..]);
        b.list.items.len = rest;
        if (b.dead * 2 > b.strings.items.len and b.strings.items.len > 4096) b.compactStrings();
    }

    // -- strings ------------------------------------------------------------------

    fn str(b: *const Blocks, s: Str) []const u8 {
        return b.strings.items[s.off..][0..s.len];
    }

    fn dupe(b: *Blocks, s: []const u8) !Str {
        if (s.len == 0) return .{};
        const off = b.strings.items.len;
        try b.strings.appendSlice(b.gpa, s);
        return .{ .off = @intCast(off), .len = @intCast(s.len) };
    }

    fn release(b: *Blocks, s: Str) void {
        b.dead += s.len;
    }

    fn compactStrings(b: *Blocks) void {
        var fresh: std.ArrayList(u8) = .empty;
        fresh.ensureTotalCapacity(b.gpa, b.strings.items.len - b.dead) catch return;
        for (b.list.items) |*blk| {
            inline for (.{ "command", "cwd" }) |f| {
                const s = @field(blk, f);
                const off = fresh.items.len;
                fresh.appendSliceAssumeCapacity(b.str(s));
                @field(blk, f) = .{ .off = @intCast(off), .len = s.len };
            }
        }
        b.strings.deinit(b.gpa);
        b.strings = fresh;
        b.dead = 0;
    }

    // -- helpers ------------------------------------------------------------------

    fn lastMut(b: *Blocks) ?*Block {
        if (b.list.items.len == 0) return null;
        return &b.list.items[b.list.items.len - 1];
    }

    fn indexOf(b: *const Blocks, id: BlockId) ?usize {
        const xs = b.list.items;
        if (xs.len == 0 or id < xs[0].id) return null;
        // Ids are consecutive unless they wrapped; try the direct slot first.
        const guess = id - xs[0].id;
        if (guess < xs.len and xs[guess].id == id) return guess;
        for (xs, 0..) |blk, i| if (blk.id == id) return i;
        return null;
    }

    fn cursorRow(b: *const Blocks) u64 {
        const s = &b.term.primary;
        return s.pages.evicted + s.pages.rowIndex(s.rowPin(s.cursor.y));
    }

    /// The text between `from` and the row `to` (exclusive): soft wraps
    /// joined, trailing blanks trimmed.
    fn readScreen(b: *Blocks, from: Pos, to: u64, out: *std.ArrayList(u8)) !void {
        const pl = &b.term.primary.pages;
        var row = from.row;
        var line_start = out.items.len;
        while (row < to or row == from.row) : (row += 1) {
            if (row < pl.evicted) continue;
            const pin = pl.screenRow(row - pl.evicted) orelse break;
            const cells = pin.cells();
            const start: usize = if (row == from.row) @min(from.col, cells.len) else 0;
            for (cells[start..]) |c| {
                if (c.wide == .spacer_tail or c.wide == .spacer_head) continue;
                const cp = c.codepoint();
                var buf: [4]u8 = undefined;
                const n = if (cp == 0) blk: {
                    buf[0] = ' ';
                    break :blk 1;
                } else std.unicode.utf8Encode(cp, &buf) catch continue;
                try out.appendSlice(b.gpa, buf[0..n]);
                if (pin.node.page.grapheme(&c)) |extra| for (extra) |x| {
                    const k = std.unicode.utf8Encode(x, &buf) catch continue;
                    try out.appendSlice(b.gpa, buf[0..k]);
                };
            }
            if (pin.row().wrap and row + 1 < to) continue;
            while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
            if (row + 1 >= to) break;
            try out.append(b.gpa, '\n');
            line_start = out.items.len;
        }
        while (out.items.len > 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\n')) out.items.len -= 1;
        if (out.items.len > b.opts.max_command) out.items.len = b.opts.max_command;
    }
};

fn firstIn(rows: []const u64, lo: u64, hi: u64) ?u64 {
    for (rows) |r| if (r >= lo and r < hi) return r;
    return null;
}

/// Marks the pinned row for reflow and rendering; `force` overrides an
/// existing mark (the prompt wins over an output end on the same row).
fn setRowMark(p: Pin, m: @import("../screen/cell.zig").Mark, force: bool) void {
    const r = p.row();
    if (force or r.mark == .none) r.mark = m;
}
