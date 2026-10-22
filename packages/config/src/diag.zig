//! Diagnostics shared by every zg_config parser and validator: a byte span in
//! some source text, a severity and a message. A `Diags` list owns its
//! message bytes in an arena so producers can format freely.

const std = @import("std");

/// Byte offsets `[start, end)` in a source text.
pub const Span = struct {
    start: u32,
    end: u32,

    /// The empty span at offset 0, for diagnostics with no source position.
    pub const none: Span = .{ .start = 0, .end = 0 };

    /// The bytes of `src` this span covers.
    pub fn slice(s: Span, src: []const u8) []const u8 {
        return src[s.start..s.end];
    }
};

/// Diagnostic severity.
pub const Severity = enum { err, warning };

/// One diagnostic.
pub const Diag = struct {
    span: Span,
    severity: Severity,
    message: []const u8,
};

/// An append-only diagnostic list that owns its message strings.
pub const Diags = struct {
    arena: std.heap.ArenaAllocator,
    list: std.ArrayList(Diag) = .empty,

    /// An empty list allocating from `gpa`.
    pub fn init(gpa: std.mem.Allocator) Diags {
        return .{ .arena = .init(gpa) };
    }

    /// Frees every message.
    pub fn deinit(d: *Diags) void {
        d.arena.deinit();
        d.* = undefined;
    }

    /// Appends a formatted diagnostic. Out of memory drops the diagnostic:
    /// reporting must never turn a recoverable error into a fatal one.
    pub fn add(d: *Diags, span: Span, sev: Severity, comptime fmt: []const u8, args: anytype) void {
        const a = d.arena.allocator();
        const msg = std.fmt.allocPrint(a, fmt, args) catch return;
        d.list.append(a, .{ .span = span, .severity = sev, .message = msg }) catch return;
    }

    /// Number of diagnostics with severity `err`.
    pub fn errorCount(d: *const Diags) usize {
        var n: usize = 0;
        for (d.list.items) |x| n += @intFromBool(x.severity == .err);
        return n;
    }

    /// All diagnostics in insertion order.
    pub fn items(d: *const Diags) []const Diag {
        return d.list.items;
    }

    /// Whether any diagnostic message contains `needle` (for tests).
    pub fn contains(d: *const Diags, needle: []const u8) bool {
        for (d.list.items) |x| if (std.mem.indexOf(u8, x.message, needle) != null) return true;
        return false;
    }
};

/// 1-based line and column of byte `off` in `src` (column counts bytes).
pub fn lineCol(src: []const u8, off: u32) struct { line: u32, col: u32 } {
    var line: u32 = 1;
    var start: u32 = 0;
    const end = @min(off, src.len);
    for (src[0..end], 0..) |c, i| if (c == '\n') {
        line += 1;
        start = @intCast(i + 1);
    };
    return .{ .line = line, .col = end - start + 1 };
}

/// Writes `path:line:col: severity: message` for `d` against `src`.
pub fn render(w: *std.Io.Writer, path: []const u8, src: []const u8, d: Diag) std.Io.Writer.Error!void {
    const lc = lineCol(src, d.span.start);
    try w.print("{s}:{d}:{d}: {s}: {s}\n", .{ path, lc.line, lc.col, @tagName(d.severity), d.message });
}

test "diag: lineCol and render" {
    const src = "ab\ncd\n";
    try std.testing.expectEqual(@as(u32, 2), lineCol(src, 4).line);
    try std.testing.expectEqual(@as(u32, 2), lineCol(src, 4).col);
    var d = Diags.init(std.testing.allocator);
    defer d.deinit();
    d.add(.{ .start = 3, .end = 4 }, .err, "bad {s}", .{"thing"});
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try render(&w, "f.zon", src, d.items()[0]);
    try std.testing.expectEqualStrings("f.zon:2:1: err: bad thing\n", w.buffered());
    try std.testing.expectEqual(@as(usize, 1), d.errorCount());
}
