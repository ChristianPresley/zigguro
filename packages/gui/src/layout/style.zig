//! The `Style` model: the CSS subset the layout engine understands, plus the
//! box decoration (background, border, radius) the paint pass draws for
//! container nodes. Colours are theme tokens so widgets never hard-code them.

const std = @import("std");
const geom = @import("../core/geom.zig");
const tokens = @import("../theme/tokens.zig");
const hash_mod = @import("../core/hash.zig");

/// A length: automatic, fixed logical pixels, or a percentage of the
/// containing block's content box.
pub const Dim = union(enum) {
    auto,
    px: f32,
    pct: f32,

    /// The resolved length against `ref`, or null when automatic or when
    /// `ref` is indefinite for a percentage.
    pub fn resolve(d: Dim, ref: ?f32) ?f32 {
        return switch (d) {
            .auto => null,
            .px => |v| v,
            .pct => |p| if (ref) |r| r * p / 100 else null,
        };
    }
};

/// How a container lays out its children.
pub const Display = enum(u8) {
    /// Flexbox along `dir`.
    flex,
    /// Every child fills the content box and is aligned on both axes.
    stack,
    /// Not laid out, painted or hit-tested.
    none,
};

/// Whether a node takes part in its parent's layout.
pub const Position = enum(u8) {
    relative,
    /// Placed by `inset` against the parent's padding box; skipped by flex.
    absolute,
};

/// The flex main axis.
pub const Dir = enum(u8) { row, column, row_reverse, column_reverse };

/// Cross-axis alignment (`align-items` / `align-self`).
pub const Align = enum(u8) { start, center, end, stretch, baseline };

/// Main-axis distribution (`justify-content`) and `align-content`.
pub const Justify = enum(u8) { start, center, end, space_between, space_around, space_evenly };

/// A fill: nothing, a theme token, or (outside widgets) a literal colour.
pub const Fill = union(enum) {
    none,
    token: tokens.Token,
    color: geom.Color,
};

/// Optional per-edge offsets for absolute positioning.
pub const Inset = struct {
    l: ?f32 = null,
    t: ?f32 = null,
    r: ?f32 = null,
    b: ?f32 = null,
};

/// A node's layout and box style. Kept small: copied per node.
pub const Style = struct {
    display: Display = .flex,
    position: Position = .relative,
    dir: Dir = .row,
    wrap: bool = false,
    align_items: Align = .stretch,
    align_self: ?Align = null,
    align_content: Justify = .start,
    justify: Justify = .start,
    clip: bool = false,
    grow: f32 = 0,
    shrink: f32 = 1,
    basis: Dim = .auto,
    w: Dim = .auto,
    h: Dim = .auto,
    min_w: f32 = 0,
    min_h: f32 = 0,
    max_w: f32 = std.math.inf(f32),
    max_h: f32 = std.math.inf(f32),
    /// Width / height; applied when exactly one axis is definite.
    aspect: ?f32 = null,
    gap: f32 = 0,
    padding: geom.Insets = .{},
    margin: geom.Insets = .{},
    inset: Inset = .{},
    bg: Fill = .none,
    border: Fill = .none,
    border_w: f32 = 0,
    radius: f32 = 0,
    /// Paint above siblings with a lower value (stable for equal values).
    z: i16 = 0,
    /// Layout of this subtree never changes the node's own size, so dirty
    /// propagation stops here.
    relayout_boundary: bool = false,

    /// A row container.
    pub fn row() Style {
        return .{ .dir = .row };
    }

    /// A column container.
    pub fn column() Style {
        return .{ .dir = .column };
    }

    /// A 64-bit hash of the style (used to detect changes on rebuild).
    pub fn hash(s: *const Style) u64 {
        return hash_mod.of(s.*);
    }

    /// Field-wise equality (cheaper than hashing both sides).
    pub fn eql(a: *const Style, b: *const Style) bool {
        return std.meta.eql(a.*, b.*);
    }

    /// True when the main axis is horizontal.
    pub fn isRow(s: *const Style) bool {
        return s.dir == .row or s.dir == .row_reverse;
    }

    /// True when the main axis runs end to start.
    pub fn isReverse(s: *const Style) bool {
        return s.dir == .row_reverse or s.dir == .column_reverse;
    }
};

/// Fields a caller may override on the next node (`Ui.with`); null keeps
/// the widget's own style.
pub const Override = struct {
    grow: ?f32 = null,
    shrink: ?f32 = null,
    basis: ?Dim = null,
    w: ?Dim = null,
    h: ?Dim = null,
    min_w: ?f32 = null,
    min_h: ?f32 = null,
    max_w: ?f32 = null,
    max_h: ?f32 = null,
    align_self: ?Align = null,
    margin: ?geom.Insets = null,
    position: ?Position = null,
    inset: ?Inset = null,
    z: ?i16 = null,

    /// `s` with every non-null field of `o` applied.
    pub fn apply(o: Override, s: Style) Style {
        var out = s;
        inline for (@typeInfo(Override).@"struct".fields) |f| {
            if (@field(o, f.name)) |v| @field(out, f.name) = v;
        }
        return out;
    }

    /// True when no field is set.
    pub fn isEmpty(o: Override) bool {
        inline for (@typeInfo(Override).@"struct".fields) |f| {
            if (@field(o, f.name) != null) return false;
        }
        return true;
    }
};

comptime {
    std.debug.assert(@sizeOf(Style) <= 192);
}

test "dim resolve" {
    try std.testing.expectEqual(@as(?f32, null), Dim.resolve(.auto, 100));
    try std.testing.expectEqual(@as(?f32, 12), Dim.resolve(.{ .px = 12 }, null));
    try std.testing.expectEqual(@as(?f32, 50), Dim.resolve(.{ .pct = 50 }, 100));
    try std.testing.expectEqual(@as(?f32, null), Dim.resolve(.{ .pct = 50 }, null));
}

test "override applies only set fields" {
    const s = Override.apply(.{ .grow = 2, .w = .{ .px = 10 } }, .{ .shrink = 0 });
    try std.testing.expectEqual(@as(f32, 2), s.grow);
    try std.testing.expectEqual(@as(f32, 0), s.shrink);
    try std.testing.expectEqual(Dim{ .px = 10 }, s.w);
    try std.testing.expect((Override{}).isEmpty());
}

test "hash changes with fields" {
    const a: Style = .{};
    var b: Style = .{};
    try std.testing.expectEqual(a.hash(), b.hash());
    b.grow = 1;
    try std.testing.expect(a.hash() != b.hash());
}
