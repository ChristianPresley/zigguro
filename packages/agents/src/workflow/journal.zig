//! The workflow replay journal (E13.F08.S01.T04):
//! `.zigguro/runs/<workflow run>/workflow.jsonl` records every child start
//! with its replay key and every result, so a stopped, crashed or edited
//! workflow resumes cheaply (`replay.zig`).
//!
//! Lines: `{"v":1,"seq":N,"t":"start","pos":"…","key":"<hex>","child":"<RunId>"}`
//! and `{"v":1,"seq":N,"t":"result","status":"ok|failed|stopped",
//! "result":{…}|"error":"…"}`. `seq` numbers starts as they happened;
//! `pos` is the agent's place in the plan (`audit#3`, `vote.1`,
//! `fix@2`), which is deterministic even when agents run concurrently and
//! is what resume matches on. Results are fsynced, starts are not; a
//! cut-off last line is dropped on open.

const std = @import("std");
const run = @import("../runs/run.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const RunId = run.RunId;
const Blake3 = std.crypto.hash.Blake3;

pub const file_name = "workflow.jsonl";

/// BLAKE3 over everything that determines an agent's work.
pub const ReplayKey = [32]u8;

/// The key of one agent start: step path (`audit` or `both/security`),
/// map item index, the final prompt text, tools, model, schema and the
/// prompt library entry's body hash. Fields are length-prefixed so no two
/// inputs collide by concatenation.
pub fn replayKey(step_path: []const u8, item: ?u32, prompt: []const u8, tools: []const []const u8, model: ?[]const u8, schema: ?[]const u8, lib_hash: ?u64) ReplayKey {
    var h = Blake3.init(.{});
    field(&h, step_path);
    var ib: [5]u8 = undefined;
    ib[0] = @intFromBool(item != null);
    std.mem.writeInt(u32, ib[1..5], item orelse 0, .little);
    h.update(&ib);
    field(&h, prompt);
    var nb: [4]u8 = undefined;
    std.mem.writeInt(u32, &nb, @intCast(tools.len), .little);
    h.update(&nb);
    for (tools) |t| field(&h, t);
    optField(&h, model);
    optField(&h, schema);
    var lb: [9]u8 = undefined;
    lb[0] = @intFromBool(lib_hash != null);
    std.mem.writeInt(u64, lb[1..9], lib_hash orelse 0, .little);
    h.update(&lb);
    var out: ReplayKey = undefined;
    h.final(&out);
    return out;
}

fn field(h: *Blake3, s: []const u8) void {
    var nb: [8]u8 = undefined;
    std.mem.writeInt(u64, &nb, s.len, .little);
    h.update(&nb);
    h.update(s);
}

fn optField(h: *Blake3, s: ?[]const u8) void {
    h.update(&.{@intFromBool(s != null)});
    field(h, s orelse "");
}

pub const Status = enum { ok, failed, stopped };

pub const Outcome = union(Status) {
    ok: std.json.Value,
    failed: []const u8,
    stopped,
};

pub const Entry = struct {
    seq: u32,
    /// The plan position (owned by the store).
    pos: []const u8,
    key: ReplayKey,
    child: RunId,
    /// Null while the agent has no result (running, or cut off).
    outcome: ?Outcome = null,
};

gpa: Allocator,
io: Io,
/// Owns entry results and strings.
arena: std.heap.ArenaAllocator,
mutex: Io.Mutex = .init,
/// By seq; a gap is an absent entry.
entries: std.ArrayList(?Entry) = .empty,
/// Plan position to seq (the latest start at that position).
by_pos: std.StringHashMapUnmanaged(u32) = .empty,
file: ?Io.File = null,
end: u64 = 0,
/// Lines dropped on open (a cut-off tail).
repaired: u32 = 0,
fsync: bool = true,

const JournalStore = @This();

/// Opens `dir/workflow.jsonl`, creating it, and loads what it holds; new
/// records append. A cut-off or unreadable tail is truncated.
pub fn open(gpa: Allocator, io: Io, dir: Io.Dir) !*JournalStore {
    const j = try init(gpa, io);
    errdefer j.deinit();
    const f = try dir.createFile(io, file_name, .{ .read = true, .truncate = false });
    j.file = f;
    const size = try f.length(io);
    const bytes = try j.arena.allocator().alloc(u8, size);
    const n = try f.readPositionalAll(io, bytes, 0);
    const good = try j.loadBytes(bytes[0..n]);
    if (good < n) try f.setLength(io, good);
    j.end = good;
    return j;
}

/// Creates (truncating) `dir/workflow.jsonl` for a fresh generation.
pub fn create(gpa: Allocator, io: Io, dir: Io.Dir) !*JournalStore {
    const j = try init(gpa, io);
    errdefer j.deinit();
    j.file = try dir.createFile(io, file_name, .{ .read = true, .truncate = true });
    return j;
}

/// Reads `dir/workflow.jsonl` without keeping it open (the previous
/// generation on resume). A missing file is an empty journal.
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir) !*JournalStore {
    const j = try init(gpa, io);
    errdefer j.deinit();
    const bytes = dir.readFileAlloc(io, file_name, j.arena.allocator(), .limited(1 << 30)) catch |e| switch (e) {
        error.FileNotFound => return j,
        else => return e,
    };
    _ = try j.loadBytes(bytes);
    return j;
}

/// A journal kept in memory only.
pub fn memory(gpa: Allocator, io: Io) !*JournalStore {
    return init(gpa, io);
}

fn init(gpa: Allocator, io: Io) !*JournalStore {
    const j = try gpa.create(JournalStore);
    j.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    return j;
}

pub fn deinit(j: *JournalStore) void {
    if (j.file) |f| f.close(j.io);
    j.entries.deinit(j.gpa);
    j.by_pos.deinit(j.gpa);
    j.arena.deinit();
    j.gpa.destroy(j);
}

/// Decodes lines; returns how many bytes were good (whole, parsable
/// lines). Later lines for a seq replace earlier ones.
fn loadBytes(j: *JournalStore, bytes: []const u8) !usize {
    const a = j.arena.allocator();
    var good: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse break;
        const line = bytes[i..nl];
        if (line.len > 0) {
            j.applyLine(a, line) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => break,
            };
        }
        i = nl + 1;
        good = i;
    }
    if (good < bytes.len) j.repaired += 1;
    return good;
}

const Line = struct {
    v: u8 = 1,
    seq: u32,
    t: []const u8,
    pos: ?[]const u8 = null,
    key: ?[]const u8 = null,
    child: ?[]const u8 = null,
    status: ?[]const u8 = null,
    result: ?std.json.Value = null,
    @"error": ?[]const u8 = null,
};

fn applyLine(j: *JournalStore, a: Allocator, line: []const u8) !void {
    const l = try std.json.parseFromSliceLeaky(Line, a, line, .{ .allocate = .alloc_always });
    if (std.mem.eql(u8, l.t, "start")) {
        var key: ReplayKey = undefined;
        const kt = l.key orelse return error.BadLine;
        if (kt.len != 64) return error.BadLine;
        _ = std.fmt.hexToBytes(&key, kt) catch return error.BadLine;
        const child = RunId.parse(l.child orelse return error.BadLine) catch return error.BadLine;
        try j.put(.{ .seq = l.seq, .pos = l.pos orelse return error.BadLine, .key = key, .child = child });
    } else if (std.mem.eql(u8, l.t, "result")) {
        const st = std.meta.stringToEnum(Status, l.status orelse return error.BadLine) orelse return error.BadLine;
        const e = j.slot(l.seq) orelse return error.BadLine;
        e.outcome = switch (st) {
            .ok => .{ .ok = l.result orelse .null },
            .failed => .{ .failed = l.@"error" orelse "" },
            .stopped => .stopped,
        };
    } else return error.BadLine;
}

fn slot(j: *JournalStore, seq: u32) ?*Entry {
    if (seq >= j.entries.items.len) return null;
    if (j.entries.items[seq]) |*e| return e;
    return null;
}

fn put(j: *JournalStore, e: Entry) !void {
    if (e.seq >= j.entries.items.len) try j.entries.appendNTimes(j.gpa, null, e.seq + 1 - j.entries.items.len);
    j.entries.items[e.seq] = e;
    try j.by_pos.put(j.gpa, e.pos, e.seq);
}

/// Records that agent `seq` started at plan position `pos` as `child`
/// with `key`.
pub fn recordStart(j: *JournalStore, seq: u32, pos: []const u8, key: ReplayKey, child: RunId) !void {
    j.mutex.lockUncancelable(j.io);
    defer j.mutex.unlock(j.io);
    try j.put(.{ .seq = seq, .pos = try j.arena.allocator().dupe(u8, pos), .key = key, .child = child });
    var w: std.Io.Writer.Allocating = .init(j.gpa);
    defer w.deinit();
    const hex = std.fmt.bytesToHex(key, .lower);
    try w.writer.print("{{\"v\":1,\"seq\":{d},\"t\":\"start\",\"pos\":", .{seq});
    try std.json.Stringify.value(pos, .{}, &w.writer);
    try w.writer.print(",\"key\":\"{s}\",\"child\":\"{s}\"}}\n", .{ &hex, &child.text() });
    try j.append(w.written(), false);
}

/// Records agent `seq`'s outcome (fsynced).
pub fn recordResult(j: *JournalStore, seq: u32, outcome: Outcome) !void {
    j.mutex.lockUncancelable(j.io);
    defer j.mutex.unlock(j.io);
    const a = j.arena.allocator();
    const e = j.slot(seq) orelse return error.UnknownSeq;
    var w: std.Io.Writer.Allocating = .init(j.gpa);
    defer w.deinit();
    var s: std.json.Stringify = .{ .writer = &w.writer };
    try s.beginObject();
    try s.objectField("v");
    try s.write(1);
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("t");
    try s.write("result");
    try s.objectField("status");
    try s.write(@tagName(outcome));
    switch (outcome) {
        .ok => |v| {
            try s.objectField("result");
            try s.write(v);
        },
        .failed => |msg| {
            try s.objectField("error");
            try s.write(msg);
        },
        .stopped => {},
    }
    try s.endObject();
    try w.writer.writeByte('\n');
    // Keep a copy that outlives the caller's value.
    e.outcome = switch (outcome) {
        .ok => .{ .ok = try std.json.parseFromSliceLeaky(std.json.Value, a, w.written(), .{ .allocate = .alloc_always }) },
        .failed => |msg| .{ .failed = try a.dupe(u8, msg) },
        .stopped => .stopped,
    };
    if (e.outcome.? == .ok) e.outcome.?.ok = e.outcome.?.ok.object.get("result") orelse .null;
    try j.append(w.written(), j.fsync);
}

fn append(j: *JournalStore, bytes: []const u8, sync: bool) !void {
    const f = j.file orelse return;
    try f.writePositionalAll(j.io, bytes, j.end);
    j.end += bytes.len;
    if (sync) try f.sync(j.io);
}

/// Entry `seq`, if recorded. Valid until the store is freed.
pub fn get(j: *JournalStore, seq: u32) ?Entry {
    j.mutex.lockUncancelable(j.io);
    defer j.mutex.unlock(j.io);
    if (seq >= j.entries.items.len) return null;
    return j.entries.items[seq];
}

/// The latest entry started at plan position `pos`.
pub fn atPos(j: *JournalStore, pos: []const u8) ?Entry {
    j.mutex.lockUncancelable(j.io);
    defer j.mutex.unlock(j.io);
    const seq = j.by_pos.get(pos) orelse return null;
    return j.entries.items[seq];
}

/// One past the highest recorded seq.
pub fn len(j: *JournalStore) u32 {
    return @intCast(j.entries.items.len);
}
