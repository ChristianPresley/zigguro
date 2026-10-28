//! Task output to lines for the problem matchers: bytes are split on
//! `\n` (a trailing `\r` dropped), ANSI escape sequences (CSI, OSC and
//! the DCS/APC/PM/SOS strings) are removed, and lines longer than the
//! buffer are truncated. A clear-screen sequence (ED 2 or 3, as
//! `zig build --watch --error-style minimal_clear` prints) is reported,
//! since background matchers use it to start a cycle.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_line = 64 * 1024;

pub const LineSplitter = struct {
    buf: []u8,
    len: usize = 0,
    state: State = .text,
    /// The current CSI's parameter bytes (enough to spot `2J`/`3J`).
    params: [4]u8 = undefined,
    params_len: u8 = 0,
    /// A clear-screen sequence was seen since the last `takeCleared`.
    cleared: bool = false,

    const State = enum { text, esc, csi, osc, osc_esc, str, str_esc };

    pub fn init(gpa: Allocator) Allocator.Error!LineSplitter {
        return .{ .buf = try gpa.alloc(u8, max_line) };
    }

    pub fn deinit(s: *LineSplitter, gpa: Allocator) void {
        gpa.free(s.buf);
    }

    /// Calls `on_line(ctx, line, cleared)` for every complete line in
    /// `bytes`; `cleared` says a clear-screen came before the line.
    pub fn feed(s: *LineSplitter, bytes: []const u8, ctx: anytype, comptime on_line: fn (@TypeOf(ctx), []const u8, bool) void) void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (s.state == .text) {
                // The common case: copy up to the next newline or escape.
                const rest = bytes[i..];
                const n = std.mem.indexOfAny(u8, rest, "\n\x1b") orelse rest.len;
                s.append(rest[0..n]);
                i += n;
                if (i == bytes.len) break;
                if (bytes[i] == '\n') {
                    s.emit(ctx, on_line);
                } else {
                    s.state = .esc;
                }
                i += 1;
                continue;
            }
            const c = bytes[i];
            i += 1;
            switch (s.state) {
                .text => unreachable,
                .esc => s.state = switch (c) {
                    '[' => blk: {
                        s.params_len = 0;
                        break :blk .csi;
                    },
                    ']' => .osc,
                    'P', '_', '^', 'X' => .str,
                    // Two-byte sequences (ESC 7, ESC =, charset designators'
                    // first byte) end here; the designator's final byte is
                    // printable and kept, which is harmless for matching.
                    else => .text,
                },
                .csi => if (c >= 0x40 and c <= 0x7e) {
                    if (c == 'J' and s.params_len == 1 and (s.params[0] == '2' or s.params[0] == '3')) s.cleared = true;
                    s.state = .text;
                } else if (s.params_len < s.params.len) {
                    s.params[s.params_len] = c;
                    s.params_len += 1;
                },
                .osc => switch (c) {
                    0x07 => s.state = .text,
                    0x1b => s.state = .osc_esc,
                    '\n' => {
                        // An unterminated OSC: give the line back.
                        s.state = .text;
                        s.emit(ctx, on_line);
                    },
                    else => {},
                },
                .osc_esc => s.state = if (c == '\\') .text else .osc,
                .str => s.state = if (c == 0x1b) .str_esc else .str,
                .str_esc => s.state = if (c == '\\') .text else .str,
            }
        }
    }

    /// The last line when the output ended without a newline.
    pub fn finish(s: *LineSplitter, ctx: anytype, comptime on_line: fn (@TypeOf(ctx), []const u8, bool) void) void {
        if (s.len > 0) s.emit(ctx, on_line);
        s.state = .text;
    }

    fn append(s: *LineSplitter, bytes: []const u8) void {
        const n = @min(bytes.len, s.buf.len - s.len);
        @memcpy(s.buf[s.len..][0..n], bytes[0..n]);
        s.len += n;
    }

    fn emit(s: *LineSplitter, ctx: anytype, comptime on_line: fn (@TypeOf(ctx), []const u8, bool) void) void {
        var line = s.buf[0..s.len];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const cleared = s.cleared;
        s.cleared = false;
        s.len = 0;
        on_line(ctx, line, cleared);
    }
};

/// `text` without escape sequences (tests, one-off use).
pub fn strip(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var s: LineSplitter = try .init(gpa);
    defer s.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const Acc = struct {
        out: *std.ArrayList(u8),
        gpa: Allocator,
        failed: bool = false,
        fn line(a: *@This(), l: []const u8, _: bool) void {
            a.out.appendSlice(a.gpa, l) catch {
                a.failed = true;
                return;
            };
            a.out.append(a.gpa, '\n') catch {
                a.failed = true;
            };
        }
    };
    var acc: Acc = .{ .out = &out, .gpa = gpa };
    s.feed(text, &acc, Acc.line);
    s.finish(&acc, Acc.line);
    if (acc.failed) return error.OutOfMemory;
    if (out.items.len > 0 and (text.len == 0 or text[text.len - 1] != '\n')) _ = out.pop();
    return out.toOwnedSlice(gpa);
}
