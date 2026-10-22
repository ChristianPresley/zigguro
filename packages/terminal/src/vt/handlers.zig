//! Reference parser handlers: `NullHandler` (discards everything; used by
//! parser-only benchmarks) and `RecordingHandler` (logs every event as a line
//! of text; used by tests, fuzz targets and the conformance harness).

const std = @import("std");
const Allocator = std.mem.Allocator;
const params = @import("params.zig");
const Csi = params.Csi;
const Esc = params.Esc;
const StringTerm = params.StringTerm;

/// A handler that ignores every event and accepts DCS and APC strings.
pub const NullHandler = struct {
    /// Bytes and code points seen, so benchmarks cannot be optimised away.
    count: u64 = 0,

    /// See `Parser`.
    pub fn printAscii(h: *NullHandler, run: []const u8) void {
        h.count += run.len;
    }
    /// See `Parser`.
    pub fn printCodepoints(h: *NullHandler, cps: []const u21) void {
        h.count += cps.len;
    }
    /// See `Parser`.
    pub fn execute(h: *NullHandler, c: u8) void {
        h.count +%= c;
    }
    /// See `Parser`.
    pub fn escDispatch(h: *NullHandler, e: Esc) void {
        h.count +%= e.final;
    }
    /// See `Parser`.
    pub fn csiDispatch(h: *NullHandler, c: *const Csi) void {
        h.count +%= c.final;
    }
    /// See `Parser`.
    pub fn oscDispatch(h: *NullHandler, data: []const u8, term: StringTerm) void {
        _ = term;
        h.count += data.len;
    }
    /// See `Parser`.
    pub fn dcsHook(h: *NullHandler, c: *const Csi) bool {
        h.count +%= c.final;
        return true;
    }
    /// See `Parser`.
    pub fn dcsPut(h: *NullHandler, bytes: []const u8) void {
        h.count += bytes.len;
    }
    /// See `Parser`.
    pub fn dcsUnhook(h: *NullHandler) void {
        h.count += 1;
    }
    /// See `Parser`.
    pub fn apcStart(h: *NullHandler) bool {
        h.count += 1;
        return true;
    }
    /// See `Parser`.
    pub fn apcPut(h: *NullHandler, bytes: []const u8) void {
        h.count += bytes.len;
    }
    /// See `Parser`.
    pub fn apcEnd(h: *NullHandler) void {
        h.count += 1;
    }
};

/// A handler that writes one text line per event into `log`.
///
/// Consecutive prints (ASCII runs and code points alike) merge into one
/// `print` line, and consecutive `dcsPut`/`apcPut` calls merge into one
/// line, so the log is independent of how input was split and of whether the
/// fast path ran. Non-printable bytes are written as `\xNN`.
///
/// Line formats:
/// `print <text>`, `exec 0xNN`, `esc <inter><final>`,
/// `csi <private><params><inter><final>[ overflow]` (params as `1;2:3`,
/// empty params empty), `osc <bel|st> <data>`, `dcs_hook <same as csi>`,
/// `dcs_put <data>`, `dcs_unhook`, `apc_start`, `apc_put <data>`, `apc_end`.
pub const RecordingHandler = struct {
    gpa: Allocator,
    /// The event log.
    log: std.ArrayList(u8) = .empty,
    /// `dcsHook` returns false when set.
    reject_dcs: bool = false,
    /// `apcStart` returns false when set.
    reject_apc: bool = false,
    /// Stop recording once `log` reaches this size (fuzzing bound).
    max_log: usize = std.math.maxInt(usize),
    open: enum { none, print, dcs, apc } = .none,
    oom: bool = false,

    /// Creates an empty recorder.
    pub fn init(gpa: Allocator) RecordingHandler {
        return .{ .gpa = gpa };
    }

    /// Frees the log.
    pub fn deinit(h: *RecordingHandler) void {
        h.log.deinit(h.gpa);
    }

    /// The log with any open merged line terminated.
    pub fn text(h: *RecordingHandler) []const u8 {
        h.close();
        return h.log.items;
    }

    fn close(h: *RecordingHandler) void {
        if (h.open != .none) {
            h.open = .none;
            h.raw("\n");
        }
    }

    fn raw(h: *RecordingHandler, s: []const u8) void {
        if (h.oom or h.log.items.len + s.len > h.max_log) return;
        h.log.appendSlice(h.gpa, s) catch {
            h.oom = true;
        };
    }

    fn line(h: *RecordingHandler, comptime fmt: []const u8, args: anytype) void {
        h.close();
        var buf: [256]u8 = undefined;
        h.raw(std.fmt.bufPrint(&buf, fmt, args) catch "<long>");
    }

    fn escaped(h: *RecordingHandler, bytes: []const u8) void {
        for (bytes) |b| {
            if (b >= 0x20 and b < 0x7F and b != '\\') {
                h.raw(&.{b});
            } else {
                var buf: [4]u8 = undefined;
                h.raw(std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{b}) catch unreachable);
            }
        }
    }

    fn merged(h: *RecordingHandler, kind: @TypeOf(h.open), comptime head: []const u8) void {
        if (h.open != kind) {
            h.close();
            h.raw(head);
            h.open = kind;
        }
    }

    fn seq(h: *RecordingHandler, c: *const Csi) void {
        if (c.private != 0) h.raw(&.{c.private});
        for (0..c.count) |i| {
            if (i > 0) h.raw(if (c.isSub(i)) ":" else ";");
            if (c.has_value & (@as(u32, 1) << @intCast(i)) != 0) {
                var buf: [8]u8 = undefined;
                h.raw(std.fmt.bufPrint(&buf, "{d}", .{c.params[i]}) catch unreachable);
            }
        }
        h.escaped(c.intermediates());
        h.escaped(&.{c.final});
        if (c.overflow) h.raw(" overflow");
        h.raw("\n");
    }

    /// See `Parser`.
    pub fn printAscii(h: *RecordingHandler, run: []const u8) void {
        h.merged(.print, "print ");
        h.escaped(run);
    }
    /// See `Parser`.
    pub fn printCodepoints(h: *RecordingHandler, cps: []const u21) void {
        h.merged(.print, "print ");
        for (cps) |cp| {
            if (cp < 0x80) {
                h.escaped(&.{@intCast(cp)});
            } else {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch {
                    h.raw("\\u{?}");
                    continue;
                };
                h.raw(buf[0..n]);
            }
        }
    }
    /// See `Parser`.
    pub fn execute(h: *RecordingHandler, c: u8) void {
        h.line("exec 0x{x:0>2}\n", .{c});
    }
    /// See `Parser`.
    pub fn escDispatch(h: *RecordingHandler, e: Esc) void {
        h.close();
        h.raw("esc ");
        h.escaped(e.intermediates());
        h.escaped(&.{e.final});
        h.raw("\n");
    }
    /// See `Parser`.
    pub fn csiDispatch(h: *RecordingHandler, c: *const Csi) void {
        h.close();
        h.raw("csi ");
        h.seq(c);
    }
    /// See `Parser`.
    pub fn oscDispatch(h: *RecordingHandler, data: []const u8, term: StringTerm) void {
        h.close();
        h.raw(if (term == .bel) "osc bel " else "osc st ");
        h.escaped(data);
        h.raw("\n");
    }
    /// See `Parser`.
    pub fn dcsHook(h: *RecordingHandler, c: *const Csi) bool {
        h.close();
        h.raw("dcs_hook ");
        h.seq(c);
        return !h.reject_dcs;
    }
    /// See `Parser`.
    pub fn dcsPut(h: *RecordingHandler, bytes: []const u8) void {
        std.debug.assert(bytes.len <= 4096);
        h.merged(.dcs, "dcs_put ");
        h.escaped(bytes);
    }
    /// See `Parser`.
    pub fn dcsUnhook(h: *RecordingHandler) void {
        h.line("dcs_unhook\n", .{});
    }
    /// See `Parser`.
    pub fn apcStart(h: *RecordingHandler) bool {
        h.line("apc_start\n", .{});
        return !h.reject_apc;
    }
    /// See `Parser`.
    pub fn apcPut(h: *RecordingHandler, bytes: []const u8) void {
        std.debug.assert(bytes.len <= 4096);
        h.merged(.apc, "apc_put ");
        h.escaped(bytes);
    }
    /// See `Parser`.
    pub fn apcEnd(h: *RecordingHandler) void {
        h.line("apc_end\n", .{});
    }
};
