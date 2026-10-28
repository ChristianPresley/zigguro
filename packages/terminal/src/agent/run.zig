//! A command an agent runs in an interactive shell (E06.F07.S01.T01): the
//! headless half of the terminal service. The owner checks `readiness`,
//! writes `commandBytes` to the shell and feeds the terminal's block
//! events to `Run.onEvent`; the run binds to the next block the shell
//! starts, collects its output as logical lines (soft wraps joined,
//! trailing blanks trimmed) as rows complete, and ends with the block's
//! exit code.
//!
//! Nothing here locks: `onEvent` runs where the terminal is fed (the UI
//! thread); an owner that lets other threads read a run guards it with
//! its own lock.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Terminal = @import("../term/Terminal.zig");
const blocks_mod = @import("../shell/blocks.zig");
const Blocks = blocks_mod.Blocks;
const BlockEvent = blocks_mod.BlockEvent;
const BlockId = blocks_mod.BlockId;
const PageList = @import("../screen/PageList.zig");
const Cell = @import("../screen/cell.zig").Cell;

pub const Readiness = enum {
    /// No shell integration: there are no blocks to bind a run to.
    inactive,
    /// A command runs, or the user has typed at the prompt.
    busy,
    /// At an empty prompt.
    ready,
};

/// Whether a command can be written to the shell now.
pub fn readiness(b: *const Blocks) Readiness {
    const cur = b.current() orelse return .inactive;
    switch (cur.state) {
        .prompt => return .ready,
        .typing => {
            // Whatever is between the input mark and the end of the
            // screen must be blank.
            const in = cur.input orelse return .ready;
            const s = &b.term.primary;
            const pl = &s.pages;
            var row = in.row;
            const last = pl.evicted + pl.rowIndex(s.rowPin(s.height() - 1));
            while (row <= last) : (row += 1) {
                if (row < pl.evicted) continue;
                const pin = pl.screenRow(row - pl.evicted) orelse break;
                const cells = pin.cells();
                const start: usize = if (row == in.row) @min(in.col, cells.len) else 0;
                for (cells[start..]) |c| if (!c.isEmpty() and c.codepoint() != ' ') return .busy;
            }
            return .ready;
        },
        .running => return .busy,
        .finished, .abandoned => return .ready,
    }
}

/// The bytes that type `command` at the prompt and run it: bracketed when
/// the shell asked for bracketed paste (so a multi-line command runs as
/// one), then Enter.
pub fn commandBytes(gpa: Allocator, term: *const Terminal, command: []const u8, out: *std.ArrayList(u8)) !void {
    const bracketed = term.modes.get(.bracketed_paste);
    if (bracketed) try out.appendSlice(gpa, "\x1b[200~");
    for (command) |ch| {
        // Nothing may end the paste early or reach the shell as a control
        // key; newlines inside a paste are kept.
        if (ch == 0x1b or (ch < 0x20 and ch != '\n' and ch != '\t') or ch == 0x7f) continue;
        try out.append(gpa, if (ch == '\n' and !bracketed) ' ' else ch);
    }
    if (bracketed) try out.appendSlice(gpa, "\x1b[201~");
    try out.append(gpa, '\r');
}

pub const Run = struct {
    gpa: Allocator,
    command: []u8,
    state: State = .pending,
    block: ?BlockId = null,
    exit: ?i32 = null,
    /// The shell reported a different command line than the one written.
    mismatch: bool = false,
    lines: std.ArrayList([]u8) = .empty,
    /// A logical line continuing on the next row (soft wrap).
    partial: std.ArrayList(u8) = .empty,
    /// Lines kept; later output is dropped and noted once.
    max_lines: usize = 200_000,
    dropped: bool = false,
    /// The next output row to read; null until the block has output.
    next_row: ?u64 = null,

    pub const State = enum { pending, running, finished, abandoned };

    pub fn init(gpa: Allocator, command: []const u8) !Run {
        return .{ .gpa = gpa, .command = try gpa.dupe(u8, command) };
    }

    pub fn deinit(r: *Run) void {
        for (r.lines.items) |l| r.gpa.free(l);
        r.lines.deinit(r.gpa);
        r.partial.deinit(r.gpa);
        r.gpa.free(r.command);
    }

    pub fn done(r: *const Run) bool {
        return r.state == .finished or r.state == .abandoned;
    }

    /// Feeds one of the terminal's block events; true when the run
    /// changed (bound, new lines, ended).
    pub fn onEvent(r: *Run, b: *Blocks, ev: BlockEvent) bool {
        switch (ev) {
            .started => |id| {
                if (r.state != .pending) return false;
                r.state = .running;
                r.block = id;
                b.setOwner(id, .agent);
                r.mismatch = !sameCommand(b.commandText(id), r.command);
                if (b.get(id)) |blk| r.next_row = blk.output;
                return true;
            },
            .output => |o| {
                if (r.block != o.id or r.state != .running) return false;
                if (r.next_row == null) r.next_row = if (b.get(o.id)) |blk| blk.output orelse o.row else o.row;
                return r.readTo(b.term, o.row + 1);
            },
            .finished => |f| {
                if (r.block != f.id or r.state != .running) return false;
                if (b.get(f.id)) |blk| if (blk.end) |e| {
                    if (r.next_row == null) r.next_row = blk.output;
                    _ = r.readTo(b.term, e);
                    // Output without a final newline ends mid-row.
                    if (blk.end_col > 0 and r.next_row == e) r.readCells(b.term, e, blk.end_col);
                };
                if (r.partial.items.len > 0) r.flushPartial();
                r.state = .finished;
                r.exit = f.exit;
                return true;
            },
            .abandoned => |id| {
                if (r.block != id or r.done()) return false;
                if (r.partial.items.len > 0) r.flushPartial();
                r.state = .abandoned;
                return true;
            },
        }
    }

    /// Reads output rows up to `end` (exclusive).
    fn readTo(r: *Run, term: *Terminal, end: u64) bool {
        const pl = &term.primary.pages;
        var changed = false;
        var row = r.next_row orelse return false;
        defer r.next_row = row;
        while (row < end) : (row += 1) {
            // Rows already evicted or cold are skipped.
            if (row < pl.evicted + pl.coldRows()) continue;
            const pin = pl.screenRow(row - pl.evicted) orelse break;
            r.appendCells(pin, pin.cells());
            if (!pin.row().wrap) {
                r.flushPartial();
                changed = true;
            }
        }
        return changed;
    }

    /// Appends the first `cols` cells of `row` to the partial line.
    fn readCells(r: *Run, term: *Terminal, row: u64, cols: u16) void {
        const pl = &term.primary.pages;
        if (row < pl.evicted + pl.coldRows()) return;
        const pin = pl.screenRow(row - pl.evicted) orelse return;
        const cells = pin.cells();
        r.appendCells(pin, cells[0..@min(cols, cells.len)]);
    }

    fn appendCells(r: *Run, pin: PageList.Pin, cells: []const Cell) void {
        for (cells) |*c| {
            if (c.wide == .spacer_tail or c.wide == .spacer_head) continue;
            const cp = c.codepoint();
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(if (cp == 0) ' ' else cp, &buf) catch continue;
            r.partial.appendSlice(r.gpa, buf[0..n]) catch return;
            if (pin.node.page.grapheme(c)) |extra| for (extra) |e| {
                const k = std.unicode.utf8Encode(e, &buf) catch continue;
                r.partial.appendSlice(r.gpa, buf[0..k]) catch return;
            };
        }
    }

    fn flushPartial(r: *Run) void {
        defer r.partial.clearRetainingCapacity();
        if (r.lines.items.len >= r.max_lines) {
            if (r.dropped) return;
            r.dropped = true;
            const note = r.gpa.dupe(u8, "[output limit reached; later lines were dropped]") catch return;
            r.lines.append(r.gpa, note) catch r.gpa.free(note);
            return;
        }
        const line = std.mem.trimEnd(u8, r.partial.items, " ");
        const copy = r.gpa.dupe(u8, line) catch return;
        r.lines.append(r.gpa, copy) catch r.gpa.free(copy);
    }
};

/// Equal ignoring runs of whitespace and the ends.
fn sameCommand(a: []const u8, b: []const u8) bool {
    var ia = std.mem.tokenizeAny(u8, a, " \t\r\n");
    var ib = std.mem.tokenizeAny(u8, b, " \t\r\n");
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null or y == null) return x == null and y == null;
        if (!std.mem.eql(u8, x.?, y.?)) return false;
    }
}
