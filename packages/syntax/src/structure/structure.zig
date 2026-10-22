//! Structure: what a parse knows about a document beyond its tokens.
//! Folds, outline symbols, scopes (sticky scroll, breadcrumbs, AI context),
//! selection ranges and indent depth. Providers (the Zig `std.zig.Ast`
//! adapter, later the GLR runtime) fill a `Builder`; queries run on the
//! finished, immutable `Structure`, which carries the version it was
//! computed for.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Bytes `[start, end)` of the parsed text.
pub const ByteRange = struct {
    start: u32,
    end: u32,

    pub fn contains(r: ByteRange, pos: u32) bool {
        return r.start <= pos and pos < r.end;
    }

    /// Like `contains`, but `end` counts as inside (a caret after the last
    /// byte of a node is still on it).
    pub fn touches(r: ByteRange, pos: u32) bool {
        return r.start <= pos and pos <= r.end;
    }
};

pub const FoldKind = enum { block, comment, imports, string };

/// A foldable region: lines `start_line` to `end_line` (inclusive; the
/// closing line usually stays visible).
pub const FoldRange = struct { start_line: u32, end_line: u32, kind: FoldKind };

pub const SymbolKind = enum { function, test_decl, @"struct", @"enum", @"union", @"opaque", error_set, field, constant, variable };

/// An outline entry. `parent` indexes `Structure.symbols`.
pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    /// The whole declaration.
    range: ByteRange,
    /// The name, for highlighting and go-to.
    selection: ByteRange,
    parent: ?u32 = null,
    is_pub: bool = false,
};

pub const ScopeKind = enum { function, test_decl, container, @"if", @"while", @"for", @"switch", block };

/// A region with a header: what sticky scroll pins and AI context
/// chunking cuts along. `header` is the first line of the scope.
pub const Scope = struct {
    kind: ScopeKind,
    range: ByteRange,
    header: ByteRange,
    name: []const u8 = "",
};

const none = std.math.maxInt(u32);

pub const ParseError = Allocator.Error || error{TooLarge};

/// A structure provider: parses a document's text.
pub const ParseFn = *const fn (gpa: Allocator, text: []const u8, version: u64) ParseError!Structure;

pub const Structure = struct {
    version: u64,
    arena: std.heap.ArenaAllocator.State,
    gpa: Allocator,
    /// Sorted by start line.
    folds: []const FoldRange,
    /// Document order; parents come before their children.
    symbols: []const Symbol,
    /// Sorted by start, outer before inner at equal starts.
    scopes: []const Scope,
    scope_parent: []const u32,
    /// Node spans, sorted by start then by decreasing end, deduplicated.
    spans: []const ByteRange,
    span_parent: []const u32,

    /// Frees everything.
    pub fn deinit(s: *Structure) void {
        s.arena.promote(s.gpa).deinit();
        s.* = undefined;
    }

    /// The outline, in document order.
    pub fn outline(s: *const Structure) []const Symbol {
        return s.symbols;
    }

    /// Scopes containing `pos`, innermost first.
    pub fn enclosingScopes(s: *const Structure, gpa: Allocator, pos: u32, out: *std.ArrayList(Scope)) Allocator.Error!void {
        out.clearRetainingCapacity();
        var i = innermost(s.scopes, s.scope_parent, pos, rangeOfScope) orelse return;
        while (true) {
            try out.append(gpa, s.scopes[i]);
            i = s.scope_parent[i];
            if (i == none) return;
        }
    }

    /// Node spans containing `pos`, innermost first, ending with the whole
    /// text: the steps of "expand selection".
    pub fn selectionRanges(s: *const Structure, gpa: Allocator, pos: u32, out: *std.ArrayList(ByteRange)) Allocator.Error!void {
        out.clearRetainingCapacity();
        var i = innermost(s.spans, s.span_parent, pos, rangeOfSpan) orelse return;
        while (true) {
            try out.append(gpa, s.spans[i]);
            i = s.span_parent[i];
            if (i == none) return;
        }
    }

    /// Block nesting at `pos`: scopes whose body (after the header line)
    /// contains it.
    pub fn indentDepth(s: *const Structure, pos: u32) ?u32 {
        var i = innermost(s.scopes, s.scope_parent, pos, rangeOfScope) orelse return 0;
        var depth: u32 = 0;
        while (true) {
            const sc = s.scopes[i];
            if (pos >= sc.header.end) depth += 1;
            i = s.scope_parent[i];
            if (i == none) return depth;
        }
    }

    fn rangeOfScope(sc: anytype) ByteRange {
        return sc.range;
    }

    fn rangeOfSpan(r: anytype) ByteRange {
        return r;
    }

    fn innermost(items: anytype, parent: []const u32, pos: u32, comptime rangeOf: anytype) ?u32 {
        // The last item starting at or before `pos`, then up its ancestors
        // to the first that touches `pos` (nesting makes the rest touch too).
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (rangeOf(items[mid]).start <= pos) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        var i: u32 = @intCast(lo - 1);
        while (!rangeOf(items[i]).touches(pos)) {
            i = parent[i];
            if (i == none) return null;
        }
        return i;
    }
};

/// Collects structure; `finish` sorts it and links parents.
pub const Builder = struct {
    arena: std.heap.ArenaAllocator,
    folds: std.ArrayList(FoldRange) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    spans: std.ArrayList(ByteRange) = .empty,

    pub fn init(gpa: Allocator) Builder {
        return .{ .arena = .init(gpa) };
    }

    /// Frees a builder that was not finished.
    pub fn deinit(b: *Builder) void {
        b.arena.deinit();
    }

    pub fn allocator(b: *Builder) Allocator {
        return b.arena.allocator();
    }

    pub fn fold(b: *Builder, start_line: u32, end_line: u32, kind: FoldKind) Allocator.Error!void {
        if (end_line > start_line) try b.folds.append(b.arena.allocator(), .{ .start_line = start_line, .end_line = end_line, .kind = kind });
    }

    /// Adds a symbol and returns its index (for children's `parent`).
    pub fn symbol(b: *Builder, s: Symbol) Allocator.Error!u32 {
        const a = b.arena.allocator();
        var copy = s;
        copy.name = try a.dupe(u8, s.name);
        try b.symbols.append(a, copy);
        return @intCast(b.symbols.items.len - 1);
    }

    pub fn scope(b: *Builder, s: Scope) Allocator.Error!void {
        const a = b.arena.allocator();
        var copy = s;
        copy.name = try a.dupe(u8, s.name);
        try b.scopes.append(a, copy);
    }

    pub fn span(b: *Builder, r: ByteRange) Allocator.Error!void {
        if (r.end > r.start) try b.spans.append(b.arena.allocator(), r);
    }

    /// The finished structure; the builder is consumed.
    pub fn finish(b: *Builder, version: u64) Allocator.Error!Structure {
        const a = b.arena.allocator();
        std.sort.pdq(FoldRange, b.folds.items, {}, struct {
            fn lt(_: void, x: FoldRange, y: FoldRange) bool {
                return x.start_line < y.start_line or (x.start_line == y.start_line and x.end_line > y.end_line);
            }
        }.lt);
        // Drop duplicate folds (same start line: keep the largest).
        var nf: usize = 0;
        for (b.folds.items) |f| {
            if (nf > 0 and b.folds.items[nf - 1].start_line == f.start_line) continue;
            b.folds.items[nf] = f;
            nf += 1;
        }
        std.sort.pdq(Scope, b.scopes.items, {}, struct {
            fn lt(_: void, x: Scope, y: Scope) bool {
                return x.range.start < y.range.start or (x.range.start == y.range.start and x.range.end > y.range.end);
            }
        }.lt);
        try sortSpans(a, b.spans.items);
        var ns: usize = 0;
        for (b.spans.items) |r| {
            if (ns > 0 and std.meta.eql(b.spans.items[ns - 1], r)) continue;
            b.spans.items[ns] = r;
            ns += 1;
        }
        const scopes = b.scopes.items;
        const spans = b.spans.items[0..ns];
        const scope_parent = try a.alloc(u32, scopes.len);
        try linkParents(a, Scope, scopes, scope_parent, struct {
            fn f(s: Scope) ByteRange {
                return s.range;
            }
        }.f);
        const span_parent = try a.alloc(u32, spans.len);
        try linkParents(a, ByteRange, spans, span_parent, struct {
            fn f(r: ByteRange) ByteRange {
                return r;
            }
        }.f);
        const out: Structure = .{
            .version = version,
            .arena = b.arena.state,
            .gpa = b.arena.child_allocator,
            .folds = b.folds.items[0..nf],
            .symbols = b.symbols.items,
            .scopes = scopes,
            .scope_parent = scope_parent,
            .spans = spans,
            .span_parent = span_parent,
        };
        b.* = undefined;
        return out;
    }

    /// Sorts by start, then by decreasing end: an LSD radix sort on 64-bit
    /// keys, since a large file has a span per AST node (millions).
    fn sortSpans(a: Allocator, spans: []ByteRange) Allocator.Error!void {
        if (spans.len < 256) {
            std.sort.pdq(ByteRange, spans, {}, struct {
                fn lt(_: void, x: ByteRange, y: ByteRange) bool {
                    return x.start < y.start or (x.start == y.start and x.end > y.end);
                }
            }.lt);
            return;
        }
        const keys = try a.alloc(u64, spans.len);
        defer a.free(keys);
        const tmp = try a.alloc(u64, spans.len);
        defer a.free(tmp);
        for (spans, keys) |r, *k| k.* = @as(u64, r.start) << 32 | (std.math.maxInt(u32) - r.end);
        var src = keys;
        var dst = tmp;
        var shift: u6 = 0;
        while (true) : (shift += 16) {
            var counts: [1 << 16]u32 = @splat(0);
            for (src) |k| counts[@as(u16, @truncate(k >> shift))] += 1;
            var sum: u32 = 0;
            for (&counts) |*c| {
                const n = c.*;
                c.* = sum;
                sum += n;
            }
            for (src) |k| {
                const d = @as(u16, @truncate(k >> shift));
                dst[counts[d]] = k;
                counts[d] += 1;
            }
            std.mem.swap([]u64, &src, &dst);
            if (shift == 48) break;
        }
        for (spans, src) |*r, k| r.* = .{ .start = @intCast(k >> 32), .end = std.math.maxInt(u32) - @as(u32, @truncate(k)) };
    }

    /// For items sorted by start (outer first), the nearest earlier item
    /// that contains each one. Ranges that cross (bad input) attach to the
    /// nearest container of their start.
    fn linkParents(a: Allocator, comptime T: type, items: []const T, parent: []u32, comptime rangeOf: fn (T) ByteRange) Allocator.Error!void {
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(a);
        for (items, 0..) |it, i| {
            const r = rangeOf(it);
            while (stack.items.len > 0) {
                const top = rangeOf(items[stack.items[stack.items.len - 1]]);
                if (top.start <= r.start and r.end <= top.end) break;
                _ = stack.pop();
            }
            parent[i] = if (stack.items.len > 0) stack.items[stack.items.len - 1] else none;
            try stack.append(a, @intCast(i));
        }
    }
};

test "structure: queries over nested ranges" {
    const gpa = std.testing.allocator;
    var b: Builder = .init(gpa);
    // text: 0..100 file; fn 10..90 (header 10..20); if 30..60 (header 30..40).
    try b.scope(.{ .kind = .@"if", .range = .{ .start = 30, .end = 60 }, .header = .{ .start = 30, .end = 40 } });
    try b.scope(.{ .kind = .function, .range = .{ .start = 10, .end = 90 }, .header = .{ .start = 10, .end = 20 }, .name = "f" });
    for ([_]ByteRange{ .{ .start = 0, .end = 100 }, .{ .start = 10, .end = 90 }, .{ .start = 30, .end = 60 }, .{ .start = 32, .end = 35 }, .{ .start = 32, .end = 35 }, .{ .start = 70, .end = 80 } }) |r| try b.span(r);
    try b.fold(3, 8, .block);
    try b.fold(3, 5, .block);
    try b.fold(1, 1, .block);
    var s = try b.finish(7);
    defer s.deinit();
    try std.testing.expectEqual(@as(u64, 7), s.version);
    try std.testing.expectEqual(@as(usize, 1), s.folds.len);
    try std.testing.expectEqual(@as(u32, 8), s.folds[0].end_line);

    var scopes: std.ArrayList(Scope) = .empty;
    defer scopes.deinit(gpa);
    try s.enclosingScopes(gpa, 45, &scopes);
    try std.testing.expectEqual(@as(usize, 2), scopes.items.len);
    try std.testing.expectEqual(ScopeKind.@"if", scopes.items[0].kind);
    try std.testing.expectEqualStrings("f", scopes.items[1].name);
    try s.enclosingScopes(gpa, 75, &scopes);
    try std.testing.expectEqual(@as(usize, 1), scopes.items.len);
    try s.enclosingScopes(gpa, 5, &scopes);
    try std.testing.expectEqual(@as(usize, 0), scopes.items.len);

    var sel: std.ArrayList(ByteRange) = .empty;
    defer sel.deinit(gpa);
    try s.selectionRanges(gpa, 33, &sel);
    try std.testing.expectEqualSlices(ByteRange, &.{ .{ .start = 32, .end = 35 }, .{ .start = 30, .end = 60 }, .{ .start = 10, .end = 90 }, .{ .start = 0, .end = 100 } }, sel.items);
    try s.selectionRanges(gpa, 65, &sel);
    try std.testing.expectEqualSlices(ByteRange, &.{ .{ .start = 10, .end = 90 }, .{ .start = 0, .end = 100 } }, sel.items);

    try std.testing.expectEqual(@as(?u32, 2), s.indentDepth(45));
    try std.testing.expectEqual(@as(?u32, 1), s.indentDepth(35));
    try std.testing.expectEqual(@as(?u32, 0), s.indentDepth(95));
}
