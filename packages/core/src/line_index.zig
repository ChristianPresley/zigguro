//! LineIndex: the line-start table of a text snapshot. `\n`, `\r\n` and a
//! lone `\r` are all line terminators (LSP 3.17 text document rules).

const std = @import("std");

const V = @Vector(32, u8);

/// Byte offsets of every line start; line 0 starts at 0. Offsets are `u64`
/// so files over 4 GiB work.
pub const LineIndex = struct {
    starts: std.ArrayList(u64),

    /// Scans `text` (SIMD: 32 bytes per step, skipping blocks with no CR/LF).
    pub fn build(gpa: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!LineIndex {
        var starts: std.ArrayList(u64) = .empty;
        errdefer starts.deinit(gpa);
        try starts.ensureTotalCapacity(gpa, text.len / 40 + 1);
        starts.appendAssumeCapacity(0);
        const nl: V = @splat('\n');
        const cr: V = @splat('\r');
        var i: usize = 0;
        while (i < text.len) {
            if (i + 32 <= text.len) {
                const v: V = text[i..][0..32].*;
                var m_nl: u32 = @bitCast(v == nl);
                const m_cr: u32 = @bitCast(v == cr);
                if (m_cr == 0) {
                    // LF-only block: one append per set bit, no per-byte branches.
                    try starts.ensureUnusedCapacity(gpa, @popCount(m_nl));
                    while (m_nl != 0) : (m_nl &= m_nl - 1) starts.appendAssumeCapacity(i + @ctz(m_nl) + 1);
                    i += 32;
                    continue;
                }
                const end = i + 32;
                while (i < end) : (i += 1) i = try scalarStep(gpa, &starts, text, i);
                continue;
            }
            i = try scalarStep(gpa, &starts, text, i);
            i += 1;
        }
        return .{ .starts = starts };
    }

    /// Handles byte `i`; returns the index of the last byte consumed.
    fn scalarStep(gpa: std.mem.Allocator, starts: *std.ArrayList(u64), text: []const u8, i: usize) !usize {
        switch (text[i]) {
            '\n' => try starts.append(gpa, i + 1),
            '\r' => {
                if (i + 1 < text.len and text[i + 1] == '\n') {
                    try starts.append(gpa, i + 2);
                    return i + 1;
                }
                try starts.append(gpa, i + 1);
            },
            else => {},
        }
        return i;
    }

    /// Number of lines (at least 1; a trailing terminator starts an empty last line).
    pub fn lineCount(self: *const LineIndex) u32 {
        return @intCast(self.starts.items.len);
    }

    /// The line containing byte offset `byte` (binary search). Offsets past
    /// the end map to the last line.
    pub fn lineOf(self: *const LineIndex, byte: u64) u32 {
        const s = self.starts.items;
        var lo: usize = 0;
        var hi: usize = s.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (s[mid] <= byte) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    /// Byte offset where `line` starts; asserts `line < lineCount()`.
    pub fn lineStart(self: *const LineIndex, line: u32) u64 {
        return self.starts.items[line];
    }

    /// Frees the table.
    pub fn deinit(self: *LineIndex, gpa: std.mem.Allocator) void {
        self.starts.deinit(gpa);
        self.* = undefined;
    }
};

test "line_index: mixed EOLs" {
    const gpa = std.testing.allocator;
    const text = "a\nbb\r\nccc\rd" ++ ("x" ** 40) ++ "\r" ++ "\n" ++ ("y" ** 31) ++ "\n";
    var li = try LineIndex.build(gpa, text);
    defer li.deinit(gpa);
    try std.testing.expectEqualSlices(u64, &.{ 0, 2, 6, 10, 53, 85 }, li.starts.items);
    try std.testing.expectEqual(@as(u32, 0), li.lineOf(1));
    try std.testing.expectEqual(@as(u32, 1), li.lineOf(2));
    try std.testing.expectEqual(@as(u32, 2), li.lineOf(9));
    try std.testing.expectEqual(@as(u32, 5), li.lineOf(1000));
    try std.testing.expectEqual(@as(u64, 6), li.lineStart(2));
}

test "line_index: CRLF split across a 32-byte block" {
    const gpa = std.testing.allocator;
    const text = ("z" ** 31) ++ "\r\n" ++ "w";
    var li = try LineIndex.build(gpa, text);
    defer li.deinit(gpa);
    try std.testing.expectEqualSlices(u64, &.{ 0, 33 }, li.starts.items);
}

test "fuzz: line_index matches a scalar reference" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            const gpa = std.testing.allocator;
            var buf: [300]u8 = undefined;
            const n = s.slice(&buf);
            for (buf[0..n]) |*c| c.* = switch (c.* % 4) {
                0 => '\n',
                1 => '\r',
                else => 'a',
            };
            const text = buf[0..n];
            var li = try LineIndex.build(gpa, text);
            defer li.deinit(gpa);
            var ref: std.ArrayList(u64) = .empty;
            defer ref.deinit(gpa);
            try ref.append(gpa, 0);
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\r' and i + 1 < text.len and text[i + 1] == '\n') {
                    i += 1;
                    try ref.append(gpa, i + 1);
                } else if (text[i] == '\n' or text[i] == '\r') try ref.append(gpa, i + 1);
            }
            try std.testing.expectEqualSlices(u64, ref.items, li.starts.items);
        }
    }.one, .{ .corpus = &.{ "abc", "\r\n\r\n" } });
}
