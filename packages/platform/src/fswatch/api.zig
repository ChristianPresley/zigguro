//! Recursive file watching for the workspace (E08), SCM status (E09) and
//! agent tools (E10). One `Watcher` holds any number of roots; changes are
//! coalesced per path and delivered in batches through `poll`.

const std = @import("std");
const builtin = @import("builtin");
const NativeHandle = @import("../queue/wake.zig").NativeHandle;

/// Identifies a watched root.
pub const RootId = enum(u32) { _ };

/// Ignore filters; see `ignore.zig`.
pub const IgnoreFilter = @import("ignore.zig").IgnoreFilter;

/// One coalesced change.
pub const FsEvent = struct {
    /// The root the path belongs to.
    root: RootId,
    /// What happened.
    kind: Kind,
    /// Path relative to the root, `/`-separated; "" is the root itself.
    path: []const u8,
    /// The previous path for `renamed`.
    old_path: ?[]const u8 = null,
    /// Whether the path is a directory, when known.
    is_dir: ?bool = null,
    /// Why a `rescan_required` was emitted.
    reason: RescanReason = .none,

    /// Kinds of change.
    pub const Kind = enum(u8) {
        /// The path appeared (created or moved in).
        created,
        /// The contents changed.
        modified,
        /// The path disappeared (deleted or moved out).
        removed,
        /// The path was renamed from `old_path` within the root.
        renamed,
        /// Metadata changed (permissions, times).
        attrib,
        /// Events were lost under `path`; rescan it.
        rescan_required,
    };
};

/// Why events under a path were lost.
pub const RescanReason = enum(u8) {
    /// Not a rescan.
    none,
    /// The kernel event queue overflowed.
    overflow,
    /// The per-user watch limit was reached; part of the tree is
    /// unwatched (see `Limits`).
    watch_limit,
    /// The root itself was moved or deleted.
    root_gone,
};

/// Options for `Watcher.init`.
pub const WatchOptions = struct {
    /// Quiet time that closes a burst.
    debounce_ms: u32 = 30,
    /// Most events held in one ready batch.
    max_batch: u32 = 4096,
    /// Use fanotify instead of inotify (not implemented yet; returns
    /// `error.Unsupported`).
    use_fanotify: bool = false,
    /// Windows: bytes in each of a root's two change buffers (clamped to
    /// 1–64 KiB; network shares refuse more than 64 KiB).
    rdcw_buffer_bytes: u32 = 64 * 1024,
};

/// Kernel limits relevant to watching, for the UI hint on `watch_limit`.
pub const Limits = struct {
    /// `/proc/sys/fs/inotify/max_user_watches`, if readable.
    max_user_watches: ?u64,
    /// Watches this watcher holds.
    watches_in_use: u32,
};

/// Errors from the watcher.
pub const Error = error{
    /// The root does not exist or is not a directory.
    NotFound,
    /// The per-user watch limit is exhausted before the root could be
    /// watched; raise `fs.inotify.max_user_watches`.
    WatchLimit,
    /// The OS refused a resource.
    SystemResources,
    /// The option or OS is not supported.
    Unsupported,
} || std.mem.Allocator.Error;

const Impl = switch (builtin.os.tag) {
    .linux => @import("linux_inotify.zig").Inotify,
    .windows => @import("windows_rdcw.zig").Rdcw,
    else => void,
};

/// A recursive file watcher with its own thread.
pub const Watcher = struct {
    impl: if (Impl == void) void else *Impl,

    /// Starts the watcher thread.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: WatchOptions) Error!Watcher {
        if (Impl == void or opts.use_fanotify) return error.Unsupported;
        return .{ .impl = try Impl.init(gpa, io, opts) };
    }

    /// Stops the thread and frees everything.
    pub fn deinit(self: *Watcher) void {
        self.impl.deinit();
    }

    /// Watches `root` (an absolute path) and everything below it that
    /// `filter` does not ignore. Blocks while the tree is scanned, so call
    /// it off the UI thread. `filter` must outlive the root.
    pub fn addRoot(self: *Watcher, root: []const u8, filter: *const IgnoreFilter) Error!RootId {
        return self.impl.addRoot(root, filter);
    }

    /// Stops watching a root.
    pub fn removeRoot(self: *Watcher, id: RootId) void {
        self.impl.removeRoot(id);
    }

    /// Moves up to `out.len` ready events into `out`. Paths stay valid
    /// until the next `poll`. Any thread.
    pub fn poll(self: *Watcher, out: []FsEvent) usize {
        return self.impl.poll(out);
    }

    /// Readable (eventfd) or signalled (event) while a batch is ready.
    pub fn waitHandle(self: *Watcher) NativeHandle {
        return self.impl.waitHandle();
    }

    /// Blocks until a batch is ready or `timeout_ns` passes.
    pub fn wait(self: *Watcher, timeout_ns: ?u64) bool {
        return self.impl.wait(timeout_ns);
    }

    /// Current kernel limits and usage.
    pub fn limits(self: *Watcher) Limits {
        return self.impl.limits();
    }
};
