//! NoteIndex (E08.F06.S01.T02): the vault-wide knowledge index, kept
//! incrementally from per-note `NoteMeta`:
//!
//! - name and alias maps for link resolution (`names.zig`);
//! - every note's resolved outgoing links, re-resolved only where a note
//!   was added, removed or renamed (an inverse map from link-target text
//!   to the notes using it avoids global re-resolution);
//! - backlinks and unresolved targets, the tag tree and the property
//!   registry, built into each published view.
//!
//! Writers (indexer workers through `plugin`, or the app directly) take
//! the mutex; `commit` publishes an immutable, refcounted `IndexView`
//! that UI, graph and agents read without blocking the writer. Notes are
//! refcounted `Entry`s shared by the views that contain them.

const std = @import("std");
const zg_workspace = @import("zg_workspace");
const note_types = @import("../vault/note.zig");
const vault_mod = @import("../vault/vault.zig");
const extract_mod = @import("../vault/extract.zig");
const names_mod = @import("names.zig");
const tag_tree = @import("tag_tree.zig");
const properties = @import("properties.zig");
const persist = @import("persist.zig");
const fuzzy = @import("fuzzy.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileId = note_types.FileId;
const NoteMeta = note_types.NoteMeta;
const Vault = vault_mod.Vault;
const VaultId = vault_mod.VaultId;
const RootId = zg_workspace.RootId;
const Names = names_mod.Names;
const KeyBuf = names_mod.KeyBuf;
const idKey = names_mod.idKey;

pub const Resolved = names_mod.Resolved;
pub const ResolvedKind = names_mod.ResolvedKind;
pub const TagNode = tag_tree.TagNode;
pub const PropertyInfo = properties.PropertyInfo;
pub const PropertyType = note_types.PropertyType;

/// One indexed note, shared by the writer and the views holding it.
pub const Entry = struct {
    refs: std.atomic.Value(u32) = .init(1),
    arena: std.heap.ArenaAllocator,
    meta: NoteMeta,
    vault: VaultId,
    root: RootId,
    /// Vault-relative path.
    path: []const u8,
    /// `zg_workspace.index_plugin.pathHash` of the root-relative path.
    path_hash: u64,

    pub fn create(gpa: Allocator) !*Entry {
        const e = try gpa.create(Entry);
        e.* = .{ .arena = .init(gpa), .meta = undefined, .vault = .of(0), .root = .of(0), .path = "", .path_hash = 0 };
        return e;
    }

    fn retain(e: *Entry) void {
        _ = e.refs.fetchAdd(1, .monotonic);
    }

    fn release(e: *Entry, gpa: Allocator) void {
        if (e.refs.fetchSub(1, .acq_rel) != 1) return;
        e.arena.deinit();
        gpa.destroy(e);
    }
};

/// Called with the index locked, after the note's metadata is in place.
pub const TextSink = struct {
    ctx: *anyopaque,
    update: *const fn (ctx: *anyopaque, id: FileId, e: *const Entry, bytes: []const u8) anyerror!void,
    remove: *const fn (ctx: *anyopaque, id: FileId) void,
};

pub const BacklinkRef = struct {
    source: FileId,
    /// Index into the source's `NoteMeta.links`.
    link_index: u32,
    /// The line holding the link, in the source's bytes.
    context: [2]u32,
};

pub const UnresolvedRef = struct {
    /// As first written.
    target: []const u8,
    vault: VaultId,
    sources: []const FileId,
};

pub const NameHit = struct { id: FileId, score: i32, matched: enum { title, alias, path } };

pub const Event = union(enum) {
    note_changed: FileId,
    note_removed: FileId,
    links_changed,
    tags_changed,
};

pub const Listener = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, ev: Event) void,
};

const IdList = std.ArrayList(FileId);

/// The persistence format version (bump when `NoteMeta` changes).
pub const persist_version: u32 = 1;

pub const NoteIndex = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    vaults: []Vault,
    names: Names = .{},
    keys: KeyBuf = .{},
    entries: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
    forward: std.AutoHashMapUnmanaged(u64, []Resolved) = .empty,
    /// vault ++ folded link-target text → notes whose links use it.
    inverse: std.StringHashMapUnmanaged(IdList) = .empty,
    overrides: properties.Overrides = .{},
    /// Loaded at warm start, adopted by `plugin.has`.
    loaded: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
    current: ?*IndexView = null,
    changed: std.ArrayList(Event) = .empty,
    dirty: bool = true,
    listeners: std.ArrayList(Listener) = .empty,
    /// Receives note text as notes are indexed (the search index).
    sink: ?TextSink = null,

    /// `vaults` is copied (its strings must outlive the index).
    pub fn init(gpa: Allocator, io: Io, vaults: []const Vault) !*NoteIndex {
        const ix = try gpa.create(NoteIndex);
        errdefer gpa.destroy(ix);
        ix.* = .{ .gpa = gpa, .io = io, .vaults = try gpa.dupe(Vault, vaults) };
        return ix;
    }

    pub fn deinit(ix: *NoteIndex) void {
        const gpa = ix.gpa;
        if (ix.current) |v| v.release();
        var it = ix.entries.valueIterator();
        while (it.next()) |e| e.*.release(gpa);
        ix.entries.deinit(gpa);
        var lit = ix.loaded.valueIterator();
        while (lit.next()) |e| e.*.release(gpa);
        ix.loaded.deinit(gpa);
        var fit = ix.forward.valueIterator();
        while (fit.next()) |f| gpa.free(f.*);
        ix.forward.deinit(gpa);
        var iit = ix.inverse.iterator();
        while (iit.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        ix.inverse.deinit(gpa);
        ix.names.deinit(gpa);
        ix.keys.deinit(gpa);
        ix.overrides.deinit(gpa);
        ix.changed.deinit(gpa);
        ix.listeners.deinit(gpa);
        gpa.free(ix.vaults);
        gpa.destroy(ix);
    }

    /// The vault holding root-relative `rel` (the deepest), and the path
    /// inside it.
    pub fn vaultFor(ix: *const NoteIndex, root: RootId, rel: []const u8) ?struct { vault: *const Vault, inner: []const u8 } {
        var best: ?*const Vault = null;
        for (ix.vaults) |*v| {
            if (v.root != root or v.vaultRel(rel) == null) continue;
            if (best == null or v.rel_dir.len > best.?.rel_dir.len) best = v;
        }
        const v = best orelse return null;
        return .{ .vault = v, .inner = v.vaultRel(rel).? };
    }

    pub fn vaultById(ix: *const NoteIndex, id: VaultId) ?*const Vault {
        for (ix.vaults) |*v| if (v.id == id) return v;
        return null;
    }

    pub fn subscribe(ix: *NoteIndex, l: Listener) !void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        try ix.listeners.append(ix.gpa, l);
    }

    /// Removes the listeners registered with `ctx`.
    pub fn unsubscribe(ix: *NoteIndex, ctx: *anyopaque) void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        var i: usize = 0;
        while (i < ix.listeners.items.len) {
            if (ix.listeners.items[i].ctx == ctx) _ = ix.listeners.orderedRemove(i) else i += 1;
        }
    }

    /// Resolutions performed so far (tests check incrementality).
    pub fn resolutionCount(ix: *NoteIndex) u64 {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        return ix.names.resolutions;
    }

    // ---- updates ----

    /// Extracts and indexes one note (any thread). `rel` is
    /// root-relative; files outside every vault are ignored.
    pub fn indexNote(ix: *NoteIndex, id: FileId, root: RootId, rel: []const u8, bytes: []const u8) !void {
        const place = ix.vaultFor(root, rel) orelse return;
        const e = try Entry.create(ix.gpa);
        errdefer e.release(ix.gpa);
        const a = e.arena.allocator();
        e.meta = try extract_mod.extract(a, bytes, place.inner, &place.vault.config);
        e.vault = place.vault.id;
        e.root = root;
        e.path = try a.dupe(u8, place.inner);
        e.path_hash = zg_workspace.index_plugin.pathHash(root, rel);
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        try ix.upsert(id, e);
        if (ix.sink) |sk| try sk.update(sk.ctx, id, e, bytes);
    }

    /// Forgets a note or attachment.
    pub fn removeFile(ix: *NoteIndex, id: FileId) !void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        try ix.removeLocked(id);
    }

    /// Records a non-note file of a vault (images, PDFs) for `![[...]]`.
    pub fn setAttachment(ix: *NoteIndex, id: FileId, root: RootId, rel: []const u8) !void {
        const place = ix.vaultFor(root, rel) orelse return;
        if (vault_mod.isMarkdownName(rel)) return;
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        if (ix.names.placeOf(id) != null) try ix.removeLocked(id);
        try ix.names.addAttachment(ix.gpa, &ix.keys, id, place.vault.id, place.inner);
        var affected: std.ArrayList([]u8) = .empty;
        defer freeKeys(ix.gpa, &affected);
        try affected.append(ix.gpa, try ix.keys.make(ix.gpa, place.vault.id, names_mod.basename(place.inner)));
        try ix.reresolve(affected.items, id);
        ix.dirty = true;
        try ix.changed.append(ix.gpa, .links_changed);
    }

    /// Sets (or clears, with null) the user's type for a property.
    pub fn setPropertyType(ix: *NoteIndex, name: []const u8, ty: ?PropertyType) !void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        try ix.overrides.set(ix.gpa, name, ty);
        ix.dirty = true;
    }

    fn upsert(ix: *NoteIndex, id: FileId, e: *Entry) !void {
        const gpa = ix.gpa;
        e.meta.id = id;
        var affected: std.ArrayList([]u8) = .empty;
        defer freeKeys(gpa, &affected);
        var names_changed = true;
        if (ix.entries.get(idKey(id))) |old| {
            names_changed = !std.mem.eql(u8, old.path, e.path) or old.vault != e.vault or !sameStrings(old.meta.aliases, e.meta.aliases);
            if (names_changed) try ix.nameKeys(old, &affected);
            ix.unregisterInverse(old);
            try ix.names.removeNote(gpa, &ix.keys, id, old.meta.aliases);
            if (ix.forward.fetchRemove(idKey(id))) |kv| gpa.free(kv.value);
            _ = ix.entries.remove(idKey(id));
            old.release(gpa);
        } else if (ix.names.placeOf(id)) |p| if (p.attachment) {
            try ix.names.removeAttachment(gpa, &ix.keys, id);
        };
        try ix.entries.put(gpa, idKey(id), e);
        try ix.names.addNote(gpa, &ix.keys, id, e.vault, e.path, e.meta.aliases);
        try ix.forward.put(gpa, idKey(id), try ix.resolveLinks(e));
        try ix.registerInverse(e);
        if (names_changed) {
            try ix.nameKeys(e, &affected);
            try ix.reresolve(affected.items, id);
        }
        ix.dirty = true;
        try ix.changed.append(gpa, .{ .note_changed = id });
    }

    fn removeLocked(ix: *NoteIndex, id: FileId) !void {
        const gpa = ix.gpa;
        var affected: std.ArrayList([]u8) = .empty;
        defer freeKeys(gpa, &affected);
        if (ix.entries.fetchRemove(idKey(id))) |kv| {
            const old = kv.value;
            try ix.nameKeys(old, &affected);
            ix.unregisterInverse(old);
            try ix.names.removeNote(gpa, &ix.keys, id, old.meta.aliases);
            if (ix.forward.fetchRemove(idKey(id))) |f| gpa.free(f.value);
            old.release(gpa);
            if (ix.sink) |sk| sk.remove(sk.ctx, id);
            try ix.reresolve(affected.items, id);
            ix.dirty = true;
            try ix.changed.append(gpa, .{ .note_removed = id });
        } else if (ix.names.placeOf(id)) |p| {
            try affected.append(gpa, try ix.keys.make(gpa, p.vault, names_mod.basename(p.path)));
            try ix.names.removeAttachment(gpa, &ix.keys, id);
            try ix.reresolve(affected.items, id);
            ix.dirty = true;
            try ix.changed.append(gpa, .links_changed);
        }
    }

    fn freeKeys(gpa: Allocator, l: *std.ArrayList([]u8)) void {
        for (l.items) |k| gpa.free(k);
        l.deinit(gpa);
    }

    /// The keys other notes' links could use to name `e`.
    fn nameKeys(ix: *NoteIndex, e: *const Entry, out: *std.ArrayList([]u8)) !void {
        try out.append(ix.gpa, try ix.keys.make(ix.gpa, e.vault, names_mod.stemOf(e.path)));
        for (e.meta.aliases) |al| try out.append(ix.gpa, try ix.keys.make(ix.gpa, e.vault, al));
    }

    fn resolveLinks(ix: *NoteIndex, e: *const Entry) ![]Resolved {
        const out = try ix.gpa.alloc(Resolved, e.meta.links.len);
        const alias = if (ix.vaultById(e.vault)) |v| v.config.alias_resolution else true;
        for (e.meta.links, out) |l, *r| r.* = try ix.names.resolve(ix.gpa, &ix.keys, e.vault, e.path, l.target, l.kind, alias, null);
        return out;
    }

    /// Re-resolves the links of every note filed under `keys` (except
    /// `skip`, already fresh).
    fn reresolve(ix: *NoteIndex, keys: []const []u8, skip: FileId) !void {
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        defer seen.deinit(ix.gpa);
        for (keys) |k| {
            const l = ix.inverse.get(k) orelse continue;
            for (l.items) |src| {
                if (src.eql(skip)) continue;
                if ((try seen.getOrPut(ix.gpa, idKey(src))).found_existing) continue;
                const e = ix.entries.get(idKey(src)) orelse continue;
                const fresh = try ix.resolveLinks(e);
                const slot = ix.forward.getPtr(idKey(src)).?;
                if (!sameResolved(slot.*, fresh)) {
                    try ix.changed.append(ix.gpa, .{ .note_changed = src });
                }
                ix.gpa.free(slot.*);
                slot.* = fresh;
            }
        }
    }

    fn registerInverse(ix: *NoteIndex, e: *const Entry) !void {
        for (e.meta.links) |l| {
            if (l.target.len == 0) continue;
            const key = try ix.keys.view(ix.gpa, e.vault, names_mod.inverseText(l.target));
            const gop = try ix.inverse.getOrPut(ix.gpa, key);
            if (!gop.found_existing) {
                gop.key_ptr.* = try ix.gpa.dupe(u8, key);
                gop.value_ptr.* = .empty;
            }
            const list = gop.value_ptr;
            for (list.items) |x| {
                if (x.eql(e.meta.id)) break;
            } else try list.append(ix.gpa, e.meta.id);
        }
    }

    fn unregisterInverse(ix: *NoteIndex, e: *const Entry) void {
        for (e.meta.links) |l| {
            if (l.target.len == 0) continue;
            const key = ix.keys.view(ix.gpa, e.vault, names_mod.inverseText(l.target)) catch continue;
            const ent = ix.inverse.getEntry(key) orelse continue;
            const list = ent.value_ptr;
            for (list.items, 0..) |x, i| if (x.eql(e.meta.id)) {
                _ = list.swapRemove(i);
                break;
            };
            if (list.items.len == 0) {
                const owned = ent.key_ptr.*;
                list.deinit(ix.gpa);
                ix.inverse.removeByPtr(ent.key_ptr);
                ix.gpa.free(owned);
            }
        }
    }

    // ---- publishing ----

    /// Publishes a new view if anything changed, then tells listeners.
    pub fn commit(ix: *NoteIndex) !void {
        var events: std.ArrayList(Event) = .empty;
        defer events.deinit(ix.gpa);
        {
            ix.mutex.lockUncancelable(ix.io);
            defer ix.mutex.unlock(ix.io);
            if (!ix.dirty) return;
            const v = try ix.buildView();
            if (ix.current) |old| old.release();
            ix.current = v;
            ix.dirty = false;
            std.mem.swap(std.ArrayList(Event), &events, &ix.changed);
            if (events.items.len > 0) {
                try events.append(ix.gpa, .links_changed);
                try events.append(ix.gpa, .tags_changed);
            }
        }
        for (ix.listeners.items) |l| for (events.items) |ev| l.on_event(l.ctx, ev);
    }

    /// The latest view, retained; `release` it when done. Commits first
    /// if nothing was ever published.
    pub fn reader(ix: *NoteIndex) !*IndexView {
        if (ix.current == null) try ix.commit();
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        if (ix.current == null) ix.current = try ix.buildView();
        const v = ix.current.?;
        v.retain();
        return v;
    }

    fn buildView(ix: *NoteIndex) !*IndexView {
        const gpa = ix.gpa;
        const v = try gpa.create(IndexView);
        v.* = .{ .gpa = gpa, .arena = .init(gpa) };
        errdefer v.release();
        const a = v.arena.allocator();
        v.names = try ix.names.clone(a);
        v.names.resolutions = 0;
        v.vaults = try a.dupe(Vault, ix.vaults);
        // Notes, in id order.
        const order = try a.alloc(FileId, ix.entries.count());
        try v.entries.ensureTotalCapacity(a, ix.entries.count());
        var it = ix.entries.iterator();
        var n: usize = 0;
        while (it.next()) |kv| {
            kv.value_ptr.*.retain();
            v.entries.putAssumeCapacity(kv.key_ptr.*, kv.value_ptr.*);
            order[n] = kv.value_ptr.*.meta.id;
            n += 1;
        }
        std.mem.sort(FileId, order, {}, idLess);
        v.order = order;
        // Links.
        try v.forward.ensureTotalCapacity(a, ix.forward.count());
        var bw: std.AutoHashMapUnmanaged(u64, std.ArrayList(BacklinkRef)) = .empty;
        var vkeys: KeyBuf = .{};
        var unres: std.StringArrayHashMapUnmanaged(struct { target: []const u8, vault: VaultId, sources: IdList }) = .empty;
        for (order) |id| {
            const e = ix.entries.get(idKey(id)).?;
            const fwd = try a.dupe(Resolved, ix.forward.get(idKey(id)).?);
            v.forward.putAssumeCapacity(idKey(id), fwd);
            for (fwd, 0..) |r, i| switch (r.kind) {
                .note, .attachment => {
                    const gop = try bw.getOrPut(a, idKey(r.id));
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(a, .{ .source = id, .link_index = @intCast(i), .context = e.meta.links[i].context });
                },
                .unresolved => {
                    const t = e.meta.links[i].target;
                    const key = try vkeys.make(a, e.vault, names_mod.withoutMd(t));
                    const gop = try unres.getOrPut(a, key);
                    if (!gop.found_existing) gop.value_ptr.* = .{ .target = t, .vault = e.vault, .sources = .empty };
                    const l = &gop.value_ptr.sources;
                    if (l.items.len == 0 or !l.items[l.items.len - 1].eql(id)) try l.append(a, id);
                },
                .self => {},
            };
        }
        try v.backward.ensureTotalCapacity(a, bw.count());
        var bit = bw.iterator();
        while (bit.next()) |kv| v.backward.putAssumeCapacity(kv.key_ptr.*, kv.value_ptr.items);
        const ur = try a.alloc(UnresolvedRef, unres.count());
        for (unres.values(), ur) |u, *o| o.* = .{ .target = u.target, .vault = u.vault, .sources = u.sources.items };
        v.unresolved_refs = ur;
        // Tags and properties.
        var tb = try tag_tree.Builder.init(a);
        var pb: properties.Builder = .{ .arena = a };
        for (order) |id| {
            const e = ix.entries.get(idKey(id)).?;
            tb.beginNote();
            for (e.meta.tags) |t| try tb.add(t.key, t.display);
            for (e.meta.props) |p| try pb.add(id, p.name, p.ty);
        }
        v.tags = try tb.finish();
        v.props = try pb.finish(&ix.overrides);
        return v;
    }

    // ---- persistence ----

    const Saved = struct {
        path_hash: u64,
        vault: u16,
        root: u16,
        path: []const u8,
        meta: NoteMeta,
    };

    /// Writes every note's metadata to `dir/name` atomically.
    pub fn save(ix: *NoteIndex, dir: Io.Dir, name: []const u8) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(ix.gpa);
        {
            ix.mutex.lockUncancelable(ix.io);
            defer ix.mutex.unlock(ix.io);
            try persist.encode(u32, &payload, ix.gpa, @intCast(ix.entries.count()));
            var it = ix.entries.valueIterator();
            while (it.next()) |ep| {
                const e = ep.*;
                try persist.encode(Saved, &payload, ix.gpa, .{ .path_hash = e.path_hash, .vault = @intFromEnum(e.vault), .root = @intFromEnum(e.root), .path = e.path, .meta = e.meta });
            }
        }
        const sealed = try persist.seal(ix.gpa, persist_version, payload.items);
        defer ix.gpa.free(sealed);
        var af = try dir.createFileAtomic(ix.io, name, .{ .replace = true });
        defer af.deinit(ix.io);
        try af.file.writeStreamingAll(ix.io, sealed);
        try af.replace(ix.io);
    }

    /// Reads `dir/name` for warm start: its notes wait in `loaded` until
    /// the indexer confirms each file unchanged (`plugin.has`) or
    /// `adoptAll` takes them. A missing or stale file loads nothing.
    pub fn load(ix: *NoteIndex, dir: Io.Dir, name: []const u8) !usize {
        const bytes = dir.readFileAlloc(ix.io, name, ix.gpa, .limited(1 << 30)) catch return 0;
        defer ix.gpa.free(bytes);
        const payload = persist.unseal(bytes, persist_version) catch return 0;
        var r: persist.Reader = .{ .bytes = payload };
        var scratch: std.heap.ArenaAllocator = .init(ix.gpa);
        defer scratch.deinit();
        const count = persist.decode(u32, &r, scratch.allocator()) catch return 0;
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        var loaded: usize = 0;
        for (0..count) |_| {
            const e = try Entry.create(ix.gpa);
            const s = persist.decode(Saved, &r, e.arena.allocator()) catch |err| {
                e.release(ix.gpa);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                break;
            };
            e.meta = s.meta;
            e.vault = @enumFromInt(s.vault);
            e.root = @enumFromInt(s.root);
            e.path = s.path;
            e.path_hash = s.path_hash;
            const gop = try ix.loaded.getOrPut(ix.gpa, s.path_hash);
            if (gop.found_existing) gop.value_ptr.*.release(ix.gpa);
            gop.value_ptr.* = e;
            loaded += 1;
        }
        return loaded;
    }

    /// Takes a loaded note for `id` if one matches `path_hash`.
    pub fn adopt(ix: *NoteIndex, id: FileId, path_hash: u64) !bool {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        // A persisted note has no text for the search index: re-read it.
        if (ix.sink != null) return false;
        const kv = ix.loaded.fetchRemove(path_hash) orelse return false;
        try ix.upsert(id, kv.value);
        return true;
    }

    // ---- the indexer plugin ----

    pub fn plugin(ix: *NoteIndex) zg_workspace.IndexPlugin {
        return .{
            .name = "notes",
            .version = persist_version,
            .ctx = ix,
            .wants = pluginWants,
            .index = pluginIndex,
            .remove = pluginRemove,
            .commit = pluginCommit,
            .has = pluginHas,
        };
    }

    fn pluginWants(ctx: *anyopaque, file: *const zg_workspace.index_plugin.FileRef, class: zg_workspace.content_class.ContentClass) bool {
        _ = class;
        const ix: *NoteIndex = @ptrCast(@alignCast(ctx));
        const place = ix.vaultFor(file.root, file.rel) orelse return false;
        return place.vault.isNotePath(file.rel);
    }

    fn pluginIndex(ctx: *anyopaque, file: *const zg_workspace.index_plugin.FileRef, bytes: []const u8, class: zg_workspace.content_class.ContentClass, out: *zg_workspace.index_plugin.PluginOutput) anyerror!void {
        _ = class;
        const ix: *NoteIndex = @ptrCast(@alignCast(ctx));
        try ix.indexNote(file.id, file.root, file.rel, bytes);
        out.bytes_indexed += bytes.len;
    }

    fn pluginRemove(ctx: *anyopaque, file: *const zg_workspace.index_plugin.FileRef) void {
        const ix: *NoteIndex = @ptrCast(@alignCast(ctx));
        ix.removeFile(file.id) catch {};
    }

    fn pluginCommit(ctx: *anyopaque) void {
        const ix: *NoteIndex = @ptrCast(@alignCast(ctx));
        ix.commit() catch {};
    }

    fn pluginHas(ctx: *anyopaque, file: *const zg_workspace.index_plugin.FileRef) bool {
        const ix: *NoteIndex = @ptrCast(@alignCast(ctx));
        return ix.adopt(file.id, file.path_hash) catch false;
    }
};

fn idLess(_: void, a: FileId, b: FileId) bool {
    return idKey(a) < idKey(b);
}

fn sameResolved(a: []const Resolved, b: []const Resolved) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.kind != y.kind or !x.id.eql(y.id) or x.ambiguous != y.ambiguous) return false;
    return true;
}

fn sameStrings(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

/// An immutable snapshot of the index. Thread-safe to read; `release`
/// when done.
pub const IndexView = struct {
    refs: std.atomic.Value(u32) = .init(1),
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    names: Names = .{},
    vaults: []const Vault = &.{},
    entries: std.AutoHashMapUnmanaged(u64, *Entry) = .empty,
    /// Every note id, ascending.
    order: []const FileId = &.{},
    forward: std.AutoHashMapUnmanaged(u64, []const Resolved) = .empty,
    backward: std.AutoHashMapUnmanaged(u64, []const BacklinkRef) = .empty,
    unresolved_refs: []const UnresolvedRef = &.{},
    tags: *const TagNode = &empty_tag,
    props: []const PropertyInfo = &.{},

    const empty_tag: TagNode = .{ .name = "", .full = "", .key = "" };

    pub fn retain(v: *IndexView) void {
        _ = v.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(v: *IndexView) void {
        if (v.refs.fetchSub(1, .acq_rel) != 1) return;
        var it = v.entries.valueIterator();
        while (it.next()) |e| e.*.release(v.gpa);
        v.arena.deinit();
        v.gpa.destroy(v);
    }

    pub fn noteCount(v: *const IndexView) usize {
        return v.order.len;
    }

    pub fn note(v: *const IndexView, id: FileId) ?*const NoteMeta {
        return if (v.entries.get(idKey(id))) |e| &e.meta else null;
    }

    pub fn entry(v: *const IndexView, id: FileId) ?*const Entry {
        return v.entries.get(idKey(id));
    }

    /// The path of a note or attachment (vault-relative).
    pub fn pathOf(v: *const IndexView, id: FileId) ?[]const u8 {
        return if (v.names.placeOf(id)) |p| p.path else null;
    }

    /// The note or attachment at vault-relative `path` (case-insensitive).
    pub fn idOfPath(v: *const IndexView, gpa: Allocator, vault: VaultId, path: []const u8) !?FileId {
        var keys: KeyBuf = .{};
        defer keys.deinit(gpa);
        const md = names_mod.isMdExt(path);
        const key = try keys.view(gpa, vault, if (md) names_mod.withoutMd(path) else path);
        const l = (if (md) v.names.paths.get(key) else v.names.att_paths.get(key)) orelse return null;
        return if (l.items.len > 0) l.items[0] else null;
    }

    pub fn vaultOf(v: *const IndexView, id: FileId) ?*const Vault {
        const p = v.names.placeOf(id) orelse return null;
        for (v.vaults) |*x| if (x.id == p.vault) return x;
        return null;
    }

    /// A note's resolved links, parallel to `NoteMeta.links`.
    pub fn outgoing(v: *const IndexView, id: FileId) []const Resolved {
        return v.forward.get(idKey(id)) orelse &.{};
    }

    /// Links pointing at `id` (a note or an attachment), by source id.
    pub fn backlinks(v: *const IndexView, id: FileId) []const BacklinkRef {
        return v.backward.get(idKey(id)) orelse &.{};
    }

    pub fn unresolved(v: *const IndexView) []const UnresolvedRef {
        return v.unresolved_refs;
    }

    pub fn tagTree(v: *const IndexView) *const TagNode {
        return v.tags;
    }

    pub fn properties(v: *const IndexView) []const PropertyInfo {
        return v.props;
    }

    /// The registry type of property `name` (`.unknown` when unused).
    pub fn propertyType(v: *const IndexView, name: []const u8) PropertyType {
        for (v.props) |p| if (std.ascii.eqlIgnoreCase(p.name, name)) return p.ty;
        return .unknown;
    }

    /// Resolves `target` as if written in note `from`. `candidates`,
    /// when given, receives every match of the winning rule.
    pub fn resolve(v: *const IndexView, gpa: Allocator, from: FileId, target: []const u8, kind: note_types.LinkKind, candidates: ?*std.ArrayList(FileId)) !Resolved {
        const p = v.names.placeOf(from) orelse return .{ .kind = .unresolved };
        var names = v.names; // shares the maps; the counter is local
        var keys: KeyBuf = .{};
        defer keys.deinit(gpa);
        const alias = for (v.vaults) |x| {
            if (x.id == p.vault) break x.config.alias_resolution;
        } else true;
        return names.resolve(gpa, &keys, p.vault, p.path, target, kind, alias, candidates);
    }

    /// Resolves a target in vault `vault` from vault-relative `from_path`
    /// (for notes not yet indexed, like a new note's template).
    pub fn resolveFrom(v: *const IndexView, gpa: Allocator, vault: VaultId, from_path: []const u8, target: []const u8, kind: note_types.LinkKind) !Resolved {
        var names = v.names;
        var keys: KeyBuf = .{};
        defer keys.deinit(gpa);
        return names.resolve(gpa, &keys, vault, from_path, target, kind, true, null);
    }

    /// Up to `k` notes whose title, aliases or path match `q` fuzzily,
    /// best first (in `gpa`).
    pub fn findByName(v: *const IndexView, gpa: Allocator, q: []const u8, k: u32) ![]NameHit {
        var hits: std.ArrayList(NameHit) = .empty;
        errdefer hits.deinit(gpa);
        for (v.order) |id| {
            const e = v.entries.get(idKey(id)).?;
            var best: ?NameHit = null;
            if (fuzzy.score(q, e.meta.title)) |s| best = .{ .id = id, .score = s + 2, .matched = .title };
            for (e.meta.aliases) |al| if (fuzzy.score(q, al)) |s| {
                if (best == null or s > best.?.score) best = .{ .id = id, .score = s, .matched = .alias };
            };
            if (fuzzy.score(q, e.path)) |s| {
                if (best == null or s - 1 > best.?.score) best = .{ .id = id, .score = s - 1, .matched = .path };
            }
            if (best) |b| try hits.append(gpa, b);
        }
        std.mem.sort(NameHit, hits.items, {}, struct {
            fn lt(_: void, a: NameHit, b: NameHit) bool {
                if (a.score != b.score) return a.score > b.score;
                return idKey(a.id) < idKey(b.id);
            }
        }.lt);
        if (hits.items.len > k) hits.shrinkRetainingCapacity(k);
        return hits.toOwnedSlice(gpa);
    }
};
