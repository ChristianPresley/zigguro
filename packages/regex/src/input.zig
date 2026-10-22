//! The haystack abstraction: a contiguous slice or a chunk source (piece
//! tree chunks searched in place, without copying), plus the search span and
//! mode flags.
//!
//! Engines read bytes sequentially through `Cursor` (forward) and
//! `RevCursor` (backward), which fetch one chunk at a time. Assertions read
//! neighbouring bytes with `byteAt`, which may cross chunk boundaries.
//! Assertions look outside `span`: `^` at `span.start` checks the byte before
//! it, as in Rust `regex`.

const std = @import("std");

/// A half-open byte range `[start, end)`.
pub const Range = struct {
    start: u64,
    end: u64,

    /// Number of bytes.
    pub fn len(r: Range) u64 {
        return r.end - r.start;
    }
};

/// One chunk: `bytes` start at absolute offset `base`.
pub const Chunk = struct {
    base: u64,
    bytes: []const u8,

    /// The absolute end offset.
    pub fn end(c: Chunk) u64 {
        return c.base + c.bytes.len;
    }
};

/// A chunk source. `chunkAt(offset)` returns the chunk containing `offset`
/// (`offset < total_len`); chunks are non-empty and tile the haystack.
pub const ChunkSource = struct {
    ctx: *const anyopaque,
    chunkAtFn: *const fn (ctx: *const anyopaque, offset: u64) Chunk,

    /// The chunk containing `offset`.
    pub fn chunkAt(s: ChunkSource, offset: u64) Chunk {
        return s.chunkAtFn(s.ctx, offset);
    }
};

/// A search input.
pub const Input = struct {
    source: union(enum) { slice: []const u8, chunks: ChunkSource },
    /// Total haystack length.
    total_len: u64,
    /// The part of the haystack searched; matches lie within it.
    span: Range,
    /// Only match at `span.start` (lexers).
    anchored: bool = false,
    /// Stop at the first match end found (for `isMatch`); the end may not
    /// be the leftmost-first end.
    earliest: bool = false,

    /// A contiguous haystack.
    pub fn fromSlice(s: []const u8) Input {
        return .{ .source = .{ .slice = s }, .total_len = s.len, .span = .{ .start = 0, .end = s.len } };
    }

    /// A chunked haystack of `total_len` bytes.
    pub fn fromChunks(src: ChunkSource, total_len: u64) Input {
        return .{ .source = .{ .chunks = src }, .total_len = total_len, .span = .{ .start = 0, .end = total_len } };
    }

    /// A copy searching only `span`.
    pub fn withSpan(in: Input, span: Range) Input {
        var r = in;
        std.debug.assert(span.start <= span.end and span.end <= in.total_len);
        r.span = span;
        return r;
    }

    /// A copy with `anchored` set.
    pub fn withAnchored(in: Input, anchored: bool) Input {
        var r = in;
        r.anchored = anchored;
        return r;
    }

    /// The chunk containing `pos` (`pos < total_len`).
    pub fn chunkAt(in: *const Input, pos: u64) Chunk {
        return switch (in.source) {
            .slice => |s| .{ .base = 0, .bytes = s },
            .chunks => |c| c.chunkAt(pos),
        };
    }

    /// The byte at `pos`, which must be `< total_len`.
    pub fn byteAt(in: *const Input, pos: u64) u8 {
        return switch (in.source) {
            .slice => |s| s[@intCast(pos)],
            .chunks => |c| blk: {
                const ch = c.chunkAt(pos);
                break :blk ch.bytes[@intCast(pos - ch.base)];
            },
        };
    }

    /// The contiguous slice, when the input is one.
    pub fn asSlice(in: *const Input) ?[]const u8 {
        return switch (in.source) {
            .slice => |s| s,
            .chunks => null,
        };
    }

    /// Copies `[r.start, r.end)` into `out` (which must be large enough).
    pub fn copyRange(in: *const Input, r: Range, out: []u8) void {
        var pos = r.start;
        var o: usize = 0;
        while (pos < r.end) {
            const ch = in.chunkAt(pos);
            const off: usize = @intCast(pos - ch.base);
            const n: usize = @intCast(@min(ch.end(), r.end) - pos);
            @memcpy(out[o..][0..n], ch.bytes[off..][0..n]);
            o += n;
            pos += n;
        }
    }
};

/// Sequential forward access to bytes from a position.
pub const Cursor = struct {
    input: *const Input,
    chunk: []const u8 = &.{},
    base: u64 = 0,

    /// A cursor over `input`.
    pub fn init(input: *const Input) Cursor {
        return .{ .input = input };
    }

    /// The byte at `pos` (`pos < total_len`); fast when `pos` is in the
    /// current chunk.
    pub inline fn get(c: *Cursor, pos: u64) u8 {
        if (pos < c.base or pos - c.base >= c.chunk.len) c.load(pos);
        return c.chunk[@intCast(pos - c.base)];
    }

    /// Loads the chunk holding `pos` and returns it as `(base, bytes)`.
    pub fn load(c: *Cursor, pos: u64) void {
        const ch = c.input.chunkAt(pos);
        c.chunk = ch.bytes;
        c.base = ch.base;
    }
};

/// A `ChunkSource` over a list of slices (tests, and callers with simple
/// segmented buffers).
pub const SliceChunks = struct {
    parts: []const []const u8,
    /// Start offset of each part.
    starts: []const u64,

    /// Builds the offset table into `starts_buf` (one entry per part).
    pub fn init(parts: []const []const u8, starts_buf: []u64) SliceChunks {
        var off: u64 = 0;
        for (parts, 0..) |p, i| {
            starts_buf[i] = off;
            off += p.len;
        }
        return .{ .parts = parts, .starts = starts_buf[0..parts.len] };
    }

    /// The total length.
    pub fn totalLen(s: *const SliceChunks) u64 {
        if (s.parts.len == 0) return 0;
        return s.starts[s.parts.len - 1] + s.parts[s.parts.len - 1].len;
    }

    /// This value as a `ChunkSource`. Empty parts are skipped by lookup.
    pub fn source(s: *const SliceChunks) ChunkSource {
        return .{ .ctx = s, .chunkAtFn = chunkAt };
    }

    fn chunkAt(ctx: *const anyopaque, offset: u64) Chunk {
        const s: *const SliceChunks = @ptrCast(@alignCast(ctx));
        // Last part whose start <= offset and which is non-empty.
        var lo: usize = 0;
        var hi: usize = s.parts.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (s.starts[mid] <= offset) lo = mid + 1 else hi = mid;
        }
        var i = lo - 1;
        while (s.parts[i].len == 0 or offset >= s.starts[i] + s.parts[i].len) i += 1;
        return .{ .base = s.starts[i], .bytes = s.parts[i] };
    }
};

test "input: chunked byteAt and copyRange agree with the slice" {
    const parts = [_][]const u8{ "ab", "", "cde", "f" };
    var starts: [4]u64 = undefined;
    const sc = SliceChunks.init(&parts, &starts);
    const in = Input.fromChunks(sc.source(), sc.totalLen());
    const flat = "abcdef";
    for (flat, 0..) |b, i| try std.testing.expectEqual(b, in.byteAt(i));
    var out: [4]u8 = undefined;
    in.copyRange(.{ .start = 1, .end = 5 }, &out);
    try std.testing.expectEqualStrings("bcde", &out);
    var c = Cursor.init(&in);
    for (flat, 0..) |b, i| try std.testing.expectEqual(b, c.get(i));
}
