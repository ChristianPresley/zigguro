//! The GitHub sync's memory (E13.F03.S03.T02):
//! `.zigguro/state/gh_sync.zon`, written whole and atomically after each
//! successful pull, push or publish.
//!
//! ```zig
//! .{
//!     .version = 1,
//!     .repo = "octo/demo",
//!     .last_pull_iso = "2026-10-22T10:00:00Z",
//!     .list_etag = "W/\"abc\"",
//!     .list_since = "2026-10-22T09:00:00Z",
//!     .issues = .{
//!         .{ .number = 7, .task_id = 42, .base = .{ .title_hash = 1, .body_hash = 2, .state = .open, .labels = .{"bug"}, .assignee = "octo" } },
//!     },
//! }
//! ```
//!
//! `base` is the last state both sides agreed on, the base of the
//! three-way merge: hashes for the title and body, values for the rest.
//! `conflicts` remembers conflicts already sent for review, so a poll does
//! not raise the same one again.

const std = @import("std");
const map = @import("map.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const file_name = "gh_sync.zon";
pub const version = 1;

pub const Base = struct {
    title_hash: u64 = 0,
    body_hash: u64 = 0,
    state: map.SyncState = .open,
    labels: []const []const u8 = &.{},
    assignee: ?[]const u8 = null,
};

pub const Conflict = struct {
    field: []const u8,
    /// The remote value it was raised for.
    remote_hash: u64,
    /// The review item.
    review: u64 = 0,
};

pub const IssueState = struct {
    number: u32,
    task_id: u32,
    etag: ?[]const u8 = null,
    base: Base = .{},
    conflicts: []const Conflict = &.{},
};

pub const SyncState = struct {
    version: u32 = version,
    /// `owner/name`.
    repo: []const u8 = "",
    /// When the last pull finished (for people).
    last_pull_iso: ?[]const u8 = null,
    /// The `since` of the next pull: the newest `updated_at` seen.
    list_since: ?[]const u8 = null,
    /// The ETag of the list at `list_since`.
    list_etag: ?[]const u8 = null,
    issues: []const IssueState = &.{},

    pub fn find(s: *const SyncState, number: u32) ?usize {
        for (s.issues, 0..) |e, i| if (e.number == number) return i;
        return null;
    }

    pub fn findTask(s: *const SyncState, id: u32) ?usize {
        for (s.issues, 0..) |e, i| if (e.task_id == id) return i;
        return null;
    }
};

/// The state in `dir`, empty when there is none; strings in `a`.
pub fn load(io: Io, a: Allocator, dir: Io.Dir) !SyncState {
    const bytes = dir.readFileAlloc(io, file_name, a, .limited(64 << 20)) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    const z = try a.dupeZ(u8, bytes);
    const s = std.zon.parse.fromSliceAlloc(SyncState, a, z, null, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidState,
    };
    if (s.version != version) return error.InvalidState;
    return s;
}

/// Writes `s` to `dir` whole: a reader sees the old file or the new one.
pub fn save(io: Io, a: Allocator, dir: Io.Dir, s: SyncState) !void {
    var out: std.Io.Writer.Allocating = .init(a);
    try std.zon.stringify.serialize(s, .{ .emit_default_optional_fields = false }, &out.writer);
    try out.writer.writeByte('\n');
    var af = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, out.written());
    try af.replace(io);
}
