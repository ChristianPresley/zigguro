//! ChangesetStore (E12.F01.S02.T01): the review state of a workspace under
//! `.zigguro/review/`, shared by every process working on it (the GUI,
//! `zg review`).
//!
//! - `journal/<8 digits>.zrj`: append-only segments of CRC-framed records
//!   (`journal.zig`). The queue's state is the fold of the journal: the
//!   last snapshot of each changeset, minus removed ones. Each frame's
//!   payload is `{"p":<process>,"s":<seq>,"r":<record>}`; a `(p, s)` seen
//!   twice is ignored.
//! - `blobs/`: contents (`blobs.zig`), always written before the frames
//!   that reference them.
//! - `lock`: an advisory exclusive lock held while appending, recovering
//!   or rolling segments.
//!
//! `append` (owner thread) only frames the record in memory. `flush`
//! (any thread, normally the store's worker) writes the new blobs, then
//! the frames, syncs and releases the lock: the records are durable when
//! it returns.
//!
//! Recovery at load: a torn or corrupt frame at the end of the last
//! segment is cut off (a crash during an append). One in an earlier
//! segment means corruption: that segment is renamed to `.bad` and the
//! rest still loads. `tail` reads what other processes appended since.

const std = @import("std");
const model = @import("../model/root.zig");
const journal = @import("journal.zig");
const records = @import("records.zig");
const DiskBlobs = @import("blobs.zig").DiskBlobs;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.zg_review);

pub const Options = struct {
    /// Segments roll over at this size.
    segment_bytes: u32 = 8 << 20,
    /// Identifies this process's records; 0 picks a random one.
    process_tag: u32 = 0,
};

pub const LoadReport = struct {
    records: u32 = 0,
    /// Bytes cut off the last segment.
    truncated_bytes: u64 = 0,
    /// Segments renamed to `.bad`.
    quarantined: u32 = 0,
};

/// Receives the records of a load or tail, on the caller's thread.
pub const Sink = struct {
    ctx: *anyopaque,
    on: *const fn (ctx: *anyopaque, kind: journal.Kind, record: std.json.Value) anyerror!void,
};

pub const ChangesetStore = struct {
    gpa: Allocator,
    io: Io,
    /// The review directory.
    dir: Io.Dir,
    opts: Options,
    blobs_: DiskBlobs,
    mutex: Io.Mutex = .init,
    /// Frames not yet written.
    pending: std.ArrayList(u8) = .empty,
    seq: u64 = 0,
    /// Read position in each segment seen (by segment number).
    read_pos: std.AutoArrayHashMapUnmanaged(u32, u64) = .empty,
    /// Highest sequence number seen per process.
    seen: std.AutoHashMapUnmanaged(u32, u64) = .empty,

    /// Opens (creating) the store at `sub_path` of `parent`.
    pub fn open(gpa: Allocator, io: Io, parent: Io.Dir, sub_path: []const u8, o: Options) !*ChangesetStore {
        var dir = try parent.createDirPathOpen(io, sub_path, .{});
        errdefer dir.close(io);
        try dir.createDirPath(io, "journal");
        try dir.createDirPath(io, "blobs");
        const s = try gpa.create(ChangesetStore);
        var opts = o;
        while (opts.process_tag == 0) {
            var b: [4]u8 = undefined;
            io.random(&b);
            opts.process_tag = std.mem.readInt(u32, &b, .little);
        }
        s.* = .{ .gpa = gpa, .io = io, .dir = dir, .opts = opts, .blobs_ = .{ .gpa = gpa, .io = io, .dir = dir } };
        return s;
    }

    /// Writes what is pending (errors are logged) and closes.
    pub fn close(s: *ChangesetStore) void {
        s.flush() catch |e| log.err("review store: final flush failed: {t}", .{e});
        s.blobs_.deinit();
        s.pending.deinit(s.gpa);
        s.read_pos.deinit(s.gpa);
        s.seen.deinit(s.gpa);
        s.dir.close(s.io);
        s.gpa.destroy(s);
    }

    pub fn blobs(s: *ChangesetStore) model.Blobs {
        return s.blobs_.blobs();
    }

    pub fn processTag(s: *const ChangesetStore) u32 {
        return s.opts.process_tag;
    }

    /// The queue's journal port.
    pub fn journalPort(s: *ChangesetStore) model.Journal {
        return .{ .ctx = s, .changeset = jChangeset, .removed = jRemoved };
    }

    fn jChangeset(ctx: *anyopaque, cs: *const model.Changeset) void {
        const s: *ChangesetStore = @ptrCast(@alignCast(ctx));
        var aw: std.Io.Writer.Allocating = .init(s.gpa);
        defer aw.deinit();
        records.writeChangeset(&aw.writer, cs, s.blobs(), s.gpa) catch |e| {
            log.err("review store: changeset {f} not recorded: {t}", .{ cs.id, e });
            return;
        };
        s.append(.changeset, aw.written()) catch |e| log.err("review store: changeset {f} not recorded: {t}", .{ cs.id, e });
    }

    /// The history's recorder port.
    pub fn recorder(s: *ChangesetStore) model.Recorder {
        return .{ .ctx = s, .apply = jApply };
    }

    /// The checkpoints' recorder port; thread-safe.
    pub fn checkpointRecorder(s: *ChangesetStore) model.CheckpointRecorder {
        return .{ .ctx = s, .checkpoint = jCheckpoint };
    }

    fn jCheckpoint(ctx: *anyopaque, c: *const model.Checkpoint) void {
        const s: *ChangesetStore = @ptrCast(@alignCast(ctx));
        var aw: std.Io.Writer.Allocating = .init(s.gpa);
        defer aw.deinit();
        records.writeCheckpoint(&aw.writer, c) catch |e| {
            log.err("review store: checkpoint {d} not recorded: {t}", .{ c.id, e });
            return;
        };
        s.append(.checkpoint, aw.written()) catch |e| log.err("review store: checkpoint {d} not recorded: {t}", .{ c.id, e });
    }

    fn jApply(ctx: *anyopaque, a: *const model.Apply) void {
        const s: *ChangesetStore = @ptrCast(@alignCast(ctx));
        var aw: std.Io.Writer.Allocating = .init(s.gpa);
        defer aw.deinit();
        records.writeApply(&aw.writer, a) catch |e| {
            log.err("review store: apply {d} not recorded: {t}", .{ a.id, e });
            return;
        };
        s.append(.apply, aw.written()) catch |e| log.err("review store: apply {d} not recorded: {t}", .{ a.id, e });
    }

    fn jRemoved(ctx: *anyopaque, id: model.ChangesetId) void {
        const s: *ChangesetStore = @ptrCast(@alignCast(ctx));
        var buf: [40]u8 = undefined;
        const body = std.fmt.bufPrint(&buf, "{{\"id\":{d}}}", .{@intFromEnum(id)}) catch unreachable;
        s.append(.remove, body) catch |e| log.err("review store: removal of {f} not recorded: {t}", .{ id, e });
    }

    /// Frames `record` (JSON) for the next flush.
    pub fn append(s: *ChangesetStore, kind: journal.Kind, record: []const u8) Allocator.Error!void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.seq += 1;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(s.gpa);
        try body.print(s.gpa, "{{\"p\":{d},\"s\":{d},\"r\":", .{ s.opts.process_tag, s.seq });
        try body.appendSlice(s.gpa, record);
        try body.append(s.gpa, '}');
        try journal.encode(s.gpa, &s.pending, kind, body.items);
    }

    /// Makes everything appended so far durable: blobs first, then the
    /// frames, under the lock.
    pub fn flush(s: *ChangesetStore) !void {
        try s.blobs_.flush();
        s.mutex.lockUncancelable(s.io);
        var frames = s.pending;
        s.pending = .empty;
        s.mutex.unlock(s.io);
        defer frames.deinit(s.gpa);
        if (frames.items.len == 0) return;
        errdefer {
            // Keep them for the next attempt, ahead of newer frames.
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            s.pending.insertSlice(s.gpa, 0, frames.items) catch {};
        }
        var lock = try s.lockFile();
        defer lock.close(s.io);
        var seg = try s.lastSegment();
        var name = segName(seg);
        var f = try s.dir.createFile(s.io, &name, .{ .truncate = false, .read = true });
        var len = try f.length(s.io);
        if (len > 0 and len + frames.items.len > s.opts.segment_bytes) {
            f.close(s.io);
            seg += 1;
            name = segName(seg);
            f = try s.dir.createFile(s.io, &name, .{ .truncate = false, .read = true });
            len = try f.length(s.io);
        }
        defer f.close(s.io);
        try f.writePositionalAll(s.io, frames.items, len);
        try f.sync(s.io);
    }

    fn lockFile(s: *ChangesetStore) !Io.File {
        return s.dir.createFile(s.io, "lock", .{ .truncate = false, .lock = .exclusive });
    }

    fn segName(n: u32) [8 + 8 + 4]u8 {
        var out: [20]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "journal/{d:0>8}.zrj", .{n}) catch unreachable;
        return out;
    }

    /// Segment numbers in order.
    fn segments(s: *ChangesetStore, out: *std.ArrayList(u32)) !void {
        var jd = try s.dir.openDir(s.io, "journal", .{ .iterate = true });
        defer jd.close(s.io);
        var it = jd.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".zrj") or e.name.len != 12) continue;
            const n = std.fmt.parseInt(u32, e.name[0..8], 10) catch continue;
            try out.append(s.gpa, n);
        }
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    }

    fn lastSegment(s: *ChangesetStore) !u32 {
        var segs: std.ArrayList(u32) = .empty;
        defer segs.deinit(s.gpa);
        try s.segments(&segs);
        return if (segs.items.len == 0) 1 else segs.items[segs.items.len - 1];
    }

    /// Replays the whole journal into `sink`, repairing it as described in
    /// the file comment. Call once, before `tail`.
    pub fn load(s: *ChangesetStore, sink: Sink) !LoadReport {
        var rep: LoadReport = .{};
        var lock = try s.lockFile();
        defer lock.close(s.io);
        var segs: std.ArrayList(u32) = .empty;
        defer segs.deinit(s.gpa);
        try s.segments(&segs);
        for (segs.items, 0..) |n, i| {
            const last = i + 1 == segs.items.len;
            const name = segName(n);
            const bytes = try s.dir.readFileAlloc(s.io, &name, s.gpa, .unlimited);
            defer s.gpa.free(bytes);
            var r: journal.Reader = .{ .bytes = bytes };
            const stop = try s.replay(&r, sink, &rep.records, false);
            if (stop == .end) {
                try s.read_pos.put(s.gpa, n, r.pos);
                continue;
            }
            if (last) {
                log.warn("review store: cutting {d} bytes off {s} ({s})", .{ bytes.len - r.pos, &name, @tagName(stop) });
                var f = try s.dir.openFile(s.io, &name, .{ .mode = .read_write });
                defer f.close(s.io);
                try f.setLength(s.io, r.pos);
                try f.sync(s.io);
                rep.truncated_bytes += bytes.len - r.pos;
                try s.read_pos.put(s.gpa, n, r.pos);
            } else {
                log.warn("review store: {s} is corrupt at byte {d}; renamed to .bad", .{ &name, r.pos });
                var bad: [24]u8 = undefined;
                const bad_name = std.fmt.bufPrint(&bad, "{s}.bad", .{&name}) catch unreachable;
                try s.dir.rename(&name, s.dir, bad_name, s.io);
                rep.quarantined += 1;
            }
        }
        return rep;
    }

    /// Feeds the records other processes appended since the last load or
    /// tail. Frames still being written are left for the next call.
    pub fn tail(s: *ChangesetStore, sink: Sink) !u32 {
        var n_records: u32 = 0;
        var segs: std.ArrayList(u32) = .empty;
        defer segs.deinit(s.gpa);
        try s.segments(&segs);
        for (segs.items) |n| {
            const from = s.read_pos.get(n) orelse 0;
            const name = segName(n);
            var f = s.dir.openFile(s.io, &name, .{}) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            defer f.close(s.io);
            const len = try f.length(s.io);
            if (len <= from) continue;
            const bytes = try s.gpa.alloc(u8, @intCast(len - from));
            defer s.gpa.free(bytes);
            const got = try f.readPositionalAll(s.io, bytes, from);
            var r: journal.Reader = .{ .bytes = bytes[0..got] };
            _ = try s.replay(&r, sink, &n_records, true);
            try s.read_pos.put(s.gpa, n, from + r.pos);
        }
        return n_records;
    }

    fn replay(s: *ChangesetStore, r: *journal.Reader, sink: Sink, count: *u32, skip_own: bool) !journal.Next {
        while (true) {
            const nx = r.next();
            const fr = switch (nx) {
                .frame => |f| f,
                else => return nx,
            };
            var arena: std.heap.ArenaAllocator = .init(s.gpa);
            defer arena.deinit();
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), fr.payload, .{}) catch {
                log.warn("review store: skipping an unreadable record", .{});
                continue;
            };
            if (v != .object) continue;
            const p = intOf(u32, v.object.get("p")) orelse continue;
            const sq = intOf(u64, v.object.get("s")) orelse continue;
            const gop = try s.seen.getOrPut(s.gpa, p);
            if (gop.found_existing and sq <= gop.value_ptr.*) continue;
            gop.value_ptr.* = sq;
            if (p == s.opts.process_tag) {
                s.seq = @max(s.seq, sq);
                if (skip_own) continue;
            }
            const rec = v.object.get("r") orelse continue;
            sink.on(sink.ctx, fr.kind, rec) catch |e| {
                log.warn("review store: record skipped: {t}", .{e});
                continue;
            };
            count.* += 1;
        }
    }

    // ------------------------------------------------- queue binding

    /// A sink that restores into `q` (load and tail), apply records into
    /// `history` and checkpoints into `checkpoints` when given.
    pub fn queueSink(s: *ChangesetStore, q: *model.Queue, history: ?*model.History, checkpoints: ?model.CheckpointSink) QueueSink {
        return .{ .store = s, .q = q, .history = history, .checkpoints = checkpoints };
    }
};

pub const QueueSink = struct {
    store: *ChangesetStore,
    q: *model.Queue,
    history: ?*model.History = null,
    checkpoints: ?model.CheckpointSink = null,

    pub fn sink(qs: *QueueSink) Sink {
        return .{ .ctx = qs, .on = on };
    }

    fn on(ctx: *anyopaque, kind: journal.Kind, rec: std.json.Value) anyerror!void {
        const qs: *QueueSink = @ptrCast(@alignCast(ctx));
        switch (kind) {
            .changeset => {
                const cs = try records.readChangeset(qs.q.gpa, rec, qs.store.blobs());
                qs.q.restore(cs) catch |e| {
                    cs.deinit(qs.q.gpa);
                    qs.q.gpa.destroy(cs);
                    return e;
                };
            },
            .remove => {
                const id = intOf(u64, if (rec == .object) rec.object.get("id") else null) orelse return error.InvalidRecord;
                qs.q.restoreRemoved(@enumFromInt(id));
            },
            .checkpoint => if (qs.checkpoints) |c| {
                var arena: std.heap.ArenaAllocator = .init(qs.q.gpa);
                defer arena.deinit();
                const cp = try records.readCheckpoint(arena.allocator(), rec);
                try c.restore(c.ctx, &cp);
            },
            .apply => if (qs.history) |h| {
                var arena: std.heap.ArenaAllocator = .init(qs.q.gpa);
                defer arena.deinit();
                try h.restore(try records.readApply(arena.allocator(), rec));
            },
            else => {},
        }
    }
};

fn intOf(comptime T: type, v: ?std.json.Value) ?T {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| std.math.cast(T, i),
        else => null,
    };
}
