//! Session file reader (E10.F08.S01.T01): tail repair, tail-first loading
//! for instant resume, and background streaming of the rest.
//!
//! Tail repair: a last line without `\n`, or one that does not parse, is a
//! torn write; the file is truncated to the last good newline. A dangling
//! `tool_use` (an assistant message with no tool results after it) gets
//! synthesized "interrupted" results in memory only, so the model is told
//! the calls were cut off.
//!
//! Tail-first: the file is read backwards in 64 KiB chunks until the last
//! compaction record or the last `tail_messages` message records, whichever
//! comes first; only those lines and the header are parsed. Corrupt lines
//! in the middle are skipped, so at worst a session opens with fewer
//! records.

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Read chunk size.
pub const chunk_size = 64 * 1024;

/// How much to parse on open.
pub const LoadMode = enum { tail_first, full };

/// Text of synthesized results for calls cut off by a crash.
pub const interrupted_text = "This tool call was interrupted: the session ended before it finished. Verify the current state before running it again.";

/// Receives records streamed by `loadRest`.
pub const RecordSink = struct {
    ctx: *anyopaque,
    on_line: *const fn (ctx: *anyopaque, line: records.Line) void,
};

pub const Options = struct {
    mode: LoadMode = .tail_first,
    /// Message records to load in tail-first mode.
    tail_messages: u32 = 50,
    /// Truncate a torn tail (needs write access; skip when another
    /// process holds the writer lock).
    repair: bool = true,
};

pub const LoadedSession = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    header: records.Header,
    /// Loaded lines in file order: the tail (tail-first) or every line (full).
    tail: []const records.Line,
    /// Synthesized results for a dangling tool_use, never written to disk.
    interrupted: ?proto.Message = null,
    /// Byte offset of the first line after the header.
    body_start: u64,
    /// Byte offset of the first tail line (`loadRest` reads up to it).
    tail_start: u64,
    /// Bytes cut off by tail repair.
    repaired_bytes: u64 = 0,
    /// Lines that failed to parse and were skipped.
    skipped_lines: u32 = 0,
    /// Bytes read so far (tests assert tail-first reads little).
    bytes_read: u64 = 0,

    pub fn deinit(l: *LoadedSession) void {
        const gpa = l.gpa;
        l.arena.deinit();
        gpa.destroy(l);
    }

    /// Streams the records before the tail, in file order, to `sink`
    /// (run on a worker; slices live in a temporary arena per chunk).
    pub fn loadRest(l: *LoadedSession, io: Io, sink: RecordSink) !void {
        const f = try Io.Dir.cwd().openFile(io, l.path, .{});
        defer f.close(io);
        var tmp: std.heap.ArenaAllocator = .init(l.gpa);
        defer tmp.deinit();
        var it: Forward = .{ .file = f, .pos = l.body_start, .end = l.tail_start, .gpa = l.gpa };
        defer it.deinit();
        while (try it.next(io)) |text| {
            _ = tmp.reset(.retain_capacity);
            const line = records.decode(tmp.allocator(), text) catch continue;
            sink.on_line(sink.ctx, line);
        }
        l.bytes_read += it.read;
    }

    /// Message records of the tail, plus the synthesized interrupted results.
    pub fn messages(l: *const LoadedSession, gpa: Allocator) Allocator.Error![]proto.Message {
        var out: std.ArrayList(proto.Message) = .empty;
        for (l.tail) |line| if (line.record.message()) |m| try out.append(gpa, m);
        if (l.interrupted) |m| try out.append(gpa, m);
        return out.toOwnedSlice(gpa);
    }
};

/// Opens and loads a session file.
pub fn open(gpa: Allocator, io: Io, path: []const u8, opts: Options) !*LoadedSession {
    const l = try gpa.create(LoadedSession);
    errdefer gpa.destroy(l);
    l.* = .{ .gpa = gpa, .arena = .init(gpa), .path = "", .header = undefined, .tail = &.{}, .body_start = 0, .tail_start = 0 };
    errdefer l.arena.deinit();
    const a = l.arena.allocator();
    l.path = try a.dupe(u8, path);

    const f = if (opts.repair)
        Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch try Io.Dir.cwd().openFile(io, path, .{})
    else
        try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var size = try f.length(io);

    // Header: the first line.
    var hbuf: std.ArrayList(u8) = .empty;
    defer hbuf.deinit(gpa);
    var off: u64 = 0;
    const header_end: u64 = while (off < size) {
        const want: usize = @intCast(@min(chunk_size, size - off));
        try hbuf.ensureUnusedCapacity(gpa, want);
        const n = try f.readPositionalAll(io, hbuf.unusedCapacitySlice()[0..want], off);
        l.bytes_read += n;
        const before = hbuf.items.len;
        hbuf.items.len += n;
        off += n;
        if (std.mem.indexOfScalarPos(u8, hbuf.items, before, '\n')) |i| break i + 1;
        if (n == 0) return error.InvalidSession;
    } else return error.InvalidSession;
    const hline = records.decode(a, hbuf.items[0 .. header_end - 1]) catch return error.InvalidSession;
    if (hline.record != .header) return error.InvalidSession;
    l.header = hline.record.header;
    l.body_start = header_end;

    // Tail repair.
    if (opts.repair) {
        const good = try lastGoodEnd(gpa, io, f, header_end, size, &l.bytes_read);
        if (good < size) {
            f.setLength(io, good) catch {};
            l.repaired_bytes = size - good;
            size = good;
        }
    }

    var lines: std.ArrayList(records.Line) = .empty;
    switch (opts.mode) {
        .full => {
            var it: Forward = .{ .file = f, .pos = header_end, .end = size, .gpa = gpa };
            defer it.deinit();
            while (try it.next(io)) |text| {
                const line = records.decode(a, text) catch {
                    l.skipped_lines += 1;
                    continue;
                };
                try lines.append(a, line);
            }
            l.bytes_read += it.read;
            l.tail_start = header_end;
        },
        .tail_first => {
            var it: Backward = .{ .file = f, .floor = header_end, .pos = size, .gpa = gpa };
            defer it.deinit();
            var msgs: u32 = 0;
            l.tail_start = size;
            while (try it.next(io)) |item| {
                const line = records.decode(a, item.text) catch {
                    l.skipped_lines += 1;
                    l.tail_start = item.start;
                    continue;
                };
                try lines.append(a, line);
                l.tail_start = item.start;
                if (line.record.message() != null) msgs += 1;
                if (line.record == .compaction or msgs >= opts.tail_messages) break;
            }
            l.bytes_read += it.read;
            std.mem.reverse(records.Line, lines.items);
        },
    }
    l.tail = lines.items;
    l.interrupted = try interruptedResults(a, l.tail);
    return l;
}

/// The end offset of the last complete, parseable line.
fn lastGoodEnd(gpa: Allocator, io: Io, f: Io.File, floor: u64, size: u64, read: *u64) !u64 {
    if (size <= floor) return floor;
    var it: Backward = .{ .file = f, .floor = floor, .pos = size, .gpa = gpa, .keep_partial = true };
    defer it.deinit();
    defer read.* += it.read;
    var tmp: std.heap.ArenaAllocator = .init(gpa);
    defer tmp.deinit();
    var end = size;
    while (try it.next(io)) |item| {
        // A line without its newline, or one that fails to parse, is torn.
        if (item.partial or !parses(tmp.allocator(), item.text)) {
            end = item.start;
            continue;
        }
        return end;
    }
    return floor;
}

fn parses(a: Allocator, text: []const u8) bool {
    _ = records.decode(a, text) catch return false;
    return true;
}

/// Synthesized `is_error` results for the tool calls of the last assistant
/// message when no tool results follow it.
pub fn interruptedResults(a: Allocator, tail: []const records.Line) Allocator.Error!?proto.Message {
    var i = tail.len;
    while (i > 0) {
        i -= 1;
        switch (tail[i].record) {
            .tool_results, .user => return null,
            .assistant => |m| {
                var blocks: std.ArrayList(proto.ContentBlock) = .empty;
                const parts = try a.alloc(proto.ResultPart, 1);
                parts[0] = .{ .text = interrupted_text };
                for (m.content) |b| if (b == .tool_use and !b.tool_use.server)
                    try blocks.append(a, .{ .tool_result = .{ .tool_use_id = b.tool_use.id, .parts = parts, .is_error = true } });
                if (blocks.items.len == 0) return null;
                return .{ .role = .user, .content = blocks.items, .meta = .{ .synthetic = true, .interrupted = true } };
            },
            else => {},
        }
    }
    return null;
}

/// Reads lines forward from `pos` to `end` in chunks (also used by
/// session search).
pub const Forward = struct {
    file: Io.File,
    pos: u64,
    end: u64,
    gpa: Allocator,
    buf: std.ArrayList(u8) = .empty,
    start: usize = 0,
    read: u64 = 0,

    pub fn deinit(it: *Forward) void {
        it.buf.deinit(it.gpa);
    }

    /// The next line (without `\n`); valid until the next call.
    pub fn next(it: *Forward, io: Io) !?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalarPos(u8, it.buf.items, it.start, '\n')) |nl| {
                const line = it.buf.items[it.start..nl];
                it.start = nl + 1;
                return line;
            }
            if (it.pos >= it.end) {
                if (it.start < it.buf.items.len) {
                    const line = it.buf.items[it.start..];
                    it.start = it.buf.items.len;
                    return line;
                }
                return null;
            }
            // Drop consumed bytes, then read the next chunk.
            const rest = it.buf.items.len - it.start;
            std.mem.copyForwards(u8, it.buf.items[0..rest], it.buf.items[it.start..]);
            it.buf.items.len = rest;
            it.start = 0;
            const want: usize = @intCast(@min(chunk_size, it.end - it.pos));
            try it.buf.ensureUnusedCapacity(it.gpa, want);
            const n = try it.file.readPositionalAll(io, it.buf.unusedCapacitySlice()[0..want], it.pos);
            if (n == 0) it.pos = it.end;
            it.buf.items.len += n;
            it.pos += n;
            it.read += n;
        }
    }
};

/// Reads lines backwards from `pos` down to `floor` (a line start).
const Backward = struct {
    file: Io.File,
    floor: u64,
    pos: u64,
    gpa: Allocator,
    /// Report a final line without `\n` (as `partial`) instead of skipping it.
    keep_partial: bool = false,
    /// Bytes `[pos, pos + buf.len)` of the file not yet returned.
    buf: std.ArrayList(u8) = .empty,
    first: bool = true,
    read: u64 = 0,
    /// The last returned line (owned; freed on the next call).
    pending: ?[]u8 = null,

    const Item = struct { text: []const u8, start: u64, partial: bool };

    fn deinit(it: *Backward) void {
        if (it.pending) |p| it.gpa.free(p);
        it.buf.deinit(it.gpa);
    }

    fn next(it: *Backward, io: Io) !?Item {
        while (true) {
            if (it.first) {
                // The bytes after the last `\n` are a torn line.
                it.first = false;
                try it.fill(io);
                while (std.mem.lastIndexOfScalar(u8, it.buf.items, '\n') == null and it.pos > it.floor) try it.fill(io);
                const nl = std.mem.lastIndexOfScalar(u8, it.buf.items, '\n');
                const cut = if (nl) |i| i + 1 else 0;
                if (cut < it.buf.items.len) {
                    const start = it.pos + cut;
                    const text = try it.gpa.dupe(u8, it.buf.items[cut..]);
                    it.buf.items.len = cut;
                    if (it.keep_partial) {
                        it.pending = text;
                        return .{ .text = text, .start = start, .partial = true };
                    }
                    it.gpa.free(text);
                }
                continue;
            }
            if (it.pending) |p| {
                it.gpa.free(p);
                it.pending = null;
            }
            if (it.buf.items.len == 0) {
                if (it.pos <= it.floor) return null;
                try it.fill(io);
                continue;
            }
            // buf ends with '\n'; find the start of that line.
            const body = it.buf.items[0 .. it.buf.items.len - 1];
            if (std.mem.lastIndexOfScalar(u8, body, '\n')) |i| {
                const start = it.pos + i + 1;
                const text = try it.gpa.dupe(u8, body[i + 1 ..]);
                it.buf.items.len = i + 1;
                it.pending = text;
                return .{ .text = text, .start = start, .partial = false };
            }
            if (it.pos > it.floor) {
                try it.fill(io);
                continue;
            }
            const text = try it.gpa.dupe(u8, body);
            const start = it.pos;
            it.buf.items.len = 0;
            it.pending = text;
            return .{ .text = text, .start = start, .partial = false };
        }
    }

    /// Prepends the previous chunk to `buf`.
    fn fill(it: *Backward, io: Io) !void {
        if (it.pos <= it.floor) return;
        const want: usize = @intCast(@min(chunk_size, it.pos - it.floor));
        const old = it.buf.items.len;
        try it.buf.resize(it.gpa, old + want);
        std.mem.copyBackwards(u8, it.buf.items[want..], it.buf.items[0..old]);
        it.pos -= want;
        const n = try it.file.readPositionalAll(io, it.buf.items[0..want], it.pos);
        if (n != want) return error.ShortRead;
        it.read += want;
    }
};
