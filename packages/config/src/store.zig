//! `SettingsStore`: merges every settings layer into immutable, versioned
//! `Snapshot`s that any thread reads without locks, and tells subscribers
//! exactly which keys changed. Semantics are documented in
//! `packages/config/docs/settings-model.md`.
//!
//! Threading:
//! - `setLayerSource`/`removeLayer`/`setTrust` may run on any thread (the
//!   config worker in the app). They build the next snapshot under a mutex
//!   and park it as *pending*, then post `ui_msg_kind` to the UI mailbox.
//! - `publish` runs on the UI thread at frame start: it swaps the pending
//!   snapshot in, computes the change set and calls subscribers.
//! - UI-thread code reads `current()` without pinning, because swaps happen
//!   only between frames on that thread. Other threads pin with `acquire()`
//!   and unpin with `release()`; a superseded snapshot is freed once its pin
//!   count drops to zero.

const std = @import("std");
const zg_core = @import("zg_core");
const schema = @import("schema.zig");
const layer_mod = @import("layer.zig");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;
/// The dynamic value type.
pub const Value = schema.Value;
/// A dense setting id.
pub const SettingId = schema.SettingId;
/// The schema registry.
pub const SchemaRegistry = schema.SchemaRegistry;
/// Layer kinds, low to high precedence.
pub const LayerKind = layer_mod.LayerKind;
/// A workspace folder id.
pub const FolderId = layer_mod.FolderId;
/// What a layer is built from.
pub const LayerSource = layer_mod.LayerSource;
/// Workspace trust port.
pub const TrustPort = layer_mod.TrustPort;
const Layer = layer_mod.Layer;
const Entry = layer_mod.Entry;

/// `UiMsg.kind` posted when a new snapshot is pending (E15 range 0x1500_xxxx).
pub const ui_msg_kind: u32 = 0x1500_0001;

/// The scope of a resource-sensitive lookup.
pub const ResourceScope = struct {
    folder: ?FolderId = null,
    /// File path (reserved for EditorConfig section matching).
    path: ?[]const u8 = null,
    /// Language id such as "zig".
    lang: ?[]const u8 = null,
};

/// The value of one setting in each layer, for "modified in" UI.
pub const Inspection = struct {
    default: Value,
    /// Effective value for the queried scope.
    effective: Value,
    /// The highest layer that contributed, `.default` if none.
    origin: LayerKind,
    /// Per layer kind: the non-language value, if set.
    layers: [std.meta.fields(LayerKind).len]?Value,
    /// Per layer kind: the language value for the queried language, if set.
    lang_layers: [std.meta.fields(LayerKind).len]?Value,
    /// Whether the policy layer sets this key (UI shows a lock).
    locked: bool,
};

/// A change notification: every id whose effective value changed in any scope.
pub const Change = struct {
    gen: u64,
    ids: []const SettingId,
};

/// Called on the UI thread from `publish`.
pub const ChangeCallback = *const fn (ctx: ?*anyopaque, change: *const Change) void;

/// Handle returned by `subscribe`.
pub const SubscriptionId = enum(u32) { _ };

/// An immutable merged view of all layers at one generation.
pub const Snapshot = struct {
    gen: u64,
    reg: *const SchemaRegistry,
    arena: std.heap.ArenaAllocator,
    /// Retained layers, low to high precedence (no default layer).
    layers: []const *Layer,
    /// Window-scope value per id.
    window: []const Value,
    /// Layer that produced each window value.
    origin: []const LayerKind,
    /// Fingerprint of resource/language entries per id, for diffing.
    res_hash: []const u64,
    /// Precomputed merged values for merge-mode settings per (id, folder, lang).
    merged: std.HashMapUnmanaged(MergeKey, Value, MergeKeyContext, 80) = .empty,
    trusted: bool,
    pins: std.atomic.Value(u32) = .init(0),

    /// The effective value of `id` in scope `rs`. Lock-free and allocation-free.
    pub fn resolve(s: *const Snapshot, id: SettingId, rs: ResourceScope) Value {
        if (rs.folder == null and rs.lang == null) return s.window[id.index()];
        const d = s.reg.def(id);
        if (d.merge == .replace) {
            var it = s.contributions(id, rs);
            var v = s.reg.default(id);
            while (it.next()) |c| v = c.value;
            return v;
        }
        const key = s.mergeKey(id, rs);
        if (key.folder == null and key.lang == null) return s.window[id.index()];
        return s.merged.get(key) orelse s.window[id.index()];
    }

    /// Values of `id` per layer for `rs`, for the settings editor.
    pub fn inspect(s: *const Snapshot, id: SettingId, rs: ResourceScope) Inspection {
        var out: Inspection = .{
            .default = s.reg.default(id),
            .effective = s.resolve(id, rs),
            .origin = .default,
            .layers = @splat(null),
            .lang_layers = @splat(null),
            .locked = false,
        };
        var it = s.contributions(id, rs);
        while (it.next()) |c| {
            const k = @intFromEnum(c.kind);
            if (c.entry.lang_block == null) out.layers[k] = c.value else out.lang_layers[k] = c.value;
            out.origin = c.kind;
            if (c.kind == .policy) out.locked = true;
        }
        return out;
    }

    /// The effective value of `key`, or null if no such setting.
    pub fn getByKey(s: *const Snapshot, key: []const u8, rs: ResourceScope) ?Value {
        const id = s.reg.lookup(key) orelse return null;
        return s.resolve(id, rs);
    }

    /// An object of every setting under `prefix` (`"lsp"` → `.{ .servers = ... }`),
    /// nested by the remaining dotted path. For LSP `workspace/configuration`.
    pub fn section(s: *const Snapshot, arena: Allocator, prefix: []const u8, rs: ResourceScope) error{OutOfMemory}!Value {
        if (s.reg.lookup(prefix)) |id| return s.resolve(id, rs);
        var root: Tree = .{};
        for (0..s.reg.count()) |i| {
            const id: SettingId = @enumFromInt(i);
            if (s.reg.isTombstone(id)) continue;
            const key = s.reg.def(id).key;
            if (prefix.len > 0 and !(std.mem.startsWith(u8, key, prefix) and key.len > prefix.len and key[prefix.len] == '.')) continue;
            const rest = if (prefix.len == 0) key else key[prefix.len + 1 ..];
            try root.insert(arena, rest, s.resolve(id, rs));
        }
        return root.toValue(arena);
    }

    /// One contributing entry.
    pub const Contribution = struct { kind: LayerKind, entry: *const Entry, value: Value };

    /// Iterates the contributions to `id` for `rs`, lowest precedence first
    /// (so the last one wins for `replace`).
    pub fn contributions(s: *const Snapshot, id: SettingId, rs: ResourceScope) ContributionIterator {
        return .{ .s = s, .id = id, .rs = rs };
    }

    fn mergeKey(s: *const Snapshot, id: SettingId, rs: ResourceScope) MergeKey {
        // Normalize to the coarsest scope that has the same contributions.
        var key: MergeKey = .{ .id = id, .folder = null, .lang = null };
        for (s.layers) |l| for (l.entriesFor(id)) |e| {
            if (rs.folder != null and l.folder != null and l.folder.? == rs.folder.?) key.folder = rs.folder;
            if (rs.lang) |lang| for (e.langs) |x| {
                if (std.mem.eql(u8, x, lang)) key.lang = lang;
            };
        };
        return key;
    }

    fn isPinnedOrCurrent(s: *const Snapshot) bool {
        return s.pins.load(.acquire) != 0;
    }
};

const MergeKey = struct { id: SettingId, folder: ?FolderId, lang: ?[]const u8 };

const MergeKeyContext = struct {
    pub fn hash(_: MergeKeyContext, k: MergeKey) u64 {
        var h = std.hash.Wyhash.init(k.id.index());
        if (k.folder) |f| h.update(std.mem.asBytes(&f));
        h.update(&.{0xff});
        if (k.lang) |l| h.update(l);
        return h.final();
    }
    pub fn eql(_: MergeKeyContext, a: MergeKey, b: MergeKey) bool {
        if (a.id != b.id or a.folder != b.folder) return false;
        if ((a.lang == null) != (b.lang == null)) return false;
        return a.lang == null or std.mem.eql(u8, a.lang.?, b.lang.?);
    }
};

/// Walks contributions in precedence order. See docs/settings-model.md:
/// default < user < workspace < workspace_local < folder < editorconfig < cli
/// < [lang] blocks (multi-language before single-language, then by layer)
/// < policy < policy[lang].
pub const ContributionIterator = struct {
    s: *const Snapshot,
    id: SettingId,
    rs: ResourceScope,
    phase: u8 = 0,
    li: usize = 0,
    ei: usize = 0,

    /// The next contribution, or null.
    pub fn next(it: *ContributionIterator) ?Snapshot.Contribution {
        // Phases: 0 non-language (non-policy); 1 multi-language blocks;
        // 2 single-language blocks; 3 policy non-language; 4 policy multi;
        // 5 policy single.
        while (it.phase < 6) {
            if (it.li >= it.s.layers.len) {
                it.phase += 1;
                it.li = 0;
                it.ei = 0;
                continue;
            }
            const l = it.s.layers[it.li];
            const policy_phase = it.phase >= 3;
            if ((l.kind == .policy) != policy_phase or !it.layerApplies(l)) {
                it.li += 1;
                it.ei = 0;
                continue;
            }
            const es = l.entriesFor(it.id);
            while (it.ei < es.len) {
                const e = &es[it.ei];
                it.ei += 1;
                if (e.skipped(it.s.trusted)) continue;
                const want: u8 = it.phase % 3;
                const have: u8 = if (e.lang_block == null) 0 else if (e.langs.len > 1) 1 else 2;
                if (want != have) continue;
                if (have != 0) {
                    const lang = it.rs.lang orelse continue;
                    const hit = for (e.langs) |x| {
                        if (std.mem.eql(u8, x, lang)) break true;
                    } else false;
                    if (!hit) continue;
                }
                return .{ .kind = l.kind, .entry = e, .value = e.value };
            }
            it.li += 1;
            it.ei = 0;
        }
        return null;
    }

    fn layerApplies(it: *const ContributionIterator, l: *const Layer) bool {
        return switch (l.kind) {
            .folder, .editorconfig => it.rs.folder != null and l.folder != null and l.folder.? == it.rs.folder.?,
            else => true,
        };
    }
};

/// Merges `v` onto `acc` with `mode`.
pub fn mergeValues(a: Allocator, mode: schema.Merge, acc: Value, v: Value) error{OutOfMemory}!Value {
    return switch (mode) {
        .replace => v,
        .concat_unique => blk: {
            const xs = switch (acc) {
                .array => |x| x,
                else => &[_]Value{},
            };
            const ys = switch (v) {
                .array => |y| y,
                else => break :blk v,
            };
            var out: std.ArrayList(Value) = try .initCapacity(a, xs.len + ys.len);
            for ([_][]const Value{ xs, ys }) |src| for (src) |x| {
                const dup = for (out.items) |o| {
                    if (o.eql(x)) break true;
                } else false;
                if (!dup) out.appendAssumeCapacity(x);
            };
            break :blk .{ .array = out.items };
        },
        .merge_object => blk: {
            if (acc != .object or v != .object) break :blk v;
            var out: std.ArrayList(Value.Field) = .empty;
            var i: usize = 0;
            var j: usize = 0;
            const xs = acc.object;
            const ys = v.object;
            while (i < xs.len or j < ys.len) {
                const order: std.math.Order = if (i >= xs.len) .gt else if (j >= ys.len) .lt else std.mem.order(u8, xs[i].key, ys[j].key);
                switch (order) {
                    .lt => {
                        try out.append(a, xs[i]);
                        i += 1;
                    },
                    .gt => {
                        if (!isDeleteMarker(ys[j].value)) try out.append(a, ys[j]);
                        j += 1;
                    },
                    .eq => {
                        if (!isDeleteMarker(ys[j].value))
                            try out.append(a, .{ .key = xs[i].key, .value = try mergeValues(a, .merge_object, xs[i].value, ys[j].value) });
                        i += 1;
                        j += 1;
                    },
                }
            }
            break :blk .{ .object = out.items };
        },
    };
}

/// In `merge_object` settings, the string "default" removes a key.
fn isDeleteMarker(v: Value) bool {
    return v == .string and std.mem.eql(u8, v.string, "default");
}

const Tree = struct {
    fields: std.ArrayList(struct { key: []const u8, leaf: ?Value, child: ?*Tree }) = .empty,

    fn insert(t: *Tree, a: Allocator, path: []const u8, v: Value) error{OutOfMemory}!void {
        const dot = std.mem.indexOfScalar(u8, path, '.');
        const head = path[0 .. dot orelse path.len];
        for (t.fields.items) |*f| if (std.mem.eql(u8, f.key, head)) {
            if (dot) |d| {
                if (f.child == null) {
                    f.child = try a.create(Tree);
                    f.child.?.* = .{};
                }
                return f.child.?.insert(a, path[d + 1 ..], v);
            }
            f.leaf = v;
            return;
        };
        if (dot) |d| {
            const c = try a.create(Tree);
            c.* = .{};
            try t.fields.append(a, .{ .key = head, .leaf = null, .child = c });
            return c.insert(a, path[d + 1 ..], v);
        }
        try t.fields.append(a, .{ .key = head, .leaf = v, .child = null });
    }

    fn toValue(t: *const Tree, a: Allocator) error{OutOfMemory}!Value {
        const out = try a.alloc(Value.Field, t.fields.items.len);
        for (t.fields.items, out) |f, *o| {
            o.* = .{ .key = f.key, .value = if (f.child) |c| try c.toValue(a) else f.leaf.? };
        }
        @import("value.zig").sortFields(out);
        return .{ .object = out };
    }
};

/// Options for `SettingsStore.init`.
pub const InitOptions = struct {
    /// Posts `ui_msg_kind` when a snapshot is pending; null for headless/tests.
    runtime: ?*zg_core.Runtime = null,
    trust: TrustPort = .untrusted,
};

/// The settings store. See the file comment for threading.
pub const SettingsStore = struct {
    gpa: Allocator,
    io: std.Io,
    reg: *const SchemaRegistry,
    runtime: ?*zg_core.Runtime,
    mutex: std.Io.Mutex = .init,
    trust: TrustPort,
    layers: std.ArrayList(*Layer) = .empty,
    gen: u64 = 0,
    current_ptr: std.atomic.Value(*Snapshot),
    pending: std.atomic.Value(?*Snapshot) = .init(null),
    retired: std.ArrayList(*Snapshot) = .empty,
    subs: std.ArrayList(Sub) = .empty,
    next_sub: u32 = 0,
    change_ids: std.ArrayList(SettingId) = .empty,

    const Sub = struct { id: SubscriptionId, prefix: []const u8, cb: ChangeCallback, ctx: ?*anyopaque };

    /// Creates a store whose first snapshot holds only defaults.
    pub fn init(gpa: Allocator, io: std.Io, reg: *const SchemaRegistry, opts: InitOptions) !*SettingsStore {
        const s = try gpa.create(SettingsStore);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .io = io, .reg = reg, .runtime = opts.runtime, .trust = opts.trust, .current_ptr = undefined };
        const snap = try s.buildSnapshot();
        s.current_ptr = .init(snap);
        return s;
    }

    /// Frees everything. No snapshot may be pinned.
    pub fn deinit(s: *SettingsStore) void {
        if (s.pending.swap(null, .acq_rel)) |p| s.freeSnapshot(p);
        s.freeSnapshot(s.current_ptr.load(.acquire));
        for (s.retired.items) |r| s.freeSnapshot(r);
        s.retired.deinit(s.gpa);
        for (s.layers.items) |l| l.release(s.gpa);
        s.layers.deinit(s.gpa);
        for (s.subs.items) |sub| s.gpa.free(sub.prefix);
        s.subs.deinit(s.gpa);
        s.change_ids.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    /// The published snapshot. UI thread only (no pin needed there).
    pub fn current(s: *const SettingsStore) *const Snapshot {
        return s.current_ptr.load(.acquire);
    }

    /// Pins the published snapshot for use on another thread.
    pub fn acquire(s: *SettingsStore) *const Snapshot {
        while (true) {
            const p = s.current_ptr.load(.acquire);
            _ = p.pins.fetchAdd(1, .acq_rel);
            if (s.current_ptr.load(.acquire) == p) return p;
            _ = p.pins.fetchSub(1, .acq_rel);
        }
    }

    /// Unpins a snapshot from `acquire`. It is freed by the next `publish`
    /// or `collect` once unpinned and superseded.
    pub fn release(_: *SettingsStore, snap: *const Snapshot) void {
        const m: *Snapshot = @constCast(snap);
        _ = m.pins.fetchSub(1, .acq_rel);
    }

    /// Builds (or replaces) the layer for `(src.kind, src.folder)` and parks
    /// a new pending snapshot. Any thread. Returns the layer's diagnostics
    /// count of errors.
    pub fn setLayerSource(s: *SettingsStore, src: LayerSource) !usize {
        const l = try layer_mod.build(s.gpa, s.reg, src);
        errdefer l.release(s.gpa);
        const errors = l.diags.errorCount();
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const slot = for (s.layers.items) |*old| {
            if (old.*.kind == src.kind and old.*.folder == src.folder) break old;
        } else null;
        if (slot) |old| {
            old.*.release(s.gpa);
            old.* = l;
        } else try s.layers.append(s.gpa, l);
        std.sort.insertion(*Layer, s.layers.items, {}, struct {
            fn lt(_: void, a: *Layer, b: *Layer) bool {
                if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
                return @intFromEnum(a.folder orelse @as(FolderId, @enumFromInt(0))) < @intFromEnum(b.folder orelse @as(FolderId, @enumFromInt(0)));
            }
        }.lt);
        try s.rebuildLocked();
        return errors;
    }

    /// Removes the layer for `(kind, folder)` if present. Any thread.
    pub fn removeLayer(s: *SettingsStore, kind: LayerKind, folder: ?FolderId) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        for (s.layers.items, 0..) |l, i| if (l.kind == kind and l.folder == folder) {
            _ = s.layers.orderedRemove(i);
            l.release(s.gpa);
            return s.rebuildLocked();
        };
    }

    /// Replaces the trust port and rebuilds (restricted keys appear or vanish).
    pub fn setTrust(s: *SettingsStore, t: TrustPort) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.trust = t;
        try s.rebuildLocked();
    }

    /// Diagnostics of the layer `(kind, folder)`, valid until that layer is
    /// replaced. Call with the store otherwise idle (UI thread).
    pub fn layerDiags(s: *SettingsStore, kind: LayerKind, folder: ?FolderId) ?*const diag.Diags {
        for (s.layers.items) |l| if (l.kind == kind and l.folder == folder) return &l.diags;
        return null;
    }

    fn rebuildLocked(s: *SettingsStore) !void {
        const snap = try s.buildSnapshot();
        if (s.pending.swap(snap, .acq_rel)) |old| s.freeSnapshot(old);
        if (s.runtime) |rt| rt.post(.{ .kind = ui_msg_kind, .a = snap.gen }) catch {};
    }

    /// UI thread: publishes the pending snapshot, notifies subscribers and
    /// frees unpinned superseded snapshots. Returns the change, valid until
    /// the next `publish`, or null when nothing was pending.
    pub fn publish(s: *SettingsStore) !?Change {
        const next = s.pending.swap(null, .acq_rel) orelse {
            s.collect();
            return null;
        };
        const prev = s.current_ptr.swap(next, .acq_rel);
        const ids = try s.diff(prev, next);
        try s.retired.append(s.gpa, prev);
        const change: Change = .{ .gen = next.gen, .ids = ids };
        s.notify(&change);
        s.collect();
        return change;
    }

    /// Frees superseded snapshots that are no longer pinned.
    pub fn collect(s: *SettingsStore) void {
        var i: usize = 0;
        while (i < s.retired.items.len) {
            const r = s.retired.items[i];
            if (r.isPinnedOrCurrent()) {
                i += 1;
                continue;
            }
            _ = s.retired.swapRemove(i);
            s.freeSnapshot(r);
        }
    }

    /// Subscribes to changes of keys starting with `prefix` ("" = all).
    pub fn subscribe(s: *SettingsStore, prefix: []const u8, cb: ChangeCallback, ctx: ?*anyopaque) !SubscriptionId {
        const id: SubscriptionId = @enumFromInt(s.next_sub);
        s.next_sub += 1;
        const p = try s.gpa.dupe(u8, prefix);
        errdefer s.gpa.free(p);
        try s.subs.append(s.gpa, .{ .id = id, .prefix = p, .cb = cb, .ctx = ctx });
        return id;
    }

    /// Removes a subscription.
    pub fn unsubscribe(s: *SettingsStore, id: SubscriptionId) void {
        for (s.subs.items, 0..) |sub, i| if (sub.id == id) {
            s.gpa.free(sub.prefix);
            _ = s.subs.orderedRemove(i);
            return;
        };
    }

    fn diff(s: *SettingsStore, a: *const Snapshot, b: *const Snapshot) ![]const SettingId {
        const ids = &s.change_ids;
        ids.clearRetainingCapacity();
        const n = @min(a.window.len, b.window.len);
        for (0..@max(a.window.len, b.window.len)) |i| {
            const changed = i >= n or !a.window[i].eql(b.window[i]) or a.res_hash[i] != b.res_hash[i];
            if (changed) try ids.append(s.gpa, @enumFromInt(i));
        }
        return ids.items;
    }

    fn notify(s: *SettingsStore, change: *const Change) void {
        if (change.ids.len == 0) return;
        for (s.subs.items) |sub| {
            const hit = for (change.ids) |id| {
                if (std.mem.startsWith(u8, s.reg.def(id).key, sub.prefix)) break true;
            } else false;
            if (hit) sub.cb(sub.ctx, change);
        }
    }

    fn freeSnapshot(s: *SettingsStore, snap: *Snapshot) void {
        for (snap.layers) |l| l.release(s.gpa);
        var a = snap.arena;
        s.gpa.destroy(snap);
        a.deinit();
    }

    fn buildSnapshot(s: *SettingsStore) !*Snapshot {
        const snap = try s.gpa.create(Snapshot);
        errdefer s.gpa.destroy(snap);
        snap.* = .{
            .gen = s.gen,
            .reg = s.reg,
            .arena = .init(s.gpa),
            .layers = &.{},
            .window = &.{},
            .origin = &.{},
            .res_hash = &.{},
            .trusted = s.trust.isTrusted(null),
        };
        s.gen += 1;
        errdefer snap.arena.deinit();
        const a = snap.arena.allocator();
        const layers = try a.alloc(*Layer, s.layers.items.len);
        for (s.layers.items, layers) |l, *o| o.* = l.retain();
        snap.layers = layers;
        errdefer for (layers) |l| l.release(s.gpa);

        const n = s.reg.count();
        const window = try a.alloc(Value, n);
        const origin = try a.alloc(LayerKind, n);
        const res_hash = try a.alloc(u64, n);
        @memset(res_hash, 0);
        for (0..n) |i| {
            const id: SettingId = @enumFromInt(i);
            const d = s.reg.def(id);
            var v = s.reg.default(id);
            var o: LayerKind = .default;
            var it = snap.contributions(id, .{});
            while (it.next()) |c| {
                v = try mergeValues(a, d.merge, v, c.value);
                o = c.kind;
            }
            window[i] = v;
            origin[i] = o;
        }
        snap.window = window;
        snap.origin = origin;
        snap.res_hash = res_hash;

        // Resource fingerprints and precomputed merges.
        for (layers) |l| for (l.entries) |*e| {
            if (e.skipped(snap.trusted)) continue;
            if (e.lang_block == null and l.kind != .folder and l.kind != .editorconfig) continue;
            var h = std.hash.Wyhash.init(@intFromEnum(l.kind));
            if (l.folder) |f| h.update(std.mem.asBytes(&f));
            if (e.lang_block) |b| h.update(b);
            h.update(std.mem.asBytes(&e.value.hash()));
            res_hash[e.id.index()] +%= h.final();
        };
        for (0..n) |i| {
            const id: SettingId = @enumFromInt(i);
            const d = s.reg.def(id);
            if (d.merge == .replace or res_hash[i] == 0) continue;
            // Every (folder, lang) combination that has its own contributions.
            var folders: std.ArrayList(?FolderId) = .empty;
            var langs: std.ArrayList(?[]const u8) = .empty;
            try folders.append(a, null);
            try langs.append(a, null);
            for (layers) |l| for (l.entriesFor(id)) |e| {
                if (l.folder) |f| if (std.mem.indexOfScalar(?FolderId, folders.items, f) == null) try folders.append(a, f);
                for (e.langs) |lg| {
                    const seen = for (langs.items) |x| {
                        if (x != null and std.mem.eql(u8, x.?, lg)) break true;
                    } else false;
                    if (!seen) try langs.append(a, lg);
                }
            };
            for (folders.items) |f| for (langs.items) |lg| {
                if (f == null and lg == null) continue;
                var v = s.reg.default(id);
                var it = snap.contributions(id, .{ .folder = f, .lang = lg });
                while (it.next()) |c| v = try mergeValues(a, d.merge, v, c.value);
                try snap.merged.put(a, .{ .id = id, .folder = f, .lang = lg }, v);
            };
        }
        return snap;
    }
};

/// A typed, bound reference to one setting. `get` is an array index.
pub fn Handle(comptime T: type) type {
    return struct {
        const Self = @This();
        key: []const u8,
        id: SettingId = undefined,

        /// Resolves the dense id once at startup.
        pub fn bind(h: *Self, reg: *const SchemaRegistry) void {
            h.id = reg.lookup(h.key) orelse std.debug.panic("setting '{s}' is not in the registry", .{h.key});
        }

        /// The window-scope value.
        pub fn get(h: Self, snap: *const Snapshot) T {
            return convert(T, snap.window[h.id.index()]);
        }

        /// The value for a folder and/or language.
        pub fn getFor(h: Self, snap: *const Snapshot, rs: ResourceScope) T {
            return convert(T, snap.resolve(h.id, rs));
        }
    };
}

fn convert(comptime T: type, v: Value) T {
    if (T == Value) return v;
    switch (@typeInfo(T)) {
        .bool => return v == .bool and v.bool,
        .int => return switch (v) {
            .int => |i| std.math.cast(T, i) orelse 0,
            .float => |f| std.math.lossyCast(T, f),
            else => 0,
        },
        .float => return switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |f| @floatCast(f),
            else => 0,
        },
        .@"enum" => {
            const s = switch (v) {
                .string, .enum_lit => |x| x,
                else => return @enumFromInt(@typeInfo(T).@"enum".fields[0].value),
            };
            return std.meta.stringToEnum(T, s) orelse @enumFromInt(@typeInfo(T).@"enum".fields[0].value);
        },
        .pointer => {
            if (T != []const u8) @compileError("unsupported handle type " ++ @typeName(T));
            return switch (v) {
                .string, .enum_lit => |s| s,
                else => "",
            };
        },
        else => @compileError("unsupported handle type " ++ @typeName(T)),
    }
}

/// Typed handles checked against a package's *own* schema at comptime.
/// `Settings(@import("settings_schema.zon")).handle(i64, "editor.tabSize")`
/// is a compile error if the key is undeclared or `T` does not fit its type.
pub fn Settings(comptime own_schema: anytype) type {
    return struct {
        /// All defs of the package.
        pub const defs = schema.comptimeDefs(own_schema);

        /// A handle for `key` of type `T`.
        pub fn handle(comptime T: type, comptime key: []const u8) Handle(T) {
            comptime {
                const d = for (defs) |d| {
                    if (std.mem.eql(u8, d.key, key)) break d;
                } else @compileError("setting '" ++ key ++ "' is not declared in this package's settings_schema.zon");
                const ok = switch (d.type) {
                    .bool => T == bool,
                    .int => @typeInfo(T) == .int,
                    .float => @typeInfo(T) == .float,
                    .string, .path, .glob, .color, .keybinding, .command_id, .when_clause => T == []const u8,
                    .enum_ => T == []const u8 or (@typeInfo(T) == .@"enum" and enumMatches(T, d.enum_values)),
                    .array, .object, .any => T == Value,
                };
                if (!ok) @compileError("setting '" ++ key ++ "' has type ." ++ @tagName(d.type) ++ ", which does not fit " ++ @typeName(T));
            }
            return .{ .key = key };
        }
    };
}

fn enumMatches(comptime E: type, comptime values: []const []const u8) bool {
    const fields = @typeInfo(E).@"enum".fields;
    if (fields.len != values.len) return false;
    for (fields) |f| {
        const found = for (values) |v| {
            if (std.mem.eql(u8, v, f.name)) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// Context for `expand`.
pub const ExpandContext = struct {
    workspace_folder: ?[]const u8 = null,
    user_home: ?[]const u8 = null,
    env: ?*const std.process.Environ.Map = null,
};

/// Expands `${workspaceFolder}`, `${userHome}` and `${env:NAME}` in `s`.
/// `${secret:NAME}` is left as-is: secrets resolve through E16 at use sites.
/// Unknown variables are left as-is.
pub fn expand(arena: Allocator, s: []const u8, ctx: ExpandContext) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOf(u8, s, "${") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "${")) if (std.mem.indexOfScalarPos(u8, s, i, '}')) |close| {
            const name = s[i + 2 .. close];
            const rep: ?[]const u8 = if (std.mem.eql(u8, name, "workspaceFolder"))
                ctx.workspace_folder
            else if (std.mem.eql(u8, name, "userHome"))
                ctx.user_home
            else if (std.mem.startsWith(u8, name, "env:"))
                (if (ctx.env) |e| e.get(name[4..]) orelse "" else null)
            else
                null;
            if (rep) |r| {
                try out.appendSlice(arena, r);
                i = close + 1;
                continue;
            }
        };
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.items;
}
