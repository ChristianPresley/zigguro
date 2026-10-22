//! The tamper-evident audit log (E16.F02.S02.T01, INV-12). Every tool
//! decision, approval answer, policy change and sandbox violation becomes
//! one JSON line in `<state>/audit/<YYYYMMDD-HHMMSS>-<seq>.jsonl`. Each line
//! carries `prev` (the previous record's hash) and `hash =
//! Blake3(prev || line-without-hash)`, so editing, deleting or reordering a
//! record breaks the chain at that exact line.
//!
//! - Appends never block on disk: the caller encodes and chains the record
//!   under a short lock and the bytes wait in memory; a flusher task writes
//!   and fsyncs every `flush_interval_ms` or `flush_records` records.
//! - Raw tool inputs are never stored: only their hash and a redacted
//!   summary of at most 512 bytes (INV-07).
//! - Segments rotate at `segment_bytes`; each starts with a
//!   `segment_start` record so verification spans rotation.
//! - Pruning deletes whole old segments and appends a `retention_pruned`
//!   record naming the last pruned hash, which is how `verify` accepts the
//!   gap explicitly.
//! - When the in-memory backlog is full, `tool_result` records are dropped
//!   first (never decisions) and the next record says how many.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts.zig");
const AuditRecord = @import("record.zig").AuditRecord;

const Blake3 = std.crypto.hash.Blake3;

/// Most bytes kept for a redacted text field.
pub const max_text = 512;
/// Backlog above which result records are dropped.
pub const max_pending_bytes = 4 << 20;

/// The log.
pub const AuditLog = struct {
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    opts: Options,
    mutex: std.Io.Mutex = .init,
    /// Encoded lines not yet on disk.
    pending: std.ArrayList(u8) = .empty,
    pending_records: u32 = 0,
    /// Offsets in `pending` where a new segment starts, with its name.
    boundaries: std.ArrayList(Boundary) = .empty,
    seq: u64 = 0,
    last_hash: [32]u8 = @splat(0),
    segment_bytes: u64 = 0,
    dropped: u64 = 0,
    file: ?std.Io.File = null,
    file_off: u64 = 0,
    flush_mutex: std.Io.Mutex = .init,
    wake: std.Io.Event = .unset,
    flusher: ?std.Io.Future(std.Io.Cancelable!void) = null,
    write_error: ?anyerror = null,

    const Boundary = struct { at: usize, name: [64]u8, name_len: u8 };

    /// Tuning.
    pub const Options = struct {
        segment_bytes: u32 = 8 << 20,
        flush_interval_ms: u32 = 250,
        flush_records: u16 = 64,
        retention_days: u16 = 90,
        redactor: ?contracts.Redactor = null,
        /// Start the background flusher (tests may flush by hand).
        background: bool = true,
    };

    /// Opens the log in `dir` (`<state>/audit/`, already created with
    /// private permissions by E16.F07). Continues the chain of existing
    /// segments in a new segment.
    pub fn open(gpa: Allocator, io: std.Io, dir: std.Io.Dir, opts: Options) !*AuditLog {
        const self = try gpa.create(AuditLog);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .dir = dir, .opts = opts };
        // Continue from the newest existing record.
        if (try lastRecord(gpa, io, dir)) |last| {
            self.seq = last.seq;
            self.last_hash = last.hash;
        }
        self.mutex.lockUncancelable(io);
        try self.startSegmentLocked();
        self.mutex.unlock(io);
        if (opts.background) {
            self.flusher = io.concurrent(flusherLoop, .{self}) catch null;
        }
        return self;
    }

    /// The sink interface; `append` never blocks on I/O.
    pub fn sink(self: *AuditLog) contracts.AuditSink {
        return .{ .ctx = self, .append = appendFn };
    }

    fn appendFn(ctx: *anyopaque, rec: *const contracts.AuditRecord) void {
        const self: *AuditLog = @ptrCast(@alignCast(ctx));
        self.append(rec) catch {};
    }

    /// Chains and buffers `rec` (its seq and hashes are assigned here).
    pub fn append(self: *AuditLog, rec: *const AuditRecord) !void {
        var kind_buf: [32]u8 = undefined;
        const kind = std.fmt.bufPrint(&kind_buf, "{t}", .{rec.kind}) catch unreachable;
        const wake = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.pending.items.len > max_pending_bytes and rec.kind == .tool_result) {
                self.dropped += 1;
                return;
            }
            try self.appendLocked(kind, rec, null);
            break :blk self.pending_records >= self.opts.flush_records;
        };
        if (wake) {
            if (self.flusher != null) self.wake.set(self.io) else try self.flush(self.io);
        }
    }

    const Extra = struct { key: []const u8, hex: [32]u8 };

    fn appendLocked(self: *AuditLog, kind: []const u8, rec: *const AuditRecord, extra: ?Extra) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
        if (self.segment_bytes >= self.opts.segment_bytes) try self.startSegmentLocked();
        self.seq += 1;
        var r = rec.*;
        r.seq = self.seq;
        const start = self.pending.items.len;
        errdefer self.pending.shrinkRetainingCapacity(start);
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.pending);
        defer self.pending = aw.toArrayList();
        const w = &aw.writer;
        try w.print("{{\"seq\":{d},\"ts\":{d},\"kind\":\"{s}\",\"actor\":", .{ r.seq, r.ts_ms, kind });
        var actor_buf: [256]u8 = undefined;
        try self.jsonText(w, std.fmt.bufPrint(&actor_buf, "{f}", .{r.actor}) catch "?");
        if (r.tool) |t| {
            try w.writeAll(",\"tool\":");
            try self.jsonText(w, t);
        }
        if (r.input_hash) |h| try w.print(",\"input_hash\":\"{s}\"", .{&std.fmt.bytesToHex(h, .lower)});
        if (r.resources_json) |t| {
            try w.writeAll(",\"resources\":");
            try self.jsonText(w, t);
        }
        if (r.decision) |d| try w.print(",\"decision\":\"{t}\"", .{d});
        if (r.rule) |t| {
            try w.writeAll(",\"rule\":");
            try self.jsonText(w, t);
        }
        if (r.source) |t| {
            try w.writeAll(",\"source\":");
            try self.jsonText(w, t);
        }
        if (r.detail) |t| {
            try w.writeAll(",\"detail\":");
            try self.jsonText(w, t);
        }
        if (extra) |x| try w.print(",\"{s}\":\"{s}\"", .{ x.key, &std.fmt.bytesToHex(x.hex, .lower) });
        if (self.dropped > 0) {
            try w.print(",\"dropped\":{d}", .{self.dropped});
            self.dropped = 0;
        }
        try w.print(",\"prev\":\"{s}\"", .{&std.fmt.bytesToHex(self.last_hash, .lower)});
        const body = aw.written()[start..];
        var h = Blake3.init(.{});
        h.update(&self.last_hash);
        h.update(body);
        var hash: [32]u8 = undefined;
        h.final(&hash);
        try w.print(",\"hash\":\"{s}\"}}\n", .{&std.fmt.bytesToHex(hash, .lower)});
        self.last_hash = hash;
        self.pending_records += 1;
        self.segment_bytes += aw.written().len - start;
    }

    /// Writes `text` as a JSON string after redaction, truncated to
    /// `max_text` bytes on a UTF-8 boundary.
    fn jsonText(self: *AuditLog, w: *std.Io.Writer, text: []const u8) !void {
        var buf: [max_text]u8 = undefined;
        var n = @min(text.len, max_text);
        while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) n -= 1;
        @memcpy(buf[0..n], text[0..n]);
        var out_text: []const u8 = buf[0..n];
        var extra: std.ArrayList(u8) = .empty;
        defer extra.deinit(self.gpa);
        if (self.opts.redactor) |r| {
            _ = r.redact(r.ctx, buf[0..n], &extra);
            if (extra.items.len > 0) out_text = extra.items;
        }
        try std.json.Stringify.encodeJsonString(out_text, .{}, w);
    }

    fn startSegmentLocked(self: *AuditLog) !void {
        var b: Boundary = .{ .at = self.pending.items.len, .name = undefined, .name_len = 0 };
        const now: i64 = @intCast(std.Io.Clock.real.now(self.io).toMilliseconds());
        const name = segmentName(&b.name, now, self.seq + 1);
        b.name_len = @intCast(name.len);
        try self.boundaries.append(self.gpa, b);
        self.segment_bytes = 0;
        const rec: AuditRecord = .{ .seq = 0, .ts_ms = now, .actor = .system, .kind = .session_start };
        try self.appendLocked("segment_start", &rec, null);
    }

    /// Writes buffered records to disk and fsyncs.
    pub fn flush(self: *AuditLog, io: std.Io) !void {
        self.flush_mutex.lockUncancelable(io);
        defer self.flush_mutex.unlock(io);
        var bytes: std.ArrayList(u8) = .empty;
        var bounds: std.ArrayList(Boundary) = .empty;
        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            bytes = self.pending;
            bounds = self.boundaries;
            self.pending = .empty;
            self.boundaries = .empty;
            self.pending_records = 0;
        }
        defer bytes.deinit(self.gpa);
        defer bounds.deinit(self.gpa);
        var pos: usize = 0;
        var bi: usize = 0;
        while (pos < bytes.items.len or bi < bounds.items.len) {
            if (bi < bounds.items.len and bounds.items[bi].at == pos) {
                const b = bounds.items[bi];
                if (self.file) |f| {
                    f.sync(io) catch {};
                    f.close(io);
                }
                self.file = try self.dir.createFile(io, b.name[0..b.name_len], .{ .truncate = false, .exclusive = true, .permissions = privateFile() });
                self.file_off = 0;
                bi += 1;
                continue;
            }
            const end = if (bi < bounds.items.len) bounds.items[bi].at else bytes.items.len;
            const f = self.file orelse return error.NoSegment;
            try f.writePositionalAll(io, bytes.items[pos..end], self.file_off);
            self.file_off += end - pos;
            pos = end;
        }
        if (self.file) |f| try f.sync(io);
    }

    fn flusherLoop(self: *AuditLog) std.Io.Cancelable!void {
        const io = self.io;
        while (true) {
            self.wake.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(self.opts.flush_interval_ms), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return error.Canceled,
            };
            self.wake.reset();
            const prev = io.swapCancelProtection(.blocked);
            self.flush(io) catch |e| {
                self.write_error = e;
            };
            _ = io.swapCancelProtection(prev);
        }
    }

    /// Deletes segments older than the retention period (never the live
    /// one) and records the gap. Returns the number deleted.
    pub fn prune(self: *AuditLog, now_ms: i64) !u32 {
        try self.flush(self.io);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const segs = try listSegments(arena.allocator(), self.io, self.dir);
        if (segs.len <= 1) return 0;
        const cutoff = now_ms - @as(i64, self.opts.retention_days) * std.time.ms_per_day;
        var deleted: u32 = 0;
        var last_pruned: ?[32]u8 = null;
        for (segs[0 .. segs.len - 1]) |s| {
            if (s.start_ms >= cutoff) break;
            last_pruned = (try lastInSegment(arena.allocator(), self.io, self.dir, s.name)) orelse continue;
            try self.dir.deleteFile(self.io, s.name);
            deleted += 1;
        }
        if (last_pruned) |h| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const rec: AuditRecord = .{ .seq = 0, .ts_ms = now_ms, .actor = .system, .kind = .policy_change, .detail = "retention" };
            try self.appendLocked("retention_pruned", &rec, .{ .key = "last_pruned", .hex = h });
        }
        return deleted;
    }

    /// Flushes, stops the flusher and closes the segment.
    pub fn close(self: *AuditLog, io: std.Io) void {
        if (self.flusher) |*f| f.cancel(io) catch {};
        self.flush(io) catch {};
        if (self.file) |f| f.close(io);
        self.pending.deinit(self.gpa);
        self.boundaries.deinit(self.gpa);
        self.gpa.destroy(self);
    }
};

fn privateFile() std.Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return .fromMode(0o600);
}

fn segmentName(buf: *[64]u8, ms: i64, first_seq: u64) []const u8 {
    const secs: u64 = @intCast(@max(ms, 0) / 1000);
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{d:0>12}.jsonl", .{
        yd.year, md.month.numeric(), @as(u32, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), first_seq,
    }) catch unreachable;
}

const Segment = struct { name: []const u8, start_ms: i64, first_seq: u64 };

fn parseSegmentName(name: []const u8) ?Segment {
    // YYYYMMDD-HHMMSS-SEQ.jsonl
    if (!std.mem.endsWith(u8, name, ".jsonl") or name.len < 16 + 6) return null;
    const y = std.fmt.parseInt(u16, name[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, name[4..6], 10) catch return null;
    const d = std.fmt.parseInt(u8, name[6..8], 10) catch return null;
    const hh = std.fmt.parseInt(u8, name[9..11], 10) catch return null;
    const mm = std.fmt.parseInt(u8, name[11..13], 10) catch return null;
    const ss = std.fmt.parseInt(u8, name[13..15], 10) catch return null;
    const seq = std.fmt.parseInt(u64, name[16 .. name.len - 6], 10) catch return null;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return null;
    var days: i64 = 0;
    var yr: u16 = 1970;
    while (yr < y) : (yr += 1) days += std.time.epoch.getDaysInYear(yr);
    var m: u4 = 1;
    while (m < mo) : (m += 1) days += std.time.epoch.getDaysInMonth(y, @enumFromInt(m));
    days += d - 1;
    const ms = ((days * 24 + hh) * 60 + mm) * 60 * 1000 + @as(i64, ss) * 1000;
    return .{ .name = name, .start_ms = ms, .first_seq = seq };
}

fn listSegments(a: Allocator, io: std.Io, dir: std.Io.Dir) ![]Segment {
    var d = try dir.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var out: std.ArrayList(Segment) = .empty;
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file) continue;
        const name = try a.dupe(u8, e.name);
        if (parseSegmentName(name)) |s| try out.append(a, s);
    }
    std.mem.sort(Segment, out.items, {}, struct {
        fn lt(_: void, x: Segment, y: Segment) bool {
            return x.first_seq < y.first_seq;
        }
    }.lt);
    return out.items;
}

const Last = struct { seq: u64, hash: [32]u8 };

fn lastInSegment(a: Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !?[32]u8 {
    const data = try dir.readFileAlloc(io, name, a, .limited(1 << 30));
    var lines = std.mem.splitBackwardsScalar(u8, data, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const f = fieldsOf(l) orelse return null;
        return f.hash;
    }
    return null;
}

fn lastRecord(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !?Last {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = try listSegments(a, io, dir);
    var i = segs.len;
    while (i > 0) {
        i -= 1;
        const data = try dir.readFileAlloc(io, segs[i].name, a, .limited(1 << 30));
        var lines = std.mem.splitBackwardsScalar(u8, data, '\n');
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            const f = fieldsOf(l) orelse continue;
            return .{ .seq = f.seq, .hash = f.hash };
        }
    }
    return null;
}

const Fields = struct { seq: u64, prev: [32]u8, hash: [32]u8, body: []const u8, kind: []const u8, last_pruned: ?[32]u8 };

/// Extracts the chain fields of one line without a full JSON parse. The
/// writer emits `prev` and `hash` last, in that order.
fn fieldsOf(line: []const u8) ?Fields {
    const hk = ",\"hash\":\"";
    const hi = std.mem.lastIndexOf(u8, line, hk) orelse return null;
    if (line.len != hi + hk.len + 64 + 2) return null;
    var f: Fields = undefined;
    _ = std.fmt.hexToBytes(&f.hash, line[hi + hk.len ..][0..64]) catch return null;
    f.body = line[0..hi];
    const pk = ",\"prev\":\"";
    const pi = std.mem.lastIndexOf(u8, f.body, pk) orelse return null;
    if (f.body.len != pi + pk.len + 64 + 1) return null;
    _ = std.fmt.hexToBytes(&f.prev, f.body[pi + pk.len ..][0..64]) catch return null;
    const sk = "{\"seq\":";
    if (!std.mem.startsWith(u8, line, sk)) return null;
    const comma = std.mem.indexOfScalarPos(u8, line, sk.len, ',') orelse return null;
    f.seq = std.fmt.parseInt(u64, line[sk.len..comma], 10) catch return null;
    const kk = ",\"kind\":\"";
    const ki = std.mem.indexOf(u8, line, kk) orelse return null;
    const ke = std.mem.indexOfScalarPos(u8, line, ki + kk.len, '"') orelse return null;
    f.kind = line[ki + kk.len .. ke];
    f.last_pruned = null;
    const lk = ",\"last_pruned\":\"";
    if (std.mem.indexOf(u8, f.body, lk)) |li| {
        var h: [32]u8 = undefined;
        if (f.body.len >= li + lk.len + 64) if (std.fmt.hexToBytes(&h, f.body[li + lk.len ..][0..64])) |_| {
            f.last_pruned = h;
        } else |_| {};
    }
    return f;
}

/// The outcome of `verify`.
pub const VerifyResult = union(enum) {
    ok: struct { records: u64, segments: u32 },
    broken: struct { segment: []const u8, line: u64, seq: u64, reason: []const u8 },
};

/// Recomputes the whole chain and reports the first broken record.
/// Strings in the result are allocated with `gpa` (use an arena).
pub fn verify(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !VerifyResult {
    const segs = try listSegments(gpa, io, dir);
    var prev: ?[32]u8 = null;
    var first_prev: ?[32]u8 = null;
    var expect_seq: ?u64 = null;
    var count: u64 = 0;
    var pruned_ok = false;
    for (segs) |s| {
        const data = try dir.readFileAlloc(io, s.name, gpa, .limited(1 << 30));
        var lines = std.mem.splitScalar(u8, data, '\n');
        var ln: u64 = 0;
        while (lines.next()) |l| {
            ln += 1;
            if (l.len == 0) continue;
            const f = fieldsOf(l) orelse return .{ .broken = .{ .segment = s.name, .line = ln, .seq = if (expect_seq) |e| e else 0, .reason = "malformed record" } };
            var h = Blake3.init(.{});
            h.update(&f.prev);
            h.update(f.body);
            var want: [32]u8 = undefined;
            h.final(&want);
            if (!std.mem.eql(u8, &want, &f.hash)) return .{ .broken = .{ .segment = s.name, .line = ln, .seq = f.seq, .reason = "hash mismatch (record modified)" } };
            if (prev) |p| {
                if (!std.mem.eql(u8, &p, &f.prev)) return .{ .broken = .{ .segment = s.name, .line = ln, .seq = f.seq, .reason = "chain broken (record missing or reordered)" } };
            } else first_prev = f.prev;
            if (expect_seq) |e| if (f.seq != e) return .{ .broken = .{ .segment = s.name, .line = ln, .seq = f.seq, .reason = "sequence gap" } };
            if (f.last_pruned) |lp| {
                if (first_prev) |fp| if (std.mem.eql(u8, &fp, &lp) and std.mem.eql(u8, f.kind, "retention_pruned")) {
                    pruned_ok = true;
                };
            }
            prev = f.hash;
            expect_seq = f.seq + 1;
            count += 1;
        }
    }
    // The first surviving record must start the chain, unless a chained
    // retention_pruned record vouches for the gap before it.
    if (first_prev) |fp| if (!std.mem.allEqual(u8, &fp, 0) and !pruned_ok)
        return .{ .broken = .{ .segment = if (segs.len > 0) segs[0].name else "", .line = 1, .seq = 0, .reason = "earlier records missing (deleted segment)" } };
    return .{ .ok = .{ .records = count, .segments = @intCast(segs.len) } };
}

/// Filters for `query`.
pub const Query = struct {
    session: ?[]const u8 = null,
    actor: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    kind: ?AuditRecord.Kind = null,
    since_ms: ?i64 = null,
    until_ms: ?i64 = null,
    limit: u32 = 1000,
};

/// Appends matching records, oldest first (strings allocated with `gpa`;
/// use an arena). The actor comes back as `system` with its text in
/// `source`'s place is avoided: `detail` keeps the record's detail and the
/// actor text is matched but returned as `Actor.human(<text>)`.
pub fn query(gpa: Allocator, io: std.Io, dir: std.Io.Dir, q: Query, out: *std.ArrayList(AuditRecord)) !void {
    const segs = try listSegments(gpa, io, dir);
    for (segs) |s| {
        const data = try dir.readFileAlloc(io, s.name, gpa, .limited(1 << 30));
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            if (out.items.len >= q.limit) return;
            const J = struct {
                seq: u64,
                ts: i64,
                kind: []const u8,
                actor: []const u8,
                tool: ?[]const u8 = null,
                decision: ?[]const u8 = null,
                rule: ?[]const u8 = null,
                source: ?[]const u8 = null,
                detail: ?[]const u8 = null,
            };
            const j = std.json.parseFromSliceLeaky(J, gpa, l, .{ .ignore_unknown_fields = true }) catch continue;
            const kind = std.meta.stringToEnum(AuditRecord.Kind, j.kind) orelse continue;
            if (q.kind) |k| if (k != kind) continue;
            if (q.since_ms) |t| if (j.ts < t) continue;
            if (q.until_ms) |t| if (j.ts > t) continue;
            if (q.tool) |t| if (j.tool == null or !std.mem.eql(u8, t, j.tool.?)) continue;
            if (q.actor) |t| if (!std.mem.eql(u8, t, j.actor)) continue;
            if (q.session) |sess| {
                // agent:<session>/<agent>
                if (!std.mem.startsWith(u8, j.actor, "agent:")) continue;
                const rest = j.actor["agent:".len..];
                const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
                if (!std.mem.eql(u8, rest[0..slash], sess)) continue;
            }
            try out.append(gpa, .{
                .seq = j.seq,
                .ts_ms = j.ts,
                .actor = .{ .human = j.actor },
                .kind = kind,
                .tool = j.tool,
                .decision = if (j.decision) |d| std.meta.stringToEnum(AuditRecord.DecisionKind, d) else null,
                .rule = j.rule,
                .source = j.source,
                .detail = j.detail,
            });
        }
    }
}

const fakes = @import("../testing/fakes.zig");

fn testRec(kind: AuditRecord.Kind, tool: []const u8, detail: ?[]const u8) AuditRecord {
    return .{ .seq = 0, .ts_ms = 1_700_000_000_000, .actor = .{ .agent = .{ .session = "s1", .agent = "main" } }, .kind = kind, .tool = tool, .decision = .allow, .detail = detail };
}

test "INV-12 audit: chain verifies after 10k appends across rotations" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const log = try AuditLog.open(std.testing.allocator, io, tmp.dir, .{ .segment_bytes = 64 * 1024, .background = false });
    for (0..10_000) |i| {
        try log.append(&testRec(.tool_decision, "run_command", if (i % 2 == 0) "even" else "odd"));
    }
    log.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try verify(arena.allocator(), io, tmp.dir);
    try std.testing.expect(r == .ok);
    try std.testing.expect(r.ok.segments > 3);
    try std.testing.expect(r.ok.records > 10_000);
    // Reopening continues the chain.
    const again = try AuditLog.open(std.testing.allocator, io, tmp.dir, .{ .background = false });
    try again.append(&testRec(.session_end, "x", null));
    again.close(io);
    try std.testing.expect(try verify(arena.allocator(), io, tmp.dir) == .ok);
}

test "audit: single byte tamper detected at exact line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const log = try AuditLog.open(std.testing.allocator, io, tmp.dir, .{ .background = false });
    for (0..10) |_| try log.append(&testRec(.tool_decision, "read_file", "fine"));
    log.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = try listSegments(a, io, tmp.dir);
    const data = try tmp.dir.readFileAlloc(io, segs[0].name, a, .unlimited);
    // Line 6 (seq 6): change "allow" to "aLlow".
    var ln: usize = 1;
    var i: usize = 0;
    while (ln < 6) : (i += 1) if (data[i] == '\n') {
        ln += 1;
    };
    const at = std.mem.indexOfPos(u8, data, i, "allow").?;
    data[at + 1] = 'L';
    try tmp.dir.writeFile(io, .{ .sub_path = segs[0].name, .data = data });
    const r = try verify(a, io, tmp.dir);
    try std.testing.expectEqual(6, r.broken.line);
    try std.testing.expectEqual(6, r.broken.seq);
}

test "audit: deleted middle segment detected" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const log = try AuditLog.open(std.testing.allocator, io, tmp.dir, .{ .segment_bytes = 2048, .background = false });
    for (0..100) |_| try log.append(&testRec(.tool_decision, "read_file", "x"));
    log.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const segs = try listSegments(a, io, tmp.dir);
    try std.testing.expect(segs.len >= 3);
    try tmp.dir.deleteFile(io, segs[1].name);
    const r = try verify(a, io, tmp.dir);
    try std.testing.expectEqualStrings(segs[2].name, r.broken.segment);
    // Deleting the first segment is caught too.
    try tmp.dir.deleteFile(io, segs[0].name);
    try std.testing.expect(try verify(a, io, tmp.dir) == .broken);
}

test "audit: prune keeps chain verifiable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two old segments written by hand-renamed files: write, close, rename
    // to an old timestamp.
    const log = try AuditLog.open(std.testing.allocator, io, tmp.dir, .{ .segment_bytes = 2048, .background = false, .retention_days = 30 });
    for (0..60) |_| try log.append(&testRec(.tool_decision, "read_file", "x"));
    try log.flush(io);
    const segs = try listSegments(a, io, tmp.dir);
    try std.testing.expect(segs.len >= 3);
    for (segs[0 .. segs.len - 1]) |s| {
        var nb: [64]u8 = undefined;
        const old = try std.fmt.bufPrint(&nb, "20200101-000000-{s}", .{s.name[16..]});
        try tmp.dir.rename(s.name, tmp.dir, old, io);
    }
    const now: i64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
    const n = try log.prune(now);
    try std.testing.expectEqual(segs.len - 1, n);
    log.close(io);
    try std.testing.expect(try verify(a, io, tmp.dir) == .ok);
}

test "INV-07 audit: planted secret absent from file bytes" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var red: fakes.MarkerRedactor = .{ .needle = "sk-PLANTED-123" };
    const log = try AuditLog.open(std.testing.allocator, io, tmp.dir, .{ .background = false, .redactor = red.redactor() });
    var r = testRec(.tool_decision, "run_command", "curl -H 'Authorization: sk-PLANTED-123' x");
    r.rule = "run_command(echo sk-PLANTED-123)";
    try log.append(&r);
    log.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const segs = try listSegments(arena.allocator(), io, tmp.dir);
    const data = try tmp.dir.readFileAlloc(io, segs[0].name, arena.allocator(), .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, data, "sk-PLANTED") == null);
    try std.testing.expect(std.mem.indexOf(u8, data, "**************") != null);
}

test "audit: append from 16 threads, no lost decision records" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const log = try AuditLog.open(std.testing.allocator, io, tmp.dir, .{ .segment_bytes = 256 * 1024 });
    var threads: [16]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, struct {
        fn run(l: *AuditLog) void {
            for (0..250) |_| l.append(&testRec(.tool_decision, "edit_file", "t")) catch @panic("append");
        }
    }.run, .{log});
    for (threads) |t| t.join();
    log.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try verify(arena.allocator(), io, tmp.dir);
    var out: std.ArrayList(AuditRecord) = .empty;
    try query(arena.allocator(), io, tmp.dir, .{ .kind = .tool_decision, .limit = 100_000 }, &out);
    try std.testing.expectEqual(4000, out.items.len);
    try std.testing.expect(r == .ok);
}

test "audit: query filters" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const log = try AuditLog.open(std.testing.allocator, io, tmp.dir, .{ .background = false });
    try log.append(&testRec(.tool_decision, "read_file", "a"));
    var other = testRec(.approval_answer, "run_command", "b");
    other.actor = .{ .agent = .{ .session = "s2", .agent = "x" } };
    other.ts_ms = 1_800_000_000_000;
    try log.append(&other);
    log.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(AuditRecord) = .empty;
    try query(a, io, tmp.dir, .{ .session = "s2" }, &out);
    try std.testing.expectEqual(1, out.items.len);
    try std.testing.expectEqualStrings("run_command", out.items[0].tool.?);
    out.clearRetainingCapacity();
    try query(a, io, tmp.dir, .{ .tool = "read_file", .until_ms = 1_750_000_000_000 }, &out);
    try std.testing.expectEqual(1, out.items.len);
    try std.testing.expectEqual(AuditRecord.DecisionKind.allow, out.items[0].decision.?);
    out.clearRetainingCapacity();
    try query(a, io, tmp.dir, .{ .kind = .approval_answer }, &out);
    try std.testing.expectEqualStrings("b", out.items[0].detail.?);
}

test "audit: segment names round-trip" {
    var b: [64]u8 = undefined;
    const name = segmentName(&b, 1_700_000_123_000, 42);
    try std.testing.expectEqualStrings("20231114-221523-000000000042.jsonl", name);
    const s = parseSegmentName(name).?;
    try std.testing.expectEqual(1_700_000_123_000, s.start_ms);
    try std.testing.expectEqual(42, s.first_seq);
}
