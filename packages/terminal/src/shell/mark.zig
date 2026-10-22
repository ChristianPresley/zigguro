//! Shell-integration marks (OSC 133 / 633 / 7 / 9;9 / 1337) as the OSC
//! dispatcher reports them, and the `MarkSink` interface E06.F06 implements.
//! `RecordingMarkSink` is the test double until the block model lands
//! (E06.F06.S02.T01).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Pin = @import("../screen/PageList.zig").Pin;

/// OSC 133;A options.
pub const PromptOpts = struct {
    /// `k=`: i (initial, default), c (continuation), s (secondary), r (right).
    kind: enum { initial, continuation, secondary, right } = .initial,
    /// `aid=`: the application id grouping nested shells (empty when absent).
    aid: []const u8 = "",
};

/// One mark. Slices are valid only during `onMark`.
pub const Mark = union(enum) {
    prompt_start: PromptOpts,
    input_start,
    command_executed,
    command_finished: ?i32,
    /// OSC 633;E; `trusted` when the nonce matched the session's.
    command_line: struct { text: []const u8, trusted: bool },
    /// OSC 633;P;Key=Value.
    property: struct { key: []const u8, value: []const u8 },
    cwd: []const u8,
    bookmark,
};

/// Receives marks with the cursor position they apply to.
pub const MarkSink = struct {
    ctx: *anyopaque,
    onMarkFn: *const fn (ctx: *anyopaque, m: Mark, at: Pin) void,

    /// Delivers `m`.
    pub fn onMark(s: MarkSink, m: Mark, at: Pin) void {
        s.onMarkFn(s.ctx, m, at);
    }
};

/// A sink that records marks as text lines with the active-area row, for
/// tests: `A k=initial aid=`, `B`, `C`, `D 2`, `D -`, `E trusted <text>`,
/// `P key=value`, `cwd <path>`, `bookmark`.
pub const RecordingMarkSink = struct {
    gpa: Allocator,
    log: std.ArrayList(u8) = .empty,
    /// Rows (page-list absolute) of each mark, in order.
    rows: std.ArrayList(u64) = .empty,
    /// Maps a pin to its absolute row (set by the owner).
    rowOf: ?*const fn (Pin) u64 = null,

    /// Frees the log.
    pub fn deinit(r: *RecordingMarkSink) void {
        r.log.deinit(r.gpa);
        r.rows.deinit(r.gpa);
    }

    /// The `MarkSink` interface.
    pub fn sink(r: *RecordingMarkSink) MarkSink {
        return .{ .ctx = r, .onMarkFn = onMarkErased };
    }

    fn onMarkErased(ctx: *anyopaque, m: Mark, at: Pin) void {
        const r: *RecordingMarkSink = @ptrCast(@alignCast(ctx));
        r.record(m, at) catch {};
    }

    fn record(r: *RecordingMarkSink, m: Mark, at: Pin) !void {
        const g = r.gpa;
        switch (m) {
            .prompt_start => |o| try r.log.print(g, "A k={s} aid={s}\n", .{ @tagName(o.kind), o.aid }),
            .input_start => try r.log.appendSlice(g, "B\n"),
            .command_executed => try r.log.appendSlice(g, "C\n"),
            .command_finished => |e| if (e) |v| try r.log.print(g, "D {d}\n", .{v}) else try r.log.appendSlice(g, "D -\n"),
            .command_line => |c| try r.log.print(g, "E {s} {s}\n", .{ if (c.trusted) "trusted" else "untrusted", c.text }),
            .property => |p| try r.log.print(g, "P {s}={s}\n", .{ p.key, p.value }),
            .cwd => |p| try r.log.print(g, "cwd {s}\n", .{p}),
            .bookmark => try r.log.appendSlice(g, "bookmark\n"),
        }
        if (r.rowOf) |f| try r.rows.append(g, f(at));
    }
};
