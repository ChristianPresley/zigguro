//! The reviewable bundle (E12.F01.S01.T01): a `Changeset` holds one
//! `FileChange` per path, each with its operation, its content against a
//! recorded base and the hunks a reviewer decides on.
//!
//! Naming: E05's `ChangeSet` is a single-document text edit; a
//! `Changeset` here is a bundle of file changes whose text edits are E05
//! `ChangeSet`s.
//!
//! Memory: a `Changeset` owns an arena for paths, labels and hunk arrays,
//! and each text `FileChange` owns its E05 `ChangeSet` (moved in).
//! `deinit` frees both.

const std = @import("std");
const zg_editor = @import("zg_editor");
const ids = @import("ids.zig");
const provenance = @import("provenance.zig");

const Allocator = std.mem.Allocator;
pub const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
/// One replacement of an E05 `ChangeSet`.
pub const Replace = zg_editor.model.edit.change_set.Replace;
const ChangesetId = ids.ChangesetId;
const BlobHash = ids.BlobHash;
const Provenance = provenance.Provenance;

/// 0-based lines `[start, start + count)`; `count` 0 is an insertion point
/// before line `start`.
pub const LineRange = struct {
    start: u32,
    count: u32,

    pub fn end(r: LineRange) u32 {
        return r.start + r.count;
    }
};

pub const ConflictKind = enum { user_edit, external_change, sibling_changeset, base_missing };

/// Why a hunk cannot be applied as proposed.
pub const ConflictInfo = struct {
    kind: ConflictKind,
    /// The other changeset for `sibling_changeset`.
    other: ?ChangesetId = null,
    ours_lines: LineRange,
    /// The text now in the way (owned by the changeset).
    theirs_text: []const u8,
};

/// Line terminators of a base text.
pub const Eol = enum {
    lf,
    crlf,
    cr,
    mixed,
    /// No terminator at all.
    none,

    /// Detects the terminators of `text`.
    pub fn detect(text: []const u8) Eol {
        var seen: Eol = .none;
        var i: usize = 0;
        while (std.mem.indexOfAnyPos(u8, text, i, "\r\n")) |p| {
            const this: Eol = if (text[p] == '\n') .lf else if (p + 1 < text.len and text[p + 1] == '\n') .crlf else .cr;
            if (seen == .none) seen = this else if (seen != this) return .mixed;
            i = p + if (this == .crlf) @as(usize, 2) else 1;
        }
        return seen;
    }
};

/// What a text or binary change was made against.
pub const BaseRef = struct {
    hash: BlobHash,
    size: u64,
    /// The E05 document version, when the file was open.
    doc_version: ?u64 = null,
    eol: Eol = .lf,

    /// The ref of `bytes` (version unknown).
    pub fn of(bytes: []const u8) BaseRef {
        return .{ .hash = ids.blobHash(bytes), .size = bytes.len, .eol = Eol.detect(bytes) };
    }
};

pub const FileOp = union(enum) {
    create: struct { executable: bool = false },
    modify,
    delete,
    rename: struct { from: []const u8 },
    set_executable: bool,
};

pub const Content = union(enum) {
    /// Delete, pure rename or mode change.
    none,
    /// `base` is null for a create; `edits` are byte ranges of the base.
    text: struct { base: ?BaseRef, edits: ChangeSet },
    binary: struct { base: ?BlobHash, new: BlobHash, new_size: u64 },
};

pub const Decision = enum(u8) { undecided, accepted, rejected, edited };

pub const Hunk = struct {
    /// Dense `0..n` within its file and revision.
    id: u32,
    base_lines: LineRange,
    new_lines: LineRange,
    /// `[first, last + 1)` into `edits.replaces`: accepting the hunk
    /// accepts exactly these replaces.
    replace_span: [2]u32,
    decision: Decision = .undecided,
    conflict: ?ConflictInfo = null,
    /// XxHash3 of the hunk's base and new text; re-derivation keeps the
    /// decision of a hunk whose key is unchanged.
    key: u64 = 0,
};

pub const FileState = enum(u8) { pending, partially_applied, applied, rejected, conflicted, stale, superseded };

pub const FileChange = struct {
    path: []const u8,
    op: FileOp,
    content: Content,
    /// Empty for deletes, renames, mode changes and binaries: the file
    /// decision is the only one.
    hunks: []Hunk = &.{},
    state: FileState = .pending,
    folded_from: []const ChangesetId = &.{},

    /// Lines added and removed by the hunks.
    pub fn countLines(fc: *const FileChange) struct { added: u32, removed: u32 } {
        var a: u32 = 0;
        var r: u32 = 0;
        for (fc.hunks) |h| {
            a += h.new_lines.count;
            r += h.base_lines.count;
        }
        return .{ .added = a, .removed = r };
    }

    fn deinit(fc: *FileChange) void {
        switch (fc.content) {
            .text => |*t| t.edits.deinit(),
            else => {},
        }
    }
};

pub const State = enum(u8) { open_batch, pending, partially_applied, applied, rejected, superseded, discarded };

/// Where review starts.
pub const Presentation = enum(u8) {
    queue,
    /// In the editor first (inline edit).
    inline_,
    /// A modal "preview before apply".
    preview,
};

pub const Changeset = struct {
    id: ChangesetId,
    prov: Provenance,
    files: []FileChange,
    state: State,
    revision: u16 = 1,
    supersedes: ?ChangesetId = null,
    /// The checkpoint taken before it (F04).
    checkpoint: ?u64 = null,
    auto_applied: bool = false,
    presentation: Presentation = .queue,
    created_ms: i64,
    decided_ms: ?i64 = null,
    arena: std.heap.ArenaAllocator.State = .{},

    /// Frees the arena and every file's ChangeSet.
    pub fn deinit(cs: *Changeset, gpa: Allocator) void {
        for (cs.files) |*f| f.deinit();
        cs.arena.promote(gpa).deinit();
        cs.* = undefined;
    }

    /// Index of the file at `path`.
    pub fn fileIndex(cs: *const Changeset, path: []const u8) ?u32 {
        for (cs.files, 0..) |f, i| if (std.mem.eql(u8, f.path, path)) return @intCast(i);
        return null;
    }
};

test "changeset: eol detection" {
    try std.testing.expectEqual(Eol.none, Eol.detect("abc"));
    try std.testing.expectEqual(Eol.lf, Eol.detect("a\nb\n"));
    try std.testing.expectEqual(Eol.crlf, Eol.detect("a\r\nb\r\n"));
    try std.testing.expectEqual(Eol.cr, Eol.detect("a\rb"));
    try std.testing.expectEqual(Eol.mixed, Eol.detect("a\r\nb\n"));
}
