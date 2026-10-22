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
//! One operation runs per file at a time; another asked meanwhile is
//! refused with `error.Busy`. Every outcome reaches `on_done` on the UI
//! thread.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Document = zg_editor.model.document.Document;
const UndoTree = zg_editor.model.edit.undo.UndoTree;
const save_mod = zg_editor.model.buffer.save;
const external = zg_editor.model.buffer.external;

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

    /// Binds `doc` to `path` (relative to `dir`), whose state on disk was
    /// `disk` when it was read (null: not on disk yet).
    pub fn init(gpa: Allocator, io: Io, app: ?*zg_gui.App, doc: *Document, undo: ?*UndoTree, dir: Io.Dir, path: []const u8, loaded: struct {
        encoding: zg_editor.model.encoding.Encoding = .utf8,
        eol: zg_editor.model.buffer.eol.Eol = .lf,
        disk: ?save_mod.DiskState = null,
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
        return fs;
    }

    /// Waits for a running operation, then frees `fs`.
    pub fn destroy(fs: *FileSync) void {
        if (fs.app) |app| while (fs.busy) {
            app.joinWork();
            _ = app.drainMessages();
        };
        fs.gpa.free(fs.path);
        fs.gpa.destroy(fs);
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

    fn done(fs: *FileSync, o: Outcome) void {
        fs.busy = false;
        if (fs.on_done) |h| h.f(h.ctx, fs, o);
    }
};

/// An operation between its worker half and its UI half.
const Op = struct {
    fs: *FileSync,
    kind: union(enum) {
        save: struct { job: save_mod.SaveJob, normalized: bool, result: anyerror!save_mod.DiskState = error.Pending },
        probe: struct { force: bool, result: anyerror!external.Probe = error.Pending },
    },
};

/// Worker: the blocking half.
fn runOp(op: *Op) void {
    const io = op.fs.io;
    switch (op.kind) {
        .save => |*s| s.result = s.job.run(io),
        .probe => |*p| p.result = external.probe(op.fs.gpa, io, &op.fs.file),
    }
    op.fs.app.?.post(.{ .ctx = op, .f = finish }) catch {
        // The mailbox is closed: the app is shutting down.
        free(op);
        op.fs.busy = false;
    };
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
            break :blk .{ .saved = .{ .bytes = disk.size, .normalized = s.normalized } };
        },
        .probe => |*p| blk: {
            const pr = p.result catch |e| break :blk .{ .check_failed = e };
            // Reverting: the reload replaces the edits (one undo step).
            if (p.force and pr == .changed) fs.doc.saved_version = fs.doc.version;
            var change = external.applyProbe(fs.doc, &fs.file, fs.undo, pr, Io.Timestamp.now(fs.io, .real)) catch |e| break :blk .{ .check_failed = e };
            break :blk switch (change) {
                .none => .unchanged,
                .reloaded_clean => .reloaded,
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
