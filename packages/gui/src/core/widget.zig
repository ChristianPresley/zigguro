//! Widget kinds: the comptime-generated vtable behind every node, the
//! process-wide kind registry, and props retention.
//!
//! A widget is a namespace struct `W` declaring:
//! - `pub const Props` (required) and `pub const State` (optional);
//! - optional functions, all taking `*const Props` and `*State`:
//!   `style(props, theme) Style`, `measure(*MeasureCx, props, state, max_w) Size`,
//!   `paint(*PaintCx, props, state)`, `event(*EventCx, props, state, *const InputEvent) bool`,
//!   `a11y(props, state) A11y`, `layoutHash(props) u64`, `paintHash(props) u64`;
//! - optional `pub const focusable: bool` and `pub const hit_testable: bool`.
//!
//! Props are retained per node (slices deep-copied into a node-owned blob)
//! so a node can be repainted or re-measured without rebuilding its view.

const std = @import("std");
const geom = @import("geom.zig");
const ids = @import("ids.zig");
const hash = @import("hash.zig");
const style_mod = @import("../layout/style.zig");
const theme_mod = @import("../theme/theme.zig");
const paint_cx = @import("../paint/paint_cx.zig");
const event_mod = @import("../input/event.zig");
const measure_mod = @import("../layout/measure.zig");

const KindId = ids.KindId;
const Style = style_mod.Style;
const Theme = theme_mod.Theme;

/// Accessibility role (subset of WAI-ARIA / UIA control types).
pub const Role = enum(u8) {
    none,
    group,
    text,
    button,
    link,
    checkbox,
    radio,
    switch_,
    slider,
    progressbar,
    textbox,
    separator,
    status,
    list,
    listitem,
    tree,
    treeitem,
    tab,
    tablist,
    tabpanel,
    menu,
    menuitem,
    menubar,
    dialog,
    tooltip,
    toolbar,
    img,
    window,
};

/// What a node exposes to assistive technology and test queries.
pub const A11y = struct {
    role: Role = .none,
    name: []const u8 = "",
    checked: ?bool = null,
    disabled: bool = false,
    value: ?f32 = null,
    /// The text of an editable node (text boxes; empty for passwords).
    text: []const u8 = "",
};

/// Type-erased widget operations; one static instance per widget type.
pub const WidgetVTable = struct {
    name: []const u8,
    tag: u64,
    props_size: u32,
    props_align: u8,
    state_size: u32,
    state_align: u8,
    focusable: bool,
    hit_testable: bool,
    initState: *const fn (*anyopaque) void,
    deinitState: *const fn (*anyopaque) void,
    /// Copies props into `blob` (resizing it) and fixes up slices.
    retain: *const fn (gpa: std.mem.Allocator, blob: *Blob, props: *const anyopaque) std.mem.Allocator.Error!void,
    /// The props' layout hash and paint hash, in that order. A widget
    /// without `layoutHash`/`paintHash` hashes its props once for both.
    hashes: *const fn (*const anyopaque) [2]u64,
    style: ?*const fn (*const anyopaque, *const Theme) Style,
    measure: ?*const fn (*measure_mod.MeasureCx, *const anyopaque, *anyopaque, ?f32) geom.Size,
    paint: ?*const fn (*paint_cx.PaintCx, *const anyopaque, *anyopaque) void,
    event: ?*const fn (*event_mod.EventCx, *const anyopaque, *anyopaque, *const event_mod.InputEvent) bool,
    a11y: ?*const fn (*const anyopaque, *anyopaque) A11y,
};

/// A node-owned, 16-byte aligned byte buffer holding retained props.
pub const Blob = struct {
    bytes: []align(16) u8 = &.{},

    /// Frees the buffer.
    pub fn deinit(b: *Blob, gpa: std.mem.Allocator) void {
        if (b.bytes.len > 0) gpa.free(b.bytes);
        b.bytes = &.{};
    }

    /// Makes the buffer exactly `n` bytes, reusing it when large enough.
    pub fn ensure(b: *Blob, gpa: std.mem.Allocator, n: usize) ![]align(16) u8 {
        // At least one byte, so "has props" is `bytes.len > 0` even for
        // widgets whose props are empty.
        const need = @max(n, 1);
        if (b.bytes.len >= need and b.bytes.len <= need * 2 + 64) return b.bytes;
        b.deinit(gpa);
        b.bytes = try gpa.alignedAlloc(u8, .@"16", need);
        return b.bytes;
    }
};

/// The empty state of widgets that declare none.
pub const NoState = struct {};

/// The `State` type of widget `W`.
pub fn StateOf(comptime W: type) type {
    return if (@hasDecl(W, "State")) W.State else NoState;
}

/// The static vtable of widget type `W`.
pub fn vtableOf(comptime W: type) *const WidgetVTable {
    return &struct {
        const P = W.Props;
        const S = StateOf(W);
        comptime {
            if (@alignOf(P) > 16) @compileError("widget props alignment above 16: " ++ @typeName(W));
        }

        fn initState(p: *anyopaque) void {
            const s: *S = @ptrCast(@alignCast(p));
            s.* = if (@hasDecl(W, "initState")) W.initState() else .{};
        }
        fn deinitState(p: *anyopaque) void {
            if (@hasDecl(W, "deinitState")) W.deinitState(@as(*S, @ptrCast(@alignCast(p))));
        }
        fn retainFn(gpa: std.mem.Allocator, blob: *Blob, src: *const anyopaque) std.mem.Allocator.Error!void {
            const props: *const P = @ptrCast(@alignCast(src));
            const extra = deepSize(P, props);
            const total = std.mem.alignForward(usize, @sizeOf(P), 16) + extra;
            const buf = try blob.ensure(gpa, total);
            const dst: *P = @ptrCast(@alignCast(buf.ptr));
            dst.* = props.*;
            var off: usize = std.mem.alignForward(usize, @sizeOf(P), 16);
            deepCopy(P, dst, buf, &off);
        }
        fn hashes(p: *const anyopaque) [2]u64 {
            const props: *const P = @ptrCast(@alignCast(p));
            const lh = comptime @hasDecl(W, "layoutHash");
            const ph = comptime @hasDecl(W, "paintHash");
            if (!lh and !ph) {
                const h = hash.of(props.*);
                return .{ h, h };
            }
            return .{
                if (lh) W.layoutHash(props) else hash.of(props.*),
                if (ph) W.paintHash(props) else hash.of(props.*),
            };
        }
        fn styleFn(p: *const anyopaque, th: *const Theme) Style {
            return W.style(@ptrCast(@alignCast(p)), th);
        }
        fn measureFn(mc: *measure_mod.MeasureCx, p: *const anyopaque, s: *anyopaque, max_w: ?f32) geom.Size {
            return W.measure(mc, @ptrCast(@alignCast(p)), @ptrCast(@alignCast(s)), max_w);
        }
        fn paintFn(pc: *paint_cx.PaintCx, p: *const anyopaque, s: *anyopaque) void {
            W.paint(pc, @ptrCast(@alignCast(p)), @ptrCast(@alignCast(s)));
        }
        fn eventFn(ec: *event_mod.EventCx, p: *const anyopaque, s: *anyopaque, ev: *const event_mod.InputEvent) bool {
            return W.event(ec, @ptrCast(@alignCast(p)), @ptrCast(@alignCast(s)), ev);
        }
        fn a11yFn(p: *const anyopaque, s: *anyopaque) A11y {
            return W.a11y(@ptrCast(@alignCast(p)), @ptrCast(@alignCast(s)));
        }

        const vt: WidgetVTable = .{
            .name = if (@hasDecl(W, "name")) W.name else @typeName(W),
            .tag = ids.kindTag(W),
            .props_size = @sizeOf(P),
            .props_align = @alignOf(P),
            .state_size = @sizeOf(S),
            .state_align = @alignOf(S),
            .focusable = if (@hasDecl(W, "focusable")) W.focusable else false,
            .hit_testable = if (@hasDecl(W, "hit_testable")) W.hit_testable else (@hasDecl(W, "event") or (@hasDecl(W, "focusable") and W.focusable)),
            .initState = initState,
            .deinitState = deinitState,
            .retain = retainFn,
            .hashes = hashes,
            .style = if (@hasDecl(W, "style")) styleFn else null,
            .measure = if (@hasDecl(W, "measure")) measureFn else null,
            .paint = if (@hasDecl(W, "paint")) paintFn else null,
            .event = if (@hasDecl(W, "event")) eventFn else null,
            .a11y = if (@hasDecl(W, "a11y")) a11yFn else null,
        };
    }.vt;
}

// ---------------------------------------------------------------------------
// Kind registry.

const max_kinds = 4096;
var registry: [max_kinds]?*const WidgetVTable = [_]?*const WidgetVTable{null} ** max_kinds;
var registry_len: std.atomic.Value(u16) = .init(first_dynamic);
const first_dynamic: u16 = 4;

/// Registers a built-in kind at a fixed id (root, box, text, view).
pub fn registerBuiltin(kind: KindId, vt: *const WidgetVTable) void {
    registry[@intFromEnum(kind)] = vt;
}

/// The kind id of widget `W`, registering it on first use.
pub fn kindOf(comptime W: type) KindId {
    const Cache = struct {
        // Referencing W makes this a distinct type per widget.
        const owner = W;
        var id: std.atomic.Value(u16) = .init(0xffff);
    };
    const cached = Cache.id.load(.acquire);
    if (cached != 0xffff) return @enumFromInt(cached);
    const fresh = registry_len.fetchAdd(1, .monotonic);
    if (fresh >= max_kinds) @panic("zg_gui: more than 4096 widget kinds");
    registry[fresh] = vtableOf(W);
    if (Cache.id.cmpxchgStrong(0xffff, fresh, .acq_rel, .acquire)) |winner| return @enumFromInt(winner);
    return @enumFromInt(fresh);
}

/// The vtable of a registered kind.
pub fn vtable(kind: KindId) *const WidgetVTable {
    return registry[@intFromEnum(kind)] orelse @panic("zg_gui: unregistered widget kind");
}

// ---------------------------------------------------------------------------
// Props retention: one level of slices is deep-copied into the node blob.

fn deepSize(comptime T: type, v: *const T) usize {
    var n: usize = 0;
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| {
            if (!f.is_comptime) n += deepSize(f.type, &@field(v.*, f.name));
        },
        .optional => |o| if (v.*) |*x| {
            n += deepSize(o.child, x);
        },
        .@"union" => |u| {
            if (u.tag_type == null) return 0;
            switch (v.*) {
                inline else => |*x| n += deepSize(@TypeOf(x.*), x),
            }
        },
        .array => |a| for (v) |*x| {
            n += deepSize(a.child, x);
        },
        .pointer => |p| if (p.size == .slice) {
            checkFlat(p.child);
            n += std.mem.alignForward(usize, v.len * @sizeOf(p.child), 16);
        },
        else => {},
    }
    return n;
}

fn deepCopy(comptime T: type, v: *T, buf: []align(16) u8, off: *usize) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| inline for (s.fields) |f| {
            if (!f.is_comptime) deepCopy(f.type, &@field(v.*, f.name), buf, off);
        },
        .optional => |o| if (v.*) |*x| {
            deepCopy(o.child, @constCast(x), buf, off);
        },
        .@"union" => |u| {
            if (u.tag_type == null) return;
            switch (v.*) {
                inline else => |*x| deepCopy(@TypeOf(x.*), x, buf, off),
            }
        },
        .array => |a| for (v) |*x| {
            deepCopy(a.child, x, buf, off);
        },
        .pointer => |p| if (p.size == .slice) {
            const bytes = v.len * @sizeOf(p.child);
            const dst = buf[off.*..][0..bytes];
            @memcpy(dst, std.mem.sliceAsBytes(v.*));
            const typed: [*]p.child = @ptrCast(@alignCast(dst.ptr));
            v.* = typed[0..v.len];
            off.* += std.mem.alignForward(usize, bytes, 16);
        },
        else => {},
    }
}

fn checkFlat(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("zg_gui props: nested slices/pointers inside a slice are not retained (" ++ @typeName(T) ++ ")"),
        .@"struct" => |s| inline for (s.fields) |f| checkFlat(f.type),
        .optional => |o| checkFlat(o.child),
        .array => |a| checkFlat(a.child),
        else => {},
    }
    if (@alignOf(T) > 16) @compileError("zg_gui props: slice element alignment above 16");
}

test "retain deep-copies slices" {
    const W = struct {
        pub const Props = struct { label: []const u8, n: u32 = 0, opt: ?[]const u16 = null };
    };
    const vt = vtableOf(W);
    var blob: Blob = .{};
    defer blob.deinit(std.testing.allocator);
    var label = "hello".*;
    const wide = [_]u16{ 1, 2, 3 };
    const p: W.Props = .{ .label = &label, .n = 7, .opt = &wide };
    try vt.retain(std.testing.allocator, &blob, &p);
    label[0] = 'j';
    const kept: *const W.Props = @ptrCast(@alignCast(blob.bytes.ptr));
    try std.testing.expectEqualStrings("hello", kept.label);
    try std.testing.expectEqual(@as(u32, 7), kept.n);
    try std.testing.expectEqualSlices(u16, &wide, kept.opt.?);
    try std.testing.expect(@intFromPtr(kept.label.ptr) >= @intFromPtr(blob.bytes.ptr));
}

test "kind ids are stable per type" {
    const A = struct {
        pub const Props = struct {};
    };
    const B = struct {
        pub const Props = struct {};
    };
    const a = kindOf(A);
    try std.testing.expectEqual(a, kindOf(A));
    try std.testing.expect(a != kindOf(B));
    try std.testing.expectEqual(vtableOf(A), vtable(a));
}
