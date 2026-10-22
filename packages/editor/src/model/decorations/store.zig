//! DecorationStore: every annotation on one document's text (diagnostics,
//! find matches, SCM marks, ghost text, pending agent edits, ...), kept
//! attached to its text through edits.
//!
//! Decorations live in an interval tree with lazy deltas, so an edit costs
//! O(log n + k) for the k decorations it touches, however many follow it.
//! Producers own their decorations through an `OwnerId` and usually
//! replace their whole set at once with `setOwnerDecorations`, giving the
//! version their ranges were computed against.

const std = @import("std");
const it_mod = @import("interval_tree.zig");
const pt = @import("../buffer/piece_tree.zig");
const cs_mod = @import("../edit/change_set.zig");
const document = @import("../document.zig");

const Allocator = std.mem.Allocator;
const Tree = it_mod.Tree;
const Range = pt.Range;
const ChangeEvent = document.ChangeEvent;
const Document = document.Document;

/// Identifies a decoration; stale ids are ignored.
pub const DecorationId = enum(u64) { _ };

/// A registered producer ("lsp.diagnostics", "find", "ai.ghost", ...).
pub const OwnerId = enum(u32) { _ };

/// How a decoration's range follows edits at and around it.
pub const StickMode = enum {
    /// Typing at either edge stays outside; edits inside narrow it, and a
    /// deletion that empties it removes it.
    shrink,
    /// Typing at either edge extends it.
    grow_both,
    /// Typing at the start extends it, at the end does not.
    grow_start,
    /// Typing at the end extends it, at the start does not.
    grow_end,
    /// Zero-width anchor that stays before text inserted at it.
    point_left,
    /// Zero-width anchor that moves after text inserted at it.
    point_right,
};

/// A theme style (E15 token id).
pub const StyleRef = enum(u32) { _ };

pub const UnderlineStyle = struct {
    kind: enum { straight, squiggle, dotted, double } = .squiggle,
    style: StyleRef,
};

pub const GutterMark = struct { lane: u8 = 0, icon: u32, style: StyleRef };
pub const OverviewMark = struct { lane: u8 = 0, style: StyleRef };

/// Virtual text. The store copies `text`.
pub const InlineText = struct {
    text: []const u8,
    style: StyleRef,
    /// The caret jumps over it instead of stopping inside.
    cursor_skip: bool = true,
};

/// A whole-row virtual block (multi-line ghost text, deleted lines of an
/// inline diff, review threads); `payload` is the producer's.
pub const BlockSpec = struct { rows: u32, payload: u64 = 0 };

pub const Kind = union(enum) {
    highlight: StyleRef,
    text_style: StyleRef,
    underline: UnderlineStyle,
    strike,
    gutter: GutterMark,
    overview: OverviewMark,
    inline_before: InlineText,
    inline_after: InlineText,
    block_above: BlockSpec,
    block_below: BlockSpec,
    /// Hidden text (folds).
    hidden,
};

pub const KindTag = std.meta.Tag(Kind);
pub const KindMask = std.EnumSet(KindTag);

pub const Decoration = struct {
    range: Range,
    owner: OwnerId,
    /// Paint order among overlapping decorations; 0 takes the owner's
    /// default.
    z: i16 = 0,
    stick: StickMode = .shrink,
    kind: Kind,
    /// Producer's hover payload id.
    hover: ?u64 = null,
};

/// A decoration with its current range.
pub const DecoRef = struct { id: DecorationId, range: Range, deco: *const Decoration };

const Slot = struct {
    deco: Decoration,
    gen: u32 = 0,
    live: bool = false,
    /// Index in the owner's id list.
    owner_pos: u32 = 0,
};

const Owner = struct {
    name: []u8,
    z: i16,
    nodes: std.ArrayList(u32) = .empty,
};

/// The decorations of one document. UI thread only.
pub const DecorationStore = struct {
    gpa: Allocator,
    doc: *const Document,
    /// Document version the ranges are at.
    version: u64,
    tree: Tree = .{},
    slots: std.ArrayList(Slot) = .empty,
    owners: std.ArrayList(Owner) = .empty,
    /// Bumped whenever an inline or block decoration is added, moved or
    /// removed; the display map rebuilds its inlay and block layers.
    inline_generation: u64 = 0,
    /// Scratch for `onChange`, sized in `add` so edits never allocate.
    touched: std.ArrayList(u32) = .empty,
    scratch_items: std.ArrayList(Tree.Item) = .empty,
    scratch_stack: std.ArrayList(u32) = .empty,
    scratch_decos: std.ArrayList(Decoration) = .empty,

    /// An empty store for `doc` (at its current version). Feed it the
    /// document's changes with `onChange` (see `listener`).
    pub fn init(gpa: Allocator, doc: *const Document) DecorationStore {
        return .{ .gpa = gpa, .doc = doc, .version = doc.version };
    }

    pub fn deinit(s: *DecorationStore) void {
        for (s.slots.items) |*sl| if (sl.live) freePayload(s.gpa, &sl.deco);
        s.slots.deinit(s.gpa);
        for (s.owners.items) |*o| {
            s.gpa.free(o.name);
            o.nodes.deinit(s.gpa);
        }
        s.owners.deinit(s.gpa);
        s.tree.deinit(s.gpa);
        s.touched.deinit(s.gpa);
        s.scratch_items.deinit(s.gpa);
        s.scratch_stack.deinit(s.gpa);
        s.scratch_decos.deinit(s.gpa);
    }

    /// A document listener that calls `onChange`.
    pub fn listener(s: *DecorationStore) document.Listener {
        return .{ .ctx = s, .onChange = struct {
            fn f(ctx: *anyopaque, ev: *const ChangeEvent) void {
                const store: *DecorationStore = @ptrCast(@alignCast(ctx));
                store.onChange(ev);
            }
        }.f };
    }

    /// Registers a producer. Paint order among owners with equal z
    /// follows registration order.
    pub fn registerOwner(s: *DecorationStore, name: []const u8, default_z: i16) Allocator.Error!OwnerId {
        const copy = try s.gpa.dupe(u8, name);
        errdefer s.gpa.free(copy);
        try s.owners.append(s.gpa, .{ .name = copy, .z = default_z });
        return @enumFromInt(s.owners.items.len - 1);
    }

    /// The owner registered as `name`.
    pub fn ownerByName(s: *const DecorationStore, name: []const u8) ?OwnerId {
        for (s.owners.items, 0..) |o, i| if (std.mem.eql(u8, o.name, name)) return @enumFromInt(i);
        return null;
    }

    /// Adds a decoration whose range is in current coordinates.
    pub fn add(s: *DecorationStore, d: Decoration) Allocator.Error!DecorationId {
        std.debug.assert(d.range.start <= d.range.end and d.range.end <= s.doc.len());
        const owner = &s.owners.items[@intFromEnum(d.owner)];
        try owner.nodes.ensureUnusedCapacity(s.gpa, 1);
        try s.touched.ensureTotalCapacity(s.gpa, s.tree.len + 1);
        var deco = d;
        if (deco.z == 0) deco.z = owner.z;
        if (isPoint(deco.stick)) deco.range.end = deco.range.start;
        try dupePayload(s.gpa, &deco);
        errdefer freePayload(s.gpa, &deco);
        const n = try s.tree.insert(s.gpa, deco.range.start, deco.range.end);
        if (n >= s.slots.items.len) {
            s.slots.append(s.gpa, .{ .deco = undefined }) catch |e| {
                s.tree.remove(n);
                return e;
            };
        }
        const sl = &s.slots.items[n];
        sl.deco = deco;
        sl.live = true;
        sl.owner_pos = @intCast(owner.nodes.items.len);
        owner.nodes.appendAssumeCapacity(n);
        if (isInline(deco.kind)) s.inline_generation += 1;
        return idOf(sl.gen, n);
    }

    /// Removes a decoration (stale ids are ignored).
    pub fn remove(s: *DecorationStore, id: DecorationId) void {
        const n = s.nodeOf(id) orelse return;
        s.drop(n);
    }

    /// The decoration with its current range, or null.
    pub fn get(s: *const DecorationStore, id: DecorationId) ?DecoRef {
        const n = s.nodeOf(id) orelse return null;
        return s.refOf(n);
    }

    /// Decorations intersecting `r` (touching counts, so zero-width ones at
    /// its edges are included) whose kind is in `filter`, sorted by start,
    /// then z, then owner registration order.
    pub fn query(s: *const DecorationStore, r: Range, filter: KindMask, gpa: Allocator, out: *std.ArrayList(DecoRef)) Allocator.Error!void {
        const first = out.items.len;
        const Ctx = struct {
            s: *const DecorationStore,
            filter: KindMask,
            gpa: Allocator,
            out: *std.ArrayList(DecoRef),
            err: ?Allocator.Error = null,
            fn f(c: *@This(), n: u32, b: it_mod.Bounds) void {
                const d = &c.s.slots.items[n].deco;
                if (!c.filter.contains(d.kind)) return;
                c.out.append(c.gpa, .{ .id = idOf(c.s.slots.items[n].gen, n), .range = .{ .start = b.start, .end = b.end }, .deco = d }) catch |e| {
                    c.err = e;
                };
            }
        };
        var ctx: Ctx = .{ .s = s, .filter = filter, .gpa = gpa, .out = out };
        s.tree.query(r.start, r.end, &ctx, Ctx.f);
        if (ctx.err) |e| return e;
        std.sort.pdq(DecoRef, out.items[first..], {}, struct {
            fn lt(_: void, a: DecoRef, b: DecoRef) bool {
                if (a.range.start != b.range.start) return a.range.start < b.range.start;
                if (a.deco.z != b.deco.z) return a.deco.z < b.deco.z;
                if (a.deco.owner != b.deco.owner) return @intFromEnum(a.deco.owner) < @intFromEnum(b.deco.owner);
                return @intFromEnum(a.id) < @intFromEnum(b.id);
            }
        }.lt);
    }

    /// Replaces all of `owner`'s decorations with `decos`, whose ranges
    /// were computed against `version`; they are mapped to the current
    /// version and the ones whose text was deleted since are dropped.
    pub fn setOwnerDecorations(s: *DecorationStore, owner: OwnerId, version: u64, decos: []const Decoration) Allocator.Error!void {
        const old = s.ownerCount(owner);
        // Large replacements rebuild the tree in O(n) instead of paying
        // O(log n) per removal and insertion.
        if (old + decos.len >= 1024 and (old + decos.len) * 4 >= s.tree.len) return s.rebuildOwner(owner, version, decos);
        s.clearOwner(owner);
        const o = &s.owners.items[@intFromEnum(owner)];
        try o.nodes.ensureTotalCapacity(s.gpa, decos.len);
        for (decos) |d_in| {
            const d = s.prepare(owner, version, d_in) orelse continue;
            _ = try s.add(d);
        }
    }

    /// `d` owned by `owner` with its range mapped from `version`; null
    /// when its text was deleted since.
    fn prepare(s: *const DecorationStore, owner: OwnerId, version: u64, d_in: Decoration) ?Decoration {
        var d = d_in;
        d.owner = owner;
        if (version != s.version) {
            const bias: cs_mod.Bias = if (d.stick == .point_left) .left else .right;
            d.range = s.doc.mapForward(version, d.range, bias) orelse return null;
        }
        return d;
    }

    fn rebuildOwner(s: *DecorationStore, owner: OwnerId, version: u64, decos: []const Decoration) Allocator.Error!void {
        const Item = Tree.Item;
        const total = s.tree.len - s.ownerCount(owner) + decos.len;
        // Scratch kept between calls: diagnostics arrive repeatedly.
        const items = &s.scratch_items;
        items.clearRetainingCapacity();
        try items.ensureTotalCapacity(s.gpa, total + decos.len);
        try s.scratch_stack.resize(s.gpa, total);
        const stack = s.scratch_stack.items;
        const tmp = items.allocatedSlice()[total..][0..decos.len];
        const o = &s.owners.items[@intFromEnum(owner)];
        try o.nodes.ensureTotalCapacity(s.gpa, decos.len);
        try s.slots.ensureTotalCapacity(s.gpa, s.tree.nodes.items.len + decos.len);
        try s.touched.ensureTotalCapacity(s.gpa, total);
        try s.tree.nodes.ensureTotalCapacity(s.gpa, s.tree.nodes.items.len + decos.len);
        try s.tree.free.ensureTotalCapacity(s.gpa, s.tree.nodes.items.len + decos.len);
        // Copy the payloads first, so nothing below can fail halfway.
        const prepared = &s.scratch_decos;
        prepared.clearRetainingCapacity();
        try prepared.ensureTotalCapacity(s.gpa, decos.len);
        errdefer for (prepared.items) |*d| freePayload(s.gpa, d);
        for (decos) |d_in| {
            var d = s.prepare(owner, version, d_in) orelse continue;
            if (d.z == 0) d.z = o.z;
            if (isPoint(d.stick)) d.range.end = d.range.start;
            try dupePayload(s.gpa, &d);
            prepared.appendAssumeCapacity(d);
        }
        // Keep the other owners' nodes (in order), recycle this owner's.
        const Ctx = struct {
            s: *DecorationStore,
            owner: OwnerId,
            items: *std.ArrayList(Item),
            fn f(c: @This(), n: u32, b: it_mod.Bounds) void {
                const sl = &c.s.slots.items[n];
                if (sl.deco.owner == c.owner) return;
                c.items.appendAssumeCapacity(.{ .node = n, .start = b.start, .end = b.end });
            }
        };
        s.tree.query(0, std.math.maxInt(u64), Ctx{ .s = s, .owner = owner, .items = items }, Ctx.f);
        var reuse = o.nodes.items.len;
        for (o.nodes.items) |n| {
            const sl = &s.slots.items[n];
            if (isInline(sl.deco.kind)) s.inline_generation += 1;
            freePayload(s.gpa, &sl.deco);
            sl.live = false;
            sl.gen +%= 1;
        }
        const kept = items.items.len;
        for (prepared.items) |d| {
            const n = if (reuse > 0) blk: {
                reuse -= 1;
                break :blk o.nodes.items[reuse];
            } else s.tree.alloc(s.gpa) catch unreachable; // capacity reserved above
            if (n >= s.slots.items.len) s.slots.appendAssumeCapacity(.{ .deco = undefined });
            const sl = &s.slots.items[n];
            sl.deco = d;
            sl.live = true;
            if (isInline(d.kind)) s.inline_generation += 1;
            items.appendAssumeCapacity(.{ .node = n, .start = d.range.start, .end = d.range.end });
        }
        prepared.clearRetainingCapacity();
        for (o.nodes.items[0..reuse]) |n| s.tree.freeDetached(n);
        // New entries are sorted, then merged with the kept (sorted) ones.
        const lessItem = struct {
            fn lt(_: void, a: Item, b: Item) bool {
                return a.start < b.start or (a.start == b.start and a.node < b.node);
            }
        }.lt;
        std.sort.pdq(Item, items.items[kept..], {}, lessItem);
        mergeSorted(Item, items.items, kept, tmp, lessItem);
        s.tree.rebuild(items.items, stack);
        o.nodes.clearRetainingCapacity();
        for (items.items) |it| {
            const sl = &s.slots.items[it.node];
            if (sl.deco.owner != owner) continue;
            sl.owner_pos = @intCast(o.nodes.items.len);
            o.nodes.appendAssumeCapacity(it.node);
        }
    }

    /// Removes all of `owner`'s decorations.
    pub fn clearOwner(s: *DecorationStore, owner: OwnerId) void {
        const o = &s.owners.items[@intFromEnum(owner)];
        while (o.nodes.items.len > 0) s.drop(o.nodes.items[o.nodes.items.len - 1]);
    }

    /// Number of `owner`'s decorations.
    pub fn ownerCount(s: *const DecorationStore, owner: OwnerId) usize {
        return s.owners.items[@intFromEnum(owner)].nodes.items.len;
    }

    /// Total number of decorations.
    pub fn count(s: *const DecorationStore) usize {
        return s.tree.len;
    }

    /// Moves decorations through a document change.
    pub fn onChange(s: *DecorationStore, ev: *const ChangeEvent) void {
        std.debug.assert(ev.old_version == s.version);
        s.version = ev.new_version;
        // Back to front, so each replace sees positions not yet moved by
        // earlier ones.
        var i = ev.changes.replaces.len;
        while (i > 0) {
            i -= 1;
            s.applyReplace(ev.changes.replaces[i]);
        }
    }

    fn applyReplace(s: *DecorationStore, r: cs_mod.Replace) void {
        const a = r.range.start;
        const b = r.range.end;
        const n_ins: u64 = r.text.len;
        // Detach the decorations touching [a, b], shift everything after
        // it, then put the detached ones back where their stick mode says.
        s.touched.clearRetainingCapacity();
        while (true) {
            const n = s.tree.findIntersecting(a, b);
            if (n == it_mod.nil) break;
            const bd = s.tree.bounds(n);
            s.slots.items[n].deco.range = .{ .start = bd.start, .end = bd.end };
            s.tree.detach(n);
            s.touched.appendAssumeCapacity(n);
        }
        s.tree.shift(b, @as(i64, @intCast(n_ins)) - @as(i64, @intCast(b - a)));
        for (s.touched.items) |n| {
            const sl = &s.slots.items[n];
            if (isInline(sl.deco.kind)) s.inline_generation += 1;
            if (mapRange(sl.deco.range, sl.deco.stick, a, b, n_ins)) |nr| {
                s.tree.attach(n, nr.start, nr.end);
            } else {
                s.unown(n);
                s.tree.freeDetached(n);
            }
        }
    }

    fn drop(s: *DecorationStore, n: u32) void {
        s.unown(n);
        s.tree.remove(n);
    }

    /// Forgets slot `n` (its tree node is handled by the caller).
    fn unown(s: *DecorationStore, n: u32) void {
        const sl = &s.slots.items[n];
        const o = &s.owners.items[@intFromEnum(sl.deco.owner)];
        const last = o.nodes.pop().?;
        if (last != n) {
            o.nodes.items[sl.owner_pos] = last;
            s.slots.items[last].owner_pos = sl.owner_pos;
        }
        if (isInline(sl.deco.kind)) s.inline_generation += 1;
        freePayload(s.gpa, &sl.deco);
        sl.live = false;
        sl.gen +%= 1;
    }

    fn nodeOf(s: *const DecorationStore, id: DecorationId) ?u32 {
        const raw = @intFromEnum(id);
        const n: u32 = @truncate(raw);
        if (n >= s.slots.items.len) return null;
        const sl = &s.slots.items[n];
        if (!sl.live or sl.gen != @as(u32, @truncate(raw >> 32))) return null;
        return n;
    }

    fn refOf(s: *const DecorationStore, n: u32) DecoRef {
        const b = s.tree.bounds(n);
        return .{ .id = idOf(s.slots.items[n].gen, n), .range = .{ .start = b.start, .end = b.end }, .deco = &s.slots.items[n].deco };
    }
};

/// Merges the sorted runs `xs[0..mid]` and `xs[mid..]` in place; `tmp`
/// holds at least `xs.len - mid` items.
fn mergeSorted(comptime T: type, xs: []T, mid: usize, tmp: []T, comptime lt: fn (void, T, T) bool) void {
    if (mid == 0 or mid == xs.len or !lt({}, xs[mid], xs[mid - 1])) return;
    const second = tmp[0 .. xs.len - mid];
    @memcpy(second, xs[mid..]);
    // Merge from the back, so writes land on slots already read.
    var i = mid;
    var j = second.len;
    var k = xs.len;
    while (j > 0) {
        k -= 1;
        if (i > 0 and lt({}, second[j - 1], xs[i - 1])) {
            xs[k] = xs[i - 1];
            i -= 1;
        } else {
            xs[k] = second[j - 1];
            j -= 1;
        }
    }
}

fn idOf(gen: u32, n: u32) DecorationId {
    return @enumFromInt(@as(u64, gen) << 32 | n);
}

fn isPoint(m: StickMode) bool {
    return m == .point_left or m == .point_right;
}

fn isInline(k: Kind) bool {
    return switch (k) {
        .inline_before, .inline_after, .block_above, .block_below, .hidden => true,
        else => false,
    };
}

fn dupePayload(gpa: Allocator, d: *Decoration) Allocator.Error!void {
    switch (d.kind) {
        .inline_before, .inline_after => |*t| t.text = try gpa.dupe(u8, t.text),
        else => {},
    }
}

fn freePayload(gpa: Allocator, d: *Decoration) void {
    switch (d.kind) {
        .inline_before, .inline_after => |t| gpa.free(t.text),
        else => {},
    }
}

/// Where a position in `[a, b]` lands when `[a, b)` is replaced by `n`
/// bytes: the deleted span collapses to `a`, then the insertion puts a
/// left-biased position before the new text and a right-biased one after.
fn mapPos(p: u64, left: bool, a: u64, b: u64, n: u64) u64 {
    if (p < a) return p;
    if (p > b) return p - (b - a) + n;
    return if (left) a else a + n;
}

/// `range` through one replacement, per `stick`; null when it is removed.
pub fn mapRange(range: Range, stick: StickMode, a: u64, b: u64, n: u64) ?Range {
    const start_left, const end_left = switch (stick) {
        .shrink => .{ false, true },
        .grow_both => .{ true, false },
        .grow_start => .{ true, true },
        .grow_end => .{ false, false },
        .point_left => .{ true, true },
        .point_right => .{ false, false },
    };
    const s = mapPos(range.start, start_left, a, b, n);
    const e = mapPos(range.end, end_left, a, b, n);
    // A shrinking range whose text was all replaced goes away.
    if (e <= s and range.start < range.end and stick == .shrink) return null;
    if (e < s) return .{ .start = s, .end = s };
    return .{ .start = s, .end = e };
}
