//! `FileSync`: keeps an open document and its file on disk in step without
//! blocking the UI thread (zg_editor.model.buffer.save and .external in
//! the workbench).
//!
//! - `save` runs E05's three-step save: `save.begin` on the UI thread
//!   (normalizations as one undo group, a snapshot), `SaveJob.run` on a
//!   worker (an atomic write that keeps the encoding, BOM, line endings and
//!   permissions, and refuses when the file changed on disk), then
//!   `save.commit` back on the UI thread.
//! - `check` probes the file on a worker (`external.probe`) and applies
//!   the result on the UI thread (`external.applyProbe`): a clean buffer
//!   reloads (undoable), a dirty one reports a conflict.
//! - `revert` reloads from disk even when the buffer is dirty; the reload
//!   is one undo step, so nothing is lost.
//!
//! - With `enableUndoFile`, each save also writes the undo history
//!   (`undo_file`, keyed by the file's absolute path and tied to the
//!   saved text's hash) on a worker, and opening the same unchanged text
//!   later restores it.
//!
//! - With `diff` set, the DiffModel's base follows the file: the saved
//!   text after a save, the file's text after a reload (the dirty-diff
//!   gutter).
//!
//! One operation runs per file at a time; another asked meanwhile is
//! refused with `error.Busy`. Every outcome reaches `on_done` on the UI
//! thread.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Document = zg_editor.model.document.Document;
const UndoTree = zg_editor.model.edit.undo.UndoTree;
const save_mod = zg_editor.model.buffer.save;
const external = zg_editor.model.buffer.external;
const undo_file = zg_editor.model.edit.undo_file;
const DiffModel = zg_editor.model.diff.diff_model.DiffModel;
const Snapshot = zg_editor.model.snapshot.Snapshot;
const log = std.log.scoped(.file_sync);

pub const FileState = save_mod.FileState;
pub const SaveOptions = save_mod.SaveOptions;

/// What finished.
pub const Outcome = union(enum) {
    saved: struct { bytes: u64, normalized: bool },
    /// The save did not happen (`ExternalChangeConflict` when the file
    /// changed on disk; `Unrepresentable` when the encoding cannot hold
    /// a character).
    save_failed: anyerror,
    /// `check` or `revert` found nothing new.
    unchanged,
    reloaded,
    /// The buffer has edits and the file changed: keep, revert or
    /// overwrite.
    conflict,
    deleted,
    check_failed: anyerror,
};

pub const DoneHook = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, fs: *FileSync, o: Outcome) void,
};

/// One document bound to its file. Lives at a fixed address (operations
/// point at it while they run).
pub const FileSync = struct {
    gpa: Allocator,
    io: Io,
    /// Where work runs (null until the window exists).
    app: ?*zg_gui.App,
    doc: *Document,
    undo: ?*UndoTree,
    file: FileState,
    /// Owned copy of the path `file.path` borrows.
    path: []u8,
    on_done: ?DoneHook = null,
    /// An operation is running.
    busy: bool = false,
    /// Where the undo history is kept (`enableUndoFile`).
    undo_store: ?UndoStore = null,
    /// An undo file is being written; `undo_next` waits for it.
    undo_writing: bool = false,
    /// The content hash of a mapped file is being computed (`hashLater`)
    /// on `hash_thread`.
    hashing: bool = false,
    hash_thread: ?std.Thread = null,
    undo_next: ?[]u8 = null,
    /// Diffs the document against the file's text (not owned).
    diff: ?*DiffModel = null,
    /// The diff's base is the file at git HEAD, which saving or reloading
    /// does not change.
    diff_head: bool = false,
    /// The HEAD commit the base was read at (`scm_base.headCommit`).
    head_commit: ?[32]u8 = null,

    pub const UndoStore = struct { dir: Io.Dir, key: [32]u8 };

    /// Binds `doc` to `path` (relative to `dir`), whose state on disk was
    /// `disk` when it was read (null: not on disk yet).
    pub fn init(gpa: Allocator, io: Io, app: ?*zg_gui.App, doc: *Document, undo: ?*UndoTree, dir: Io.Dir, path: []const u8, loaded: struct {
        encoding: zg_editor.model.encoding.Encoding = .utf8,
        eol: zg_editor.model.buffer.eol.Eol = .lf,
        disk: ?save_mod.DiskState = null,
        /// `disk.content_hash` is still to be computed from the document's
        /// original (large-file mode, the document owning the map).
        hash_pending: bool = false,
    }) !*FileSync {
        const fs = try gpa.create(FileSync);
        errdefer gpa.destroy(fs);
        const p = try gpa.dupe(u8, path);
        fs.* = .{
            .gpa = gpa,
            .io = io,
            .app = app,
            .doc = doc,
            .undo = undo,
            .path = p,
            .file = .{ .dir = dir, .path = p, .encoding = loaded.encoding, .eol = loaded.eol, .disk = loaded.disk },
        };
        if (loaded.hash_pending) if (loaded.disk) |d| fs.hashLater(d);
        return fs;
    }

    /// Computes the content hash of the document's original (the file as
    /// read) on its own thread (a pool task may run inline on the UI
    /// thread) and records it in `disk` if that still describes the same
    /// read. Until then a metadata change compares the text instead of
    /// telling a touch from an edit by hash.
    fn hashLater(fs: *FileSync, disk: save_mod.DiskState) void {
        const store = fs.doc.store;
        if (fs.app == null) return fs.hashNow();
        const job = fs.gpa.create(HashJob) catch return fs.hashNow();
        store.retain();
        job.* = .{ .fs = fs, .store = store, .disk = disk };
        fs.hashing = true;
        fs.hash_thread = std.Thread.spawn(.{}, runHash, .{job}) catch {
            fs.hashing = false;
            store.release();
            fs.gpa.destroy(job);
            return fs.hashNow();
        };
    }

    fn hashNow(fs: *FileSync) void {
        fs.file.disk.?.content_hash = save_mod.hashBytesParallel(fs.io, fs.doc.store.bt.original);
    }

    /// Waits for a running operation, then frees `fs`.
    pub fn destroy(fs: *FileSync) void {
        // Its result is posted, then run below.
        if (fs.hash_thread) |t| t.join();
        fs.hash_thread = null;
        if (fs.app) |app| while (fs.busy or fs.undo_writing or fs.hashing) {
            app.joinWork();
            _ = app.drainMessages();
        };
        if (fs.undo_next) |b| fs.gpa.free(b);
        fs.gpa.free(fs.path);
        fs.gpa.destroy(fs);
    }

    /// Keeps the undo history in `dir` after each save, keyed by the
    /// file's absolute path `abs_path`, unless privacy rules exclude the
    /// file (`undo_file.shouldPersist`). When the history saved there
    /// belongs to `text` (the document as just read, before any edit), it
    /// replaces the undo tree. Reads on the calling thread; returns
    /// whether a history came back.
    pub fn enableUndoFile(fs: *FileSync, dir: Io.Dir, abs_path: []const u8, text: []const u8) bool {
        if (!undo_file.shouldPersist(abs_path, text.len, .{})) return false;
        const key = undo_file.pathKey(abs_path);
        fs.undo_store = .{ .dir = dir, .key = key };
        const u = fs.undo orelse return false;
        const restored = undo_file.read(fs.io, dir, key, undo_file.contentHash(text), text.len, fs.gpa) catch |e| {
            log.warn("undo history of {s}: {t}", .{ fs.path, e });
            return false;
        } orelse return false;
        u.deinit();
        u.* = restored;
        return true;
    }

    /// Starts saving the document.
    pub fn save(fs: *FileSync, o: SaveOptions) !void {
        const app = fs.app orelse return error.NotAttached;
        if (fs.busy) return error.Busy;
        const op = try fs.gpa.create(Op);
        errdefer fs.gpa.destroy(op);
        const b = try save_mod.begin(fs.doc, &fs.file, fs.undo, o, Io.Timestamp.now(fs.io, .real));
        op.* = .{ .fs = fs, .kind = .{ .save = .{ .job = b.job, .normalized = b.normalized } } };
        fs.busy = true;
        app.spawn(runOp, .{op});
    }

    /// Starts looking for changes on disk.
    pub fn check(fs: *FileSync) !void {
        try fs.startProbe(false);
    }

    /// Starts reloading from disk, dropping unsaved edits (undoable).
    pub fn revert(fs: *FileSync) !void {
        try fs.startProbe(true);
    }

    fn startProbe(fs: *FileSync, force: bool) !void {
        const app = fs.app orelse return error.NotAttached;
        if (fs.busy) return error.Busy;
        const op = try fs.gpa.create(Op);
        op.* = .{ .fs = fs, .kind = .{ .probe = .{ .force = force } } };
        fs.busy = true;
        app.spawn(runOp, .{op});
    }

    /// UI thread: writes `bytes` (an encoded undo file, owned) after the
    /// one being written, if any.
    fn writeUndo(fs: *FileSync, bytes: []u8) void {
        if (fs.undo_writing) {
            if (fs.undo_next) |b| fs.gpa.free(b);
            fs.undo_next = bytes;
            return;
        }
        fs.undo_writing = true;
        fs.app.?.spawn(runUndoWrite, .{ fs, bytes });
    }

    /// Makes `snap` (a reference this takes over) the diff's base.
    fn rebase(fs: *FileSync, snap: Snapshot) void {
        var s = snap;
        const m = fs.diff orelse return s.release();
        if (fs.diff_head) return s.release();
        m.setBase(s) catch |e| {
            s.release();
            log.warn("diff of {s}: {t}", .{ fs.path, e });
        };
    }

    fn done(fs: *FileSync, o: Outcome) void {
        fs.busy = false;
        if (fs.on_done) |h| h.f(h.ctx, fs, o);
    }
};

/// An operation between its worker half and its UI half.
const Op = struct {
    fs: *FileSync,
    kind: union(enum) {
        save: struct {
            job: save_mod.SaveJob,
            normalized: bool,
            result: anyerror!save_mod.DiskState = error.Pending,
            /// `undo_file.contentHash` of the saved text (with an undo store).
            hash: [32]u8 = undefined,
        },
        probe: struct { force: bool, result: anyerror!external.Probe = error.Pending },
    },
};

/// Worker: the blocking half.
fn runOp(op: *Op) void {
    const io = op.fs.io;
    switch (op.kind) {
        .save => |*s| {
            s.result = s.job.run(io);
            if (op.fs.undo_store != null) s.hash = textHash(&s.job.snap);
        },
        .probe => |*p| p.result = external.probe(op.fs.gpa, io, &op.fs.file),
    }
    op.fs.app.?.post(.{ .ctx = op, .f = finish }) catch {
        // The mailbox is closed: the app is shutting down.
        free(op);
        op.fs.busy = false;
    };
}

const HashJob = struct {
    fs: *FileSync,
    store: *zg_editor.model.snapshot.Store,
    /// What `fs.file.disk` was when the job started.
    disk: save_mod.DiskState,
};

/// Hash thread: hashes the original, then hands the result to the UI
/// thread.
fn runHash(job: *HashJob) void {
    job.disk.content_hash = save_mod.hashBytes(job.store.bt.original);
    job.fs.app.?.post(.{ .ctx = job, .f = hashDone }) catch {
        job.store.release();
        job.fs.hashing = false;
        job.fs.gpa.destroy(job);
    };
}

/// UI thread: records the hash unless the file state moved on (saved or
/// reloaded since).
fn hashDone(ctx: *anyopaque, _: *zg_gui.App) void {
    const job: *HashJob = @ptrCast(@alignCast(ctx));
    const fs = job.fs;
    if (fs.file.disk) |*d| if (d.size == job.disk.size and d.file_id == job.disk.file_id and d.mtime.nanoseconds == job.disk.mtime.nanoseconds and d.content_hash == 0) {
        d.content_hash = job.disk.content_hash;
    };
    job.store.release();
    fs.hashing = false;
    if (fs.hash_thread) |t| t.detach();
    fs.hash_thread = null;
    fs.gpa.destroy(job);
}

/// `undo_file.contentHash` of a snapshot's text, chunk by chunk.
fn textHash(snap: *const zg_editor.model.snapshot.Snapshot) [32]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    var it = snap.tree.chunks(0);
    while (it.next()) |c| h.update(c);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// Worker: writes an undo file atomically.
fn runUndoWrite(fs: *FileSync, bytes: []u8) void {
    const st = fs.undo_store.?;
    const name = undo_file.fileName(st.key);
    writeAtomic(fs.io, st.dir, &name, bytes) catch |e| log.warn("undo history of {s}: {t}", .{ fs.path, e });
    fs.gpa.free(bytes);
    fs.app.?.post(.{ .ctx = fs, .f = undoWritten }) catch {
        fs.undo_writing = false;
    };
}

fn writeAtomic(io: Io, dir: Io.Dir, name: []const u8, bytes: []const u8) !void {
    var af = try dir.createFileAtomic(io, name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.file.sync(io);
    try af.replace(io);
}

/// UI thread: an undo file was written; starts the next.
fn undoWritten(ctx: *anyopaque, _: *zg_gui.App) void {
    const fs: *FileSync = @ptrCast(@alignCast(ctx));
    fs.undo_writing = false;
    if (fs.undo_next) |b| {
        fs.undo_next = null;
        fs.writeUndo(b);
    }
}

fn free(op: *Op) void {
    switch (op.kind) {
        .save => |*s| s.job.deinit(),
        .probe => |*p| if (p.result) |*pr| pr.deinit(op.fs.gpa) else |_| {},
    }
    op.fs.gpa.destroy(op);
}

/// UI thread: the committing half.
fn finish(ctx: *anyopaque, _: *zg_gui.App) void {
    const op: *Op = @ptrCast(@alignCast(ctx));
    const fs = op.fs;
    const o: Outcome = switch (op.kind) {
        .save => |*s| blk: {
            defer s.job.deinit();
            const disk = s.result catch |e| break :blk .{ .save_failed = e };
            save_mod.commit(fs.doc, &fs.file, &s.job, disk, fs.undo);
            if (fs.diff != null) fs.rebase(s.job.snap.retain());
            if (fs.undo_store != null) if (fs.undo) |u| {
                const len = s.job.snap.len();
                if (undo_file.encode(fs.gpa, u, s.hash, len, undo_file.default_max_bytes)) |bytes|
                    fs.writeUndo(bytes)
                else |e|
                    log.warn("undo history of {s}: {t}", .{ fs.path, e });
            };
            break :blk .{ .saved = .{ .bytes = disk.size, .normalized = s.normalized } };
        },
        .probe => |*p| blk: {
            const pr = p.result catch |e| break :blk .{ .check_failed = e };
            // Reverting: the reload replaces the edits (one undo step).
            if (p.force and pr == .changed) fs.doc.saved_version = fs.doc.version;
            var change = external.applyProbe(fs.doc, &fs.file, fs.undo, pr, Io.Timestamp.now(fs.io, .real)) catch |e| break :blk .{ .check_failed = e };
            break :blk switch (change) {
                .none => .unchanged,
                .reloaded_clean => r: {
                    if (fs.diff != null) fs.rebase(fs.doc.snapshot());
                    break :r .reloaded;
                },
                .deleted => .deleted,
                .conflict => |*c| c: {
                    c.deinit(fs.gpa);
                    break :c .conflict;
                },
            };
        },
    };
    fs.gpa.destroy(op);
    fs.done(o);
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

const Fx = struct {
    tmp: testing.TmpDir,
    app: zg_gui.App,
    doc: *Document,
    undo: UndoTree,
    fs: *FileSync,
    last: ?Outcome = null,

    fn init(f: *Fx, bytes: []const u8) !void {
        const gpa = testing.allocator;
        f.tmp = testing.tmpDir(.{});
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = bytes });
        var l = try external.load(gpa, testing.io, f.tmp.dir, "a.txt", null, .utf8);
        defer l.deinit(gpa);
        f.app = zg_gui.App.init(gpa);
        f.doc = try Document.initBytes(gpa, @enumFromInt(1), l.text);
        f.undo = .init(gpa, .{});
        f.fs = try FileSync.init(gpa, testing.io, &f.app, f.doc, &f.undo, f.tmp.dir, "a.txt", .{ .encoding = l.encoding, .eol = l.eol.style, .disk = l.disk });
        f.fs.on_done = .{ .ctx = f, .f = onDone };
    }

    fn deinit(f: *Fx) void {
        f.fs.destroy();
        f.undo.deinit();
        f.doc.deinit();
        f.app.deinit();
        f.tmp.cleanup();
    }

    fn onDone(ctx: *anyopaque, _: *FileSync, o: Outcome) void {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.last = o;
    }

    /// Runs the posted UI halves and returns the outcome.
    fn settle(f: *Fx) Outcome {
        f.app.joinWork();
        _ = f.app.drainMessages();
        defer f.last = null;
        return f.last.?;
    }

    fn edit(f: *Fx, at: u64, text: []const u8) !void {
        var cs = try zg_editor.model.edit.change_set.ChangeSet.fromEdits(testing.allocator, f.doc.len(), &.{.{ .range = .{ .start = at, .end = at }, .text = text }});
        defer cs.deinit();
        try f.doc.applyChangeSet(&cs, .{ .user = 0 });
    }

    fn content(f: *Fx) ![]u8 {
        return f.doc.tree.copyRange(testing.allocator, .{ .start = 0, .end = f.doc.len() });
    }

    fn disk(f: *Fx) ![]u8 {
        return f.tmp.dir.readFileAlloc(testing.io, "a.txt", testing.allocator, .limited(1 << 20));
    }
};

test "file sync: save, external change, conflict, overwrite and revert" {
    const gpa = testing.allocator;
    var f: Fx = undefined;
    try f.init("one\r\ntwo\r\n");
    defer f.deinit();

    // A save keeps the CRLF line ends and marks the buffer clean.
    try f.edit(0, "zero ");
    try testing.expect(f.doc.isDirty());
    try f.fs.save(.{});
    try testing.expectError(error.Busy, f.fs.save(.{}));
    try testing.expectEqual(std.meta.Tag(Outcome).saved, std.meta.activeTag(f.settle()));
    try testing.expect(!f.doc.isDirty());
    {
        const b = try f.disk();
        defer gpa.free(b);
        try testing.expectEqualStrings("zero one\r\ntwo\r\n", b);
    }

    // Clean buffer, file changed elsewhere: reloads.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "from disk\r\n" });
    try f.fs.check();
    try testing.expectEqual(Outcome.reloaded, f.settle());
    {
        const t = try f.content();
        defer gpa.free(t);
        try testing.expectEqualStrings("from disk\r\n", t);
    }

    // Dirty buffer and a changed file: a conflict, and saving refuses.
    try f.edit(0, "mine ");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "theirs, longer\r\n" });
    try f.fs.check();
    try testing.expectEqual(Outcome.conflict, f.settle());
    try f.fs.save(.{});
    const failed = f.settle();
    try testing.expectEqual(@as(anyerror, error.ExternalChangeConflict), failed.save_failed);

    // Overwrite wins.
    try f.fs.save(.{ .overwrite = true });
    try testing.expectEqual(std.meta.Tag(Outcome).saved, std.meta.activeTag(f.settle()));
    {
        const b = try f.disk();
        defer gpa.free(b);
        try testing.expectEqualStrings("mine from disk\r\n", b);
    }

    // Revert drops edits, as one undo step.
    try f.edit(0, "scratch ");
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "reverted\n" });
    try f.fs.revert();
    try testing.expectEqual(Outcome.reloaded, f.settle());
    try testing.expect(!f.doc.isDirty());
    {
        const t = try f.content();
        defer gpa.free(t);
        try testing.expectEqualStrings("reverted\n", t);
    }

    // Deleted on disk.
    try f.tmp.dir.deleteFile(testing.io, "a.txt");
    try f.fs.check();
    try testing.expectEqual(Outcome.deleted, f.settle());
}

test "file sync: the undo history is written on save and restored on open" {
    const gpa = testing.allocator;
    var f: Fx = undefined;
    try f.init("hello\n");
    defer f.deinit();
    var undo_dir = try f.tmp.dir.createDirPathOpen(testing.io, "undo", .{});
    defer undo_dir.close(testing.io);
    try testing.expect(!f.fs.enableUndoFile(undo_dir, "/work/a.txt", "hello\n"));

    // Two undoable edits, then a save.
    for ([_][]const u8{ "one ", "two " }) |w| {
        var cs = try zg_editor.model.edit.change_set.ChangeSet.fromEdits(gpa, f.doc.len(), &.{.{ .range = .{ .start = 0, .end = 0 }, .text = w }});
        errdefer cs.deinit();
        var inv = try cs.invert(f.doc.tree, gpa);
        errdefer inv.deinit();
        try f.doc.applyChangeSet(&cs, .{ .user = 0 });
        try f.undo.record(cs, inv, &.{}, &.{}, .{ .origin = .{ .user = 0 }, .timestamp = .{ .nanoseconds = 1 } });
        f.undo.breakGroup();
    }
    try f.fs.save(.{});
    try testing.expectEqual(std.meta.Tag(Outcome).saved, std.meta.activeTag(f.settle()));
    // The undo file is written after the save reports.
    f.app.joinWork();
    _ = f.app.drainMessages();
    try testing.expect(!f.fs.undo_writing);

    // Reopening the saved text brings the history back, at the saved state.
    var undo2: UndoTree = .init(gpa, .{});
    defer undo2.deinit();
    const fs2 = try FileSync.init(gpa, testing.io, &f.app, f.doc, &undo2, f.tmp.dir, "a.txt", .{});
    defer fs2.destroy();
    try testing.expect(fs2.enableUndoFile(undo_dir, "/work/a.txt", "two one hello\n"));
    try testing.expect(undo2.isAtSaved());
    try testing.expect(undo2.canUndo());
    // Other text (changed elsewhere since): not restored.
    var undo3: UndoTree = .init(gpa, .{});
    defer undo3.deinit();
    const fs3 = try FileSync.init(gpa, testing.io, &f.app, f.doc, &undo3, f.tmp.dir, "a.txt", .{});
    defer fs3.destroy();
    try testing.expect(!fs3.enableUndoFile(undo_dir, "/work/a.txt", "changed\n"));
    try testing.expect(!undo3.canUndo());
    // Secret files are never written.
    try testing.expect(!fs3.enableUndoFile(undo_dir, "/work/.env", "changed\n"));
    try testing.expect(fs3.undo_store == null or !std.mem.eql(u8, &fs3.undo_store.?.key, &undo_file.pathKey("/work/.env")));
}

test "file sync: the diff base follows saves and reloads" {
    var f: Fx = undefined;
    try f.init("a\nb\n");
    defer f.deinit();
    const m = try DiffModel.init(testing.allocator, null, f.doc.snapshot(), f.doc, .{});
    defer m.deinit();
    try m.completeFull();
    f.fs.diff = m;
    try testing.expectEqual(@as(usize, 0), m.hunks().len);

    try f.edit(0, "new\n");
    try testing.expectEqual(@as(usize, 1), m.hunks().len);
    try f.fs.save(.{});
    _ = f.settle();
    try m.completeFull();
    try testing.expectEqual(@as(usize, 0), m.hunks().len);

    // Reloaded from disk: no difference from the new base either.
    try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "x\ny\nz\n" });
    try f.fs.check();
    try testing.expectEqual(Outcome.reloaded, f.settle());
    try m.completeFull();
    try testing.expectEqual(@as(usize, 0), m.hunks().len);
}

test "file_sync: a mapped file's content hash is computed on a worker" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const n: usize = @intCast(external.map_min + 3);
    const data = try gpa.alloc(u8, n);
    defer gpa.free(data);
    for (data, 0..) |*b, i| b.* = if (i % 40 == 39) '\n' else 'x';
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "big.txt", .data = data });
    const l = try external.load(gpa, testing.io, tmp.dir, "big.txt", null, .utf8);
    try testing.expect(l.hash_pending);
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var app = zg_gui.App.init(gpa);
    defer app.deinit();
    // Posting from the hash thread needs the runtime's mailbox.
    app.attachRuntime(&rt);
    const doc = try Document.initMapped(gpa, @enumFromInt(1), l.map.?);
    defer doc.deinit();
    const fs = try FileSync.init(gpa, testing.io, &app, doc, null, tmp.dir, "big.txt", .{ .disk = l.disk, .hash_pending = true });
    defer fs.destroy();
    try testing.expect(fs.hashing);
    fs.hash_thread.?.join();
    fs.hash_thread = null;
    _ = app.drainMessages();
    try testing.expect(!fs.hashing);
    try testing.expectEqual(try save_mod.hashFile(tmp.dir, testing.io, "big.txt"), fs.file.disk.?.content_hash);
}
