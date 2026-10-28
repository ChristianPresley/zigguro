//! A native Perfetto trace writer (E14.F02.S01.T01): encodes collected
//! `zg_core.trace` events as a `.pftrace` (protobuf `Trace` of
//! `TracePacket`s with `TrackEvent`s) that ui.perfetto.dev opens directly.
//!
//! Tracks: one process track, one per thread, a GPU track for `gpu.*`
//! zones, one per counter, and async lanes per span name allocated so that
//! overlapping ids never share a track. Names and categories are interned
//! per sequence. Field numbers follow Perfetto's `.proto` files (see the
//! E14.F02.S01.T01 task for the list).

const std = @import("std");
const builtin = @import("builtin");
const zg_core = @import("zg_core");
const pb = @import("protobuf.zig");
const redact_mod = @import("redact.zig");
const Category = @import("../trace/categories.zig").Category;

const Event = zg_core.trace.Event;
const Kind = zg_core.trace.Kind;
const Site = zg_core.trace.Site;
const Io = std.Io;

/// Counter track units (`CounterDescriptor.Unit`).
pub const CounterUnit = enum(u8) { unspecified = 0, time_ns = 1, count = 2, size_bytes = 3 };

// Field numbers.
const f_trace_packet = 1;
const f_pkt_timestamp = 8;
const f_pkt_seq_id = 10;
const f_pkt_track_event = 11;
const f_pkt_interned = 12;
const f_pkt_seq_flags = 13;
const f_pkt_defaults = 59;
const f_pkt_track_desc = 60;
const f_pkt_first_on_seq = 87;
const f_td_uuid = 1;
const f_td_name = 2;
const f_td_process = 3;
const f_td_thread = 4;
const f_td_parent = 5;
const f_td_counter = 8;
const f_proc_pid = 1;
const f_proc_name = 6;
const f_thr_pid = 1;
const f_thr_tid = 2;
const f_thr_name = 5;
const f_ctr_unit = 3;
const f_te_category_iids = 3;
const f_te_debug = 4;
const f_te_type = 9;
const f_te_name_iid = 10;
const f_te_track = 11;
const f_te_counter_value = 30;
const f_te_flow_ids = 47;
const f_te_term_flow_ids = 48;
const f_def_clock_id = 58;
const f_int_categories = 1;
const f_int_names = 2;
const f_da_int = 4;
const f_da_string = 6;
const f_da_name = 10;
const f_iid = 1;
const f_iname = 2;

const seq_cleared = 1;
const seq_needs_state = 2;
/// `BUILTIN_CLOCK_MONOTONIC`: `.awake` is CLOCK_MONOTONIC on Linux.
const clock_monotonic = 3;

/// `TrackEvent.Type`.
pub const EventType = enum(u8) { slice_begin = 1, slice_end = 2, instant = 3, counter = 4 };

/// The Perfetto writer.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    out: *Io.Writer,
    opts: Options,
    pkt: Io.Writer.Allocating,
    body: Io.Writer.Allocating,
    scratch: Io.Writer.Allocating,
    names: std.StringHashMapUnmanaged(u64) = .empty,
    cats: std.AutoHashMapUnmanaged(Category, u64) = .empty,
    /// Track key hash -> small uuid (1-byte varints keep events small).
    tracks: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    first_event: bool = true,
    process_written: bool = false,
    /// Async lanes: per span name, the end time of each lane's open span.
    lanes: std.StringHashMapUnmanaged(std.ArrayList(u64)) = .empty,
    /// Async id -> track of its open span.
    open_async: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// Events written (diagnostics).
    events_written: u64 = 0,

    /// Writer options.
    pub const Options = struct {
        pid: i32 = 1,
        process_name: []const u8 = "zigguro",
        redact: redact_mod.Redact = .none,
        sequence_id: u32 = 1,
        /// Allocator for per-call temporaries in `writeEvents` (default:
        /// the writer's). The crash path resets an arena between calls.
        temp: ?std.mem.Allocator = null,
        /// Stamp packets with BUILTIN_CLOCK_MONOTONIC (Linux) so the trace
        /// lines up with perf/ftrace recordings.
        monotonic_clock: bool = builtin.os.tag == .linux,
    };

    /// A writer appending packets to `out`.
    pub fn init(gpa: std.mem.Allocator, out: *Io.Writer, opts: Options) Writer {
        return .{ .gpa = gpa, .out = out, .opts = opts, .pkt = .init(gpa), .body = .init(gpa), .scratch = .init(gpa) };
    }

    /// Frees the writer's tables (not `out`).
    pub fn deinit(w: *Writer) void {
        w.pkt.deinit();
        w.body.deinit();
        w.scratch.deinit();
        var it = w.names.keyIterator();
        while (it.next()) |k| w.gpa.free(k.*);
        w.names.deinit(w.gpa);
        w.cats.deinit(w.gpa);
        w.tracks.deinit(w.gpa);
        var li = w.lanes.valueIterator();
        while (li.next()) |l| l.deinit(w.gpa);
        var lk = w.lanes.keyIterator();
        while (lk.next()) |k| w.gpa.free(k.*);
        w.lanes.deinit(w.gpa);
        w.open_async.deinit(w.gpa);
        w.* = undefined;
    }

    fn key(kind: []const u8, a: u64, b: []const u8) u64 {
        var h = std.hash.Wyhash.init(0x5045_5246);
        h.update(kind);
        h.update(std.mem.asBytes(&a));
        h.update(b);
        return h.final();
    }

    /// The process track is always uuid 1; other tracks count up from 2.
    fn processUuid(_: *const Writer) u64 {
        return 1;
    }

    /// The uuid for track `k`; `new` is true the first time.
    fn trackUuid(w: *Writer, k: u64) !struct { id: u64, new: bool } {
        const gop = try w.tracks.getOrPut(w.gpa, k);
        if (!gop.found_existing) gop.value_ptr.* = w.tracks.count() + 1;
        return .{ .id = gop.value_ptr.*, .new = !gop.found_existing };
    }

    /// Writes the packet assembled in `pkt` to the output.
    fn flushPacket(w: *Writer) !void {
        try pb.writeUint(&w.pkt.writer, f_pkt_seq_id, w.opts.sequence_id);
        try pb.writeMessage(w.out, f_trace_packet, w.pkt.written());
        w.pkt.clearRetainingCapacity();
    }

    fn writeName(w: *Writer, name: []const u8, field: u29, sink: *Io.Writer) !void {
        if (w.opts.redact == .paths and redact_mod.isPath(name)) {
            var buf: [512]u8 = undefined;
            try pb.writeBytes(sink, field, redact_mod.redactInto(&buf, name));
        } else try pb.writeBytes(sink, field, name);
    }

    fn ensureProcess(w: *Writer) !void {
        if (w.process_written) return;
        w.process_written = true;
        const d = pb.Nested.begin(&w.body);
        try pb.writeUint(d.writer(), f_td_uuid, w.processUuid());
        const p = pb.Nested.begin(&w.scratch);
        try pb.writeInt(p.writer(), f_proc_pid, w.opts.pid);
        try pb.writeBytes(p.writer(), f_proc_name, w.opts.process_name);
        try p.end(d.writer(), f_td_process);
        try d.end(&w.pkt.writer, f_pkt_track_desc);
        try w.flushPacket();
    }

    /// Declares the track of thread `tid`; returns its uuid.
    pub fn defineThread(w: *Writer, tid: u32, name: []const u8) !u64 {
        try w.ensureProcess();
        const t_id = try w.trackUuid(key("thread", tid, ""));
        const id = t_id.id;
        if (!t_id.new and name.len == 0) return id;
        const d = pb.Nested.begin(&w.body);
        try pb.writeUint(d.writer(), f_td_uuid, id);
        const t = pb.Nested.begin(&w.scratch);
        try pb.writeInt(t.writer(), f_thr_pid, w.opts.pid);
        try pb.writeInt(t.writer(), f_thr_tid, tid);
        if (name.len != 0) try w.writeName(name, f_thr_name, t.writer());
        try t.end(d.writer(), f_td_thread);
        try d.end(&w.pkt.writer, f_pkt_track_desc);
        try w.flushPacket();
        return id;
    }

    fn defineChild(w: *Writer, k: u64, parent: u64, name: []const u8, counter_unit: ?CounterUnit) !u64 {
        try w.ensureProcess();
        const t = try w.trackUuid(k);
        const id = t.id;
        if (!t.new) return id;
        const d = pb.Nested.begin(&w.body);
        try pb.writeUint(d.writer(), f_td_uuid, id);
        try w.writeName(name, f_td_name, d.writer());
        try pb.writeUint(d.writer(), f_td_parent, parent);
        if (counter_unit) |u| {
            const c = pb.Nested.begin(&w.scratch);
            if (u != .unspecified) try pb.writeUint(c.writer(), f_ctr_unit, @intFromEnum(u));
            try c.end(d.writer(), f_td_counter);
        }
        try d.end(&w.pkt.writer, f_pkt_track_desc);
        try w.flushPacket();
        return id;
    }

    /// Declares a counter track named `name`; returns its uuid.
    pub fn defineCounter(w: *Writer, name: []const u8, unit: CounterUnit) !u64 {
        return w.defineChild(key("counter", 0, name), w.processUuid(), name, unit);
    }

    /// Declares an async track under `parent_uuid`; returns its uuid.
    pub fn defineAsyncTrack(w: *Writer, parent_uuid: u64, name: []const u8) !u64 {
        return w.defineChild(key("async", parent_uuid, name), parent_uuid, name, null);
    }

    fn gpuTrack(w: *Writer) !u64 {
        return w.defineChild(key("gpu", 0, ""), w.processUuid(), "GPU", null);
    }

    fn laneTrack(w: *Writer, name: []const u8, lane: usize) !u64 {
        var buf: [96]u8 = undefined;
        const label = if (lane == 0) name else std.fmt.bufPrint(&buf, "{s} #{d}", .{ name, lane + 1 }) catch name;
        return w.defineChild(key("lane", lane, name), w.processUuid(), label, null);
    }

    /// Interns `name` (and its category), adding new entries to the
    /// packet's `interned_data`.
    fn intern(w: *Writer, name: []const u8, interned: *pb.Nested, any_interned: *bool) !struct { name: u64, cat: u64 } {
        const n = w.names.get(name) orelse blk: {
            const iid = w.names.count() + 1;
            try w.names.put(w.gpa, try w.gpa.dupe(u8, name), iid);
            const e = pb.Nested.begin(&w.scratch);
            try pb.writeUint(e.writer(), f_iid, iid);
            try pb.writeBytes(e.writer(), f_iname, name);
            try e.end(interned.writer(), f_int_names);
            any_interned.* = true;
            break :blk iid;
        };
        const cat = Category.ofName(name);
        const c = w.cats.get(cat) orelse blk: {
            const iid = w.cats.count() + 1;
            try w.cats.put(w.gpa, cat, iid);
            const e = pb.Nested.begin(&w.scratch);
            try pb.writeUint(e.writer(), f_iid, iid);
            try pb.writeBytes(e.writer(), f_iname, @tagName(cat));
            try e.end(interned.writer(), f_int_categories);
            any_interned.* = true;
            break :blk iid;
        };
        return .{ .name = n, .cat = c };
    }

    /// A debug annotation (shown in the slice's Arguments).
    pub const Annotation = struct {
        name: []const u8,
        value: union(enum) { int: i64, string: []const u8 },
    };

    /// One track event.
    pub const TrackEvent = struct {
        ts: u64,
        type: EventType,
        track: u64,
        name: ?[]const u8 = null,
        counter_value: ?i64 = null,
        flow_ids: []const u64 = &.{},
        terminating_flow_ids: []const u64 = &.{},
        annotations: []const Annotation = &.{},
    };

    /// Writes one `TrackEvent` packet.
    pub fn writeTrackEvent(w: *Writer, e: TrackEvent) !void {
        try pb.writeUint(&w.pkt.writer, f_pkt_timestamp, e.ts);
        var interned = pb.Nested.begin(&w.body);
        var any_interned = false;
        var ids: @TypeOf(try w.intern("", &interned, &any_interned)) = undefined;
        if (e.name) |n| ids = try w.intern(n, &interned, &any_interned);
        if (any_interned) {
            try interned.end(&w.pkt.writer, f_pkt_interned);
        } else w.body.shrinkRetainingCapacity(interned.start);
        if (w.first_event) {
            try pb.writeUint(&w.pkt.writer, f_pkt_seq_flags, seq_cleared | seq_needs_state);
            try pb.writeUint(&w.pkt.writer, f_pkt_first_on_seq, 1);
            // The clock goes in the sequence defaults instead of every packet.
            if (w.opts.monotonic_clock) {
                const d = pb.Nested.begin(&w.body);
                try pb.writeUint(d.writer(), f_def_clock_id, clock_monotonic);
                try d.end(&w.pkt.writer, f_pkt_defaults);
            }
            w.first_event = false;
        } else try pb.writeUint(&w.pkt.writer, f_pkt_seq_flags, seq_needs_state);
        const te = pb.Nested.begin(&w.body);
        try pb.writeUint(te.writer(), f_te_type, @intFromEnum(e.type));
        try pb.writeUint(te.writer(), f_te_track, e.track);
        if (e.name != null) {
            try pb.writeUint(te.writer(), f_te_name_iid, ids.name);
            try pb.writeUint(te.writer(), f_te_category_iids, ids.cat);
        }
        if (e.counter_value) |v| try pb.writeInt(te.writer(), f_te_counter_value, v);
        for (e.flow_ids) |id| try pb.writeFixed64(te.writer(), f_te_flow_ids, id);
        for (e.terminating_flow_ids) |id| try pb.writeFixed64(te.writer(), f_te_term_flow_ids, id);
        for (e.annotations) |a| {
            const da = pb.Nested.begin(&w.scratch);
            try pb.writeBytes(da.writer(), f_da_name, a.name);
            switch (a.value) {
                .int => |v| try pb.writeInt(da.writer(), f_da_int, v),
                .string => |v| try w.writeName(v, f_da_string, da.writer()),
            }
            try da.end(te.writer(), f_te_debug);
        }
        try te.end(&w.pkt.writer, f_pkt_track_event);
        try w.flushPacket();
        w.events_written += 1;
    }

    const Edge = struct {
        ts: u64,
        order: u8, // 0 end, 1 begin/instant/counter
        /// Longer zones first among equal begins; later starts first among
        /// equal ends.
        tie: u64,
        ev: u32,
        is_end: bool,
    };

    fn edgeLess(_: void, a: Edge, b: Edge) bool {
        if (a.ts != b.ts) return a.ts < b.ts;
        if (a.order != b.order) return a.order < b.order;
        return a.tie > b.tie;
    }

    /// Zones searched backwards per flow.
    const max_flow_scan = 256;

    fn zoneLess(events: []const Event, a: u32, b: u32) bool {
        const x = events[a];
        const y = events[b];
        if (x.tid != y.tid) return x.tid < y.tid;
        return x.ts < y.ts;
    }

    const ZoneKey = struct {
        tid: u32,
        ts: u64,
        events: []const Event,
        fn order(k: ZoneKey, zi: u32) std.math.Order {
            const z = k.events[zi];
            if (k.tid != z.tid) return std.math.order(k.tid, z.tid);
            return std.math.order(k.ts, z.ts);
        }
    };

    fn siteName(e: Event) []const u8 {
        const s: *const Site = @ptrFromInt(e.site_or_name);
        return s.name;
    }

    /// Encodes `events` (from `zg_core.trace.collect`: ns timestamps, zone
    /// durations in `value`). Can be called repeatedly with later chunks.
    pub fn writeEvents(w: *Writer, events: []const Event) !void {
        try w.ensureProcess();
        const gpa = w.opts.temp orelse w.gpa;
        // Thread tracks and names.
        for (events) |e| if (e.kind == @intFromEnum(Kind.thread_name)) {
            _ = try w.defineThread(e.tid, siteName(e));
        };
        // Flows attach to the innermost zone around them on their thread.
        var flows_out: std.AutoHashMapUnmanaged(u32, std.ArrayList(u64)) = .empty;
        var flows_in: std.AutoHashMapUnmanaged(u32, std.ArrayList(u64)) = .empty;
        defer {
            var a = flows_out.valueIterator();
            while (a.next()) |l| l.deinit(gpa);
            flows_out.deinit(gpa);
            var b = flows_in.valueIterator();
            while (b.next()) |l| l.deinit(gpa);
            flows_in.deinit(gpa);
        }
        var orphan_flows: std.ArrayList(u32) = .empty;
        defer orphan_flows.deinit(gpa);
        // Zones by (tid, start), built only when there are flows.
        var zones: std.ArrayList(u32) = .empty;
        defer zones.deinit(gpa);
        const has_flows = for (events) |e| {
            if (e.kind == @intFromEnum(Kind.flow_out) or e.kind == @intFromEnum(Kind.flow_in)) break true;
        } else false;
        if (has_flows) {
            for (events, 0..) |e, i| if (e.kind == @intFromEnum(Kind.zone)) try zones.append(gpa, @intCast(i));
            std.mem.sort(u32, zones.items, events, zoneLess);
        }
        for (events, 0..) |f, fi| {
            const k: Kind = @enumFromInt(f.kind);
            if (k != .flow_out and k != .flow_in) continue;
            var best: ?u32 = null;
            var best_dur: u64 = std.math.maxInt(u64);
            // Zones on f's thread starting at or before f, nearest first;
            // the innermost enclosing one is among the last few.
            var hi = std.sort.upperBound(u32, zones.items, ZoneKey{ .tid = f.tid, .ts = f.ts, .events = events }, ZoneKey.order);
            var scanned: usize = 0;
            while (hi > 0 and scanned < max_flow_scan) : (scanned += 1) {
                hi -= 1;
                const zi = zones.items[hi];
                const z = events[zi];
                if (z.tid != f.tid) break;
                const dur: u64 = @intCast(@max(0, z.value));
                if (f.ts <= z.ts + dur and dur < best_dur) {
                    best = zi;
                    best_dur = dur;
                }
            }
            if (best) |zi| {
                const map = if (k == .flow_out) &flows_out else &flows_in;
                const gop = try map.getOrPut(gpa, zi);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, @bitCast(f.value));
            } else try orphan_flows.append(gpa, @intCast(fi));
        }
        // Edges sorted by time.
        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(gpa);
        for (events, 0..) |e, i| {
            const k: Kind = @enumFromInt(e.kind);
            switch (k) {
                .thread_name, .flow_out, .flow_in => {},
                .zone => {
                    const dur: u64 = @intCast(@max(0, e.value));
                    try edges.append(gpa, .{ .ts = e.ts, .order = 1, .tie = dur, .ev = @intCast(i), .is_end = false });
                    try edges.append(gpa, .{ .ts = e.ts + dur, .order = 0, .tie = e.ts, .ev = @intCast(i), .is_end = true });
                },
                else => try edges.append(gpa, .{ .ts = e.ts, .order = 1, .tie = 0, .ev = @intCast(i), .is_end = false }),
            }
        }
        for (orphan_flows.items) |fi| try edges.append(gpa, .{ .ts = events[fi].ts, .order = 1, .tie = 0, .ev = fi, .is_end = false });
        std.mem.sort(Edge, edges.items, {}, edgeLess);

        for (edges.items) |edge| {
            const e = events[edge.ev];
            const k: Kind = @enumFromInt(e.kind);
            const name = siteName(e);
            switch (k) {
                .zone => {
                    const track = if (std.mem.startsWith(u8, name, "gpu.")) try w.gpuTrack() else try w.defineThread(e.tid, "");
                    if (edge.is_end) {
                        try w.writeTrackEvent(.{ .ts = edge.ts, .type = .slice_end, .track = track });
                    } else {
                        const fo = if (flows_out.get(edge.ev)) |l| l.items else &.{};
                        const fin = if (flows_in.get(edge.ev)) |l| l.items else &.{};
                        try w.writeTrackEvent(.{ .ts = edge.ts, .type = .slice_begin, .track = track, .name = name, .flow_ids = fo, .terminating_flow_ids = fin });
                    }
                },
                .instant => try w.writeTrackEvent(.{ .ts = e.ts, .type = .instant, .track = try w.defineThread(e.tid, ""), .name = name }),
                .counter => {
                    const unit: CounterUnit = if (std.mem.endsWith(u8, name, "_ns")) .time_ns else if (std.mem.endsWith(u8, name, "_bytes")) .size_bytes else .unspecified;
                    try w.writeTrackEvent(.{ .ts = e.ts, .type = .counter, .track = try w.defineCounter(name, unit), .counter_value = e.value });
                },
                .flow_out, .flow_in => {
                    // No enclosing zone: an instant carrying the flow.
                    const id: u64 = @bitCast(e.value);
                    const one = [_]u64{id};
                    const track = try w.defineThread(e.tid, "");
                    if (k == .flow_out)
                        try w.writeTrackEvent(.{ .ts = e.ts, .type = .instant, .track = track, .name = "flow", .flow_ids = &one })
                    else
                        try w.writeTrackEvent(.{ .ts = e.ts, .type = .instant, .track = track, .name = "flow", .terminating_flow_ids = &one });
                },
                .async_begin => {
                    const id: u64 = @bitCast(e.value);
                    const gop = try w.lanes.getOrPut(w.gpa, name);
                    if (!gop.found_existing) {
                        gop.key_ptr.* = try w.gpa.dupe(u8, name);
                        gop.value_ptr.* = .empty;
                    }
                    // A lane is free when its span ended (0 = free).
                    const lanes = gop.value_ptr;
                    var lane: usize = lanes.items.len;
                    for (lanes.items, 0..) |busy, li| if (busy == 0) {
                        lane = li;
                        break;
                    };
                    if (lane == lanes.items.len) try lanes.append(w.gpa, 0);
                    lanes.items[lane] = id;
                    const track = try w.laneTrack(gop.key_ptr.*, lane);
                    try w.open_async.put(w.gpa, id, track);
                    try w.writeTrackEvent(.{ .ts = e.ts, .type = .slice_begin, .track = track, .name = name });
                },
                .async_end => {
                    const id: u64 = @bitCast(e.value);
                    const track = (w.open_async.fetchRemove(id) orelse continue).value;
                    if (w.lanes.getPtr(name)) |lanes| for (lanes.items) |*busy| if (busy.* == id) {
                        busy.* = 0;
                    };
                    try w.writeTrackEvent(.{ .ts = e.ts, .type = .slice_end, .track = track });
                },
                .async_instant => {
                    const id: u64 = @bitCast(e.value);
                    const track = w.open_async.get(id) orelse try w.defineThread(e.tid, "");
                    try w.writeTrackEvent(.{ .ts = e.ts, .type = .instant, .track = track, .name = name });
                },
                .thread_name => {},
            }
        }
    }

    /// Flushes the output.
    pub fn finish(w: *Writer) !void {
        try w.out.flush();
    }
};

// ---- tests ----

const Dump = struct {
    descriptors: usize = 0,
    thread_names: [8][]const u8 = undefined,
    n_thread_names: usize = 0,
    track_names: [16][]const u8 = undefined,
    n_track_names: usize = 0,
    events: usize = 0,
    begins: usize = 0,
    ends: usize = 0,
    counters: usize = 0,
    flows_out: usize = 0,
    flows_in: usize = 0,
    interned_names: usize = 0,
    first_flags: u64 = 0,
    begin_tracks: [64]u64 = undefined,

    fn decode(d: *Dump, bytes: []const u8) !void {
        var r: pb.Reader = .{ .buf = bytes };
        while (try r.next()) |pkt| {
            try std.testing.expectEqual(@as(u29, 1), pkt.number);
            var pr: pb.Reader = .{ .buf = pkt.bytes };
            var is_event = false;
            var flags: u64 = 0;
            while (try pr.next()) |f| switch (f.number) {
                f_pkt_track_desc => {
                    d.descriptors += 1;
                    var tr: pb.Reader = .{ .buf = f.bytes };
                    while (try tr.next()) |tf| switch (tf.number) {
                        f_td_name => {
                            d.track_names[d.n_track_names] = tf.bytes;
                            d.n_track_names += 1;
                        },
                        f_td_thread => {
                            var th: pb.Reader = .{ .buf = tf.bytes };
                            while (try th.next()) |x| if (x.number == f_thr_name) {
                                d.thread_names[d.n_thread_names] = x.bytes;
                                d.n_thread_names += 1;
                            };
                        },
                        else => {},
                    };
                },
                f_pkt_interned => {
                    var ir: pb.Reader = .{ .buf = f.bytes };
                    while (try ir.next()) |x| if (x.number == f_int_names) {
                        d.interned_names += 1;
                    };
                },
                f_pkt_seq_flags => flags = f.int,
                f_pkt_track_event => {
                    is_event = true;
                    d.events += 1;
                    var er: pb.Reader = .{ .buf = f.bytes };
                    var track: u64 = 0;
                    var typ: u64 = 0;
                    while (try er.next()) |x| switch (x.number) {
                        f_te_type => typ = x.int,
                        f_te_track => track = x.int,
                        f_te_flow_ids => {
                            try std.testing.expectEqual(pb.WireType.i64, x.wire);
                            d.flows_out += 1;
                        },
                        f_te_term_flow_ids => d.flows_in += 1,
                        else => {},
                    };
                    switch (typ) {
                        1 => {
                            if (d.begins < d.begin_tracks.len) d.begin_tracks[d.begins] = track;
                            d.begins += 1;
                        },
                        2 => d.ends += 1,
                        4 => d.counters += 1,
                        else => {},
                    }
                },
                else => {},
            };
            if (is_event and d.events == 1) d.first_flags = flags;
        }
    }
};

fn site(comptime name: []const u8) usize {
    return @intFromPtr(zg_core.trace.siteFor(@src(), name));
}

fn smallTrace() [12]Event {
    const z = @intFromEnum(Kind.zone);
    return .{
        .{ .ts = 0, .site_or_name = site("ui"), .kind = @intFromEnum(Kind.thread_name), .tid = 1, .value = 0 },
        .{ .ts = 0, .site_or_name = site("worker"), .kind = @intFromEnum(Kind.thread_name), .tid = 2, .value = 0 },
        // Nested zones on thread 1: outer 1000..5000, inner 2000..3000.
        .{ .ts = 2000, .site_or_name = site("gui.layout"), .kind = z, .tid = 1, .value = 1000 },
        .{ .ts = 1000, .site_or_name = site("gui.frame"), .kind = z, .tid = 1, .value = 4000 },
        .{ .ts = 1500, .site_or_name = site("workspace.scan"), .kind = z, .tid = 2, .value = 500 },
        .{ .ts = 1600, .site_or_name = site("gpu.frame"), .kind = z, .tid = 3, .value = 300 },
        .{ .ts = 2500, .site_or_name = site("perf.frame_cpu_ns"), .kind = @intFromEnum(Kind.counter), .tid = 1, .value = 42 },
        .{ .ts = 1200, .site_or_name = site("ai.request"), .kind = @intFromEnum(Kind.async_begin), .tid = 2, .value = 9 },
        .{ .ts = 4000, .site_or_name = site("ai.request"), .kind = @intFromEnum(Kind.async_end), .tid = 1, .value = 9 },
        // A flow from the worker zone to the inner UI zone.
        .{ .ts = 1700, .site_or_name = site("flow"), .kind = @intFromEnum(Kind.flow_out), .tid = 2, .value = 77 },
        .{ .ts = 2100, .site_or_name = site("flow"), .kind = @intFromEnum(Kind.flow_in), .tid = 1, .value = 77 },
        .{ .ts = 2200, .site_or_name = site("frame"), .kind = @intFromEnum(Kind.instant), .tid = 1, .value = 0 },
    };
}

test "perfetto: small trace structure" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w = Writer.init(gpa, &out.writer, .{ .pid = 42 });
    defer w.deinit();
    const evs = smallTrace();
    try w.writeEvents(&evs);
    try w.finish();
    var d: Dump = .{};
    try d.decode(out.written());
    try std.testing.expectEqual(@as(usize, 2), d.n_thread_names);
    try std.testing.expectEqualStrings("ui", d.thread_names[0]);
    // 4 zones + 1 async = 5 slices, each closed.
    try std.testing.expectEqual(@as(usize, 5), d.begins);
    try std.testing.expectEqual(@as(usize, 5), d.ends);
    try std.testing.expectEqual(@as(usize, 1), d.counters);
    try std.testing.expectEqual(@as(usize, 1), d.flows_out);
    try std.testing.expectEqual(@as(usize, 1), d.flows_in);
    try std.testing.expectEqual(@as(u64, seq_cleared | seq_needs_state), d.first_flags);
    var has_gpu = false;
    var has_counter = false;
    for (d.track_names[0..d.n_track_names]) |n| {
        if (std.mem.eql(u8, n, "GPU")) has_gpu = true;
        if (std.mem.eql(u8, n, "perf.frame_cpu_ns")) has_counter = true;
    }
    try std.testing.expect(has_gpu and has_counter);
    // Bytes per slice event stays small.
    try std.testing.expect(out.written().len < 1200);
}

test "perfetto: interning emits each name once per sequence" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w = Writer.init(gpa, &out.writer, .{});
    defer w.deinit();
    var evs: [100]Event = undefined;
    for (&evs, 0..) |*e, i| e.* = .{ .ts = i * 10, .site_or_name = site("editor.paint"), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = 5 };
    try w.writeEvents(&evs);
    try w.writeEvents(&evs);
    var d: Dump = .{};
    try d.decode(out.written());
    try std.testing.expectEqual(@as(usize, 1), d.interned_names);
    try std.testing.expectEqual(@as(usize, 200), d.begins);
}

test "perfetto: overlapping async ids get separate lanes" {
    const gpa = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w = Writer.init(gpa, &out.writer, .{});
    defer w.deinit();
    const b = @intFromEnum(Kind.async_begin);
    const e = @intFromEnum(Kind.async_end);
    const s = site("lsp.request");
    const evs = [_]Event{
        .{ .ts = 10, .site_or_name = s, .kind = b, .tid = 1, .value = 1 },
        .{ .ts = 20, .site_or_name = s, .kind = b, .tid = 1, .value = 2 },
        .{ .ts = 30, .site_or_name = s, .kind = e, .tid = 1, .value = 1 },
        .{ .ts = 40, .site_or_name = s, .kind = b, .tid = 1, .value = 3 }, // reuses lane 1
        .{ .ts = 50, .site_or_name = s, .kind = e, .tid = 1, .value = 2 },
        .{ .ts = 60, .site_or_name = s, .kind = e, .tid = 1, .value = 3 },
    };
    try w.writeEvents(&evs);
    var d: Dump = .{};
    try d.decode(out.written());
    try std.testing.expectEqual(@as(usize, 3), d.begins);
    try std.testing.expect(d.begin_tracks[0] != d.begin_tracks[1]);
    try std.testing.expectEqual(d.begin_tracks[0], d.begin_tracks[2]);
}

test "fuzz: perfetto random events never produce invalid varints" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [384]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            const gpa = std.testing.allocator;
            const sites = [_]usize{ site("gui.a"), site("ai.request"), site("gpu.x"), site("perf.c_ns") };
            var evs: std.ArrayList(Event) = .empty;
            defer evs.deinit(gpa);
            var i: usize = 0;
            while (i + 6 <= input.len and evs.items.len < 64) : (i += 6) {
                const kind: u8 = input[i] % 9;
                try evs.append(gpa, .{
                    .ts = std.mem.readInt(u16, input[i + 1 ..][0..2], .little),
                    .site_or_name = sites[input[i + 3] % sites.len],
                    .kind = kind,
                    .tid = input[i + 4] % 3,
                    .value = @as(i64, input[i + 5]) - 20,
                });
            }
            var out: Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            var w = Writer.init(gpa, &out.writer, .{});
            defer w.deinit();
            try w.writeEvents(evs.items);
            var d: Dump = .{};
            try d.decode(out.written());
        }
    }.f, .{});
}

/// A synthetic corpus for size and speed checks: `n` zones on four threads,
/// 16 names, nested two deep, at realistic monotonic timestamps.
pub fn syntheticZones(gpa: std.mem.Allocator, n: usize) ![]Event {
    const names = [_][]const u8{
        "gui.frame",       "gui.layout",    "gui.paint",        "gui.input",
        "editor.paint",    "editor.edit",   "editor.highlight", "text.shape",
        "text.layout",     "render.submit", "render.record",    "workspace.scan",
        "workspace.index", "ai.parse",      "lsp.decode",       "scm.status",
    };
    const sites = comptime blk: {
        var out: [names.len]*const Site = undefined;
        for (names, 0..) |nm, i| out[i] = zg_core.trace.siteFor(@src(), nm);
        break :blk out;
    };
    const evs = try gpa.alloc(Event, n);
    var ts: u64 = 183_000_000_000_000;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Every other zone nests inside the previous one on the same thread.
        const tid: u32 = @intCast((i / 2) % 4 + 1);
        const nested = i % 2 == 1;
        const dur: i64 = if (nested) 400 + @as(i64, @intCast(i % 7)) * 30 else 2_000 + @as(i64, @intCast(i % 13)) * 50;
        const start = if (nested) evs[i - 1].ts + 100 else ts;
        evs[i] = .{ .ts = start, .site_or_name = @intFromPtr(sites[(i * 7) % names.len]), .kind = @intFromEnum(Kind.zone), .tid = tid, .value = dur };
        if (!nested) ts += 2_500;
    }
    return evs;
}

test "perfetto: bytes per slice event on the synthetic corpus" {
    const gpa = std.testing.allocator;
    const evs = try syntheticZones(gpa, 20_000);
    defer gpa.free(evs);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var w = Writer.init(gpa, &out.writer, .{});
    defer w.deinit();
    try w.writeEvents(evs);
    const per_slice = @as(f64, @floatFromInt(out.written().len)) / @as(f64, @floatFromInt(w.events_written));
    // 22 bytes on this corpus (packet framing, sequence id and flags take
    // 6 of them); a regression past 24 means a field leaked into every event.
    try std.testing.expect(per_slice <= 24);
    var d: Dump = .{};
    try d.decode(out.written());
    try std.testing.expectEqual(@as(usize, 20_000), d.begins);
}
