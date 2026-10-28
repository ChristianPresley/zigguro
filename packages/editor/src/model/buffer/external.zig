//! Loading files and handling changes made on disk by other programs.
//!
//! A watch event (debounced 50 ms by the watcher) runs `probe` on a
//! worker: it compares the file's metadata with the recorded `DiskState`
//! and, when that differs, hashes the bytes so a touch alone is ignored.
//! `applyProbe` then runs on the UI thread: a clean buffer reloads by
//! diffing old against new text and applying only the changed hunks as
//! one undo group "Reload from disk", so cursors, anchors and folds
//! outside them survive; a dirty buffer reports a conflict for the UI to
//! offer reload, keep or `merge3`.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const pt = @import("piece_tree.zig");
const buffers = @import("buffers.zig");
const eol_mod = @import("eol.zig");
const save_mod = @import("save.zig");
const enc = @import("../encoding.zig");
const diff = @import("../diff.zig");
const document = @import("../document.zig");
const cs_mod = @import("../edit/change_set.zig");
const undo_mod = @import("../edit/undo.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const PieceTree = pt.PieceTree;
const Document = document.Document;
const ChangeSet = cs_mod.ChangeSet;
const UndoTree = undo_mod.UndoTree;
const Encoding = enc.Encoding;
const DiskState = save_mod.DiskState;
const FileState = save_mod.FileState;
const LineSource = diff.LineSource;

/// A file read from disk and decoded.
pub const Loaded = struct {
    /// The decoded text (UTF-8, or WTF-8 for unpaired surrogates). Inside
    /// `map` when there is one (read-only).
    text: []u8,
    /// The file's memory map holding `text` (large-file mode); hand it to
    /// the document (`DocumentRegistry.openFileMapped`).
    map: ?buffers.Mapped = null,
    /// `disk.content_hash` is not computed yet (a mapped file is hashed
    /// off the open path): hash `text` before relying on it.
    hash_pending: bool = false,
    encoding: Encoding,
    confidence: @FieldType(enc.Detection, "confidence"),
    eol: eol_mod.EolStats,
    disk: DiskState,

    /// Frees the text.
    pub fn deinit(l: *Loaded, gpa: Allocator) void {
        if (l.map) |*m| m.destroy() else gpa.free(l.text);
        l.* = undefined;
    }
};

/// Reads and decodes `path` (blocking). `hint` is a user or workspace
/// encoding setting (a BOM still wins); `fallback` is used when detection
/// is unsure. A UTF-8 file of `map_min` bytes or more is memory-mapped
/// instead of read (`Loaded.map`).
pub fn load(gpa: Allocator, io: Io, dir: Dir, path: []const u8, hint: ?Encoding, fallback: Encoding) !Loaded {
    return loadWith(gpa, io, dir, path, hint, fallback, true);
}

/// Files from this size open in large-file mode: memory-mapped, line ends
/// sampled from the first MiB (`EolStats.sampled`), the content hash left
/// to the caller (`Loaded.hash_pending`). Not on Windows, where replacing a file that has an open
/// mapping fails, so saving it would.
pub const map_min: u64 = 64 << 20;

fn loadWith(gpa: Allocator, io: Io, dir: Dir, path: []const u8, hint: ?Encoding, fallback: Encoding, allow_map: bool) !Loaded {
    var f = try dir.openFile(io, path, .{});
    defer f.close(io);
    const st = try f.stat(io);
    if (allow_map and builtin.os.tag != .windows and st.kind == .file and st.size >= map_min) {
        if (try loadMapped(gpa, io, f, st, hint, fallback)) |l| return l;
    }
    const bytes = try readWhole(gpa, io, f, st);
    var bytes_owned = true;
    defer if (bytes_owned) gpa.free(bytes);
    // A large file is hashed on another task while it is decoded and its
    // line ends counted.
    var hash: u64 = 0;
    var group: Io.Group = .init;
    defer group.await(io) catch {};
    if (bytes.len >= parallel_min) {
        group.concurrent(io, hashInto, .{ &hash, bytes }) catch hashInto(&hash, bytes);
    } else hashInto(&hash, bytes);
    const d = enc.detect(bytes[0..@min(bytes.len, 8 << 10)], hint, fallback);
    // UTF-8 without a BOM decodes to itself: keep the buffer instead of
    // copying it (a 1 GB file would otherwise be held twice).
    const text = if (d.encoding == .utf8) bytes else try enc.decodeAll(d.encoding, bytes, gpa);
    errdefer if (text.ptr != bytes.ptr) gpa.free(text);
    const eol = eol_mod.detectEolBytes(text);
    group.await(io) catch {};
    bytes_owned = text.ptr != bytes.ptr;
    return .{
        .text = text,
        .encoding = d.encoding,
        .confidence = d.confidence,
        .eol = eol,
        // Size and hash describe the bytes read, even if the file grew
        // after the stat.
        .disk = .{ .size = bytes.len, .mtime = st.mtime, .file_id = save_mod.fileId(st), .content_hash = hash },
    };
}

/// Maps `f`; null when it cannot be mapped (then it is read). A UTF-8
/// file keeps the map; other encodings are decoded from it and unmapped.
fn loadMapped(gpa: Allocator, io: Io, f: File, st: File.Stat, hint: ?Encoding, fallback: Encoding) !?Loaded {
    const size = std.math.cast(usize, st.size) orelse return error.FileTooBig;
    // Pages fault in on the threads that summarize the text.
    var m: buffers.Mapped = .{
        .mm = f.createMemoryMap(io, .{ .len = size, .protection = .{ .read = true }, .populate = false }) catch return null,
        .io = io,
    };
    var map_owned = true;
    defer if (map_owned) m.destroy();
    const bytes = m.mm.memory;
    const d = enc.detect(bytes[0..@min(bytes.len, 8 << 10)], hint, fallback);
    var disk: DiskState = .{ .size = bytes.len, .mtime = st.mtime, .file_id = save_mod.fileId(st), .content_hash = 0 };
    if (d.encoding != .utf8) {
        disk.content_hash = save_mod.hashBytesParallel(io, bytes);
        const text = try enc.decodeAll(d.encoding, bytes, gpa);
        return .{ .text = text, .encoding = d.encoding, .confidence = d.confidence, .eol = eol_mod.detectEolSample(text), .disk = disk };
    }
    map_owned = false;
    return .{ .text = bytes, .map = m, .hash_pending = true, .encoding = d.encoding, .confidence = d.confidence, .eol = eol_mod.detectEolSample(bytes), .disk = disk };
}

/// Files from this size are read by several tasks at once and hashed on
/// one while the caller decodes them (page faults and memory bandwidth,
/// not the disk, bound a warm read of a large file).
pub const parallel_min: u64 = 32 << 20;
const max_read_tasks = 8;

fn hashInto(out: *u64, bytes: []const u8) void {
    out.* = save_mod.hashBytes(bytes);
}

const ReadTask = struct {
    f: File,
    buf: []u8,
    off: u64,
    err: ?File.ReadPositionalError = null,
    n: usize = 0,

    fn run(t: *ReadTask, io: Io) void {
        t.n = t.f.readPositionalAll(io, t.buf, t.off) catch |e| {
            t.err = e;
            return;
        };
    }
};

/// Reads a regular file of `size` bytes with up to `max_read_tasks`
/// positional reads at once. Null when the file changed size meanwhile
/// or does not read positionally: the caller reads it sequentially.
fn readParallel(gpa: Allocator, io: Io, f: File, size: usize) Allocator.Error!?[]u8 {
    const buf = try gpa.alloc(u8, size);
    var ok = false;
    defer if (!ok) gpa.free(buf);
    const cpus = std.Thread.getCpuCount() catch 1;
    const n: usize = std.math.clamp(cpus, 1, max_read_tasks);
    var tasks: [max_read_tasks]ReadTask = undefined;
    const per = std.mem.alignForward(usize, size / n, 1 << 16);
    var group: Io.Group = .init;
    var used: usize = 0;
    var off: usize = 0;
    while (off < size) : (used += 1) {
        const end = if (used + 1 == n) size else @min(size, off + per);
        tasks[used] = .{ .f = f, .buf = buf[off..end], .off = off };
        off = end;
    }
    for (tasks[1..used]) |*t| group.concurrent(io, ReadTask.run, .{ t, io }) catch t.run(io);
    tasks[0].run(io);
    group.await(io) catch return null;
    for (tasks[0..used]) |t| if (t.err != null or t.n != t.buf.len) return null;
    // Grown since the stat: read it all again, sequentially.
    var probe_buf: [1]u8 = undefined;
    if ((f.readPositional(io, &.{&probe_buf}, size) catch return null) != 0) return null;
    ok = true;
    return buf;
}

/// Reads all of `f` into one allocation sized from the stat (`size`), so
/// a large file is read straight into place instead of through a growing
/// buffer (in parallel from `parallel_min` bytes); a file that grew since
/// the stat is read to its end, one that shrank is cut to what was read.
/// Procfs-style files (size 0) work too.
fn readWhole(gpa: Allocator, io: Io, f: File, st: File.Stat) ![]u8 {
    const size = st.size;
    if (st.kind == .file and size >= parallel_min) {
        if (try readParallel(gpa, io, f, std.math.cast(usize, size) orelse return error.FileTooBig)) |b| return b;
    }
    var rbuf: [64 << 10]u8 = undefined;
    var r = f.reader(io, &rbuf);
    var list: std.ArrayList(u8) = try .initCapacity(gpa, std.math.cast(usize, size) orelse return error.FileTooBig);
    errdefer list.deinit(gpa);
    while (true) {
        if (list.items.len == list.capacity) {
            // At the stat size: probe for more before growing.
            var probe_buf: [4096]u8 = undefined;
            const n = r.interface.readSliceShort(&probe_buf) catch |e| return mapRead(e, &r);
            if (n == 0) break;
            try list.appendSlice(gpa, probe_buf[0..n]);
            continue;
        }
        const n = r.interface.readSliceShort(list.unusedCapacitySlice()) catch |e| return mapRead(e, &r);
        if (n == 0) break;
        list.items.len += n;
    }
    if (list.items.len == list.capacity) return list.items;
    return list.toOwnedSlice(gpa);
}

fn mapRead(e: Io.Reader.ShortError, r: *const File.Reader) File.Reader.Error {
    return switch (e) {
        error.ReadFailed => r.err.?,
    };
}

/// What `probe` found on disk.
pub const Probe = union(enum) {
    unchanged,
    /// Metadata changed, bytes did not.
    touched: DiskState,
    changed: Loaded,
    deleted,

    /// Frees a `changed` text.
    pub fn deinit(p: *Probe, gpa: Allocator) void {
        if (p.* == .changed) p.changed.deinit(gpa);
        p.* = .unchanged;
    }
};

/// Checks `file` on disk against its recorded state (blocking; any
/// thread).
pub fn probe(gpa: Allocator, io: Io, file: *const FileState) !Probe {
    const st = file.dir.statFile(io, file.path, .{}) catch |e| switch (e) {
        error.FileNotFound => return if (file.disk == null) .unchanged else .deleted,
        else => |x| return x,
    };
    if (file.disk) |d| {
        if (d.sameMeta(st)) return .unchanged;
        if (try save_mod.hashFile(file.dir, io, file.path) == d.content_hash) return .{ .touched = .fromStat(st, d.content_hash) };
    }
    // Read, not mapped: a conflict hands the text on as owned bytes.
    return .{ .changed = try loadWith(gpa, io, file.dir, file.path, file.encoding, file.encoding, false) };
}

/// A dirty buffer whose file changed on disk.
pub const ConflictInfo = struct {
    disk: DiskState,
    /// The disk's text, decoded.
    theirs: []u8,
    encoding: Encoding,

    /// Frees the text.
    pub fn deinit(c: *ConflictInfo, gpa: Allocator) void {
        gpa.free(c.theirs);
        c.* = undefined;
    }
};

/// The outcome of an external change.
pub const ExternalChange = union(enum) {
    none,
    reloaded_clean,
    conflict: ConflictInfo,
    deleted,
};

/// Acts on `p` (UI thread), taking ownership of it: reloads a clean
/// buffer, reports a conflict for a dirty one.
pub fn applyProbe(doc: *Document, file: *FileState, undo: ?*UndoTree, p: Probe, now: Io.Timestamp) !ExternalChange {
    switch (p) {
        .unchanged => return .none,
        .touched => |d| {
            file.disk = d;
            return .none;
        },
        .deleted => {
            file.disk = null;
            return .deleted;
        },
        .changed => {},
    }
    var loaded = p.changed;
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(doc.gpa);
    var cs = try reloadChanges(doc.gpa, doc.tree, loaded.text);
    defer if (cs) |*c| c.deinit();
    if (cs == null) {
        // The disk now holds what the buffer holds.
        file.disk = loaded.disk;
        file.encoding = loaded.encoding;
        doc.saved_version = doc.version;
        if (undo) |u| u.markSaved(u.current);
        return .none;
    }
    if (doc.isDirty()) {
        loaded_owned = false;
        return .{ .conflict = .{ .disk = loaded.disk, .theirs = loaded.text, .encoding = loaded.encoding } };
    }
    var inv = try cs.?.invert(doc.tree, doc.gpa);
    var inv_owned = true;
    defer if (inv_owned) inv.deinit();
    try doc.applyChangeSet(&cs.?, .reload);
    if (undo) |u| {
        const fwd = cs.?;
        cs = null;
        inv_owned = false;
        u.breakGroup();
        try u.record(fwd, inv, &.{}, &.{}, .{ .label = "Reload from disk", .origin = .reload, .timestamp = now });
        u.breakGroup();
        u.markSaved(u.current);
    }
    doc.saved_version = doc.version;
    file.disk = loaded.disk;
    file.encoding = loaded.encoding;
    file.eol = loaded.eol.style;
    return .reloaded_clean;
}

/// `probe` then `applyProbe`, blocking the caller. UI code runs `probe` on
/// a worker and posts the result back instead.
pub fn onWatchEvent(doc: *Document, file: *FileState, rt: *zg_core.Runtime, undo: ?*UndoTree) !ExternalChange {
    const p = try probe(doc.gpa, rt.io, file);
    return applyProbe(doc, file, undo, p, Io.Timestamp.now(rt.io, .real));
}

/// The ChangeSet turning `old` into `new_text`, touching only the lines a
/// line diff reports changed (trimmed to their differing bytes) and line
/// terminators that differ; null when the texts are equal.
pub fn reloadChanges(gpa: Allocator, old: PieceTree, new_text: []const u8) !?ChangeSet {
    var a = try LineSource.fromTree(gpa, old);
    defer a.deinit(gpa);
    if (std.mem.eql(u8, a.text, new_text)) return null;
    var b = try LineSource.fromBytes(gpa, new_text);
    defer b.deinit(gpa);
    var r = try diff.diffLines(gpa, &a, &b, .{ .intraline = .none, .indent_heuristic = false, .context_lines = 0 });
    defer r.deinit(gpa);
    var edits: std.ArrayList(pt.Edit) = .empty;
    defer edits.deinit(gpa);
    var hunk: ?Span = null;
    for (r.edits) |e| switch (e.kind) {
        .equal => {
            if (hunk) |h| try emitHunk(gpa, &edits, &a, &b, h);
            hunk = null;
            // Lines compare without terminators: CRLF to LF is still a change.
            for (0..e.len) |k| {
                const ia = e.a_start + k;
                const ib = e.b_start + k;
                const la = a.lines[ia];
                const lb = b.lines[ib];
                if (!std.mem.eql(u8, a.lineWithEol(ia)[la.len..], b.lineWithEol(ib)[lb.len..])) {
                    try edits.append(gpa, .{ .range = .{ .start = la.start + la.len, .end = la.start + la.len + la.eol }, .text = b.lineWithEol(ib)[lb.len..] });
                }
            }
        },
        .delete => {
            var h = hunk orelse Span{ .a_lo = e.a_start, .a_hi = e.a_start, .b_lo = e.b_start, .b_hi = e.b_start };
            h.a_hi = e.a_start + e.len;
            hunk = h;
        },
        .insert => {
            var h = hunk orelse Span{ .a_lo = e.a_start, .a_hi = e.a_start, .b_lo = e.b_start, .b_hi = e.b_start };
            h.b_hi = e.b_start + e.len;
            hunk = h;
        },
    };
    if (hunk) |h| try emitHunk(gpa, &edits, &a, &b, h);
    return try ChangeSet.fromEdits(gpa, a.text.len, edits.items);
}

/// A changed region: lines `a_lo..a_hi` of one text became `b_lo..b_hi`
/// of the other.
const Span = struct { a_lo: usize, a_hi: usize, b_lo: usize, b_hi: usize };

fn emitHunk(gpa: Allocator, edits: *std.ArrayList(pt.Edit), a: *const LineSource, b: *const LineSource, h: Span) !void {
    var a0: usize = @intCast(a.offsetOf(h.a_lo));
    var a1: usize = @intCast(a.offsetOf(h.a_hi));
    var b0: usize = @intCast(b.offsetOf(h.b_lo));
    var b1: usize = @intCast(b.offsetOf(h.b_hi));
    while (a0 < a1 and b0 < b1 and a.text[a0] == b.text[b0]) : ({
        a0 += 1;
        b0 += 1;
    }) {}
    while (a1 > a0 and b1 > b0 and a.text[a1 - 1] == b.text[b1 - 1]) : ({
        a1 -= 1;
        b1 -= 1;
    }) {}
    if (a0 == a1 and b0 == b1) return;
    try edits.append(gpa, .{ .range = .{ .start = a0, .end = a1 }, .text = b.text[b0..b1] });
}

/// A three-way merge.
pub const MergeResult = struct {
    text: []u8,
    /// Regions both sides changed differently, written with markers.
    conflicts: u32,

    /// Frees the text.
    pub fn deinit(m: *MergeResult, gpa: Allocator) void {
        gpa.free(m.text);
        m.* = undefined;
    }
};

/// Conflict marker labels.
pub const MergeLabels = struct {
    mine: []const u8 = "buffer",
    theirs: []const u8 = "disk",
};

/// Merges the changes `mine` and `theirs` each made to `base`, line by
/// line (diff3). A region only one side changed takes that side; regions
/// both changed (or changed on adjacent lines, as git does) take the
/// change when both made the same one and otherwise become
/// `<<<<<<< mine`, `=======`, `>>>>>>> theirs` blocks. Line terminators
/// are not compared. Callers pass snapshot text via `copyRange`.
pub fn merge3(gpa: Allocator, base: []const u8, mine: []const u8, theirs: []const u8, labels: MergeLabels) !MergeResult {
    var lb = try LineSource.fromBytes(gpa, base);
    defer lb.deinit(gpa);
    var lm = try LineSource.fromBytes(gpa, mine);
    defer lm.deinit(gpa);
    var lt = try LineSource.fromBytes(gpa, theirs);
    defer lt.deinit(gpa);
    const hm = try changedSpans(gpa, &lb, &lm);
    defer gpa.free(hm);
    const ht = try changedSpans(gpa, &lb, &lt);
    defer gpa.free(ht);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var conflicts: u32 = 0;
    var pos: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < hm.len or j < ht.len) {
        const take_mine = j == ht.len or (i < hm.len and hm[i].a_lo <= ht[j].a_lo);
        var lo = if (take_mine) hm[i].a_lo else ht[j].a_lo;
        var hi = lo;
        const m_start = i;
        const t_start = j;
        // Absorb every span touching the cluster, from either side.
        while (true) {
            if (i < hm.len and hm[i].a_lo <= hi) {
                hi = @max(hi, hm[i].a_hi);
                lo = @min(lo, hm[i].a_lo);
                i += 1;
            } else if (j < ht.len and ht[j].a_lo <= hi) {
                hi = @max(hi, ht[j].a_hi);
                lo = @min(lo, ht[j].a_lo);
                j += 1;
            } else break;
        }
        try out.appendSlice(gpa, linesText(&lb, pos, lo));
        const m_text = sideText(&lb, &lm, hm[m_start..i], lo, hi);
        const t_text = sideText(&lb, &lt, ht[t_start..j], lo, hi);
        if (i == m_start) {
            try out.appendSlice(gpa, t_text);
        } else if (j == t_start or std.mem.eql(u8, m_text, t_text)) {
            try out.appendSlice(gpa, m_text);
        } else {
            conflicts += 1;
            try out.print(gpa, "<<<<<<< {s}\n", .{labels.mine});
            try appendLines(gpa, &out, m_text);
            try out.appendSlice(gpa, "=======\n");
            try appendLines(gpa, &out, t_text);
            try out.print(gpa, ">>>>>>> {s}\n", .{labels.theirs});
        }
        pos = hi;
    }
    try out.appendSlice(gpa, linesText(&lb, pos, lb.count()));
    return .{ .text = try out.toOwnedSlice(gpa), .conflicts = conflicts };
}

fn changedSpans(gpa: Allocator, a: *const LineSource, b: *const LineSource) ![]Span {
    var r = try diff.diffLines(gpa, a, b, .{ .intraline = .none, .indent_heuristic = false, .context_lines = 0 });
    defer r.deinit(gpa);
    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(gpa);
    var cur: ?Span = null;
    for (r.edits) |e| switch (e.kind) {
        .equal => {
            if (cur) |c| try out.append(gpa, c);
            cur = null;
        },
        .delete => {
            var c = cur orelse Span{ .a_lo = e.a_start, .a_hi = e.a_start, .b_lo = e.b_start, .b_hi = e.b_start };
            c.a_hi = e.a_start + e.len;
            cur = c;
        },
        .insert => {
            var c = cur orelse Span{ .a_lo = e.a_start, .a_hi = e.a_start, .b_lo = e.b_start, .b_hi = e.b_start };
            c.b_hi = e.b_start + e.len;
            cur = c;
        },
    };
    if (cur) |c| try out.append(gpa, c);
    return out.toOwnedSlice(gpa);
}

fn linesText(src: *const LineSource, lo: usize, hi: usize) []const u8 {
    return src.text[@intCast(src.offsetOf(lo))..@intCast(src.offsetOf(hi))];
}

/// Base lines `lo..hi` as one side has them, given that side's spans
/// within the range (between spans the side equals the base).
fn sideText(base: *const LineSource, side: *const LineSource, spans: []const Span, lo: usize, hi: usize) []const u8 {
    if (spans.len == 0) return linesText(base, lo, hi);
    const s_lo = spans[0].b_lo - (spans[0].a_lo - lo);
    const s_hi = spans[spans.len - 1].b_hi + (hi - spans[spans.len - 1].a_hi);
    return linesText(side, s_lo, s_hi);
}

/// Appends `text`, ending it with a newline so a marker starts a line.
fn appendLines(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.appendSlice(gpa, text);
    if (text.len > 0 and text[text.len - 1] != '\n' and text[text.len - 1] != '\r') try out.append(gpa, '\n');
}
