//! SettleDetector (E07.F05.S01.T02): after the agent edits a file, waits
//! until the language servers have answered for the new text (every
//! server that reports diagnostics on it has published or been pulled
//! since the edit went out, and nothing changed for `quiet`), then
//! summarizes the file's errors and warnings for the tool result.
//!
//! The driver records per document when text was sent and how many
//! servers still owe a report (`set`, UI thread); `afterAgentEdit` reads
//! that from the agent's worker thread.

const SettleDetector = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Store = @import("Store.zig");

pub const Options = struct {
    /// Give up waiting after this long and report what is known.
    timeout: Io.Duration = .fromSeconds(3),
    /// Settled once nothing was sent or reported for this long.
    quiet: Io.Duration = .fromMilliseconds(80),
    /// An edit sent this long before the call still counts as this edit's
    /// (the UI may flush it before the tool asks).
    slack: Io.Duration = .fromMilliseconds(250),
    poll: Io.Duration = .fromMilliseconds(15),
    /// Diagnostics listed in a summary.
    max_listed: usize = 20,
};

/// One document's state, by store key.
pub const Activity = struct {
    /// When text was last sent to a server (`.awake` ns).
    sent_ns: i96 = 0,
    /// When a server last reported.
    report_ns: i96 = 0,
    /// Servers that were sent text and have not reported on it yet.
    pending: u32 = 0,
};

gpa: Allocator,
io: Io,
store: *Store,
opts: Options,
mutex: Io.Mutex = .init,
/// Keys are borrowed from the driver (valid while present).
activity: std.StringHashMapUnmanaged(Activity) = .empty,

pub fn init(gpa: Allocator, io: Io, store: *Store, opts: Options) SettleDetector {
    return .{ .gpa = gpa, .io = io, .store = store, .opts = opts };
}

pub fn deinit(sd: *SettleDetector) void {
    sd.activity.deinit(sd.gpa);
}

/// Replaces the activity table (UI thread): `keys[i]` has `acts[i]`.
pub fn set(sd: *SettleDetector, keys: []const []const u8, acts: []const Activity) Allocator.Error!void {
    sd.mutex.lockUncancelable(sd.io);
    defer sd.mutex.unlock(sd.io);
    sd.activity.clearRetainingCapacity();
    try sd.activity.ensureTotalCapacity(sd.gpa, @intCast(keys.len));
    for (keys, acts) |k, a| {
        const gop = sd.activity.getOrPutAssumeCapacity(k);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const v = gop.value_ptr;
        v.sent_ns = @max(v.sent_ns, a.sent_ns);
        v.report_ns = @max(v.report_ns, a.report_ns);
        v.pending += a.pending;
    }
}

fn get(sd: *SettleDetector, key: []const u8) ?Activity {
    sd.mutex.lockUncancelable(sd.io);
    defer sd.mutex.unlock(sd.io);
    return sd.activity.get(key);
}

/// Waits for the servers to settle on `abs` (an absolute path), then
/// summarizes its errors and warnings ("2 errors, 1 warning:" and one
/// line each), or null when there are none. Any thread but the UI's.
pub fn afterAgentEdit(sd: *SettleDetector, io: Io, arena: Allocator, abs: []const u8) (Allocator.Error || Io.Cancelable)!?[]const u8 {
    const key = try sd.store.keyOfPath(arena, abs);
    const t0 = Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    const deadline = t0 + sd.opts.timeout.nanoseconds;
    while (true) {
        // A file no server has open reports what is known at once.
        const a = sd.get(key) orelse break;
        const now = Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        if (now >= deadline) break;
        const since = @max(a.sent_ns, a.report_ns);
        if (a.sent_ns + sd.opts.slack.nanoseconds >= t0 and a.pending == 0 and now - since >= sd.opts.quiet.nanoseconds) break;
        try io.sleep(sd.opts.poll, .awake);
    }
    const snap = sd.store.acquire();
    defer snap.release();
    return sd.summarize(arena, snap, key, std.fs.path.basename(abs));
}

/// The errors and warnings of `key` in `snap`, labelled `name`; null
/// when there are none.
pub fn summarize(sd: *const SettleDetector, arena: Allocator, snap: *const Store.Snapshot, key: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
    var all: std.ArrayList(*const Store.Diagnostic) = .empty;
    try snap.forKey(key, arena, &all);
    var errors: usize = 0;
    var warnings: usize = 0;
    var listed: std.ArrayList(*const Store.Diagnostic) = .empty;
    for (all.items) |d| switch (d.severity) {
        .err => {
            errors += 1;
            try listed.append(arena, d);
        },
        .warning => {
            warnings += 1;
            try listed.append(arena, d);
        },
        else => {},
    };
    if (listed.items.len == 0) return null;
    // Errors first, each kind in document order (the sort is stable).
    std.mem.sort(*const Store.Diagnostic, listed.items, {}, struct {
        fn lt(_: void, a: *const Store.Diagnostic, b: *const Store.Diagnostic) bool {
            return @intFromEnum(a.severity) < @intFromEnum(b.severity);
        }
    }.lt);
    var w: std.Io.Writer.Allocating = .init(arena);
    const out = &w.writer;
    out.print("{d} error{s}, {d} warning{s}:", .{ errors, plural(errors), warnings, plural(warnings) }) catch return error.OutOfMemory;
    for (listed.items[0..@min(listed.items.len, sd.opts.max_listed)]) |d| {
        out.print("\n{s}:{d}:{d}: {s}: ", .{ name, d.start.line + 1, d.start.character + 1, d.severity.label() }) catch return error.OutOfMemory;
        // One line per diagnostic.
        const first = d.message[0 .. std.mem.indexOfScalar(u8, d.message, '\n') orelse d.message.len];
        out.writeAll(first) catch return error.OutOfMemory;
        if (d.source.len > 0) out.print(" ({s})", .{d.source}) catch return error.OutOfMemory;
    }
    if (listed.items.len > sd.opts.max_listed) out.print("\n... and {d} more", .{listed.items.len - sd.opts.max_listed}) catch return error.OutOfMemory;
    return w.written();
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// For `zg_ai.tools.builtin.files.Diagnostics.after_edit` (`ctx` is the
/// detector).
pub fn afterEdit(ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8) anyerror!?[]const u8 {
    const sd: *SettleDetector = @ptrCast(@alignCast(ctx));
    return sd.afterAgentEdit(io, arena, abs);
}
