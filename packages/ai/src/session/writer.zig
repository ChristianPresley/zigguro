//! `SessionWriter`: appends records to one session file (E10.F08.S01.T01).
//!
//! Records are encoded into a 64 KiB buffer and written after every
//! committed record (positional writes at the tracked end of file);
//! `sync` makes them durable and runs at turn end, on compaction and on
//! close. One writer per file, enforced with an exclusive file lock: a
//! second writer gets `error.SessionLocked` and may fork instead.
//!
//! Before writing, user text and tool output pass through the `Redactor`
//! (E16; identity by default), and images or documents whose base64 is
//! 64 KiB or more move to sidecar files `<id>.blobs/<sha256>` referenced
//! by `Blob.file`. Never call from the UI thread.

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const deps = @import("../loop/deps.zig");
const bus = @import("../loop/bus.zig");
const ev = @import("../loop/events.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Buffer size of the writer.
pub const buffer_size = 64 * 1024;
/// Inline base64 payloads smaller than this; larger ones become sidecars.
pub const blob_threshold = 64 * 1024;

/// Result of one redaction.
pub const Redacted = struct { text: []const u8, count: u32 };

/// Secret redaction applied before writing (E16 `Redactor`). Must be
/// idempotent. The default leaves text unchanged.
pub const Redactor = struct {
    ctx: ?*anyopaque = null,
    redact: ?*const fn (ctx: ?*anyopaque, arena: Allocator, text: []const u8) Allocator.Error!Redacted = null,

    fn apply(r: Redactor, arena: Allocator, text: []const u8, count: *u64) Allocator.Error![]const u8 {
        const f = r.redact orelse return text;
        const out = try f(r.ctx, arena, text);
        count.* += out.count;
        return out.text;
    }
};

pub const SessionWriter = struct {
    gpa: Allocator,
    io: Io,
    file: Io.File,
    /// Absolute path of the `.jsonl` file (owned).
    path: []const u8,
    id: proto.SessionId,
    /// Bytes on disk.
    end: u64,
    buf: std.ArrayList(u8) = .empty,
    mutex: Io.Mutex = .init,
    redactor: Redactor = .{},
    /// Redactions applied so far.
    redactions: u64 = 0,
    last_seq: u64 = 0,
    /// The model of the latest `request_sent` (for usage records).
    model: []const u8 = "",

    /// Opens `path` for appending (created by the store), locked exclusively.
    pub fn open(gpa: Allocator, io: Io, path: []const u8, id: proto.SessionId, create: bool) !*SessionWriter {
        const file = if (create)
            try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .read = true })
        else
            try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);
        if (!try file.tryLock(io, .exclusive)) return error.SessionLocked;
        const w = try gpa.create(SessionWriter);
        errdefer gpa.destroy(w);
        w.* = .{ .gpa = gpa, .io = io, .file = file, .path = try gpa.dupe(u8, path), .id = id, .end = try file.length(io) };
        try w.buf.ensureTotalCapacity(gpa, buffer_size);
        return w;
    }

    /// Flushes, syncs, unlocks and frees the writer.
    pub fn close(w: *SessionWriter) void {
        w.sync() catch {};
        w.file.unlock(w.io);
        w.file.close(w.io);
        w.buf.deinit(w.gpa);
        w.gpa.free(w.path);
        w.gpa.destroy(w);
    }

    /// Appends one record and writes it out.
    pub fn append(w: *SessionWriter, seq: u64, r: records.Record) !void {
        var arena_state: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        const rec = try w.prepare(a, r);
        const now = Io.Timestamp.now(w.io, .real).toMilliseconds();
        const line = try records.encodeAlloc(a, .{ .seq = seq, .t = now, .record = rec });
        try w.buf.appendSlice(w.gpa, line);
        w.last_seq = @max(w.last_seq, seq);
        try w.flushLocked();
    }

    /// Writes buffered bytes and fsyncs (turn end, compaction, exit).
    pub fn sync(w: *SessionWriter) !void {
        w.mutex.lockUncancelable(w.io);
        defer w.mutex.unlock(w.io);
        try w.flushLocked();
        try w.file.sync(w.io);
    }

    fn flushLocked(w: *SessionWriter) !void {
        if (w.buf.items.len == 0) return;
        try w.file.writePositionalAll(w.io, w.buf.items, w.end);
        w.end += w.buf.items.len;
        w.buf.clearRetainingCapacity();
    }

    /// Redacts user text and tool output and moves large blobs to sidecars.
    fn prepare(w: *SessionWriter, a: Allocator, r: records.Record) !records.Record {
        const m = r.message() orelse return r;
        const blocks = try a.dupe(proto.ContentBlock, m.content);
        for (blocks) |*b| switch (b.*) {
            .text => |*t| if (m.role == .user) {
                t.text = try w.redactor.apply(a, t.text, &w.redactions);
            },
            .tool_result => |*tr| {
                const parts = try a.dupe(proto.ResultPart, tr.parts);
                for (parts) |*p| switch (p.*) {
                    .text => |*t| t.* = try w.redactor.apply(a, t.*, &w.redactions),
                    .image => |*im| im.data = try w.sidecar(a, im.data),
                    .document => |*d| d.data = try w.sidecar(a, d.data),
                    else => {},
                };
                tr.parts = parts;
            },
            .image => |*im| im.data = try w.sidecar(a, im.data),
            .document => |*d| d.data = try w.sidecar(a, d.data),
            else => {},
        };
        var copy = m;
        copy.content = blocks;
        return switch (r) {
            .user => .{ .user = copy },
            .assistant => .{ .assistant = copy },
            else => .{ .tool_results = copy },
        };
    }

    /// Writes a large base64 payload to `<id>.blobs/<sha256>` and returns
    /// a `file` blob pointing at it; small or non-base64 blobs are kept.
    fn sidecar(w: *SessionWriter, a: Allocator, blob: proto.Blob) !proto.Blob {
        if (blob != .base64 or blob.base64.len < blob_threshold) return blob;
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(blob.base64) catch return blob;
        const bytes = try a.alloc(u8, n);
        dec.decode(bytes, blob.base64) catch return blob;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const id_text = proto.agent_ref.format(w.id);
        const dir_name = try std.fmt.allocPrint(a, "{s}.blobs", .{&id_text});
        const base = std.fs.path.dirname(w.path) orelse ".";
        const dir_path = try std.fs.path.join(a, &.{ base, dir_name });
        Io.Dir.cwd().createDirPath(w.io, dir_path) catch return blob;
        const file_path = try std.fs.path.join(a, &.{ dir_path, &hex });
        Io.Dir.cwd().access(w.io, file_path, .{}) catch {
            Io.Dir.cwd().writeFile(w.io, .{ .sub_path = file_path, .data = bytes }) catch return blob;
        };
        return .{ .file = file_path };
    }

    /// The agent's `SessionLog` seam: committed messages and turn-end sync.
    pub fn sessionLog(w: *SessionWriter) deps.SessionLog {
        return .{ .ctx = w, .vtable = &.{ .message = logMessage, .sync = logSync, .compaction = logCompaction } };
    }

    fn logCompaction(ctx: *anyopaque, _: Io, _: proto.AgentRef, seq: u64, info: deps.CompactionInfo) anyerror!void {
        const w: *SessionWriter = @ptrCast(@alignCast(ctx));
        try w.append(seq, .{ .compaction = .{ .head_seq = info.head_seq, .trigger = info.trigger, .tokens_before = info.tokens_before, .tokens_after = info.tokens_after, .model = info.model } });
    }

    fn logMessage(ctx: *anyopaque, _: Io, _: proto.AgentRef, seq: u64, m: *const proto.Message) anyerror!void {
        const w: *SessionWriter = @ptrCast(@alignCast(ctx));
        try w.append(seq, records.Record.fromMessage(m.*));
    }

    fn logSync(ctx: *anyopaque, _: Io) anyerror!void {
        const w: *SessionWriter = @ptrCast(@alignCast(ctx));
        try w.sync();
    }

    /// A queued bus subscriber that records usage and the events worth
    /// keeping (errors, budget stops, recoveries) with their bus `seq`, so
    /// stream-json output and session lines correlate.
    pub fn subscriber(w: *SessionWriter) bus.Subscriber {
        return .{ .ctx = w, .on_events = onEvents, .mode = .queued, .coalesce_text = true };
    }

    fn onEvents(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const w: *SessionWriter = @ptrCast(@alignCast(ctx));
        var arena_state: std.heap.ArenaAllocator = .init(w.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        for (batch) |e| {
            const rec: ?records.Record = switch (e.ev) {
                .request_sent => |r| blk: {
                    w.model = r.model;
                    break :blk null;
                },
                .usage => |u| .{ .usage = .{ .model = w.model, .usage = u.last, .cost_micros = u.cost_micros, .estimated = u.estimated } },
                .checkpoint => |c| .{ .checkpoint = .{ .id = c.id, .turn = c.turn, .label = c.label } },
                .error_ => |er| .{ .event = .{ .kind = "error", .data_json = jsonOf(a, er) } },
                .budget => |b| .{ .event = .{ .kind = "budget", .data_json = jsonOf(a, b) } },
                .recovery => |r| .{ .event = .{ .kind = "recovery", .data_json = jsonOf(a, r) } },
                .plan_proposed => |p| .{ .event = .{ .kind = "plan_proposed", .data_json = jsonOf(a, .{ .plan = p }) } },
                .plan_approved => |p| .{ .event = .{ .kind = "plan_approved", .data_json = jsonOf(a, p) } },
                else => null,
            };
            if (rec) |r| w.append(e.seq, r) catch {};
        }
    }
};

fn jsonOf(a: Allocator, v: anytype) []const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    proto.json.encodeValue(&out.writer, v) catch return "";
    return out.written();
}
