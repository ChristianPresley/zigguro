//! Incremental search (GNU Emacs manual, "Incremental Search"): `C-s`
//! and `C-r`, and the regexp forms `C-M-s` and `C-M-r`.
//!
//! Each change to the search string searches again with a `FindSession`
//! (F06) from where the search started (forward) or from the current
//! match (backward), so the match grows in place while it can. Repeating
//! the key moves to the next match; when there is none the search is
//! "failing", and repeating it once more wraps around. `DEL` goes back
//! one step (the string and the match before the last key). The state
//! holds the match; the Emacs state moves point (to the match's end
//! going forward, its start going backward) and handles `RET` and `C-g`.

const std = @import("std");
const zg_regex = @import("zg_regex");
const find = @import("../../model/search/find.zig");
const document = @import("../../model/document.zig");
const regexp = @import("regexp.zig");

const Allocator = std.mem.Allocator;
const Document = document.Document;
pub const Range = find.Range;

pub const ISearch = struct {
    gpa: Allocator,
    backward: bool,
    regex: bool,
    /// Point when the search started.
    start: u64,
    query: std.ArrayList(u8) = .empty,
    match: ?Range = null,
    failing: bool = false,
    wrapped: bool = false,
    /// The pattern does not compile yet (regexp searches).
    incomplete: bool = false,
    stack: std.ArrayList(Frame) = .empty,
    session: ?*find.FindSession = null,

    const Frame = struct { query_len: usize, match: ?Range, failing: bool, wrapped: bool, backward: bool, incomplete: bool };

    pub fn init(gpa: Allocator, start: u64, backward: bool, regex: bool) ISearch {
        return .{ .gpa = gpa, .start = start, .backward = backward, .regex = regex };
    }

    pub fn deinit(s: *ISearch) void {
        s.stopSession();
        s.query.deinit(s.gpa);
        s.stack.deinit(s.gpa);
    }

    fn stopSession(s: *ISearch) void {
        if (s.session) |f| f.stop();
        s.session = null;
    }

    /// Where point goes: the end of the match going forward, its start
    /// going backward; the start point without a match.
    pub fn point(s: *const ISearch) u64 {
        const m = s.match orelse return s.start;
        return if (s.backward) m.start else m.end;
    }

    /// The prompt, as Emacs shows it in the echo area.
    pub fn prompt(s: *const ISearch, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}{s}{s}I-search{s}: {s}{s}", .{
            if (s.failing) "Failing " else "",
            if (s.wrapped) "Wrapped " else "",
            if (s.regex) "Regexp " else "",
            if (s.backward) " backward" else "",
            s.query.items,
            if (s.incomplete) " [incomplete input]" else "",
        }) catch buf[0..0];
    }

    fn push(s: *ISearch) !void {
        try s.stack.append(s.gpa, .{ .query_len = s.query.items.len, .match = s.match, .failing = s.failing, .wrapped = s.wrapped, .backward = s.backward, .incomplete = s.incomplete });
    }

    /// `DEL`: back to the state before the last key; false when there is
    /// nothing to go back to.
    pub fn pop(s: *ISearch, doc: *Document) !bool {
        const f = s.stack.pop() orelse return false;
        const changed = f.query_len != s.query.items.len;
        s.query.shrinkRetainingCapacity(f.query_len);
        s.match = f.match;
        s.failing = f.failing;
        s.wrapped = f.wrapped;
        s.backward = f.backward;
        s.incomplete = f.incomplete;
        if (changed) try s.compile(doc);
        return true;
    }

    /// Types text into the search string and searches again.
    pub fn addText(s: *ISearch, doc: *Document, text: []const u8) !void {
        try s.push();
        try s.query.appendSlice(s.gpa, text);
        try s.compile(doc);
        if (s.incomplete) return;
        if (s.failing) return; // still failing: Emacs does not search
        // Forward, the match may grow in place; backward, it may too
        // (the search starts at the current match's end).
        const anchor = if (s.match) |m| (if (s.backward) m.end else m.start) else s.start;
        if (s.backward) {
            const extended = s.backwardFrom(anchor, true);
            s.setResult(extended);
        } else s.setResult(s.forwardFrom(anchor));
    }

    /// Replaces the search string (`C-s C-s` reusing the last search).
    pub fn setQuery(s: *ISearch, doc: *Document, text: []const u8) !void {
        s.query.clearRetainingCapacity();
        try s.query.appendSlice(s.gpa, text);
        try s.compile(doc);
    }

    /// `C-s`/`C-r` again: the next match in direction `backward` (turning
    /// around when it differs), wrapping after a failure.
    pub fn repeat(s: *ISearch, doc: *Document, backward: bool) !void {
        try s.push();
        if (s.session == null) try s.compile(doc);
        if (s.incomplete or s.session == null) return;
        const turned = backward != s.backward;
        s.backward = backward;
        const pt = s.point();
        if (turned and s.match != null and !s.failing) {
            // Turning around stays on the same match, with point at its
            // other end.
            return;
        }
        if (s.failing) {
            // Wrap around.
            s.wrapped = true;
            const len = doc.len();
            const r = if (backward) s.backwardFrom(len, false) else s.forwardFrom(0);
            s.setResult(r);
            return;
        }
        const from = if (s.match) |m| (if (m.start == m.end) (if (backward) m.start -| 1 else m.end + 1) else pt) else pt;
        s.setResult(if (backward) s.backwardFrom(from, false) else s.forwardFrom(from));
    }

    fn setResult(s: *ISearch, r: ?Range) void {
        if (r) |m| {
            s.match = m;
            s.failing = false;
        } else s.failing = true;
    }

    /// The first match starting at or after `from`.
    fn forwardFrom(s: *ISearch, from: u64) ?Range {
        const f = s.session orelse return null;
        const n = f.index.count();
        const i = f.index.rank(from);
        return if (i < n) f.index.nth(i) else null;
    }

    /// The last match ending at or before `to` (or, when `grow`, starting
    /// before `to` and covering it, so a backward match can grow).
    fn backwardFrom(s: *ISearch, to: u64, grow: bool) ?Range {
        const f = s.session orelse return null;
        var i = f.index.rank(if (grow) to else to + 1);
        while (i > 0) {
            i -= 1;
            const m = f.index.nth(i);
            if (grow and m.start < to) {
                if (s.match) |cur| if (m.start == cur.start) return m;
            }
            if (m.end <= to) return m;
        }
        return null;
    }

    fn compile(s: *ISearch, doc: *Document) !void {
        s.stopSession();
        s.incomplete = false;
        if (s.query.items.len == 0) {
            s.match = null;
            s.failing = false;
            return;
        }
        var translated: ?[]u8 = null;
        defer if (translated) |t| s.gpa.free(t);
        if (s.regex) {
            translated = regexp.translate(s.gpa, s.query.items) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => {
                    s.incomplete = true;
                    return;
                },
            };
        }
        const pat = translated orelse s.query.items;
        var diag: zg_regex.Error = undefined;
        const f = find.FindSession.start(s.gpa, doc, .{ .pattern = pat, .regex = s.regex, .case = .smart }, .{ .start = 0, .end = doc.len() }, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                s.incomplete = true;
                return;
            },
        };
        s.session = f;
        try f.finish();
    }
};
