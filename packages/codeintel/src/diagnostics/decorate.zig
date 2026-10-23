//! Diagnostics as editor decorations: for each attached document, the
//! store's diagnostics become squiggles by severity (hints dotted),
//! faded text for unnecessary code, strike-through for deprecated code,
//! a gutter mark with the line's highest severity and overview ruler
//! marks, all under the "lsp.diagnostics" owner.
//!
//! Commits only mark the documents whose diagnostics changed; `flush`
//! (once per frame) rebuilds those, so a frame costs O(changed
//! documents). Ranges are mapped from the version the server saw to the
//! decoration store's version, dropping the ones whose text was edited.

const Decorator = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_editor = @import("zg_editor");
const Store = @import("Store.zig");

const deco = zg_editor.model.decorations.store;
const DecorationStore = deco.DecorationStore;
const Decoration = deco.Decoration;
const StyleRef = deco.StyleRef;

pub const owner_name = "lsp.diagnostics";

pub const Styles = struct {
    /// Squiggle style per severity (error, warning, information, hint).
    severity: [4]StyleRef,
    faded: StyleRef,
    /// Gutter icon per severity.
    icons: [4]u32 = .{ 1, 2, 3, 4 },
};

const Target = struct {
    key: []u8,
    store: *DecorationStore,
    owner: deco.OwnerId,
    dirty: bool = true,
};

gpa: Allocator,
diags: *Store,
styles: Styles,
targets: std.ArrayList(Target) = .empty,
scratch: std.ArrayList(Decoration) = .empty,
lines: std.AutoArrayHashMapUnmanaged(u64, Store.Severity) = .empty,
/// Documents rebuilt (tests).
rebuilt: u32 = 0,

/// `d` must not move.
pub fn init(d: *Decorator, gpa: Allocator, diags: *Store, styles: Styles) Allocator.Error!void {
    d.* = .{ .gpa = gpa, .diags = diags, .styles = styles };
    try diags.addListener(.{ .ctx = d, .func = onCommit });
}

pub fn deinit(d: *Decorator) void {
    for (d.targets.items) |t| d.gpa.free(t.key);
    d.targets.deinit(d.gpa);
    d.scratch.deinit(d.gpa);
    d.lines.deinit(d.gpa);
}

/// Decorates `store` (a document's) with the diagnostics of store key
/// `key`, from the next `flush`.
pub fn attach(d: *Decorator, key: []const u8, store: *DecorationStore) Allocator.Error!void {
    const owner = store.ownerByName(owner_name) orelse try store.registerOwner(owner_name, 10);
    const k = try d.gpa.dupe(u8, key);
    errdefer d.gpa.free(k);
    try d.targets.append(d.gpa, .{ .key = k, .store = store, .owner = owner });
}

/// Stops decorating `store` (and clears what was drawn).
pub fn detach(d: *Decorator, store: *DecorationStore) void {
    var i: usize = d.targets.items.len;
    while (i > 0) {
        i -= 1;
        const t = d.targets.items[i];
        if (t.store != store) continue;
        t.store.clearOwner(t.owner);
        d.gpa.free(t.key);
        _ = d.targets.swapRemove(i);
    }
}

fn onCommit(ctx: *anyopaque, _: *const Store.Snapshot, changed: []const []const u8) void {
    const d: *Decorator = @ptrCast(@alignCast(ctx));
    for (d.targets.items) |*t| for (changed) |k| if (std.mem.eql(u8, k, t.key)) {
        t.dirty = true;
        break;
    };
}

/// Rebuilds the decorations of documents whose diagnostics changed; true
/// when any did.
pub fn flush(d: *Decorator) Allocator.Error!bool {
    var any = false;
    for (d.targets.items) |*t| if (t.dirty) {
        any = true;
        break;
    };
    if (!any) return false;
    const snap = d.diags.acquire();
    defer snap.release();
    for (d.targets.items) |*t| if (t.dirty) {
        try d.rebuild(t, snap);
        t.dirty = false;
        d.rebuilt += 1;
    };
    return true;
}

fn rebuild(d: *Decorator, t: *Target, snap: *const Store.Snapshot) Allocator.Error!void {
    const ds = t.store;
    const doc = ds.doc;
    // Ranges are mapped to the document's version, which the store must
    // be at (it hears every change).
    std.debug.assert(ds.version == doc.version);
    d.scratch.clearRetainingCapacity();
    d.lines.clearRetainingCapacity();
    if (snap.bucket(t.key)) |b| for (b.sets) |set| {
        const v = set.version orelse continue;
        for (set.diags) |dg| {
            const br = dg.bytes orelse continue;
            var r = doc.mapForward(v, .{ .start = br.start, .end = br.end }, .right) orelse continue;
            // An empty range still shows a character's squiggle.
            if (r.end == r.start) r.end = @min(r.start + 1, doc.len());
            const sev = @intFromEnum(dg.severity) - 1;
            const style = d.styles.severity[sev];
            const z: i16 = 4 - @as(i16, sev);
            try d.scratch.append(d.gpa, .{
                .range = r,
                .owner = t.owner,
                .z = z,
                .kind = .{ .underline = .{ .kind = if (dg.severity == .hint) .dotted else .squiggle, .style = style } },
            });
            if (dg.flags.unnecessary) try d.scratch.append(d.gpa, .{ .range = r, .owner = t.owner, .kind = .{ .text_style = d.styles.faded } });
            if (dg.flags.deprecated) try d.scratch.append(d.gpa, .{ .range = r, .owner = t.owner, .kind = .strike });
            try d.scratch.append(d.gpa, .{ .range = r, .owner = t.owner, .z = z, .kind = .{ .overview = .{ .style = style } } });
            const line = doc.tree.lineOf(r.start);
            const gop = try d.lines.getOrPut(d.gpa, line);
            if (!gop.found_existing or @intFromEnum(dg.severity) < @intFromEnum(gop.value_ptr.*)) gop.value_ptr.* = dg.severity;
        }
    };
    for (d.lines.keys(), d.lines.values()) |line, sev| {
        const at = doc.tree.lineStart(line);
        const i = @intFromEnum(sev) - 1;
        try d.scratch.append(d.gpa, .{
            .range = .{ .start = at, .end = at },
            .owner = t.owner,
            .stick = .point_left,
            .kind = .{ .gutter = .{ .icon = d.styles.icons[i], .style = d.styles.severity[i] } },
        });
    }
    try ds.setOwnerDecorations(t.owner, ds.version, d.scratch.items);
}
