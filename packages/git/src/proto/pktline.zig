//! pkt-line framing (gitprotocol-common): every packet starts with its
//! length as 4 hex digits, counting the 4 digits themselves. `0000` is a
//! flush, `0001` a delimiter and `0002` a response end (protocol v2);
//! anything from `0004` on carries `len - 4` payload bytes, at most 65516.
//!
//! `PktReader` hands out payloads as slices of the underlying reader's
//! buffer (no copies, no allocation); a slice is valid until the next
//! call. `PktWriter` sends lowercase lengths and never sends an empty data
//! packet.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// The largest payload of one packet.
pub const max_payload = 65516;
/// The largest packet, length prefix included.
pub const max_pkt = max_payload + 4;

pub const Pkt = union(enum) {
    data: []const u8,
    flush,
    delim,
    response_end,
};

pub const ReadError = error{
    /// A length prefix that is not 4 hex digits, or is 3 (reserved).
    InvalidPktLength,
    PktTooLong,
    /// The stream ended inside a packet.
    TruncatedPkt,
    ReadFailed,
};

pub const PktReader = struct {
    r: *Reader,
    /// Payload bytes handed out by the last call, consumed by the next.
    pending: usize = 0,

    /// The reader's buffer must hold a whole packet.
    pub fn init(r: *Reader) PktReader {
        std.debug.assert(r.buffer.len >= max_pkt);
        return .{ .r = r };
    }

    /// The next packet, or null at the end of the stream (between
    /// packets).
    pub fn next(pr: *PktReader) ReadError!?Pkt {
        pr.r.toss(pr.pending);
        pr.pending = 0;
        pr.r.fill(4) catch |e| switch (e) {
            error.EndOfStream => {
                if (pr.r.bufferedLen() == 0) return null;
                return error.TruncatedPkt;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        const hdr = pr.r.buffered()[0..4];
        const len = try parseLength(hdr[0..4].*);
        switch (len) {
            0 => {
                pr.r.toss(4);
                return .flush;
            },
            1 => {
                pr.r.toss(4);
                return .delim;
            },
            2 => {
                pr.r.toss(4);
                return .response_end;
            },
            3 => return error.InvalidPktLength,
            else => {},
        }
        if (len > max_pkt) return error.PktTooLong;
        pr.r.fill(len) catch |e| switch (e) {
            error.EndOfStream => return error.TruncatedPkt,
            error.ReadFailed => return error.ReadFailed,
        };
        const payload = pr.r.buffered()[4..len];
        pr.r.toss(4);
        pr.pending = len - 4;
        return .{ .data = payload };
    }

    /// The next data packet as a line, without one trailing LF; null at a
    /// flush. A delimiter or response end is `UnexpectedPkt`, and the end
    /// of the stream `UnexpectedEof`.
    pub fn nextLine(pr: *PktReader) (ReadError || error{ UnexpectedPkt, UnexpectedEof })!?[]const u8 {
        const p = try pr.next() orelse return error.UnexpectedEof;
        return switch (p) {
            .data => |d| trimLf(d),
            .flush => null,
            .delim, .response_end => error.UnexpectedPkt,
        };
    }
};

/// `line` without one trailing LF.
pub fn trimLf(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\n') line[0 .. line.len - 1] else line;
}

/// Decodes a 4-digit hex length (either case).
pub fn parseLength(hdr: [4]u8) error{InvalidPktLength}!usize {
    var v: usize = 0;
    for (hdr) |c| {
        const d: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidPktLength,
        };
        v = v * 16 + d;
    }
    return v;
}

pub const PktWriter = struct {
    w: *Writer,

    pub fn init(w: *Writer) PktWriter {
        return .{ .w = w };
    }

    /// One data packet. Empty payloads are not sent (git never sends
    /// `0004`).
    pub fn data(pw: PktWriter, bytes: []const u8) (Writer.Error || error{PktTooLong})!void {
        if (bytes.len == 0) return;
        if (bytes.len > max_payload) return error.PktTooLong;
        try writeLength(pw.w, bytes.len + 4);
        try pw.w.writeAll(bytes);
    }

    /// `bytes` split into as many data packets as needed.
    pub fn dataChunked(pw: PktWriter, bytes: []const u8) Writer.Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, max_payload);
            pw.data(rest[0..n]) catch |e| switch (e) {
                error.PktTooLong => unreachable,
                else => |x| return x,
            };
            rest = rest[n..];
        }
    }

    /// A formatted line, LF added.
    pub fn line(pw: PktWriter, comptime fmt: []const u8, args: anytype) (Writer.Error || error{PktTooLong})!void {
        const n = std.fmt.count(fmt ++ "\n", args);
        if (n == 0) return;
        if (n > max_payload) return error.PktTooLong;
        try writeLength(pw.w, @intCast(n + 4));
        try pw.w.print(fmt ++ "\n", args);
    }

    /// `bytes` on sideband `band` (1 data, 2 progress, 3 error), split so
    /// every packet fits `max` total bytes (65520 for side-band-64k, 1000
    /// for side-band).
    pub fn band(pw: PktWriter, b: u8, bytes: []const u8, max: usize) Writer.Error!void {
        std.debug.assert(max > 5 and max <= max_pkt);
        var rest = bytes;
        while (true) {
            const n = @min(rest.len, max - 5);
            try writeLength(pw.w, n + 5);
            try pw.w.writeByte(b);
            try pw.w.writeAll(rest[0..n]);
            rest = rest[n..];
            if (rest.len == 0) return;
        }
    }

    /// A flush packet (`0000`). Does not flush the underlying writer.
    pub fn flush(pw: PktWriter) Writer.Error!void {
        try pw.w.writeAll("0000");
    }

    pub fn delim(pw: PktWriter) Writer.Error!void {
        try pw.w.writeAll("0001");
    }

    pub fn responseEnd(pw: PktWriter) Writer.Error!void {
        try pw.w.writeAll("0002");
    }
};

fn writeLength(w: *Writer, len: usize) Writer.Error!void {
    const digits = "0123456789abcdef";
    var hdr: [4]u8 = undefined;
    var v = len;
    var i: usize = 4;
    while (i > 0) {
        i -= 1;
        hdr[i] = digits[v & 15];
        v >>= 4;
    }
    try w.writeAll(&hdr);
}
