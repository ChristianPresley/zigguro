//! The persistent piece B+tree.
//!
//! A `PieceTree` value is cheap to copy and holds one reference to its root;
//! every version a document ever produced stays readable while someone holds
//! it. Edits never modify a shared node: they path-copy (see
//! `NodePool.makeMut`), so an edit costs O(log n) node copies and a snapshot
//! is just a retained root.
//!
//! Shape: leaves hold up to 32 pieces, internal nodes 16 children, all
//! leaves at the same depth. Edits are expressed as split and concatenate
//! (join by height, merging or redistributing the nodes that meet at the
//! seam), which keeps every non-root node at least half full.
//!
//! Coordinates: byte offsets (`u64`) everywhere. Lines are separated by
//! `\n`, `\r\n` or a lone `\r`; line `k` starts after the `k`-th terminator,
//! so an offset between the `\r` and `\n` of a CRLF belongs to the line the
//! CRLF ends. Columns are bytes (`Point`) or UTF-16 units (`PointUtf16`,
//! LSP), counted from the line start and clamped to `u32`.
//!
//! Pieces are at most `max_piece_len` bytes so that any scan inside one
//! piece (line lookup, UTF-16 conversion, piece splits) is bounded.
//!
//! Threading: queries and iterators on a `PieceTree` value may run on any
//! thread that holds a reference (a snapshot). Edits run on the owner
//! thread of the node pool and buffer table.

const std = @import("std");
const zg_utf8 = @import("zg_core").utf8;
const summary_mod = @import("summary.zig");
const buffers = @import("buffers.zig");
const pool_mod = @import("node_pool.zig");

const Allocator = std.mem.Allocator;
const Summary = summary_mod.Summary;
const LineState = summary_mod.LineState;
const Utf16State = summary_mod.Utf16State;
const Node = pool_mod.Node;
const NodePool = pool_mod.NodePool;
const Piece = buffers.Piece;
const BufferTable = buffers.BufferTable;
const leaf_max = pool_mod.leaf_max;
const inner_max = pool_mod.inner_max;

/// A byte range `[start, end)`.
pub const Range = struct {
    start: u64,
    end: u64,

    /// Length in bytes.
    pub fn len(r: Range) u64 {
        return r.end - r.start;
    }
};

/// A line and a byte column.
pub const Point = struct { line: u64, col: u32 };
/// A line and a UTF-16 column (LSP positions).
pub const PointUtf16 = struct { line: u64, col: u32 };

/// One replacement in old coordinates.
pub const Edit = struct { range: Range, text: []const u8 };

/// Longest piece. Original text is cut into pieces of this size at load.
pub const max_piece_len: u32 = 8 << 10;
/// Deepest tree the iterators support (16^7 * 32 pieces).
pub const max_height = 8;

/// Errors from edits.
pub const EditError = error{ OutOfMemory, BufferFull, OutOfBounds, Overlap };

const Ctx = struct {
    pool: *NodePool,
    bt: *BufferTable,
};

/// A version of the text. Holds one reference to `root`.
pub const PieceTree = struct {
    root: ?*Node,
    buffers: *BufferTable,

    /// An empty tree over `bt`.
    pub fn empty(bt: *BufferTable) PieceTree {
        return .{ .root = null, .buffers = bt };
    }

    /// A tree over the whole of `bt.original`, cut into pieces.
    pub fn fromOriginal(pool: *NodePool, bt: *BufferTable) Allocator.Error!PieceTree {
        const n = bt.original.len;
        const count = std.math.divCeil(usize, n, max_piece_len) catch unreachable;
        const pieces = try pool.gpa.alloc(Piece, count);
        defer pool.gpa.free(pieces);
        var off: usize = 0;
        for (pieces) |*p| {
            const plen = @min(max_piece_len, n - off);
            p.* = .{ .start = off, .len = @intCast(plen), .buf = .original };
            off += plen;
        }
        const c: Ctx = .{ .pool = pool, .bt = bt };
        return .{ .root = try buildFromPieces(c, pieces), .buffers = bt };
    }

    /// Another reference to the same version.
    pub fn clone(t: PieceTree) PieceTree {
        if (t.root) |r| r.retain();
        return t;
    }

    /// Drops this reference.
    pub fn deinit(t: *PieceTree, pool: *NodePool) void {
        if (t.root) |r| pool.release(r);
        t.root = null;
    }

    /// Summary of the whole text.
    pub fn summary(t: PieceTree) Summary {
        return if (t.root) |r| r.total else .empty;
    }

    /// Length in bytes.
    pub fn len(t: PieceTree) u64 {
        return t.summary().bytes;
    }

    /// Number of lines (at least 1; a trailing terminator starts an empty
    /// last line).
    pub fn lineCount(t: PieceTree) u64 {
        return t.summary().newlines + 1;
    }

    /// The tree's height (0 for empty or a single leaf).
    pub fn height(t: PieceTree) u8 {
        return if (t.root) |r| r.height else 0;
    }

    // -- edits -------------------------------------------------------------

    /// A new version with `text` inserted at `at`. `t` is unchanged.
    pub fn insert(t: PieceTree, pool: *NodePool, at: u64, text: []const u8) EditError!PieceTree {
        return t.replace(pool, &.{.{ .range = .{ .start = at, .end = at }, .text = text }});
    }

    /// A new version with `range` removed. `t` is unchanged.
    pub fn delete(t: PieceTree, pool: *NodePool, range: Range) EditError!PieceTree {
        return t.replace(pool, &.{.{ .range = range, .text = "" }});
    }

    /// A new version with every edit applied in one pass. `edits` are in
    /// old coordinates, sorted by start and non-overlapping (adjacent is
    /// fine). `t` is unchanged. On `OutOfMemory` nothing leaks but the
    /// partially built version is lost.
    pub fn replace(t: PieceTree, pool: *NodePool, edits: []const Edit) EditError!PieceTree {
        const total = t.len();
        var prev_end: u64 = 0;
        for (edits) |e| {
            if (e.range.start > e.range.end or e.range.end > total) return error.OutOfBounds;
            if (e.range.start < prev_end) return error.Overlap;
            prev_end = e.range.end;
        }
        const c: Ctx = .{ .pool = pool, .bt = t.buffers };
        // Fast path: every edit stays inside one leaf, so leaves are rebuilt
        // in place along copied paths (typing, backspace, multi-cursor).
        if (t.root) |root| if (try prepareLocal(c, root, edits)) {
            root.retain();
            var list: std.ArrayList(*Node) = .empty;
            defer list.deinit(pool.gpa);
            try applyLocal(c, root, edits, 0, &list);
            return .{ .root = try buildUpper(c, &list), .buffers = t.buffers };
        };
        // Each step consumes `rest` and `out`; on OutOfMemory the pieces in
        // flight leak rather than risk a double release.
        var rest: ?*Node = t.root;
        if (rest) |r| r.retain();
        var out: ?*Node = null;
        var consumed: u64 = 0;
        for (edits) |e| {
            if (e.range.start == e.range.end and e.text.len == 0) continue;
            const head = try split(c, rest, e.range.start - consumed);
            out = try concat(c, out, head.l);
            if (e.text.len > 0) {
                const mid = try buildFromText(c, e.text);
                out = try concat(c, out, mid);
            }
            const dead = try split(c, head.r, e.range.end - e.range.start);
            rest = dead.r;
            if (dead.l) |d| pool.release(d);
            consumed = e.range.end;
        }
        out = try concat(c, out, rest);
        return .{ .root = out, .buffers = t.buffers };
    }

    // -- queries -----------------------------------------------------------

    /// The byte at `off` (`off < len()`).
    pub fn byteAt(t: PieceTree, off: u64) u8 {
        const f = findPiece(t.root.?, off);
        return t.buffers.bytes(f.piece)[@intCast(off - f.start)];
    }

    /// Summary of `text[0..off]`.
    pub fn prefixSummary(t: PieceTree, off: u64) Summary {
        if (off == 0) return .empty;
        if (off >= t.len()) return t.summary();
        const s = seekBytes(t.root.?, off);
        const bytes = t.buffers.bytes(s.piece);
        return s.prefix.combine(Summary.of(bytes[0..@intCast(off - s.start)]));
    }

    /// Line-break state of `text[0..off]`, plus the byte at `off` (or
    /// null at the end).
    fn prefixLines(t: PieceTree, off: u64) struct { lines: LineState, next: ?u8 } {
        const root = t.root orelse return .{ .lines = .{}, .next = null };
        if (off >= root.total.bytes) return .{ .lines = (LineState{}).then(root.total), .next = null };
        var n = root;
        var base: u64 = 0;
        var acc: LineState = .{};
        while (true) {
            var i: usize = 0;
            if (n.isLeaf()) {
                const l = n.leaf();
                while (base + l.pieces[i].len <= off) : (i += 1) {
                    base += l.pieces[i].len;
                    acc = acc.then(l.sums[i]);
                }
                const bytes = t.buffers.bytes(l.pieces[i]);
                const k: usize = @intCast(off - base);
                return .{ .lines = acc.thenBytes(bytes[0..k]), .next = bytes[k] };
            }
            const in = n.inner();
            while (base + in.sums[i].bytes <= off) : (i += 1) {
                base += in.sums[i].bytes;
                acc = acc.then(in.sums[i]);
            }
            n = in.children[i];
        }
    }

    /// The line containing `off` (clamped to the text).
    pub fn lineOf(t: PieceTree, off_in: u64) u64 {
        const p = t.prefixLines(off_in);
        var line = p.lines.newlines;
        if (p.lines.ends_with_cr and p.next == '\n') line -= 1;
        return line;
    }

    /// Byte offset where `line` starts; lines past the end return `len()`.
    pub fn lineStart(t: PieceTree, line: u64) u64 {
        if (line == 0) return 0;
        const root = t.root orelse return 0;
        if (line > root.total.newlines) return root.total.bytes;
        // Descend to the piece where the prefix reaches `line` terminators.
        var n = root;
        var acc: LineState = .{};
        var base: u64 = 0;
        while (true) {
            var i: usize = 0;
            while (i < n.count) : (i += 1) {
                const s = n.sum(i);
                const next = acc.then(s);
                if (next.newlines >= line) break;
                acc = next;
                base += s.bytes;
            }
            std.debug.assert(i < n.count);
            if (n.isLeaf()) {
                const p = n.leaf().pieces[i];
                const bytes = t.buffers.bytes(p);
                const need = line - acc.newlines;
                var pos = base + findTerminatorEnd(bytes, need, acc.ends_with_cr);
                // A CRLF split across pieces: the line starts after the LF.
                if (pos < root.total.bytes and pos > 0 and t.byteAt(pos - 1) == '\r' and t.byteAt(pos) == '\n') pos += 1;
                return pos;
            }
            n = n.inner().children[i];
        }
    }

    /// Line and byte column of `off` (clamped to the text).
    pub fn offsetToPoint(t: PieceTree, off_in: u64) Point {
        const off = @min(off_in, t.len());
        const line = t.lineOf(off);
        if (t.localLineStart(off)) |ls| return .{ .line = line, .col = sat32(off - ls.start) };
        return .{ .line = line, .col = sat32(off - t.lineStart(line)) };
    }

    /// The start of the line containing `off` when it lies in the same
    /// piece (the common case), found by scanning back; null otherwise.
    /// Also returns the piece bytes from that line start to the piece end.
    fn localLineStart(t: PieceTree, off: u64) ?struct { start: u64, rest: []const u8 } {
        if (off == 0 or off >= t.len()) return null;
        const f = findPiece(t.root.?, off);
        const bytes = t.buffers.bytes(f.piece);
        const k: usize = @intCast(off - f.start);
        var j = k;
        while (j > 0) {
            j -= 1;
            const c = bytes[j];
            if (c == '\n' or c == '\r') {
                // Between the CR and LF of a CRLF: the line is the one the
                // CRLF ends; leave it to the general path.
                if (c == '\r' and j + 1 == k and bytes[k] == '\n') return null;
                return .{ .start = f.start + j + 1, .rest = bytes[j + 1 ..] };
            }
        }
        return null;
    }

    /// The byte range of `line` without its terminator, and the
    /// terminator's length (0 on the last line). Lines past the end give an
    /// empty range at `len()`.
    pub fn lineRange(t: PieceTree, line: u64) struct { start: u64, end: u64, eol_len: u2 } {
        const start = t.lineStart(line);
        if (line + 1 >= t.lineCount()) return .{ .start = start, .end = t.len(), .eol_len = 0 };
        const next = t.lineStart(line + 1);
        const eol: u2 = if (next >= 2 and t.byteAt(next - 1) == '\n' and t.byteAt(next - 2) == '\r') 2 else 1;
        return .{ .start = start, .end = next - eol, .eol_len = eol };
    }

    /// Offset of `p`; the column is clamped to the line's length (excluding
    /// its terminator) and lines past the end give `len()`.
    pub fn pointToOffset(t: PieceTree, p: Point) u64 {
        if (p.line >= t.lineCount()) return t.len();
        const r = t.lineRange(p.line);
        return @min(r.start + p.col, r.end);
    }

    /// UTF-16 units of `text[0..off]`, excluding a code point (or ill-formed
    /// subsequence) that straddles `off` — `zg_core.utf8.byteToColumn`
    /// semantics.
    fn unitsBefore(t: PieceTree, off: u64) u64 {
        const p = t.prefixUtf16(off);
        const u = p.state;
        if (u.n == 0) return u.units;
        if (p.next) |b| {
            const info = summary_mod.leadInfo(u.lead).?;
            const lo: u8 = if (u.n == 1) info.lo else 0x80;
            const hi: u8 = if (u.n == 1) info.hi else 0xBF;
            if (b >= lo and b <= hi) return u.units;
        }
        return u.total();
    }

    /// UTF-16 state of `text[0..off]` plus the byte at `off` (null at the
    /// end).
    fn prefixUtf16(t: PieceTree, off: u64) struct { state: Utf16State, next: ?u8 } {
        const root = t.root orelse return .{ .state = .{}, .next = null };
        if (off >= root.total.bytes) return .{ .state = .of(root.total), .next = null };
        var n = root;
        var base: u64 = 0;
        var acc: Utf16State = .{};
        while (true) {
            var i: usize = 0;
            if (n.isLeaf()) {
                const l = n.leaf();
                while (base + l.pieces[i].len <= off) : (i += 1) {
                    base += l.pieces[i].len;
                    acc = acc.then(l.sums[i]);
                }
                const bytes = t.buffers.bytes(l.pieces[i]);
                const k: usize = @intCast(off - base);
                return .{ .state = acc.then(Summary.of(bytes[0..k])), .next = bytes[k] };
            }
            const in = n.inner();
            while (base + in.sums[i].bytes <= off) : (i += 1) {
                base += in.sums[i].bytes;
                acc = acc.then(in.sums[i]);
            }
            n = in.children[i];
        }
    }

    /// Line and UTF-16 column of `off` (LSP position). An offset inside a
    /// code point maps to that code point's start.
    pub fn offsetToUtf16(t: PieceTree, off_in: u64) PointUtf16 {
        const off = @min(off_in, t.len());
        const line = t.lineOf(off);
        if (t.localLineStart(off)) |ls| {
            const k: usize = @intCast(off - ls.start);
            // A code point straddling the piece end needs the general path.
            if (k + 4 <= ls.rest.len) return .{ .line = line, .col = zg_utf8.byteToColumn(ls.rest, k, .utf16) };
        }
        const ls = t.lineStart(line);
        return .{ .line = line, .col = sat32(t.unitsBefore(off) - t.prefixUtf16(ls).state.total()) };
    }

    /// Offset of an LSP position. A column inside a surrogate pair maps to
    /// the code point's start; columns past the line end clamp to it (before
    /// the terminator); lines past the end give `len()`.
    pub fn utf16ToOffset(t: PieceTree, p: PointUtf16) u64 {
        if (p.line >= t.lineCount()) return t.len();
        const r = t.lineRange(p.line);
        const target = t.prefixUtf16(r.start).state.total() + p.col;
        return @min(t.offsetOfUnits(target), r.end);
    }

    /// The largest code point boundary whose unit count is <= `target`.
    fn offsetOfUnits(t: PieceTree, target: u64) u64 {
        const root = t.root orelse return 0;
        if (target >= root.total.utf16Total()) return root.total.bytes;
        var n = root;
        var acc: Summary = .empty;
        var base: u64 = 0;
        while (true) {
            var i: usize = 0;
            while (i + 1 < n.count) : (i += 1) {
                const s = n.sum(i);
                const next = acc.combine(s);
                if (next.utf16Total() > target) break;
                acc = next;
                base += s.bytes;
            }
            if (n.isLeaf()) break;
            n = n.inner().children[i];
        }
        // Decode subparts from `base`, resuming `acc`'s pending sequence.
        var c = acc.utf16;
        var lead = acc.tail_lead;
        var pend: u8 = acc.tail_n;
        var sub_start = base - pend;
        var info: summary_mod.LeadInfo = if (pend > 0) summary_mod.leadInfo(lead).? else undefined;
        var it = t.chunks(base);
        var pos = base;
        while (it.next()) |chunk| {
            var j: usize = 0;
            while (j < chunk.len) {
                const b = chunk[j];
                if (pend == 0) {
                    sub_start = pos + j;
                    if (b < 0x80) {
                        if (c + 1 > target) return sub_start;
                        c += 1;
                    } else if (summary_mod.leadInfo(b)) |li| {
                        lead = b;
                        info = li;
                        pend = 1;
                    } else {
                        if (c + 1 > target) return sub_start;
                        c += 1;
                    }
                    j += 1;
                    continue;
                }
                const lo: u8 = if (pend == 1) info.lo else 0x80;
                const hi: u8 = if (pend == 1) info.hi else 0xBF;
                if (b < lo or b > hi) {
                    if (c + pend > target) return sub_start;
                    c += pend;
                    pend = 0;
                    continue; // reprocess b
                }
                pend += 1;
                j += 1;
                if (pend == info.len) {
                    const u: u64 = if (info.len == 4) 2 else 1;
                    if (c + u > target) return sub_start;
                    c += u;
                    pend = 0;
                }
            }
            pos += chunk.len;
        }
        if (pend > 0 and c + pend > target) return sub_start;
        return root.total.bytes;
    }

    // -- iteration ---------------------------------------------------------

    /// Zero-copy chunks of `range`, in order.
    pub fn slice(t: PieceTree, range: Range) ChunkIterator {
        return .init(t, range);
    }

    /// Zero-copy chunks from `from` to the end.
    pub fn chunks(t: PieceTree, from: u64) ChunkIterator {
        return .init(t, .{ .start = from, .end = t.len() });
    }

    /// Zero-copy chunks of `text[0..from]`, last chunk first.
    pub fn chunksRev(t: PieceTree, from: u64) RevChunkIterator {
        return .init(t, .{ .start = 0, .end = from });
    }

    /// A copy of `range`, owned by `gpa`.
    pub fn copyRange(t: PieceTree, gpa: Allocator, range: Range) Allocator.Error![]u8 {
        const out = try gpa.alloc(u8, @intCast(range.len()));
        var it = t.slice(range);
        var i: usize = 0;
        while (it.next()) |ch| {
            @memcpy(out[i..][0..ch.len], ch);
            i += ch.len;
        }
        return out;
    }

    /// Checks structural invariants (tests).
    pub fn check(t: PieceTree) !void {
        const root = t.root orelse return;
        _ = try checkNode(t.buffers, root, true);
    }
};

fn sat32(x: u64) u32 {
    return @intCast(@min(x, std.math.maxInt(u32)));
}

/// Offset just past the `need`-th line terminator in `bytes` (need >= 1).
/// A leading `\n` after a `\r` that ended the previous text is not a
/// terminator.
fn findTerminatorEnd(bytes: []const u8, need: u64, prev_cr: bool) usize {
    var k: u64 = 0;
    var i: usize = 0;
    if (prev_cr and bytes.len > 0 and bytes[0] == '\n') i = 1;
    const V = @Vector(32, u8);
    while (i < bytes.len) {
        if (i + 33 <= bytes.len) {
            // Skip whole blocks whose terminators all come before the
            // target (an upper bound: CRLF pairs count twice here, and a CR
            // at the block end is left to the scalar path).
            const v: V = bytes[i..][0..32].*;
            const lf: u32 = @bitCast(v == @as(V, @splat('\n')));
            const cr: u32 = @bitCast(v == @as(V, @splat('\r')));
            const m = lf | cr;
            if (m == 0) {
                i += 32;
                continue;
            }
            if (cr >> 31 == 0 and bytes[i] != '\n') {
                const in_block = @popCount(lf) + @popCount(cr) - @popCount(cr & (lf >> 1));
                if (k + in_block < need) {
                    k += in_block;
                    i += 32;
                    continue;
                }
            }
            i += @ctz(m);
        }
        const c = bytes[i];
        if (c == '\n' or c == '\r') {
            if (c == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
            k += 1;
            if (k == need) return i + 1;
        }
        i += 1;
    }
    unreachable;
}

const Found = struct { piece: Piece, start: u64 };

/// The piece containing `off` (`off < total`) and its start offset.
fn findPiece(root: *Node, off: u64) Found {
    var n = root;
    var base: u64 = 0;
    while (true) {
        var i: usize = 0;
        if (n.isLeaf()) {
            const l = n.leaf();
            while (i + 1 < n.count and base + l.pieces[i].len <= off) : (i += 1) base += l.pieces[i].len;
            return .{ .piece = l.pieces[i], .start = base };
        }
        const in = n.inner();
        while (i + 1 < n.count and base + in.sums[i].bytes <= off) : (i += 1) base += in.sums[i].bytes;
        n = in.children[i];
    }
}

const Seek = struct { piece: Piece, start: u64, prefix: Summary };

/// Like `findPiece`, also accumulating the summary before the piece.
fn seekBytes(root: *Node, off: u64) Seek {
    var n = root;
    var base: u64 = 0;
    var acc: Summary = .empty;
    while (true) {
        var i: usize = 0;
        if (n.isLeaf()) {
            const l = n.leaf();
            while (i + 1 < n.count and base + l.pieces[i].len <= off) : (i += 1) {
                base += l.pieces[i].len;
                acc = acc.combine(l.sums[i]);
            }
            return .{ .piece = l.pieces[i], .start = base, .prefix = acc };
        }
        const in = n.inner();
        while (i + 1 < n.count and base + in.sums[i].bytes <= off) : (i += 1) {
            base += in.sums[i].bytes;
            acc = acc.combine(in.sums[i]);
        }
        n = in.children[i];
    }
}

// -- structural operations (consume their node arguments) ---------------------

fn slotMax(n: *const Node) usize {
    return if (n.height == 0) leaf_max else inner_max;
}

/// Copies `count` slots from `src[si..]` to `dst[di..]` (same kind;
/// regions may overlap when `src == dst`).
fn copySlots(dst: *Node, di: usize, src: *Node, si: usize, count: usize) void {
    if (count == 0) return;
    if (dst.height == 0) {
        const d = dst.leaf();
        const s = src.leaf();
        moveItems(Summary, d.sums[di..][0..count], s.sums[si..][0..count]);
        moveItems(Piece, d.pieces[di..][0..count], s.pieces[si..][0..count]);
    } else {
        const d = dst.inner();
        const s = src.inner();
        moveItems(Summary, d.sums[di..][0..count], s.sums[si..][0..count]);
        moveItems(*Node, d.children[di..][0..count], s.children[si..][0..count]);
    }
}

fn moveItems(comptime T: type, dst: []T, src: []const T) void {
    if (@intFromPtr(dst.ptr) <= @intFromPtr(src.ptr)) {
        for (dst, src) |*d, s| d.* = s;
    } else {
        var i = dst.len;
        while (i > 0) {
            i -= 1;
            dst[i] = src[i];
        }
    }
}

/// Takes `b`'s slots (appending them to `a`'s first `a.count`); `b` is
/// consumed.
fn absorb(c: Ctx, a: *Node, b: *Node) void {
    copySlots(a, a.count, b, 0, b.count);
    if (b.rc.load(.acquire) == 1) {
        c.pool.freeShell(b);
    } else {
        if (b.height != 0) for (b.inner().children[0..b.count]) |ch| ch.retain();
        c.pool.release(b);
    }
    a.count += b.count;
}

const Pair = struct { left: *Node, right: ?*Node };

/// Joins two nodes of equal height (both consumed): one node when the
/// slots fit, otherwise two balanced siblings.
fn mergeEqual(c: Ctx, a_in: *Node, b_in: *Node) Allocator.Error!Pair {
    const a = try c.pool.makeMut(a_in);
    const max = slotMax(a);
    if (a.count + b_in.count <= max) {
        absorb(c, a, b_in);
        a.recompute();
        return .{ .left = a, .right = null };
    }
    const b = try c.pool.makeMut(b_in);
    const total: usize = a.count + b.count;
    const want_a = total / 2;
    if (a.count > want_a) {
        const k = a.count - want_a;
        copySlots(b, k, b, 0, b.count);
        copySlots(b, 0, a, want_a, k);
        a.count = @intCast(want_a);
        b.count += @intCast(k);
    } else if (a.count < want_a) {
        const k = want_a - a.count;
        copySlots(a, a.count, b, 0, k);
        copySlots(b, 0, b, k, b.count - k);
        a.count = @intCast(want_a);
        b.count -= @intCast(k);
    }
    a.recompute();
    b.recompute();
    return .{ .left = a, .right = b };
}

/// Inserts `child` at `idx` in the mutable internal node `a`, splitting it
/// when full; returns the new right sibling.
fn insertChild(c: Ctx, a: *Node, idx: usize, child: *Node) Allocator.Error!?*Node {
    const in = a.inner();
    if (a.count < inner_max) {
        copySlots(a, idx + 1, a, idx, a.count - idx);
        in.children[idx] = child;
        in.sums[idx] = child.total;
        a.count += 1;
        return null;
    }
    const s = try c.pool.allocInner(a.height);
    // 17 slots: the left keeps 9, the right gets 8.
    var tmp_c: [inner_max + 1]*Node = undefined;
    var tmp_s: [inner_max + 1]Summary = undefined;
    @memcpy(tmp_c[0..idx], in.children[0..idx]);
    @memcpy(tmp_s[0..idx], in.sums[0..idx]);
    tmp_c[idx] = child;
    tmp_s[idx] = child.total;
    @memcpy(tmp_c[idx + 1 ..], in.children[idx..inner_max]);
    @memcpy(tmp_s[idx + 1 ..], in.sums[idx..inner_max]);
    const left_n = (inner_max + 2) / 2;
    @memcpy(in.children[0..left_n], tmp_c[0..left_n]);
    @memcpy(in.sums[0..left_n], tmp_s[0..left_n]);
    a.count = left_n;
    const right_n = inner_max + 1 - left_n;
    @memcpy(s.children[0..right_n], tmp_c[left_n..]);
    @memcpy(s.sums[0..right_n], tmp_s[left_n..]);
    s.node.count = right_n;
    s.node.recompute();
    return &s.node;
}

/// Joins `a` and `b` (in that order), both consumed. The result has the
/// height of the taller one, plus an optional right sibling of that height.
fn join(c: Ctx, a: *Node, b: *Node) Allocator.Error!Pair {
    if (a.height == b.height) return mergeEqual(c, a, b);
    if (a.height > b.height) {
        const m = try c.pool.makeMut(a);
        const in = m.inner();
        const last = m.count - 1;
        const r = try join(c, in.children[last], b);
        in.children[last] = r.left;
        in.sums[last] = r.left.total;
        var sib: ?*Node = null;
        if (r.right) |rr| sib = try insertChild(c, m, last + 1, rr);
        m.recompute();
        return .{ .left = m, .right = sib };
    }
    const m = try c.pool.makeMut(b);
    const in = m.inner();
    const r = try join(c, a, in.children[0]);
    in.children[0] = r.left;
    in.sums[0] = r.left.total;
    var sib: ?*Node = null;
    if (r.right) |rr| sib = try insertChild(c, m, 1, rr);
    m.recompute();
    return .{ .left = m, .right = sib };
}

/// Concatenates two trees (both consumed).
fn concat(c: Ctx, a: ?*Node, b: ?*Node) Allocator.Error!?*Node {
    const x = a orelse return b;
    const y = b orelse return a;
    const r = try join(c, x, y);
    const right = r.right orelse return r.left;
    const p = try c.pool.allocInner(r.left.height + 1);
    p.children[0] = r.left;
    p.children[1] = right;
    p.sums[0] = r.left.total;
    p.sums[1] = right.total;
    p.node.count = 2;
    p.node.recompute();
    return &p.node;
}

/// Replaces a root with fewer than two slots by its only child (or null).
fn normalizeRoot(c: Ctx, n_in: ?*Node) ?*Node {
    var n = n_in orelse return null;
    while (true) {
        if (n.count == 0) {
            c.pool.release(n);
            return null;
        }
        if (n.height == 0 or n.count > 1) return n;
        const child = n.inner().children[0];
        if (n.rc.load(.acquire) == 1) {
            c.pool.freeShell(n);
        } else {
            child.retain();
            c.pool.release(n);
        }
        n = child;
    }
}

const Halves = struct { l: ?*Node, r: ?*Node };

/// Splits a tree (consumed) at byte `off`.
fn split(c: Ctx, n_in: ?*Node, off: u64) EditError!Halves {
    const n0 = n_in orelse return .{ .l = null, .r = null };
    if (off == 0) return .{ .l = null, .r = n0 };
    if (off >= n0.total.bytes) return .{ .l = n0, .r = null };
    const n = try c.pool.makeMut(n0);
    if (n.isLeaf()) {
        const l = n.leaf();
        var i: usize = 0;
        var base: u64 = 0;
        while (base + l.pieces[i].len <= off) : (i += 1) base += l.pieces[i].len;
        const rl = try c.pool.allocLeaf();
        const r = &rl.node;
        if (off == base) {
            copySlots(r, 0, n, i, n.count - i);
            r.count = n.count - @as(u8, @intCast(i));
            n.count = @intCast(i);
        } else {
            const p = l.pieces[i];
            const k: u32 = @intCast(off - base);
            const p1: Piece = .{ .start = p.start, .len = k, .buf = p.buf };
            const p2: Piece = .{ .start = p.start + k, .len = p.len - k, .buf = p.buf };
            copySlots(r, 1, n, i + 1, n.count - i - 1);
            rl.pieces[0] = p2;
            rl.sums[0] = Summary.of(c.bt.bytes(p2));
            r.count = n.count - @as(u8, @intCast(i));
            l.pieces[i] = p1;
            l.sums[i] = Summary.of(c.bt.bytes(p1));
            n.count = @intCast(i + 1);
        }
        n.recompute();
        r.recompute();
        return .{ .l = normalizeRoot(c, n), .r = normalizeRoot(c, r) };
    }
    const in = n.inner();
    var i: usize = 0;
    var base: u64 = 0;
    while (base + in.sums[i].bytes < off) : (i += 1) base += in.sums[i].bytes;
    const ri = try c.pool.allocInner(n.height);
    const r = &ri.node;
    if (base + in.sums[i].bytes == off) {
        // Between children i and i + 1.
        copySlots(r, 0, n, i + 1, n.count - i - 1);
        r.count = n.count - @as(u8, @intCast(i + 1));
        n.count = @intCast(i + 1);
        n.recompute();
        r.recompute();
        return .{ .l = normalizeRoot(c, n), .r = normalizeRoot(c, r) };
    }
    const child = in.children[i];
    copySlots(r, 0, n, i + 1, n.count - i - 1);
    r.count = n.count - @as(u8, @intCast(i + 1));
    n.count = @intCast(i);
    n.recompute();
    r.recompute();
    const halves = try split(c, child, off - base);
    const left = try concat(c, normalizeRoot(c, n), halves.l);
    const right = try concat(c, halves.r, normalizeRoot(c, r));
    return .{ .l = normalizeRoot(c, left), .r = normalizeRoot(c, right) };
}

/// Builds a balanced tree over `pieces` (new references).
fn buildFromPieces(c: Ctx, pieces: []const Piece) Allocator.Error!?*Node {
    if (pieces.len == 0) return null;
    const gpa = c.pool.gpa;
    var level: std.ArrayList(*Node) = .empty;
    defer level.deinit(gpa);
    const nleaves = std.math.divCeil(usize, pieces.len, leaf_max) catch unreachable;
    try level.ensureTotalCapacity(gpa, nleaves);
    var off: usize = 0;
    for (0..nleaves) |k| {
        const take = pieces.len / nleaves + @intFromBool(k < pieces.len % nleaves);
        const l = try c.pool.allocLeaf();
        for (pieces[off..][0..take], 0..) |p, j| {
            l.pieces[j] = p;
            l.sums[j] = Summary.of(c.bt.bytes(p));
        }
        l.node.count = @intCast(take);
        l.node.recompute();
        level.appendAssumeCapacity(&l.node);
        off += take;
    }
    return buildUpper(c, &level);
}

/// Builds parents over `level` (nodes of one height, in order) until one
/// root remains; null for an empty level.
fn buildUpper(c: Ctx, level: *std.ArrayList(*Node)) Allocator.Error!?*Node {
    if (level.items.len == 0) return null;
    var h: u8 = level.items[0].height + 1;
    while (level.items.len > 1) : (h += 1) {
        const n = level.items.len;
        const groups = std.math.divCeil(usize, n, inner_max) catch unreachable;
        var src: usize = 0;
        for (0..groups) |g| {
            const take = n / groups + @intFromBool(g < n % groups);
            const p = try c.pool.allocInner(h);
            for (level.items[src..][0..take], 0..) |ch, j| {
                p.children[j] = ch;
                p.sums[j] = ch.total;
            }
            p.node.count = @intCast(take);
            p.node.recompute();
            level.items[g] = &p.node;
            src += take;
        }
        level.shrinkRetainingCapacity(groups);
    }
    return normalizeRoot(c, level.items[0]);
}

/// Appends `text` to the add buffer and builds a tree of pieces over it.
fn buildFromText(c: Ctx, text: []const u8) EditError!?*Node {
    if (text.len <= max_piece_len) {
        if (c.bt.tailRoom() >= text.len) {
            const p = try c.bt.append(text);
            const l = try c.pool.allocLeaf();
            l.pieces[0] = p;
            l.sums[0] = Summary.of(text);
            l.node.count = 1;
            l.node.total = l.sums[0];
            return &l.node;
        }
    }
    const gpa = c.pool.gpa;
    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(gpa);
    var rest = text;
    while (rest.len > 0) {
        const p = try c.bt.append(rest);
        rest = rest[p.len..];
        var q = p;
        while (q.len > 0) {
            const n = @min(q.len, max_piece_len);
            try pieces.append(gpa, .{ .start = q.start, .len = n, .buf = q.buf });
            q.start += n;
            q.len -= n;
        }
    }
    return buildFromPieces(c, pieces.items);
}

/// The child of `n` that an edit ending at `key` belongs to: the first
/// whose end is at or after `key` (insertions at a boundary go left).
fn childFor(n: *Node, key: u64, base_in: u64) struct { idx: usize, base: u64 } {
    var base = base_in;
    var i: usize = 0;
    while (i + 1 < n.count and base + n.sum(i).bytes < key) : (i += 1) base += n.sum(i).bytes;
    return .{ .idx = i, .base = base };
}

/// Whether every edit lies inside one leaf and all inserted text fits the
/// current add page (reserving a fresh page when needed).
fn prepareLocal(c: Ctx, root: *Node, edits: []const Edit) error{ OutOfMemory, BufferFull }!bool {
    var text_total: usize = 0;
    for (edits) |e| {
        if (e.text.len > max_piece_len) return false;
        text_total += e.text.len;
        var n = root;
        var base: u64 = 0;
        while (true) {
            const ch = childFor(n, e.range.end, base);
            if (ch.base > e.range.start) return false;
            if (n.isLeaf()) break;
            n = n.inner().children[ch.idx];
            base = ch.base;
        }
    }
    if (text_total > buffers.page_size) return false;
    if (text_total > 0) try c.bt.reserve(text_total);
    return true;
}

/// Applies `edits` (absolute offsets, all inside `n_in`'s range, each
/// inside one leaf) to the subtree `n_in` (consumed), appending the
/// replacement nodes (same height, possibly none or several) to `out`.
fn applyLocal(c: Ctx, n_in: *Node, edits: []const Edit, base: u64, out: *std.ArrayList(*Node)) EditError!void {
    const n = try c.pool.makeMut(n_in);
    if (n.isLeaf()) return rebuildLeaf(c, n, edits, base, out);
    const gpa = c.pool.gpa;
    var kids: std.ArrayList(*Node) = .empty;
    defer kids.deinit(gpa);
    const in = n.inner();
    var e0: usize = 0;
    var cb = base;
    for (0..n.count) |i| {
        const child = in.children[i];
        const ce = cb + in.sums[i].bytes;
        var e1 = e0;
        while (e1 < edits.len and (edits[e1].range.end <= ce or i + 1 == n.count)) e1 += 1;
        if (e1 == e0) {
            try kids.append(gpa, child);
        } else {
            try applyLocal(c, child, edits[e0..e1], cb, &kids);
        }
        e0 = e1;
        cb = ce;
    }
    n.count = 0;
    if (kids.items.len == 0) {
        c.pool.release(n);
        return;
    }
    // Regroup into nodes of at most 16 children, reusing `n` first.
    const groups = std.math.divCeil(usize, kids.items.len, inner_max) catch unreachable;
    var src: usize = 0;
    for (0..groups) |g| {
        const take = kids.items.len / groups + @intFromBool(g < kids.items.len % groups);
        const dst: *Node = if (g == 0) n else &(try c.pool.allocInner(n.height)).node;
        const din = dst.inner();
        for (kids.items[src..][0..take], 0..) |k, j| {
            din.children[j] = k;
            din.sums[j] = k.total;
        }
        dst.count = @intCast(take);
        dst.recompute();
        try out.append(gpa, dst);
        src += take;
    }
}

fn rebuildLeaf(c: Ctx, n: *Node, edits: []const Edit, base: u64, out: *std.ArrayList(*Node)) EditError!void {
    const gpa = c.pool.gpa;
    const l = n.leaf();
    var stack_p: [96]Piece = undefined;
    var stack_s: [96]Summary = undefined;
    const need = @as(usize, n.count) + 3 * edits.len;
    const heap = need > stack_p.len;
    const ps: []Piece = if (heap) try gpa.alloc(Piece, need) else stack_p[0..need];
    defer if (heap) gpa.free(ps);
    const ss: []Summary = if (heap) try gpa.alloc(Summary, need) else stack_s[0..need];
    defer if (heap) gpa.free(ss);
    var np: usize = 0;

    var pi: usize = 0; // current piece
    var cut: u32 = 0; // bytes of the current piece already consumed
    var cur: u64 = base;
    for (edits) |e| {
        // Copy up to the edit start.
        while (cur < e.range.start) {
            const p = l.pieces[pi];
            const take: u32 = @intCast(@min(p.len - cut, e.range.start - cur));
            if (cut == 0 and take == p.len) {
                ps[np] = p;
                ss[np] = l.sums[pi];
            } else {
                ps[np] = .{ .start = p.start + cut, .len = take, .buf = p.buf };
                ss[np] = Summary.of(c.bt.bytes(ps[np]));
            }
            np += 1;
            cur += take;
            cut += take;
            if (cut == p.len) {
                pi += 1;
                cut = 0;
            }
        }
        // Insert, extending the previous piece when it ends at the add tail.
        if (e.text.len > 0) {
            const add_sum = Summary.of(e.text);
            if (np > 0 and c.bt.isTail(ps[np - 1]) and ps[np - 1].len + e.text.len <= max_piece_len) {
                const q = try c.bt.append(e.text);
                std.debug.assert(q.len == e.text.len);
                ps[np - 1].len += q.len;
                ss[np - 1] = ss[np - 1].combine(add_sum);
            } else {
                ps[np] = try c.bt.append(e.text);
                std.debug.assert(ps[np].len == e.text.len);
                ss[np] = add_sum;
                np += 1;
            }
        }
        // Skip the replaced range.
        while (cur < e.range.end) {
            const p = l.pieces[pi];
            const take: u32 = @intCast(@min(p.len - cut, e.range.end - cur));
            cur += take;
            cut += take;
            if (cut == p.len) {
                pi += 1;
                cut = 0;
            }
        }
    }
    // Copy the rest.
    while (pi < n.count) {
        const p = l.pieces[pi];
        if (cut == 0) {
            ps[np] = p;
            ss[np] = l.sums[pi];
        } else {
            ps[np] = .{ .start = p.start + cut, .len = p.len - cut, .buf = p.buf };
            ss[np] = Summary.of(c.bt.bytes(ps[np]));
        }
        np += 1;
        pi += 1;
        cut = 0;
    }
    n.count = 0;
    if (np == 0) {
        c.pool.release(n);
        return;
    }
    const groups = std.math.divCeil(usize, np, leaf_max) catch unreachable;
    var src: usize = 0;
    for (0..groups) |g| {
        const take = np / groups + @intFromBool(g < np % groups);
        const dst: *Node = if (g == 0) n else &(try c.pool.allocLeaf()).node;
        const dl = dst.leaf();
        @memcpy(dl.pieces[0..take], ps[src..][0..take]);
        @memcpy(dl.sums[0..take], ss[src..][0..take]);
        dst.count = @intCast(take);
        dst.recompute();
        try out.append(gpa, dst);
        src += take;
    }
}

fn checkNode(bt: *const BufferTable, n: *Node, is_root: bool) !u8 {
    const max = slotMax(n);
    if (n.count == 0 or n.count > max) return error.BadCount;
    _ = is_root;
    var t: Summary = .empty;
    if (n.isLeaf()) {
        const l = n.leaf();
        for (l.pieces[0..n.count], l.sums[0..n.count]) |p, s| {
            if (p.len == 0 or p.len > max_piece_len) return error.BadPiece;
            const want = Summary.of(bt.bytes(p));
            if (want.bytes != s.bytes or want.newlines != s.newlines or want.utf16Total() != s.utf16Total()) return error.BadSummary;
            t = t.combine(s);
        }
    } else {
        const in = n.inner();
        for (in.children[0..n.count], in.sums[0..n.count]) |ch, s| {
            if (ch.height + 1 != n.height) return error.BadHeight;
            _ = try checkNode(bt, ch, false);
            if (ch.total.bytes != s.bytes or ch.total.newlines != s.newlines) return error.BadSummary;
            t = t.combine(s);
        }
    }
    if (t.bytes != n.total.bytes or t.newlines != n.total.newlines or t.utf16Total() != n.total.utf16Total()) return error.BadTotal;
    return n.height;
}

// -- iterators ----------------------------------------------------------------

const Frame = struct { node: *Node, idx: u8 };

/// Forward zero-copy chunk iterator. Allocation-free.
pub const ChunkIterator = struct {
    bt: *const BufferTable,
    stack: [max_height]Frame = undefined,
    depth: u8 = 0,
    /// Absolute offset of the current piece's start.
    piece_start: u64 = 0,
    /// Absolute offset of the next byte to yield.
    pos: u64,
    end: u64,

    fn init(t: PieceTree, range: Range) ChunkIterator {
        var it: ChunkIterator = .{ .bt = t.buffers, .pos = range.start, .end = @min(range.end, t.len()) };
        const root = t.root orelse {
            it.end = it.pos;
            return it;
        };
        if (it.pos >= it.end) return it;
        var n = root;
        var base: u64 = 0;
        while (true) {
            var i: usize = 0;
            if (n.isLeaf()) {
                const l = n.leaf();
                while (base + l.pieces[i].len <= it.pos) : (i += 1) base += l.pieces[i].len;
                it.stack[it.depth] = .{ .node = n, .idx = @intCast(i) };
                it.depth += 1;
                break;
            }
            const in = n.inner();
            while (base + in.sums[i].bytes <= it.pos) : (i += 1) base += in.sums[i].bytes;
            it.stack[it.depth] = .{ .node = n, .idx = @intCast(i) };
            it.depth += 1;
            n = in.children[i];
        }
        it.piece_start = base;
        return it;
    }

    /// The offset of the next chunk's first byte.
    pub fn offset(it: *const ChunkIterator) u64 {
        return it.pos;
    }

    /// The next chunk, or null at the end of the range.
    pub fn next(it: *ChunkIterator) ?[]const u8 {
        if (it.pos >= it.end) return null;
        const top = it.stack[it.depth - 1];
        const p = top.node.leaf().pieces[top.idx];
        const bytes = it.bt.bytes(p);
        const from: usize = @intCast(it.pos - it.piece_start);
        const to: usize = @intCast(@min(p.len, it.end - it.piece_start));
        it.pos = it.piece_start + to;
        if (to == p.len) {
            it.piece_start += p.len;
            if (it.pos < it.end) it.advance();
        }
        return bytes[from..to];
    }

    fn advance(it: *ChunkIterator) void {
        // Pop exhausted frames, then descend leftmost.
        while (true) {
            const f = &it.stack[it.depth - 1];
            if (f.idx + 1 < f.node.count) {
                f.idx += 1;
                break;
            }
            it.depth -= 1;
        }
        var n = it.stack[it.depth - 1];
        while (!n.node.isLeaf()) {
            const child = n.node.inner().children[n.idx];
            it.stack[it.depth] = .{ .node = child, .idx = 0 };
            it.depth += 1;
            n = it.stack[it.depth - 1];
        }
    }
};

/// Backward zero-copy chunk iterator. Allocation-free.
pub const RevChunkIterator = struct {
    bt: *const BufferTable,
    stack: [max_height]Frame = undefined,
    depth: u8 = 0,
    /// Absolute offset of the current piece's start.
    piece_start: u64 = 0,
    /// Absolute offset just past the next byte to yield.
    pos: u64,
    start: u64,

    fn init(t: PieceTree, range: Range) RevChunkIterator {
        var it: RevChunkIterator = .{ .bt = t.buffers, .pos = @min(range.end, t.len()), .start = range.start };
        const root = t.root orelse return it;
        if (it.pos <= it.start) return it;
        const target = it.pos - 1;
        var n = root;
        var base: u64 = 0;
        while (true) {
            var i: usize = 0;
            if (n.isLeaf()) {
                const l = n.leaf();
                while (base + l.pieces[i].len <= target) : (i += 1) base += l.pieces[i].len;
                it.stack[it.depth] = .{ .node = n, .idx = @intCast(i) };
                it.depth += 1;
                break;
            }
            const in = n.inner();
            while (base + in.sums[i].bytes <= target) : (i += 1) base += in.sums[i].bytes;
            it.stack[it.depth] = .{ .node = n, .idx = @intCast(i) };
            it.depth += 1;
            n = in.children[i];
        }
        it.piece_start = base;
        return it;
    }

    /// The next chunk (towards the start), or null.
    pub fn next(it: *RevChunkIterator) ?[]const u8 {
        if (it.pos <= it.start) return null;
        const top = it.stack[it.depth - 1];
        const p = top.node.leaf().pieces[top.idx];
        const bytes = it.bt.bytes(p);
        const from: usize = @intCast(@max(it.piece_start, it.start) - it.piece_start);
        const to: usize = @intCast(it.pos - it.piece_start);
        it.pos = it.piece_start + from;
        if (from == 0 and it.pos > it.start) it.retreat();
        return bytes[from..to];
    }

    fn retreat(it: *RevChunkIterator) void {
        while (true) {
            const f = &it.stack[it.depth - 1];
            if (f.idx > 0) {
                f.idx -= 1;
                break;
            }
            it.depth -= 1;
        }
        var n = it.stack[it.depth - 1];
        while (!n.node.isLeaf()) {
            const child = n.node.inner().children[n.idx];
            it.stack[it.depth] = .{ .node = child, .idx = child.count - 1 };
            it.depth += 1;
            n = it.stack[it.depth - 1];
        }
        const f = it.stack[it.depth - 1];
        it.piece_start -= f.node.leaf().pieces[f.idx].len;
    }
};
