//! LspSync: turns document changes into LSP text synchronization
//! (`didOpen`, `didChange`, `didSave`, `didClose`) for one language
//! server, in its negotiated position encoding and sync kind.
//!
//! Changes are coalesced per frame: the first change after a flush keeps
//! the version before it (a retained snapshot), and `flush` (called once
//! per frame) composes everything since into one `didChange`. E07
//! implements the sink and serializes JSON-RPC; text is handed over as a
//! chunk iterator so it can be streamed without concatenating.

const std = @import("std");
const zg_core = @import("zg_core");
const pt = @import("../buffer/piece_tree.zig");
const cs_mod = @import("../edit/change_set.zig");
const document = @import("../document.zig");
const Snapshot = @import("../snapshot.zig").Snapshot;
const registry = @import("registry.zig");

const Allocator = std.mem.Allocator;
const ChunkIterator = pt.ChunkIterator;
const ChangeEvent = document.ChangeEvent;
const Document = document.Document;
const DocHandle = registry.DocHandle;
const DocumentRegistry = registry.DocumentRegistry;
const RegistryEvent = registry.RegistryEvent;

pub const LspChange = cs_mod.LspChange;

/// Whether `off` lies between the CR and LF of a CRLF.
fn splitsCrlf(t: pt.PieceTree, off: u64) bool {
    return off > 0 and off < t.len() and t.byteAt(off) == '\n' and t.byteAt(off - 1) == '\r';
}

/// LSP `TextDocumentSyncKind` (0, 1, 2).
pub const SyncKind = enum(u2) { none = 0, full = 1, incremental = 2 };

/// Receives the notifications (implemented by E07). Strings, changes and
/// iterators are valid during the call only.
pub const LspSink = struct {
    ctx: *anyopaque,
    didOpen: *const fn (ctx: *anyopaque, uri: []const u8, lang: []const u8, version: i32, text: ChunkIterator) void,
    /// `changes` in sequence order (incremental), or `full_text` (full).
    didChange: *const fn (ctx: *anyopaque, uri: []const u8, version: i32, changes: []const LspChange, full_text: ?ChunkIterator) void,
    didSave: *const fn (ctx: *anyopaque, uri: []const u8, text: ?ChunkIterator) void,
    didClose: *const fn (ctx: *anyopaque, uri: []const u8) void,
};

pub const TrackError = Allocator.Error || error{ StaleHandle, TooLarge, AlreadyTracked };

const Tracked = struct {
    handle: DocHandle,
    listener: document.ListenerId,
    lang: []u8,
    version: i32,
    /// The version before the first unflushed change.
    pending: ?Snapshot = null,
};

/// Text sync with one language server.
pub const LspSync = struct {
    gpa: Allocator,
    reg: *DocumentRegistry,
    enc: zg_core.utf8.Encoding,
    kind: SyncKind,
    sink: LspSink,
    /// Whether `didSave` carries the text (the server's `includeText`).
    include_text_on_save: bool = false,
    /// Documents larger than this are not synced (`track` fails with
    /// `TooLarge`; E07 may choose a range-based strategy).
    max_bytes: u64 = 64 << 20,
    tracked: std.AutoArrayHashMapUnmanaged(u32, Tracked) = .empty,
    reg_listener: ?u32 = null,
    changes: std.ArrayList(LspChange) = .empty,
    /// Past this version a document is reopened at version 1 (LSP versions
    /// are i32 and must increase); tests lower it.
    max_version: i32 = std.math.maxInt(i32),

    /// Sync over `reg`. The struct must not move after the first `track`
    /// (listeners point at it).
    pub fn init(gpa: Allocator, reg: *DocumentRegistry, enc: zg_core.utf8.Encoding, kind: SyncKind, sink: LspSink) LspSync {
        return .{ .gpa = gpa, .reg = reg, .enc = enc, .kind = kind, .sink = sink };
    }

    /// Stops listening; sends nothing.
    pub fn deinit(s: *LspSync) void {
        for (s.tracked.values()) |*t| s.drop(t);
        s.tracked.deinit(s.gpa);
        if (s.reg_listener) |id| s.reg.unsubscribe(id);
        s.changes.deinit(s.gpa);
    }

    /// Starts syncing `h`: sends `didOpen` with the full text at version 1.
    pub fn track(s: *LspSync, h: DocHandle, language_id: []const u8) TrackError!void {
        const doc = s.reg.get(h) orelse return error.StaleHandle;
        if (doc.len() > s.max_bytes) return error.TooLarge;
        const key = @intFromEnum(h.id);
        if (s.tracked.contains(key)) return error.AlreadyTracked;
        if (s.reg_listener == null) s.reg_listener = try s.reg.subscribe(.{ .ctx = s, .onEvent = onRegistryEvent });
        const lang = try s.gpa.dupe(u8, language_id);
        errdefer s.gpa.free(lang);
        try s.tracked.ensureUnusedCapacity(s.gpa, 1);
        const listener = try doc.subscribe(.{ .ctx = s, .onChange = onDocChange });
        s.tracked.putAssumeCapacity(key, .{ .handle = h, .listener = listener, .lang = lang, .version = 1 });
        s.sink.didOpen(s.sink.ctx, s.reg.uri(h).?, lang, 1, doc.tree.chunks(0));
    }

    /// Stops syncing `h`: sends `didClose` (pending changes are dropped).
    pub fn untrack(s: *LspSync, h: DocHandle) void {
        const t = s.find(h) orelse return;
        const uri = s.reg.uri(h).?;
        s.drop(t);
        _ = s.tracked.swapRemove(@intFromEnum(h.id));
        s.sink.didClose(s.sink.ctx, uri);
    }

    /// Whether `h` is synced.
    pub fn isTracked(s: *const LspSync, h: DocHandle) bool {
        return s.find(h) != null;
    }

    /// The last version sent for `h`.
    pub fn version(s: *const LspSync, h: DocHandle) ?i32 {
        return (s.find(h) orelse return null).version;
    }

    /// Sends the coalesced changes of every document; call once per frame.
    pub fn flush(s: *LspSync) void {
        for (s.tracked.values()) |*t| if (t.pending != null) {
            s.flushOne(t, s.reg.uri(t.handle).?);
        };
    }

    /// Flushes `h`, then sends `didSave` (with the text when the server
    /// asked for it).
    pub fn saved(s: *LspSync, h: DocHandle) void {
        const t = s.find(h) orelse return;
        const uri = s.reg.uri(h).?;
        if (t.pending != null) s.flushOne(t, uri);
        const text: ?ChunkIterator = if (s.include_text_on_save) s.reg.get(h).?.tree.chunks(0) else null;
        s.sink.didSave(s.sink.ctx, uri, text);
    }

    fn find(s: *const LspSync, h: DocHandle) ?*Tracked {
        const t = s.tracked.getPtr(@intFromEnum(h.id)) orelse return null;
        if (t.handle.gen != h.gen) return null;
        return t;
    }

    /// Releases `t`'s resources and listener (the document must be open).
    fn drop(s: *LspSync, t: *Tracked) void {
        if (t.pending) |*p| p.release();
        t.pending = null;
        if (s.reg.get(t.handle)) |doc| doc.unsubscribe(t.listener);
        s.gpa.free(t.lang);
    }

    fn flushOne(s: *LspSync, t: *Tracked, uri: []const u8) void {
        var before = t.pending.?;
        t.pending = null;
        defer before.release();
        const doc = s.reg.get(t.handle).?;
        if (t.version >= s.max_version) {
            // LSP versions must increase: start over with a fresh open.
            t.version = 1;
            s.sink.didClose(s.sink.ctx, uri);
            s.sink.didOpen(s.sink.ctx, uri, t.lang, 1, doc.tree.chunks(0));
            return;
        }
        t.version += 1;
        if (s.kind == .incremental) {
            // Null when the log no longer reaches back (or memory ran
            // out): send the full text instead.
            const composed_opt = doc.change_log.compose(before.version, doc.version, s.gpa) catch null;
            if (composed_opt) |composed_in| {
                var composed = composed_in;
                defer composed.deinit();
                s.changes.clearRetainingCapacity();
                if (s.lspChanges(&composed, before.tree, doc.tree)) |owned| {
                    defer if (owned) |o| s.gpa.free(o);
                    s.sink.didChange(s.sink.ctx, uri, t.version, s.changes.items, null);
                    return;
                } else |_| {}
            }
        }
        s.sink.didChange(s.sink.ctx, uri, t.version, &.{}, doc.tree.chunks(0));
    }

    /// Fills `s.changes` for `cs`. LSP positions cannot fall between the CR
    /// and LF of a CRLF, so when an edge does, the whole span of changes
    /// (widened over the CRLF) is sent as one replacement; its text is
    /// returned for the caller to free.
    fn lspChanges(s: *LspSync, cs: *const cs_mod.ChangeSet, before: pt.PieceTree, after: pt.PieceTree) Allocator.Error!?[]u8 {
        var split = false;
        for (cs.replaces) |r| split = split or splitsCrlf(before, r.range.start) or splitsCrlf(before, r.range.end);
        if (!split) {
            try cs.toLspChanges(before, s.enc, &s.changes, s.gpa);
            return null;
        }
        var start = cs.replaces[0].range.start;
        var end = cs.replaces[cs.replaces.len - 1].range.end;
        if (splitsCrlf(before, start)) start -= 1;
        if (splitsCrlf(before, end)) end += 1;
        const new_end = end + cs.newLen() - cs.base_len;
        const text = try after.copyRange(s.gpa, .{ .start = start, .end = new_end });
        errdefer s.gpa.free(text);
        try s.changes.append(s.gpa, .{
            .start = try cs_mod.position(before, start, s.enc, s.gpa),
            .end = try cs_mod.position(before, end, s.enc, s.gpa),
            .text = text,
        });
        return text;
    }

    fn onDocChange(ctx: *anyopaque, ev: *const ChangeEvent) void {
        const s: *LspSync = @ptrCast(@alignCast(ctx));
        if (s.kind == .none) return;
        const t = s.tracked.getPtr(@intFromEnum(ev.doc)) orelse return;
        if (t.pending != null) return;
        const doc = s.reg.get(t.handle).?;
        doc.store.retain();
        t.pending = .{ .tree = ev.before.clone(), .version = ev.old_version, .doc_id = ev.doc, .store = doc.store };
    }

    fn onRegistryEvent(ctx: *anyopaque, reg: *DocumentRegistry, ev: *const RegistryEvent) void {
        const s: *LspSync = @ptrCast(@alignCast(ctx));
        switch (ev.*) {
            .opened => {},
            .closed => |h| s.untrack(h),
            .renamed => |r| {
                const t = s.find(r.handle) orelse return;
                // LSP has no rename for open documents: flush under the
                // old URI, close it and open the new one.
                if (t.pending != null) s.flushOne(t, r.old_uri);
                s.sink.didClose(s.sink.ctx, r.old_uri);
                t.version = 1;
                s.sink.didOpen(s.sink.ctx, r.new_uri, t.lang, 1, reg.get(r.handle).?.tree.chunks(0));
            },
        }
    }
};
