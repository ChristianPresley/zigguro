//! Semantic tokens over lexical highlighting.
//!
//! A `SemanticOverlay` holds one document's LSP semantic tokens, decoded
//! from the wire format (groups of five: line delta, start delta, length,
//! type, modifier bits) into byte ranges per line. Full results, delta
//! results (edits to the previous integer array) and range results all
//! decode the same way. Results arrive late: tokens computed for an older
//! document version are mapped through the line edits made since, and
//! lines edited after that version get none (they fall back to lexical
//! highlighting) until fresh tokens arrive. `mergeLine` lays a line's
//! semantic tokens over its lexical tokens; comments and strings keep
//! their lexical highlight, so escapes inside strings stay visible.

const std = @import("std");
const zg_core = @import("zg_core");
const names_mod = @import("../highlight_names.zig");
const scanner = @import("../lex/scanner.zig");
const highlighter = @import("../highlight/highlighter.zig");
const legend_mod = @import("legend.zig");

const Allocator = std.mem.Allocator;
const HighlightId = names_mod.HighlightId;
const Token = scanner.Token;
const LineSource = highlighter.LineSource;
const LineEdit = highlighter.LineEdit;
const CompiledLegend = legend_mod.CompiledLegend;
const Encoding = zg_core.utf8.Encoding;

/// One semantic token: bytes `[start, end)` of its line.
pub const SemToken = struct { start: u32, end: u32, hl: HighlightId };

/// One edit of a delta result: replace `delete_count` integers of the
/// previous array, from index `start`, with `data`.
pub const DeltaEdit = struct { start: u32, delete_count: u32, data: []const u32 };

/// Lexical families that keep their highlight under semantic tokens.
pub const default_keep = [_]HighlightId{ .comment, .string, .character };

/// Edits kept for mapping late results.
pub const max_log = 64;

const LineEntry = struct {
    /// Points into one of `SemanticOverlay.bufs`.
    toks: []const SemToken = &.{},
    /// Version of the last edit touching the line (0: never edited).
    edited_at: u64 = 0,
};

const LogEntry = struct { version: u64, edits: []LineEdit };

pub const SemanticOverlay = struct {
    gpa: Allocator,
    /// Column units of the server's positions.
    enc: Encoding = .utf16,
    lines: std.ArrayList(LineEntry) = .empty,
    /// The token storage: one buffer per installed result, so a result
    /// costs one allocation rather than one per line. A full result
    /// replaces every line and frees the older buffers; range results add
    /// buffers until `max_bufs`, then the live tokens are compacted.
    bufs: std.ArrayList([]SemToken) = .empty,
    /// The last full or delta result, for applying the next delta.
    raw: std.ArrayList(u32) = .empty,
    result_id: ?[]u8 = null,
    /// The document version the lines are in.
    version: u64 = 0,
    log: std.ArrayList(LogEntry) = .empty,
    /// Results older than this cannot be mapped any more.
    log_floor: u64 = 0,
    keep: std.StaticBitSet(HighlightId.count) = .initEmpty(),

    /// An overlay for a document of `line_count` lines at `version`.
    pub fn init(gpa: Allocator, line_count: u64, version: u64) Allocator.Error!SemanticOverlay {
        var o: SemanticOverlay = .{ .gpa = gpa, .version = version, .log_floor = version };
        try o.lines.appendNTimes(gpa, .{}, @intCast(line_count));
        o.setKeep(&default_keep);
        return o;
    }

    /// Frees everything.
    pub fn deinit(o: *SemanticOverlay) void {
        for (o.bufs.items) |b| o.gpa.free(b);
        o.bufs.deinit(o.gpa);
        o.lines.deinit(o.gpa);
        o.raw.deinit(o.gpa);
        if (o.result_id) |r| o.gpa.free(r);
        for (o.log.items) |e| o.gpa.free(e.edits);
        o.log.deinit(o.gpa);
        o.* = undefined;
    }

    /// Lexical highlights within any of `families` keep their highlight.
    pub fn setKeep(o: *SemanticOverlay, families: []const HighlightId) void {
        o.keep = .initEmpty();
        for (0..HighlightId.count) |i| {
            var c: ?HighlightId = @enumFromInt(i);
            while (c) |id| : (c = id.parent()) {
                if (std.mem.indexOfScalar(HighlightId, families, id) != null) {
                    o.keep.set(i);
                    break;
                }
            }
        }
    }

    /// The result id of the last full or delta result, for delta requests.
    pub fn lastResultId(o: *const SemanticOverlay) ?[]const u8 {
        return o.result_id;
    }

    /// The semantic tokens of `line` (none while it is edited and not yet
    /// re-tokenized).
    pub fn lineTokens(o: *const SemanticOverlay, line: u64) []const SemToken {
        if (line >= o.lines.items.len) return &.{};
        return o.lines.items[@intCast(line)].toks;
    }

    /// True if `line` changed after the tokens were computed.
    pub fn isStale(o: *const SemanticOverlay, line: u64, tokens_version: u64) bool {
        return line < o.lines.items.len and o.lines.items[@intCast(line)].edited_at > tokens_version;
    }

    /// Follows a document change to `new_version`: `edits` are in old
    /// line coordinates, sorted and disjoint (as `Highlighter.onEdits`).
    /// Edited lines lose their tokens.
    pub fn onEdits(o: *SemanticOverlay, edits: []const LineEdit, new_version: u64) Allocator.Error!void {
        const owned = try o.gpa.dupe(LineEdit, edits);
        errdefer o.gpa.free(owned);
        try o.log.ensureUnusedCapacity(o.gpa, 1);
        var i = edits.len;
        while (i > 0) {
            i -= 1;
            const e = edits[i];
            const first: usize = @intCast(e.first);
            const removed: usize = @intCast(e.removed);
            const inserted: usize = @intCast(e.inserted);
            std.debug.assert(first + removed <= o.lines.items.len);
            try o.lines.ensureUnusedCapacity(o.gpa, inserted -| removed);
            const fill = [_]LineEntry{.{ .edited_at = new_version }} ** 16;
            // Replace the removed entries with stale ones, 16 at a time.
            o.lines.replaceRangeAssumeCapacity(first, removed, fill[0..@min(inserted, 16)]);
            var done = @min(inserted, 16);
            while (done < inserted) {
                const n = @min(inserted - done, 16);
                o.lines.insertSliceAssumeCapacity(first + done, fill[0..n]);
                done += n;
            }
        }
        o.log.appendAssumeCapacity(.{ .version = new_version, .edits = owned });
        o.version = new_version;
        if (o.log.items.len > max_log) {
            const old = o.log.orderedRemove(0);
            o.gpa.free(old.edits);
            o.log_floor = old.version;
        }
    }

    /// Applies a full result computed for document `version`. False when
    /// the result is too old (or from the future) to map: re-request.
    pub fn applyFull(o: *SemanticOverlay, version: u64, result_id: ?[]const u8, data: []const u32, legend: *CompiledLegend, src: LineSource) Allocator.Error!bool {
        if (!o.mappable(version)) return false;
        o.raw.clearRetainingCapacity();
        try o.raw.appendSlice(o.gpa, data);
        try o.setResultId(result_id);
        try o.install(version, o.raw.items, legend, src, null);
        return true;
    }

    /// Applies a delta result against the previous full or delta result.
    /// False when it cannot apply (too old, or edits outside the previous
    /// array): drop the result id and re-request in full.
    pub fn applyDelta(o: *SemanticOverlay, version: u64, result_id: ?[]const u8, edits: []const DeltaEdit, legend: *CompiledLegend, src: LineSource) Allocator.Error!bool {
        if (!o.mappable(version) or o.result_id == null) return false;
        const order = try o.gpa.alloc(u32, edits.len);
        defer o.gpa.free(order);
        for (order, 0..) |*x, k| x.* = @intCast(k);
        std.mem.sort(u32, order, edits, struct {
            fn gt(es: []const DeltaEdit, a: u32, b: u32) bool {
                return es[a].start > es[b].start;
            }
        }.gt);
        // Back to front, so earlier indices stay valid; edits must not overlap.
        var limit: u64 = o.raw.items.len;
        for (order) |k| {
            const e = edits[k];
            if (@as(u64, e.start) + e.delete_count > limit) {
                o.dropResult();
                return false;
            }
            limit = e.start;
        }
        for (order) |k| {
            const e = edits[k];
            try o.raw.replaceRange(o.gpa, e.start, e.delete_count, e.data);
        }
        try o.setResultId(result_id);
        try o.install(version, o.raw.items, legend, src, null);
        return true;
    }

    /// Applies a range result: only lines `[first, end)` (in the result's
    /// version) change. Range results have no result id.
    pub fn applyRange(o: *SemanticOverlay, version: u64, first: u64, end: u64, data: []const u32, legend: *CompiledLegend, src: LineSource) Allocator.Error!bool {
        if (!o.mappable(version)) return false;
        try o.install(version, data, legend, src, .{ first, end });
        return true;
    }

    fn mappable(o: *const SemanticOverlay, version: u64) bool {
        return version <= o.version and version >= o.log_floor;
    }

    fn setResultId(o: *SemanticOverlay, id: ?[]const u8) Allocator.Error!void {
        const dup = if (id) |s| try o.gpa.dupe(u8, s) else null;
        if (o.result_id) |r| o.gpa.free(r);
        o.result_id = dup;
    }

    fn dropResult(o: *SemanticOverlay) void {
        if (o.result_id) |r| o.gpa.free(r);
        o.result_id = null;
        o.raw.clearRetainingCapacity();
    }

    /// Maps `line` of document `version` to the current version; null if
    /// an edit since touched it.
    fn mapLine(o: *const SemanticOverlay, version: u64, line: u64) ?u64 {
        var l = line;
        for (o.log.items) |entry| {
            if (entry.version <= version) continue;
            var delta: i128 = 0;
            const mapped = for (entry.edits) |e| {
                if (l < e.first) break @as(i128, l) + delta;
                if (l < e.first + e.removed) return null;
                delta += @as(i128, e.inserted) - @as(i128, e.removed);
            } else @as(i128, l) + delta;
            l = @intCast(mapped);
        }
        return l;
    }

    /// Decodes `data` (computed for `version`) and installs it on every
    /// line, or on the lines of `range` (in `version` coordinates).
    fn install(o: *SemanticOverlay, version: u64, data: []const u32, legend: *CompiledLegend, src: LineSource, range: ?[2]u64) Allocator.Error!void {
        std.debug.assert(src.lines == o.lines.items.len);
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(o.gpa);
        // Every token of the result, then where each line's run is.
        var store: std.ArrayList(SemToken) = .empty;
        defer store.deinit(o.gpa);
        const Run = struct { line: u64, off: u32, len: u32 };
        var runs: std.ArrayList(Run) = .empty;
        defer runs.deinit(o.gpa);
        // Current-coordinate lines the result covers, as [lo, hi).
        var lo: u64 = 0;
        var hi: u64 = o.lines.items.len;
        if (range) |r| {
            lo = o.mapForward(version, r[0]);
            hi = @min(hi, o.mapForward(version, r[1]));
        }
        try store.ensureTotalCapacity(o.gpa, data.len / 5);

        var line: u64 = 0;
        var col: u32 = 0;
        var cur_line: ?u64 = null;
        var run_start: usize = 0;
        var text: []const u8 = "";
        var ascii = true;
        const no_log = o.log.items.len == 0 or o.log.items[o.log.items.len - 1].version <= version;
        var k: usize = 0;
        while (k + 5 <= data.len) : (k += 5) {
            const dl = data[k];
            if (dl != 0) col = 0;
            line += dl;
            col +%= data[k + 1];
            const len = data[k + 2];
            const target = if (no_log) line else o.mapLine(version, line) orelse continue;
            if (target < lo or target >= hi) continue;
            if (cur_line == null or cur_line.? != target) {
                if (cur_line) |c| try runs.append(o.gpa, .{ .line = c, .off = @intCast(run_start), .len = @intCast(store.items.len - run_start) });
                run_start = store.items.len;
                cur_line = target;
                text = try src.get(target, &scratch, o.gpa);
                ascii = allAscii(text);
            }
            // On an ASCII line every encoding's columns are bytes.
            var s: u32 = if (ascii) @min(col, @as(u32, @intCast(text.len))) else @intCast(zg_core.utf8.columnToByte(text, col, o.enc));
            const e: u32 = if (ascii) @min(col +| len, @as(u32, @intCast(text.len))) else @intCast(zg_core.utf8.columnToByte(text, col +| len, o.enc));
            const run = store.items[run_start..];
            if (run.len > 0) s = @max(s, run[run.len - 1].end);
            if (s >= e) continue;
            const hl = try legend.resolve(data[k + 3], data[k + 4]);
            if (hl == .none) continue;
            try store.append(o.gpa, .{ .start = s, .end = e, .hl = hl });
        }
        if (cur_line) |c| try runs.append(o.gpa, .{ .line = c, .off = @intCast(run_start), .len = @intCast(store.items.len - run_start) });

        const buf = try store.toOwnedSlice(o.gpa);
        o.bufs.append(o.gpa, buf) catch |err| {
            o.gpa.free(buf);
            return err;
        };
        // Lines in [lo, hi) not reached by any token are cleared; a line
        // edited after `version` keeps having no tokens.
        var next_clear: u64 = lo;
        for (runs.items) |r| {
            while (next_clear < r.line) : (next_clear += 1) o.setLine(next_clear, &.{}, version);
            next_clear = r.line + 1;
            o.setLine(r.line, buf[r.off..][0..r.len], version);
        }
        while (next_clear < hi) : (next_clear += 1) o.setLine(next_clear, &.{}, version);
        if (range == null) {
            // Every line now points into `buf` or has no tokens.
            for (o.bufs.items[0 .. o.bufs.items.len - 1]) |b| o.gpa.free(b);
            o.bufs.replaceRangeAssumeCapacity(0, o.bufs.items.len - 1, &.{});
        } else if (o.bufs.items.len > max_bufs) try o.compact();
    }

    fn allAscii(t: []const u8) bool {
        for (t) |c| if (c >= 0x80) return false;
        return true;
    }

    /// Range results kept as separate buffers before compacting.
    const max_bufs = 8;

    /// Copies the live tokens into one buffer and frees the others.
    fn compact(o: *SemanticOverlay) Allocator.Error!void {
        var n: usize = 0;
        for (o.lines.items) |l| n += l.toks.len;
        const buf = try o.gpa.alloc(SemToken, n);
        try o.bufs.ensureUnusedCapacity(o.gpa, 1);
        var at: usize = 0;
        for (o.lines.items) |*l| {
            @memcpy(buf[at..][0..l.toks.len], l.toks);
            l.toks = buf[at..][0..l.toks.len];
            at += l.toks.len;
        }
        for (o.bufs.items) |b| o.gpa.free(b);
        o.bufs.clearRetainingCapacity();
        o.bufs.appendAssumeCapacity(buf);
    }

    /// Maps a line boundary of `version` forward (edited lines map to the
    /// start of their replacement).
    fn mapForward(o: *const SemanticOverlay, version: u64, line: u64) u64 {
        var l = line;
        for (o.log.items) |entry| {
            if (entry.version <= version) continue;
            var delta: i128 = 0;
            for (entry.edits) |e| {
                if (l < e.first) break;
                if (l < e.first + e.removed) {
                    l = e.first;
                    break;
                }
                delta += @as(i128, e.inserted) - @as(i128, e.removed);
            }
            l = @intCast(@as(i128, l) + delta);
        }
        return l;
    }

    fn setLine(o: *SemanticOverlay, line: u64, toks: []const SemToken, version: u64) void {
        const entry = &o.lines.items[@intCast(line)];
        // A line edited after `version` keeps having no tokens.
        if (entry.edited_at > version) return;
        entry.toks = toks;
    }

    /// Lays `line`'s semantic tokens over its `lexical` tokens (`line_len`
    /// bytes long) into `out`. Semantic highlights replace lexical ones,
    /// except in the kept families; token kinds stay lexical.
    pub fn mergeLine(o: *const SemanticOverlay, line: u64, lexical: []const Token, line_len: u32, out: *std.ArrayList(Token), gpa: Allocator) Allocator.Error!void {
        out.clearRetainingCapacity();
        const sem = o.lineTokens(line);
        if (sem.len == 0) return out.appendSlice(gpa, lexical);
        try out.ensureTotalCapacity(gpa, lexical.len + 2 * sem.len + 1);
        var li: usize = 0;
        var si: usize = 0;
        var pos: u32 = 0;
        var prev_li: usize = std.math.maxInt(usize);
        while (pos < line_len) {
            while (li + 1 < lexical.len and lexical[li + 1].start <= pos) li += 1;
            const have_lex = lexical.len > 0 and lexical[li].start <= pos;
            var end: u32 = if (li + 1 < lexical.len and have_lex) lexical[li + 1].start else if (lexical.len > 0 and !have_lex) lexical[0].start else line_len;
            const kind: u16 = if (have_lex) lexical[li].kind else 0;
            const lex_hl: HighlightId = if (have_lex) lexical[li].hl else .none;
            var hl = lex_hl;
            while (si < sem.len and sem[si].end <= pos) si += 1;
            if (si < sem.len) {
                if (sem[si].start <= pos) {
                    end = @min(end, sem[si].end);
                    const keep = @intFromEnum(lex_hl) < HighlightId.count and o.keep.isSet(@intFromEnum(lex_hl));
                    if (!keep) hl = sem[si].hl;
                } else end = @min(end, sem[si].start);
            }
            end = @min(@max(end, pos + 1), line_len);
            const items = out.items;
            const same_src = prev_li == li or kind & Token.atomic_bit == 0;
            if (items.len > 0 and items[items.len - 1].kind == kind and items[items.len - 1].hl == hl and same_src) {
                // Extends the previous token.
            } else {
                out.appendAssumeCapacity(.{ .start = pos, .kind = kind, .hl = hl });
            }
            prev_li = li;
            pos = end;
        }
    }
};
