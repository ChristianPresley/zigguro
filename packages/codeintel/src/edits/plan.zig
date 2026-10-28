//! Workspace edit planning (E07.F04.S02.T01): an LSP `WorkspaceEdit`
//! turned into an `EditPlan`, the ordered steps the engine applies.
//!
//! - `documentChanges` wins over `changes` when both are present.
//! - A `TextDocumentEdit` with a version must match the version last sent
//!   to that server for an open document with nothing unsent; LSP edits
//!   are never rebased.
//! - The edits of one `TextDocumentEdit` are all relative to the text
//!   before it: they are sorted (stable, so inserts at one point keep
//!   their order) and an overlap fails the plan. Snippet edits become
//!   their plain text.
//! - Planning runs the whole edit on copies of the touched files (a small
//!   virtual workspace), so each text step's byte edits are relative to
//!   the text the step will see (after earlier steps, creates and
//!   renames), and resource operations are checked against their flags
//!   before anything is touched. The copies also give the review queue
//!   each file's text before and after (`files`).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Snippet = @import("../snippet/Snippet.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const uri_mod = zg_lsp.uri;
const DocumentRegistry = zg_editor.model.api.registry.DocumentRegistry;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const PieceTree = zg_editor.model.buffer.piece_tree.PieceTree;
pub const Replace = zg_editor.model.edit.change_set.Replace;
pub const Encoding = zg_core.utf8.Encoding;

pub const FileKind = enum { file, dir };

/// The file system the engine changes (E08's file operations in the
/// app). Paths are absolute.
pub const FileOps = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        kind: *const fn (ctx: *anyopaque, path: []const u8) ?FileKind,
        /// The file's bytes, owned by `gpa`.
        read: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror![]u8,
        /// Writes (creating or replacing) the file; makes its folders.
        write: *const fn (ctx: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void,
        /// Moves a file or folder; `new` does not exist.
        move: *const fn (ctx: *anyopaque, old: []const u8, new: []const u8) anyerror!void,
        /// Moves a file or folder tree out of the way and returns a token
        /// (owned by `gpa`) that `restore` puts it back with.
        trash: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror![]u8,
        restore: *const fn (ctx: *anyopaque, token: []const u8, path: []const u8) anyerror!void,
        /// The token will not be restored (the trashed copy may be purged).
        forget: *const fn (ctx: *anyopaque, token: []const u8) void,
    };

    pub fn kind(f: FileOps, path: []const u8) ?FileKind {
        return f.vtable.kind(f.ctx, path);
    }
    pub fn read(f: FileOps, gpa: Allocator, path: []const u8) ![]u8 {
        return f.vtable.read(f.ctx, gpa, path);
    }
    pub fn write(f: FileOps, path: []const u8, bytes: []const u8) !void {
        return f.vtable.write(f.ctx, path, bytes);
    }
    pub fn move(f: FileOps, old: []const u8, new: []const u8) !void {
        return f.vtable.move(f.ctx, old, new);
    }
    pub fn trash(f: FileOps, gpa: Allocator, path: []const u8) ![]u8 {
        return f.vtable.trash(f.ctx, gpa, path);
    }
    pub fn restore(f: FileOps, token: []const u8, path: []const u8) !void {
        return f.vtable.restore(f.ctx, token, path);
    }
    pub fn forget(f: FileOps, token: []const u8) void {
        f.vtable.forget(f.ctx, token);
    }
};

/// Where the edit comes from: the server's position encoding and the
/// versions it was sent.
pub const Source = struct {
    enc: Encoding = .utf16,
    versions: ?VersionLookup = null,
};

pub const VersionLookup = struct {
    ctx: *anyopaque,
    /// The version last sent for `h`, or null when the server does not
    /// have it open or has not been sent its latest changes.
    f: *const fn (ctx: *anyopaque, h: DocHandle) ?i32,
};

pub const Annotation = struct {
    id: []const u8,
    label: []const u8,
    description: ?[]const u8,
    needs_confirmation: bool,
};

pub const Step = struct {
    /// The index of the change in the edit (`failedChange`).
    index: u32,
    annotation: ?u32 = null,
    op: Op,

    pub const Op = union(enum) {
        text: Text,
        create: struct { path: []const u8, overwrite: bool },
        rename: struct { old: []const u8, new: []const u8, overwrite: bool },
        delete: struct { path: []const u8 },
        /// A create, rename or delete its flags say to skip.
        skip,
    };

    pub const Text = struct {
        path: []const u8,
        /// Against the file's text when the step runs: sorted, not
        /// overlapping.
        edits: []const Replace,
        /// Hash of that text (`hashText`): the engine fails the step when
        /// the file changed since planning.
        base_hash: u64,
        base_len: u64,
    };
};

/// A file's text before and after the plan, for review and preview.
pub const FileChange = struct {
    path: []const u8,
    /// Null when the file did not exist.
    before: ?[]const u8,
    /// Null when the plan deletes it (or moves it away).
    after: ?[]const u8,
};

pub const EditPlan = struct {
    arena: std.heap.ArenaAllocator,
    steps: []const Step,
    annotations: []const Annotation,
    needs_confirmation: bool,
    label: []const u8,
    /// Files whose text changes, are created or are deleted.
    files: []const FileChange,
    new_bytes: u64,

    pub fn deinit(p: *EditPlan) void {
        p.arena.deinit();
    }

    /// More than the limits a user edit applies without asking.
    pub fn isLarge(p: *const EditPlan, l: Limits) bool {
        return p.files.len > l.max_files or p.new_bytes > l.max_new_bytes;
    }
};

pub const Limits = struct {
    max_files: usize = 1000,
    max_new_bytes: u64 = 50 << 20,
};

pub const Error = error{
    VersionMismatch,
    Overlap,
    BadUri,
    NotFound,
    Exists,
    NotAFile,
    UnknownAnnotation,
} || Allocator.Error;

/// Why planning failed, and at which change (for `failedChange`).
pub const Failure = struct { index: u32, err: anyerror };

pub fn reason(err: anyerror) []const u8 {
    return switch (err) {
        error.VersionMismatch => "document version mismatch",
        error.Overlap => "overlapping edits",
        error.BadUri => "unsupported URI",
        error.NotFound => "file not found",
        error.Exists => "file already exists",
        error.NotAFile => "not a file",
        error.UnknownAnnotation => "unknown change annotation",
        error.Changed => "the file changed since the edit was computed",
        error.ReadOnly => "the document is read-only",
        error.OutOfMemory => "out of memory",
        error.ReviewUnavailable => "review is not available (it starts with the agent)",
        error.DeletesNotReviewable => "the review queue cannot take file deletions yet",
        error.OutsideWorkspace => "the edit touches files outside the workspace",
        else => @errorName(err),
    };
}

/// The FNV-1a 64 hash of `t`'s text.
pub fn hashText(t: *const PieceTree) u64 {
    var h: std.hash.Fnv1a_64 = .init();
    var it = t.chunks(0);
    while (it.next()) |c| h.update(c);
    return h.final();
}

fn hashBytes(b: []const u8) u64 {
    var h: std.hash.Fnv1a_64 = .init();
    h.update(b);
    return h.final();
}

/// One file of the virtual workspace.
const Entry = struct {
    kind: ?FileKind,
    /// The current text (files only; loaded on first use).
    text: ?std.ArrayList(u8) = null,
    /// The text before the plan (null: did not exist).
    before: ?[]const u8 = null,
    /// `before` has been recorded.
    based: bool = false,
    touched: bool = false,
};

const Planner = struct {
    gpa: Allocator,
    a: Allocator,
    docs: *DocumentRegistry,
    fs: FileOps,
    src: Source,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,
    /// Renames so far, oldest first: a path under `new` was at `old`.
    renames: std.ArrayList([2][]const u8) = .empty,
    steps: std.ArrayList(Step) = .empty,
    annotations: std.ArrayList(Annotation) = .empty,
    edits: std.ArrayList(Replace) = .empty,
    lines: std.ArrayList(u64) = .empty,
    new_bytes: u64 = 0,

    fn deinit(p: *Planner) void {
        for (p.entries.values()) |*e| if (e.text) |*t| t.deinit(p.gpa);
        p.entries.deinit(p.gpa);
        p.renames.deinit(p.gpa);
        p.steps.deinit(p.gpa);
        p.annotations.deinit(p.gpa);
        p.edits.deinit(p.gpa);
        p.lines.deinit(p.gpa);
    }

    fn pathOf(p: *Planner, uri: []const u8) Error![]const u8 {
        const path = (uri_mod.pathFromUri(p.a, uri) catch return error.BadUri) orelse return error.BadUri;
        return path;
    }

    /// Where `path` was before the renames so far.
    fn original(p: *Planner, path: []const u8) Allocator.Error![]const u8 {
        var cur = path;
        var i = p.renames.items.len;
        while (i > 0) {
            i -= 1;
            const r = p.renames.items[i];
            if (std.mem.eql(u8, cur, r[1])) {
                cur = r[0];
            } else if (under(cur, r[1])) {
                cur = try std.mem.concat(p.a, u8, &.{ r[0], cur[r[1].len..] });
            }
        }
        return cur;
    }

    /// The kind of `path` now, in the virtual workspace.
    fn kindOf(p: *Planner, path: []const u8) Allocator.Error!?FileKind {
        if (p.entries.get(path)) |e| return e.kind;
        // Under a folder deleted or moved away?
        for (p.entries.keys(), p.entries.values()) |k, e| if (e.kind == null and under(path, k)) return null;
        const orig = try p.original(path);
        if (orig.ptr != path.ptr) {
            if (p.entries.get(orig)) |e| return e.kind;
        }
        if (try p.docs.findFile(orig)) |_| return .file;
        return p.fs.kind(orig);
    }

    /// The entry for file `path`, its text loaded.
    fn file(p: *Planner, path: []const u8) (Error || anyerror)!*Entry {
        if (p.entries.getPtr(path) == null) {
            const k = try p.kindOf(path);
            if (k != .file) return if (k == null) error.NotFound else error.NotAFile;
            try p.entries.put(p.gpa, try p.a.dupe(u8, path), .{ .kind = .file });
        }
        const e = p.entries.getPtr(path).?;
        if (e.kind != .file) return if (e.kind == null) error.NotFound else error.NotAFile;
        if (e.text == null) {
            var t: std.ArrayList(u8) = .empty;
            errdefer t.deinit(p.gpa);
            const orig = try p.original(path);
            if (try p.docs.findFile(orig)) |h| {
                const doc = p.docs.get(h).?;
                try t.ensureTotalCapacity(p.gpa, @intCast(doc.len()));
                var it = doc.tree.chunks(0);
                while (it.next()) |c| t.appendSliceAssumeCapacity(c);
            } else {
                const bytes = try p.fs.read(p.gpa, orig);
                t = .fromOwnedSlice(bytes);
            }
            e.text = t;
        }
        if (!e.based) {
            e.based = true;
            e.before = try p.a.dupe(u8, e.text.?.items);
        }
        return e;
    }

    /// Records that `path` did not exist before the plan (when first seen).
    fn markNew(p: *Planner, path: []const u8) Allocator.Error!*Entry {
        const gop = try p.entries.getOrPut(p.gpa, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try p.a.dupe(u8, path);
            gop.value_ptr.* = .{ .kind = null, .based = true };
        }
        return gop.value_ptr;
    }

    fn annotationIndex(p: *Planner, id: ?[]const u8) Error!?u32 {
        const s = id orelse return null;
        for (p.annotations.items, 0..) |an, i| if (std.mem.eql(u8, an.id, s)) return @intCast(i);
        return error.UnknownAnnotation;
    }

    fn text(p: *Planner, index: u32, doc_uri: []const u8, version: ?i32, items: anytype) (Error || anyerror)!void {
        const path = try p.pathOf(doc_uri);
        if (version) |v| {
            const h = (try p.docs.findFile(try p.original(path))) orelse return error.VersionMismatch;
            const look = p.src.versions orelse return error.VersionMismatch;
            if (look.f(look.ctx, h) != v) return error.VersionMismatch;
        }
        const e = try p.file(path);
        e.touched = true;
        const cur = &e.text.?;
        try p.indexLines(cur.items);
        p.edits.clearRetainingCapacity();
        var annotation: ?u32 = null;
        for (items) |item| {
            const r, const new_text, const ann = switch (@TypeOf(item)) {
                protocol.TextEdit => .{ item.range, item.newText, null },
                else => switch (item) {
                    .text_edit => |te| .{ te.range, te.newText, null },
                    .annotated_text_edit => |te| .{ te.range, te.newText, te.annotationId },
                    .snippet_text_edit => |te| blk: {
                        var sn = try Snippet.parse(p.gpa, te.snippet.value);
                        defer sn.deinit();
                        break :blk .{ te.range, try sn.plainText(p.a), te.annotationId };
                    },
                },
            };
            if (try p.annotationIndex(ann)) |ai| annotation = ai;
            const start = p.byteOf(cur.items, r.start);
            const end = @max(start, p.byteOf(cur.items, r.end));
            try p.edits.append(p.gpa, .{ .range = .{ .start = start, .end = end }, .text = new_text });
        }
        std.sort.block(Replace, p.edits.items, {}, struct {
            fn lt(_: void, x: Replace, y: Replace) bool {
                return x.range.start < y.range.start;
            }
        }.lt);
        var i: usize = 1;
        while (i < p.edits.items.len) : (i += 1) {
            if (p.edits.items[i].range.start < p.edits.items[i - 1].range.end) return error.Overlap;
        }
        const base_hash = hashBytes(cur.items);
        const base_len: u64 = cur.items.len;
        const edits = try p.a.alloc(Replace, p.edits.items.len);
        for (edits, p.edits.items) |*d, s| {
            d.* = .{ .range = s.range, .text = try p.a.dupe(u8, s.text) };
            p.new_bytes += s.text.len;
        }
        // Apply to the copy in one pass.
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(p.gpa);
        try next.ensureTotalCapacity(p.gpa, cur.items.len + p.new_bytes);
        var at: usize = 0;
        for (edits) |ed| {
            try next.appendSlice(p.gpa, cur.items[at..@intCast(ed.range.start)]);
            try next.appendSlice(p.gpa, ed.text);
            at = @intCast(ed.range.end);
        }
        try next.appendSlice(p.gpa, cur.items[at..]);
        cur.deinit(p.gpa);
        cur.* = next;
        try p.steps.append(p.gpa, .{ .index = index, .annotation = annotation, .op = .{ .text = .{
            .path = try p.a.dupe(u8, path),
            .edits = edits,
            .base_hash = base_hash,
            .base_len = base_len,
        } } });
    }

    /// Line starts of `t` (`\n`, `\r\n` and a lone `\r` end lines).
    fn indexLines(p: *Planner, t: []const u8) Allocator.Error!void {
        p.lines.clearRetainingCapacity();
        try p.lines.append(p.gpa, 0);
        var i: usize = 0;
        while (i < t.len) : (i += 1) {
            switch (t[i]) {
                '\n' => try p.lines.append(p.gpa, i + 1),
                '\r' => {
                    if (i + 1 < t.len and t[i + 1] == '\n') i += 1;
                    try p.lines.append(p.gpa, i + 1);
                },
                else => {},
            }
        }
    }

    fn byteOf(p: *Planner, t: []const u8, pos: protocol.Position) u64 {
        if (pos.line >= p.lines.items.len) return t.len;
        const start = p.lines.items[pos.line];
        var end: usize = if (pos.line + 1 < p.lines.items.len) @intCast(p.lines.items[pos.line + 1]) else t.len;
        // Before the line break.
        if (end > start and t[end - 1] == '\n') end -= 1;
        if (end > start and t[end - 1] == '\r') end -= 1;
        const line = t[@intCast(start)..end];
        return start + zg_core.utf8.columnToByte(line, pos.character, p.src.enc);
    }

    fn create(p: *Planner, index: u32, c: protocol.CreateFile) (Error || anyerror)!void {
        const path = try p.pathOf(c.uri);
        const ann = try p.annotationIndex(c.annotationId);
        const o = c.options orelse protocol.CreateFileOptions{};
        const overwrite = o.overwrite orelse false;
        const k = try p.kindOf(path);
        if (k != null and !overwrite) {
            if (o.ignoreIfExists orelse false) return p.steps.append(p.gpa, .{ .index = index, .annotation = ann, .op = .skip });
            return error.Exists;
        }
        if (k == .dir) return error.NotAFile;
        if (k == .file) _ = try p.file(path) else _ = try p.markNew(path);
        const e = p.entries.getPtr(path).?;
        e.kind = .file;
        e.touched = true;
        if (e.text) |*t| t.clearRetainingCapacity() else e.text = .empty;
        try p.steps.append(p.gpa, .{ .index = index, .annotation = ann, .op = .{ .create = .{ .path = try p.a.dupe(u8, path), .overwrite = k != null } } });
    }

    fn rename(p: *Planner, index: u32, r: protocol.RenameFile) (Error || anyerror)!void {
        const old = try p.pathOf(r.oldUri);
        const new = try p.pathOf(r.newUri);
        const ann = try p.annotationIndex(r.annotationId);
        const o = r.options orelse protocol.RenameFileOptions{};
        const overwrite = o.overwrite orelse false;
        const ok = (try p.kindOf(old)) orelse return error.NotFound;
        const nk = try p.kindOf(new);
        if (nk != null and !overwrite) {
            if (o.ignoreIfExists orelse false) return p.steps.append(p.gpa, .{ .index = index, .annotation = ann, .op = .skip });
            return error.Exists;
        }
        if (ok == .file) {
            const e = try p.file(old);
            const t = e.text.?;
            e.text = null;
            e.kind = null;
            e.touched = true;
            if (nk == .file) _ = try p.file(new) else _ = try p.markNew(new);
            const ne = p.entries.getPtr(new).?;
            if (ne.text) |*nt| nt.deinit(p.gpa);
            ne.text = t;
            ne.kind = .file;
            ne.touched = true;
        } else {
            // A folder: files loaded under it move with it.
            _ = try p.markNew(old);
            var moved: std.ArrayList(struct { []const u8, Entry }) = .empty;
            defer moved.deinit(p.gpa);
            var i: usize = 0;
            while (i < p.entries.count()) {
                const k = p.entries.keys()[i];
                if (under(k, old) and p.entries.values()[i].kind != null) {
                    try moved.append(p.gpa, .{ try std.mem.concat(p.a, u8, &.{ new, k[old.len..] }), p.entries.values()[i] });
                    p.entries.values()[i] = .{ .kind = null, .based = true, .before = p.entries.values()[i].before, .touched = true };
                }
                i += 1;
            }
            for (moved.items) |m| {
                const ne = try p.markNew(m[0]);
                ne.* = .{ .kind = m[1].kind, .text = m[1].text, .based = true, .before = ne.before, .touched = true };
            }
            const de = p.entries.getPtr(new) orelse try p.markNew(new);
            de.kind = .dir;
        }
        p.entries.getPtr(old).?.kind = null;
        try p.renames.append(p.gpa, .{ try p.a.dupe(u8, old), try p.a.dupe(u8, new) });
        try p.steps.append(p.gpa, .{ .index = index, .annotation = ann, .op = .{ .rename = .{ .old = try p.a.dupe(u8, old), .new = try p.a.dupe(u8, new), .overwrite = nk != null } } });
    }

    fn delete(p: *Planner, index: u32, d: protocol.DeleteFile) (Error || anyerror)!void {
        const path = try p.pathOf(d.uri);
        const ann = try p.annotationIndex(d.annotationId);
        const o = d.options orelse protocol.DeleteFileOptions{};
        const k = (try p.kindOf(path)) orelse {
            if (o.ignoreIfNotExists orelse false) return p.steps.append(p.gpa, .{ .index = index, .annotation = ann, .op = .skip });
            return error.NotFound;
        };
        if (k == .file) {
            const e = try p.file(path);
            if (e.text) |*t| t.deinit(p.gpa);
            e.text = null;
            e.kind = null;
            e.touched = true;
        } else {
            for (p.entries.keys(), p.entries.values()) |key, *e| if (under(key, path) and e.kind != null) {
                if (e.text) |*t| t.deinit(p.gpa);
                e.text = null;
                e.kind = null;
                e.touched = true;
            };
            const e = try p.markNew(path);
            e.kind = null;
        }
        try p.steps.append(p.gpa, .{ .index = index, .annotation = ann, .op = .{ .delete = .{ .path = try p.a.dupe(u8, path) } } });
    }
};

fn under(path: []const u8, dir: []const u8) bool {
    return path.len > dir.len and std.mem.startsWith(u8, path, dir) and (path[dir.len] == '/' or path[dir.len] == '\\');
}

/// Plans `edit`. Reads touched files that are not open through `fs`.
/// On failure `fail` (when given) names the change.
pub fn plan(gpa: Allocator, docs: *DocumentRegistry, fs: FileOps, edit: *const protocol.WorkspaceEdit, src: Source, label: []const u8, fail: ?*Failure) !EditPlan {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    var p: Planner = .{ .gpa = gpa, .a = arena.allocator(), .docs = docs, .fs = fs, .src = src };
    defer p.deinit();
    var needs_confirmation = false;
    if (edit.changeAnnotations) |m| {
        var it = m.map.iterator();
        while (it.next()) |kv| {
            const an = kv.value_ptr.*;
            const nc = an.needsConfirmation orelse false;
            needs_confirmation = needs_confirmation or nc;
            try p.annotations.append(gpa, .{
                .id = try p.a.dupe(u8, kv.key_ptr.*),
                .label = try p.a.dupe(u8, an.label),
                .description = if (an.description) |d| try p.a.dupe(u8, d) else null,
                .needs_confirmation = nc,
            });
        }
    }
    var index: u32 = 0;
    errdefer if (fail) |f| {
        f.index = index;
    };
    if (edit.documentChanges) |dcs| {
        for (dcs, 0..) |dc, i| {
            index = @intCast(i);
            const r = switch (dc) {
                .text_document_edit => |te| p.text(index, te.textDocument.uri, te.textDocument.version, te.edits),
                .create_file => |c| p.create(index, c),
                .rename_file => |r| p.rename(index, r),
                .delete_file => |d| p.delete(index, d),
            };
            r catch |e| {
                if (fail) |f| f.* = .{ .index = index, .err = e };
                return e;
            };
        }
    } else if (edit.changes) |ch| {
        var it = ch.map.iterator();
        while (it.next()) |kv| : (index += 1) {
            p.text(index, kv.key_ptr.*, null, kv.value_ptr.*) catch |e| {
                if (fail) |f| f.* = .{ .index = index, .err = e };
                return e;
            };
        }
    }
    const a = p.a;
    var files: std.ArrayList(FileChange) = .empty;
    for (p.entries.keys(), p.entries.values()) |k, e| {
        if (!e.touched) continue;
        const after: ?[]const u8 = if (e.kind == .file) if (e.text) |t| try a.dupe(u8, t.items) else null else null;
        if (e.before == null and after == null) continue;
        if (e.before != null and after != null and std.mem.eql(u8, e.before.?, after.?)) continue;
        try files.append(a, .{ .path = k, .before = e.before, .after = after });
    }
    const steps = try a.dupe(Step, p.steps.items);
    const annotations = try a.dupe(Annotation, p.annotations.items);
    const label_copy = try a.dupe(u8, label);
    return .{
        .arena = arena,
        .steps = steps,
        .annotations = annotations,
        .needs_confirmation = needs_confirmation,
        .label = label_copy,
        .files = files.items,
        .new_bytes = p.new_bytes,
    };
}
