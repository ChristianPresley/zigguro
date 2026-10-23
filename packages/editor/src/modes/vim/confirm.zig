//! `:s` with the `c` flag (`:s_c`): the matches and their replacements are
//! found when the command runs, then each key answers the prompt for the
//! next one: `y` substitutes, `n` skips, `a` substitutes this and the rest,
//! `l` substitutes this one and stops, `q`, Esc or Ctrl-C stop. Other keys
//! (`^E`/`^Y` included, there is no view to scroll) are ignored.
//!
//! As in Vim 9.1, each substitution is applied as it is accepted, every line
//! with accepted matches is its own undo step (the lines `a` covers share
//! the step of the line it was typed on), and the cursor ends on the last
//! match answered, or at column 0 of its line when that one was substituted
//! (the first non-blank after `a`).

const std = @import("std");
const state_mod = @import("state.zig");
const mode_mod = @import("../mode.zig");
const key_mod = @import("../key.zig");
const ops = @import("operators.zig");
const cs_mod = @import("../../model/edit/change_set.zig");

const VimState = state_mod.VimState;
const Host = mode_mod.Host;
const Key = key_mod.Key;

/// Vim's 'report': changes to more lines than this are reported.
const report = 2;

pub const Confirm = struct {
    arena: std.heap.ArenaAllocator,
    /// Matches in document order with their replacement text, in the
    /// document as it was when `:s` ran; `shift` maps them to now.
    edits: []cs_mod.Replace,
    /// The line of each match when `:s` ran.
    lines: []u64,
    /// For the prompt.
    replacement: []const u8,
    /// The match being asked about.
    i: usize = 0,
    shift: i64 = 0,
    /// The document version after the last substitution made here.
    version: u64,
    /// The line whose undo step is open.
    step_line: ?u64 = null,
    subs: usize = 0,
    sub_lines: usize = 0,
    last_line: ?u64 = null,
    /// Where the last substitution starts now.
    last_pos: u64 = 0,

    pub fn destroy(c: *Confirm, gpa: std.mem.Allocator) void {
        c.arena.deinit();
        gpa.destroy(c);
    }

    /// Where match `j` starts in the document now.
    fn pos(c: *const Confirm, j: usize) u64 {
        return @intCast(@as(i64, @intCast(c.edits[j].range.start)) + c.shift);
    }
};

/// Starts prompting for `edits` (copied); the cursor goes to the first.
pub fn start(vs: *VimState, host: *Host, edits: []const cs_mod.Replace, replacement: []const u8) !void {
    const gpa = vs.gpa;
    const c = try gpa.create(Confirm);
    errdefer gpa.destroy(c);
    c.* = .{ .arena = .init(gpa), .edits = &.{}, .lines = &.{}, .replacement = "", .version = host.doc.version };
    errdefer c.arena.deinit();
    const a = c.arena.allocator();
    const x = ops.txt(host);
    c.edits = try a.alloc(cs_mod.Replace, edits.len);
    c.lines = try a.alloc(u64, edits.len);
    for (edits, 0..) |ed, j| {
        c.edits[j] = .{ .range = ed.range, .text = try a.dupe(u8, ed.text) };
        c.lines[j] = x.lineOf(ed.range.start);
    }
    c.replacement = try a.dupe(u8, replacement[0..@min(replacement.len, 100)]);
    if (vs.confirm) |old| old.destroy(gpa);
    vs.confirm = c;
    try prompt(vs, host);
}

/// Ends a prompt without touching the document or the cursor (the
/// document went away).
pub fn cancel(vs: *VimState) void {
    if (vs.confirm) |c| c.destroy(vs.gpa);
    vs.confirm = null;
}

/// Answers the prompt with `k`.
pub fn key(vs: *VimState, k: Key, host: *Host) !void {
    const c = vs.confirm.?;
    if (host.doc.version != c.version) {
        try finish(vs, host, .stay);
        _ = vs.setMessage(true, "E: the document changed during :s with c", .{});
        vs.bell = true;
        return;
    }
    if (k.isEscape() or k.isCtrl('c')) return finish(vs, host, .{ .match = c.i });
    const ch = k.text() orelse return prompt(vs, host);
    switch (ch) {
        'y' => {
            try accept(vs, host, c.i, false);
            c.i += 1;
            if (c.i == c.edits.len) return finish(vs, host, .line_start);
        },
        'l' => {
            try accept(vs, host, c.i, false);
            return finish(vs, host, .line_start);
        },
        'n' => {
            c.i += 1;
            if (c.i == c.edits.len) return finish(vs, host, .{ .match = c.i - 1 });
        },
        'a' => {
            try accept(vs, host, c.i, false);
            for (c.i + 1..c.edits.len) |j| try accept(vs, host, j, true);
            return finish(vs, host, .first_non_blank);
        },
        'q' => return finish(vs, host, .{ .match = c.i }),
        else => {},
    }
    try prompt(vs, host);
}

fn prompt(vs: *VimState, host: *Host) !void {
    const c = vs.confirm.?;
    try setCursor(vs, host, c.pos(c.i));
    _ = vs.setMessage(false, "replace with {s} (y/n/a/q/l/^E/^Y)?", .{c.replacement});
}

fn setCursor(vs: *VimState, host: *Host, p: u64) !void {
    vs.cursors.clearRetainingCapacity();
    try vs.cursors.append(vs.gpa, .{ .pos = p, .want = ops.txt(host).column(p) });
}

fn accept(vs: *VimState, host: *Host, j: usize, same_step: bool) !void {
    const c = vs.confirm.?;
    const line = c.lines[j];
    const at = c.pos(j);
    if (!same_step and c.step_line != line) {
        if (c.step_line != null) try vs.commitChange(host);
        // Undo puts the cursor at the start of the line, as in Vim.
        const x = ops.txt(host);
        try setCursor(vs, host, x.lineStart(x.lineOf(at)));
        try vs.beginChange(host);
        c.step_line = line;
    }
    const ed = c.edits[j];
    const len = ed.range.end - ed.range.start;
    try ops.replace(host, at, at + len, ed.text);
    c.shift += @as(i64, @intCast(ed.text.len)) - @as(i64, @intCast(len));
    c.version = host.doc.version;
    c.subs += 1;
    if (c.last_line != line) c.sub_lines += 1;
    c.last_line = line;
    c.last_pos = at;
}

const End = union(enum) {
    /// Leave the cursor where it is.
    stay,
    /// On the start of match `n`.
    match: usize,
    /// Column 0 or the first non-blank of the last substituted line.
    line_start,
    first_non_blank,
};

fn finish(vs: *VimState, host: *Host, end: End) !void {
    const c = vs.confirm.?;
    defer cancel(vs);
    if (c.step_line != null) try vs.commitChange(host);
    const x = ops.txt(host);
    switch (end) {
        .stay => {},
        .match => |n| try setCursor(vs, host, x.clampNormal(c.pos(n))),
        .line_start, .first_non_blank => {
            const l = x.lineOf(c.last_pos);
            try setCursor(vs, host, if (end == .line_start) x.lineStart(l) else x.firstNonBlank(l));
        },
    }
    if (c.sub_lines > report) _ = vs.setMessage(false, "{d} substitution{s} on {d} line{s}", .{ c.subs, if (c.subs == 1) "" else "s", c.sub_lines, if (c.sub_lines == 1) "" else "s" });
}
