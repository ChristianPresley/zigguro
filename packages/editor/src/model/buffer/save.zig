//! Saving a document: save-time normalizations as one undo group, then an
//! atomic write that preserves the file's encoding, BOM, line endings and
//! permissions.
//!
//! A save has three steps so the UI thread never waits on the disk:
//!
//! 1. `begin` (UI thread) applies the requested normalizations as one
//!    undo group "Save normalizations" and snapshots the document.
//! 2. `SaveJob.run` (a worker) checks the target for external changes,
//!    encodes the snapshot and writes it: to a temporary file in the same
//!    directory that is synced and renamed over the target, so a failure
//!    at any point leaves the original intact.
//! 3. `commit` (UI thread) records the new `DiskState`, marks the snapshot's
//!    version saved and moves the undo tree's saved marker.
//!
//! `save` runs all three for callers that may block (tests, the CLI).
//!
//! Hard links and symlinks: renaming over the path would break a hard link
//! and replace a symlink with a regular file. For a path that is a symlink
//! or has more than one link, the text is instead written in place
//! through the existing file: a copy of the old contents goes to
//! `SaveOptions.backup_dir` first (named by the path's hash, as in
//! `$state/zigguro/backup/<hash>`), the text is checked to be encodable
//! before the file is touched, and the file is cut to the new length only
//! after every byte is written.

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const pt = @import("piece_tree.zig");
const eol_mod = @import("eol.zig");
const enc = @import("../encoding.zig");
const document = @import("../document.zig");
const Snapshot = @import("../snapshot.zig").Snapshot;
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
const Eol = eol_mod.Eol;

/// What a save may change before writing, and how it writes.
pub const SaveOptions = struct {
    /// Remove spaces and tabs before every line end and at the end.
    trim_trailing_whitespace: bool = false,
    /// End a non-empty text with a line terminator.
    insert_final_newline: bool = false,
    /// Convert every terminator to this one (`mixed` means "keep").
    eol_override: ?Eol = null,
    /// Write in this encoding instead of the file's.
    encoding_override: ?Encoding = null,
    /// Write even when the file changed on disk since it was read
    /// (the user chose "overwrite").
    overwrite: bool = false,
    /// Where the in-place fallback keeps a copy of the old contents.
    backup_dir: ?Dir = null,
};

/// The errors a save reports to the user, plus the file system's.
pub const SaveError = error{
    /// A character has no encoding in the target encoding
    /// (`SaveJob.unrepresentable_at` gives its offset).
    Unrepresentable,
    /// The file changed on disk since it was read or last saved.
    ExternalChangeConflict,
    /// The file is read-only, or the directory is not writable.
    AccessDenied,
    NoSpaceLeft,
    IsDir,
    OutOfMemory,
} || File.OpenError || File.StatError || Dir.StatFileError || Dir.CreateFileAtomicError ||
    File.Atomic.ReplaceError || File.SyncError || File.Writer.Error || File.Writer.EndError ||
    File.Reader.Error || Dir.CopyFileError;

/// What the editor last knew about the file on disk.
pub const DiskState = struct {
    size: u64,
    mtime: Io.Timestamp,
    /// Inode number (POSIX) or file index (Windows).
    file_id: u128,
    /// XxHash3 of the bytes last read or written.
    content_hash: u64,

    /// The state of a file with metadata `st` and contents hashing to
    /// `hash`.
    pub fn fromStat(st: File.Stat, hash: u64) DiskState {
        return .{ .size = st.size, .mtime = st.mtime, .file_id = fileId(st), .content_hash = hash };
    }

    /// Whether `st` matches the recorded size, mtime and file id (a
    /// mismatch may still be a touch; compare `content_hash` to tell).
    pub fn sameMeta(d: DiskState, st: File.Stat) bool {
        return d.size == st.size and d.mtime.nanoseconds == st.mtime.nanoseconds and d.file_id == fileId(st);
    }
};

/// The file id of `st` as a u128.
pub fn fileId(st: File.Stat) u128 {
    return @intCast(st.inode);
}

/// Fails with `AccessDenied` for a read-only target, which the rename
/// would otherwise replace silently. Windows stat does not report
/// attributes, so there they are queried from the file.
fn checkWritable(dir: Dir, io: Io, path: []const u8, st: File.Stat) SaveError!void {
    if (builtin.os.tag != .windows) {
        if (isReadOnly(st.permissions)) return error.AccessDenied;
        return;
    }
    const w = std.os.windows;
    var f = try dir.openFile(io, path, .{});
    defer f.close(io);
    var iosb: w.IO_STATUS_BLOCK = undefined;
    var info: w.FILE.BASIC_INFORMATION = undefined;
    const rc = w.ntdll.NtQueryInformationFile(f.handle, &iosb, &info, @sizeOf(w.FILE.BASIC_INFORMATION), .Basic);
    if (rc == .SUCCESS and info.FileAttributes.READONLY) return error.AccessDenied;
}

/// Whether `p` forbids writing (Zig 0.16's Windows `Permissions.readOnly`
/// does not compile, so the attribute bit is tested directly).
pub fn isReadOnly(p: File.Permissions) bool {
    if (builtin.os.tag == .windows) return @intFromEnum(p) & windows_readonly != 0;
    return p.readOnly();
}

/// `p` with writing forbidden or allowed.
pub fn withReadOnly(p: File.Permissions, ro: bool) File.Permissions {
    if (builtin.os.tag == .windows) {
        const bits = @intFromEnum(p);
        const next = if (ro) bits | windows_readonly else bits & ~@as(@TypeOf(bits), windows_readonly);
        // Zero means "leave unchanged" to NtSetInformationFile.
        return @enumFromInt(if (next == 0) windows_normal else next);
    }
    return p.setReadOnly(ro);
}

/// FILE_ATTRIBUTE_READONLY and FILE_ATTRIBUTE_NORMAL.
const windows_readonly = 0x1;
const windows_normal = 0x80;

/// The content hash `DiskState` records.
pub fn hashBytes(bytes: []const u8) u64 {
    return std.hash.XxHash3.hash(0, bytes);
}

/// Where a document lives on disk and how it is stored there.
pub const FileState = struct {
    /// Borrowed; must stay open while the document is bound to it.
    dir: Dir,
    /// Relative to `dir`; borrowed.
    path: []const u8,
    encoding: Encoding = .utf8,
    /// The terminator style detected at load (informational).
    eol: Eol = .lf,
    /// Null for a file not yet on disk.
    disk: ?DiskState = null,
};

/// The ChangeSet the normalizations in `o` make to `t`, or null when they
/// change nothing.
pub fn normalizationChanges(gpa: Allocator, t: PieceTree, o: SaveOptions) !?ChangeSet {
    const override: ?Eol = if (o.eol_override) |e| (if (e == .mixed) null else e) else null;
    if (!o.trim_trailing_whitespace and !o.insert_final_newline and override == null) return null;
    const text = try t.copyRange(gpa, .{ .start = 0, .end = t.len() });
    defer gpa.free(text);
    const final_eol = (override orelse eol_mod.detectEol(t).dominant).bytes();
    var edits: std.ArrayList(pt.Edit) = .empty;
    defer edits.deinit(gpa);
    var start: usize = 0;
    while (start < text.len) {
        const nl = std.mem.indexOfAnyPos(u8, text, start, "\r\n") orelse text.len;
        const eol_len: usize = if (nl == text.len) 0 else if (text[nl] == '\r' and nl + 1 < text.len and text[nl + 1] == '\n') 2 else 1;
        var keep = nl;
        if (o.trim_trailing_whitespace) {
            while (keep > start and (text[keep - 1] == ' ' or text[keep - 1] == '\t')) keep -= 1;
        }
        const old_eol = text[nl..][0..eol_len];
        const new_eol: []const u8 = if (eol_len == 0)
            (if (o.insert_final_newline) final_eol else "")
        else
            (if (override) |e| e.bytes() else old_eol);
        if (keep < nl or !std.mem.eql(u8, old_eol, new_eol)) {
            try edits.append(gpa, .{ .range = .{ .start = keep, .end = nl + eol_len }, .text = new_eol });
        }
        start = nl + eol_len;
    }
    if (edits.items.len == 0) return null;
    return try ChangeSet.fromEdits(gpa, t.len(), edits.items);
}

/// Applies the normalizations in `o` to `doc` (UI thread) as one undo
/// group "Save normalizations" in `undo`. Returns whether anything
/// changed.
pub fn applyNormalizations(doc: *Document, undo: ?*UndoTree, o: SaveOptions, now: Io.Timestamp) !bool {
    var cs = (try normalizationChanges(doc.gpa, doc.tree, o)) orelse return false;
    var cs_owned = true;
    defer if (cs_owned) cs.deinit();
    var inv = try cs.invert(doc.tree, doc.gpa);
    var inv_owned = true;
    defer if (inv_owned) inv.deinit();
    try doc.applyChangeSet(&cs, .format);
    if (undo) |u| {
        u.breakGroup();
        cs_owned = false;
        inv_owned = false;
        try u.record(cs, inv, &.{}, &.{}, .{ .label = "Save normalizations", .origin = .format, .timestamp = now });
        u.breakGroup();
    }
    return true;
}

/// The write half of a save: a snapshot and where it goes. Created by
/// `begin` on the UI thread, run on a worker, finished by `commit`.
pub const SaveJob = struct {
    gpa: Allocator,
    snap: Snapshot,
    dir: Dir,
    path: []const u8,
    encoding: Encoding,
    /// The state the file must still be in (null: no check).
    expect: ?DiskState,
    overwrite: bool = false,
    backup_dir: ?Dir = null,
    /// The undo node whose state the snapshot is.
    undo_node: ?undo_mod.NodeId = null,
    /// Set by `run` when the text could not be encoded.
    unrepresentable_at: ?u64 = null,
    /// Set by `run` when it wrote through the existing file.
    in_place: bool = false,
    /// Testing: fail with `NoSpaceLeft` once this many bytes are written.
    fail_after: ?u64 = null,

    /// Releases the snapshot.
    pub fn deinit(job: *SaveJob) void {
        job.snap.release();
    }

    /// Writes the snapshot (blocking; any thread). Returns the new disk
    /// state; on error the file on disk is unchanged (except in place,
    /// see the module notes).
    pub fn run(job: *SaveJob, io: Io) SaveError!DiskState {
        const link_st = try statOrNull(job.dir, io, job.path, false);
        const st: ?File.Stat = if (link_st) |l|
            (if (l.kind == .sym_link) try statOrNull(job.dir, io, job.path, true) else l)
        else
            null;
        if (st) |s| {
            if (s.kind == .directory) return error.IsDir;
            if (job.expect) |exp| if (!job.overwrite and !exp.sameMeta(s)) {
                // A touch changes the metadata but not the bytes.
                if (try hashFile(job.dir, io, job.path) != exp.content_hash) return error.ExternalChangeConflict;
            };
            try checkWritable(job.dir, io, job.path, s);
        }
        const buf = try job.gpa.alloc(u8, 64 << 10);
        defer job.gpa.free(buf);
        var sink: Sink = .{ .fail_after = job.fail_after };
        job.in_place = if (link_st) |l| l.kind == .sym_link or (st != null and st.?.nlink > 1) else false;
        if (job.in_place) {
            try job.writeInPlace(io, st != null, buf, &sink);
        } else {
            var af = try job.dir.createFileAtomic(io, job.path, .{ .replace = true, .permissions = if (st) |s| s.permissions else .default_file });
            defer af.deinit(io);
            var fw = af.file.writer(io, buf);
            sink.w = &fw.interface;
            job.writeText(&sink) catch |e| return mapWriteError(e, &fw);
            try fw.flush();
            try af.file.sync(io);
            try af.replace(io);
        }
        const after = try job.dir.statFile(io, job.path, .{});
        return .fromStat(after, sink.hasher.final());
    }

    fn writeInPlace(job: *SaveJob, io: Io, exists: bool, buf: []u8, sink: *Sink) SaveError!void {
        // Nothing may touch the file until the text is known to encode.
        var check: Sink = .{};
        try job.writeText(&check);
        if (exists) if (job.backup_dir) |bd| {
            const name = std.fmt.hex(hashBytes(job.path));
            try job.dir.copyFile(job.path, bd, &name, io, .{});
        };
        var f = job.dir.openFile(io, job.path, .{ .mode = .read_write }) catch |e| switch (e) {
            // A dangling symlink: create its target.
            error.FileNotFound => try job.dir.createFile(io, job.path, .{ .truncate = false }),
            else => return e,
        };
        defer f.close(io);
        var fw = f.writer(io, buf);
        sink.w = &fw.interface;
        job.writeText(sink) catch |e| return mapWriteError(e, &fw);
        fw.end() catch |e| switch (e) {
            error.WriteFailed => return fw.err.?,
            else => |x| return x,
        };
        try f.sync(io);
    }

    /// Streams the snapshot into `sink` in `job.encoding`: UTF-8 chunks
    /// straight from the tree, other encodings 1 MiB at a time, cut on
    /// character boundaries.
    fn writeText(job: *SaveJob, sink: *Sink) (Allocator.Error || error{ WriteFailed, NoSpaceLeft, Unrepresentable })!void {
        const e = job.encoding;
        try sink.write(e.bom());
        var it = job.snap.tree.chunks(0);
        if (e == .utf8 or e == .utf8_bom) {
            while (it.next()) |c| try sink.write(c);
            return;
        }
        var carry: std.ArrayList(u8) = .empty;
        defer carry.deinit(job.gpa);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(job.gpa);
        var consumed: u64 = 0;
        while (true) {
            const c = it.next();
            if (c) |bytes| try carry.appendSlice(job.gpa, bytes);
            if (c != null and carry.items.len < encode_piece) continue;
            const cut = if (c == null) carry.items.len else charBoundary(carry.items);
            const piece = carry.items[0..cut];
            out.clearRetainingCapacity();
            enc.encodeBody(e, piece, &out, job.gpa) catch |err| switch (err) {
                error.Unrepresentable => {
                    job.unrepresentable_at = consumed + (enc.firstUnrepresentable(e, piece) orelse 0);
                    return error.Unrepresentable;
                },
                else => |x| return x,
            };
            try sink.write(out.items);
            consumed += cut;
            const tail = carry.items.len - cut;
            std.mem.copyForwards(u8, carry.items[0..tail], carry.items[cut..]);
            carry.shrinkRetainingCapacity(tail);
            if (c == null) return;
        }
    }
};

const encode_piece = 1 << 20;

/// Where `writeText` sends bytes: a writer (or nowhere, to check
/// encodability), hashing what it writes.
const Sink = struct {
    w: ?*Io.Writer = null,
    hasher: std.hash.XxHash3 = .init(0),
    written: u64 = 0,
    fail_after: ?u64 = null,

    fn write(s: *Sink, bytes: []const u8) error{ WriteFailed, NoSpaceLeft }!void {
        const w = s.w orelse return;
        if (s.fail_after) |n| if (s.written + bytes.len > n) {
            try w.writeAll(bytes[0..@intCast(n - s.written)]);
            try w.flush();
            return error.NoSpaceLeft;
        };
        try w.writeAll(bytes);
        s.hasher.update(bytes);
        s.written += bytes.len;
    }
};

fn mapWriteError(e: anyerror, fw: *File.Writer) SaveError {
    return switch (e) {
        error.WriteFailed => fw.err.?,
        error.NoSpaceLeft => error.NoSpaceLeft,
        error.Unrepresentable => error.Unrepresentable,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

/// The longest prefix of `s` that does not end inside a UTF-8 sequence.
fn charBoundary(s: []const u8) usize {
    var i = s.len;
    var k: usize = 0;
    while (k < 3 and i > 0 and s[i - 1] & 0xC0 == 0x80) : (k += 1) i -= 1;
    if (i == 0 or s[i - 1] < 0xC0) return s.len;
    const lead = s[i - 1];
    const n: usize = if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else 2;
    return if (k + 1 >= n) s.len else i - 1;
}

fn statOrNull(dir: Dir, io: Io, path: []const u8, follow: bool) SaveError!?File.Stat {
    return dir.statFile(io, path, .{ .follow_symlinks = follow }) catch |e| switch (e) {
        error.FileNotFound => null,
        else => |x| x,
    };
}

/// XxHash3 of the file at `path`, streamed.
pub fn hashFile(dir: Dir, io: Io, path: []const u8) (File.OpenError || File.Reader.Error)!u64 {
    var f = try dir.openFile(io, path, .{});
    defer f.close(io);
    var rbuf: [64 << 10]u8 = undefined;
    var r = f.reader(io, &rbuf);
    var h: std.hash.XxHash3 = .init(0);
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return r.err.?,
        };
        h.update(chunk);
        r.interface.toss(chunk.len);
    }
    return h.final();
}

/// `begin` and `commit` around a blocking `run`.
pub const SaveResult = struct {
    disk: DiskState,
    normalized: bool,
    in_place: bool,
};

/// Step 1 (UI thread): applies normalizations and snapshots `doc` for
/// `file`.
pub fn begin(doc: *Document, file: *const FileState, undo: ?*UndoTree, o: SaveOptions, now: Io.Timestamp) !struct { job: SaveJob, normalized: bool } {
    const normalized = try applyNormalizations(doc, undo, o, now);
    return .{ .normalized = normalized, .job = .{
        .gpa = doc.gpa,
        .snap = doc.snapshot(),
        .dir = file.dir,
        .path = file.path,
        .encoding = o.encoding_override orelse file.encoding,
        .expect = file.disk,
        .overwrite = o.overwrite,
        .backup_dir = o.backup_dir,
        .undo_node = if (undo) |u| u.current else null,
    } };
}

/// Step 3 (UI thread): records a successful `run`. Edits made while the
/// job ran keep the document dirty.
pub fn commit(doc: *Document, file: *FileState, job: *const SaveJob, disk: DiskState, undo: ?*UndoTree) void {
    file.disk = disk;
    file.encoding = job.encoding;
    doc.saved_version = job.snap.version;
    if (undo) |u| if (job.undo_node) |n| u.markSaved(n);
}

/// Saves `doc` to `file`, running the write on a worker of `rt` and
/// returning after `commit`. Blocks the caller; UI code calls `begin`,
/// hands the job to a worker and posts `commit` back instead.
pub fn save(doc: *Document, file: *FileState, rt: *zg_core.Runtime, undo: ?*UndoTree, o: SaveOptions) !SaveResult {
    var b = try begin(doc, file, undo, o, Io.Timestamp.now(rt.io, .real));
    defer b.job.deinit();
    var fut = rt.io.async(SaveJob.run, .{ &b.job, rt.io });
    const disk = try fut.await(rt.io);
    commit(doc, file, &b.job, disk, undo);
    return .{ .disk = disk, .normalized = b.normalized, .in_place = b.job.in_place };
}

test "save: char boundary" {
    try std.testing.expectEqual(@as(usize, 3), charBoundary("abc"));
    try std.testing.expectEqual(@as(usize, 1), charBoundary("a\xE2\x82"));
    try std.testing.expectEqual(@as(usize, 4), charBoundary("a\xE2\x82\xAC"));
    try std.testing.expectEqual(@as(usize, 1), charBoundary("a\xF0"));
}
