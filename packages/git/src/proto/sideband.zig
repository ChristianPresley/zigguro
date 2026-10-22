//! Sideband demultiplexing (gitprotocol-pack): in `side-band`,
//! `side-band-64k` and `sideband-all` responses the first payload byte of
//! each packet names a band. Band 1 is data (the pack), band 2 progress
//! text for the user, band 3 a fatal error message.
//!
//! `Sideband.reader` exposes band 1 as a `std.Io.Reader` (for the pack
//! indexer), forwarding progress to a callback as it goes. The data ends
//! at a flush (or, in `sideband-all`, also at a delimiter or response
//! end, recorded in `end`). Band 3 fails the read with `ReadFailed`, and
//! `err` is then `RemoteError` with the message in `remoteMessage()`.
//!
//! Progress text is split at CR and LF (git redraws a line with CR), and
//! lines like `Receiving objects:  45% (450/1000)` are parsed into
//! `Progress`. Nothing is allocated.

const std = @import("std");
const pktline = @import("pktline.zig");
const PktReader = pktline.PktReader;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const Mode = enum {
    /// `side-band-64k`: packets up to 65520 bytes.
    band64k,
    /// `side-band`: packets up to 1000 bytes (not enforced on read).
    band,
    /// `sideband-all` (protocol v2): every packet of the response is
    /// banded; empty progress packets are keepalives.
    all,
};

/// One parsed progress line.
pub const Progress = struct {
    /// "Receiving objects", "Resolving deltas", ...
    phase: []const u8,
    done: u64,
    total: ?u64 = null,
    /// Whether git reported the phase finished (", done.").
    finished: bool = false,
};

pub const ProgressEvent = union(enum) {
    progress: Progress,
    /// A line that is not a progress counter.
    message: []const u8,
};

pub const ProgressFn = *const fn (ctx: ?*anyopaque, ev: ProgressEvent) void;

pub const Error = pktline.ReadError || error{
    /// Band 3: the remote gave up; see `remoteMessage`.
    RemoteError,
    /// A data packet with no band byte or an unknown band.
    BadSideband,
};

pub const Sideband = struct {
    pr: *PktReader,
    mode: Mode,
    on_progress: ?ProgressFn = null,
    progress_ctx: ?*anyopaque = null,
    /// Why the band-1 stream ended with `ReadFailed`.
    err: ?Error = null,
    /// The packet that ended the band-1 stream (null at end of input).
    end: ?pktline.Pkt = null,
    done: bool = false,
    /// Band-1 bytes of the current packet not yet handed out.
    pending: []const u8 = &.{},
    line_buf: [512]u8 = undefined,
    line_len: usize = 0,
    msg_buf: [1024]u8 = undefined,
    msg_len: usize = 0,
    interface: Reader = undefined,

    pub fn init(pr: *PktReader, mode: Mode) Sideband {
        return .{ .pr = pr, .mode = mode };
    }

    /// Band 1 as a reader with buffer `buf`. `sb` must not move while
    /// the reader is in use.
    pub fn reader(sb: *Sideband, buf: []u8) *Reader {
        sb.interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buf,
            .seek = 0,
            .end = 0,
        };
        return &sb.interface;
    }

    /// The band-3 message, after `err` became `RemoteError`.
    pub fn remoteMessage(sb: *const Sideband) []const u8 {
        return sb.msg_buf[0..sb.msg_len];
    }

    /// The next band-1 payload, handling the other bands on the way; null
    /// when the data ends.
    pub fn nextData(sb: *Sideband) Error!?[]const u8 {
        while (!sb.done) {
            const p = try sb.pr.next() orelse {
                sb.done = true;
                sb.flushLine();
                return null;
            };
            const payload = switch (p) {
                .data => |d| d,
                else => {
                    sb.done = true;
                    sb.end = p;
                    sb.flushLine();
                    return null;
                },
            };
            if (payload.len == 0) return error.BadSideband;
            const body = payload[1..];
            switch (payload[0]) {
                1 => if (body.len > 0) return body,
                2 => sb.progressBytes(body),
                3 => {
                    const m = std.mem.trimEnd(u8, body, "\r\n");
                    sb.msg_len = @min(m.len, sb.msg_buf.len);
                    @memcpy(sb.msg_buf[0..sb.msg_len], m[0..sb.msg_len]);
                    sb.done = true;
                    return error.RemoteError;
                },
                else => return error.BadSideband,
            }
        }
        return null;
    }

    fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const sb: *Sideband = @alignCast(@fieldParentPtr("interface", r));
        if (sb.pending.len == 0) {
            const d = sb.nextData() catch |e| {
                sb.err = e;
                return error.ReadFailed;
            } orelse return error.EndOfStream;
            sb.pending = d;
        }
        const n = try w.write(limit.sliceConst(sb.pending));
        sb.pending = sb.pending[n..];
        return n;
    }

    fn progressBytes(sb: *Sideband, bytes: []const u8) void {
        for (bytes) |c| {
            if (c == '\r' or c == '\n') {
                sb.flushLine();
                continue;
            }
            if (sb.line_len == sb.line_buf.len) sb.flushLine();
            sb.line_buf[sb.line_len] = c;
            sb.line_len += 1;
        }
    }

    fn flushLine(sb: *Sideband) void {
        const line = sb.line_buf[0..sb.line_len];
        sb.line_len = 0;
        if (line.len == 0) return;
        const f = sb.on_progress orelse return;
        f(sb.progress_ctx, if (parseProgress(line)) |p| .{ .progress = p } else .{ .message = line });
    }
};

/// Parses git's progress lines: `Phase: N`, `Phase: N, done.`,
/// `Phase:  P% (N/T)` with optional `, size | rate` and `, done.`
/// suffixes. Null for anything else.
pub fn parseProgress(line: []const u8) ?Progress {
    const colon = std.mem.indexOf(u8, line, ": ") orelse return null;
    const phase = line[0..colon];
    if (phase.len == 0) return null;
    var rest = std.mem.trimStart(u8, line[colon + 2 ..], " ");
    var p: Progress = .{ .phase = phase, .done = 0 };
    if (std.mem.endsWith(u8, rest, ", done.")) {
        p.finished = true;
        rest = rest[0 .. rest.len - ", done.".len];
    }
    if (std.mem.indexOfScalar(u8, rest, '%')) |pct| {
        _ = std.fmt.parseInt(u8, rest[0..pct], 10) catch return null;
        const open = std.mem.indexOfScalarPos(u8, rest, pct, '(') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, rest, open, ')') orelse return null;
        const frac = rest[open + 1 .. close];
        const slash = std.mem.indexOfScalar(u8, frac, '/') orelse return null;
        p.done = std.fmt.parseInt(u64, frac[0..slash], 10) catch return null;
        p.total = std.fmt.parseInt(u64, frac[slash + 1 ..], 10) catch return null;
        return p;
    }
    const end = std.mem.indexOfNone(u8, rest, "0123456789") orelse rest.len;
    if (end == 0) return null;
    // Only "N" or "N, ..." (sizes, rates) after the count.
    if (end != rest.len and !std.mem.startsWith(u8, rest[end..], ", ")) return null;
    p.done = std.fmt.parseInt(u64, rest[0..end], 10) catch return null;
    return p;
}
