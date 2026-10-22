//! The indexer plugin interface. Plugins (trigrams, symbols, notes)
//! register with the `Scheduler`, which hands them file contents on worker
//! threads.

const std = @import("std");
const ids = @import("../ids.zig");
const FileId = ids.FileId;
const RootId = ids.RootId;
const ContentClass = @import("content_class.zig").ContentClass;

/// The file a plugin is asked about.
pub const FileRef = struct {
    /// Its id in the current PathStore.
    id: FileId,
    /// Its root.
    root: RootId,
    /// Root-relative path.
    rel: []const u8,
    /// `pathHash(root, rel)`: the key that survives restarts.
    path_hash: u64,
};

/// The stable key of a file across sessions.
pub fn pathHash(root: RootId, rel: []const u8) u64 {
    return std.hash.XxHash3.hash(@intFromEnum(root), rel);
}

/// What a plugin reports for one file.
pub const PluginOutput = struct {
    /// Bytes the plugin indexed (for throughput counters).
    bytes_indexed: u64 = 0,
};

/// A plugin. All callbacks may run on any indexer worker; `index` runs
/// concurrently with itself.
pub const IndexPlugin = struct {
    /// Unique name (also the cache key).
    name: []const u8,
    /// Bump to invalidate this plugin's cached results.
    version: u32,
    /// Passed back to every callback.
    ctx: *anyopaque,
    /// Whether the plugin wants this file.
    wants: *const fn (ctx: *anyopaque, file: *const FileRef, class: ContentClass) bool,
    /// Indexes one file. `bytes` is UTF-8 for UTF-16 files (transcoded) and
    /// raw otherwise. Errors are logged and the file is skipped.
    index: *const fn (ctx: *anyopaque, file: *const FileRef, bytes: []const u8, class: ContentClass, out: *PluginOutput) anyerror!void,
    /// Forgets a file (removed, or changed before re-indexing).
    remove: *const fn (ctx: *anyopaque, file: *const FileRef) void,
    /// Called after each batch (<= 256 files or 50 ms) so the plugin can
    /// publish what it built.
    commit: *const fn (ctx: *anyopaque) void,
    /// Whether the plugin still holds valid results for an unchanged file
    /// found in the cache at warm start (so it need not be re-indexed).
    /// Null means "always" (the plugin persists everything it indexed).
    has: ?*const fn (ctx: *anyopaque, file: *const FileRef) bool = null,
};
