//! Background documents for agents (E07.F05.S01.T01): several servers
//! answer only for open documents, so a file an agent asks about that
//! the editor does not have open is read from disk and opened with the
//! language servers (`didOpen`). Each use holds it (`acquire`/`release`);
//! `sweep` closes it (`didClose`) once nothing has held it for `idle`.
//! A file the editor already has is only retained, never closed here.
//!
//! The editor tells this table when it opens or closes a file
//! (`adopt`, `editorClosed`) so neither closes a document the other
//! still uses. UI thread only.

const BackgroundDocs = @This();
const std = @import("std");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const DocHandle = zg_editor.model.api.registry.DocHandle;

pub const Opener = struct {
    ctx: *anyopaque,
    /// The file's bytes, owned by `gpa`.
    read: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror![]u8,
    /// The LSP language id of the file (null: no language services).
    language: *const fn (ctx: *anyopaque, path: []const u8, head: []const u8) ?[]const u8,
};

/// Monotonic nanoseconds (injected for tests).
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now: *const fn (ctx: ?*anyopaque) i96,
};

pub const Options = struct {
    idle: Io.Duration = .fromSeconds(30),
    /// Files larger than this are not opened.
    max_bytes: usize = 16 << 20,
};

const Entry = struct {
    h: DocHandle,
    refs: u32,
    /// When it was last released (`Clock` ns).
    idle_since: i96,
    /// Opened here (with `Manager.openDoc`), so closed here; false while
    /// the editor also shows it.
    ours: bool,
};

gpa: Allocator,
mgr: *Manager,
opener: Opener,
clock: Clock,
opts: Options,
entries: std.ArrayList(Entry) = .empty,

pub fn init(mgr: *Manager, opener: Opener, clock: Clock, opts: Options) BackgroundDocs {
    return .{ .gpa = mgr.gpa, .mgr = mgr, .opener = opener, .clock = clock, .opts = opts };
}

/// Closes every document opened here. Before `Manager.deinit`.
pub fn deinit(b: *BackgroundDocs) void {
    for (b.entries.items) |e| b.drop(e);
    b.entries.deinit(b.gpa);
}

pub const Error = error{ NoLanguage, TooLarge, NotAFile } || Allocator.Error;

/// The document of `path` (absolute, normalized), opened with the
/// language servers and held until `release`.
pub fn acquire(b: *BackgroundDocs, path: []const u8) (Error || anyerror)!DocHandle {
    const docs = b.mgr.docs;
    if (try docs.findFile(path)) |h| {
        if (b.find(h)) |e| {
            e.refs += 1;
            return h;
        }
        if (b.mgr.docMatch(h) != null) {
            // The editor has it: keep it alive, never close it.
            try docs.retain(h);
            errdefer docs.release(h);
            try b.entries.append(b.gpa, .{ .h = h, .refs = 1, .idle_since = 0, .ours = false });
            return h;
        }
    }
    const bytes = try b.opener.read(b.opener.ctx, b.gpa, path);
    defer b.gpa.free(bytes);
    if (bytes.len > b.opts.max_bytes) return error.TooLarge;
    const lang = b.opener.language(b.opener.ctx, path, bytes[0..@min(bytes.len, 512)]) orelse return error.NoLanguage;
    const h = try docs.openFile(path, bytes);
    errdefer docs.release(h);
    try b.entries.ensureUnusedCapacity(b.gpa, 1);
    try b.mgr.openDoc(h, lang);
    b.entries.appendAssumeCapacity(.{ .h = h, .refs = 1, .idle_since = 0, .ours = true });
    return h;
}

/// Ends one `acquire` of `h`.
pub fn release(b: *BackgroundDocs, h: DocHandle) void {
    const e = b.find(h) orelse return;
    std.debug.assert(e.refs > 0);
    e.refs -= 1;
    if (e.refs == 0) e.idle_since = b.clock.now(b.clock.ctx);
}

/// Whether `h` is held or kept open here.
pub fn holds(b: *const BackgroundDocs, h: DocHandle) bool {
    for (b.entries.items) |e| if (std.meta.eql(e.h, h)) return true;
    return false;
}

/// The editor opened `h`: it owns the language-server attachment now.
pub fn adopt(b: *BackgroundDocs, h: DocHandle) void {
    if (b.find(h)) |e| e.ours = false;
}

/// The editor closes `h`; true when this table keeps it open (the
/// editor must then not `closeDoc` it: `sweep` will).
pub fn editorClosed(b: *BackgroundDocs, h: DocHandle) bool {
    const e = b.find(h) orelse return false;
    if (e.refs == 0) {
        // Not in use: let the editor close it now.
        b.removeEntry(e, false);
        return false;
    }
    e.ours = true;
    return true;
}

/// Closes the documents idle for `opts.idle`; returns how many.
pub fn sweep(b: *BackgroundDocs) usize {
    const now = b.clock.now(b.clock.ctx);
    const idle = b.opts.idle.nanoseconds;
    var n: usize = 0;
    var i: usize = 0;
    while (i < b.entries.items.len) {
        const e = b.entries.items[i];
        if (e.refs == 0 and now - e.idle_since >= idle) {
            b.drop(e);
            _ = b.entries.swapRemove(i);
            n += 1;
        } else i += 1;
    }
    return n;
}

/// When `sweep` next has work (`Clock` ns).
pub fn nextDue(b: *const BackgroundDocs) ?i96 {
    var due: ?i96 = null;
    for (b.entries.items) |e| if (e.refs == 0) {
        const d = e.idle_since + b.opts.idle.nanoseconds;
        due = if (due) |x| @min(x, d) else d;
    };
    return due;
}

pub fn count(b: *const BackgroundDocs) usize {
    return b.entries.items.len;
}

fn find(b: *BackgroundDocs, h: DocHandle) ?*Entry {
    for (b.entries.items) |*e| if (std.meta.eql(e.h, h)) return e;
    return null;
}

fn removeEntry(b: *BackgroundDocs, e: *Entry, close: bool) void {
    const v = e.*;
    _ = b.entries.swapRemove(e - b.entries.items.ptr);
    if (close) b.drop(v) else b.mgr.docs.release(v.h);
}

fn drop(b: *BackgroundDocs, e: Entry) void {
    if (e.ours) b.mgr.closeDoc(e.h);
    b.mgr.docs.release(e.h);
}

/// `Clock` on the `.awake` clock.
pub fn awakeClock(io: *const Io) Clock {
    return .{ .ctx = @constCast(io), .now = awakeNow };
}

fn awakeNow(ctx: ?*anyopaque) i96 {
    const io: *const Io = @ptrCast(@alignCast(ctx.?));
    return Io.Clock.Timestamp.now(io.*, .awake).raw.nanoseconds;
}
