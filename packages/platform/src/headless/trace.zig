//! `.zgtrace` input traces: a recorded `Event` sequence that replays
//! byte-identically on every OS.
//!
//! Layout (little-endian throughout): magic `ZGTR`, `u16` version, then
//! records. Each record is a `u32` length of what follows, then `u8` event
//! tag, `u64` nanoseconds since the previous record, the event's fields in
//! declaration order, a `u32` payload length and the payload bytes (every
//! `PayloadSlice` of the event, concatenated in field order). Fields are
//! written one by one, never as raw memory, so padding never leaks into a
//! trace: integers at their byte-rounded width, floats as their bits, bools
//! and optionals' presence as one byte, packed structs as their backing
//! integer, and a `PayloadSlice` as its `u32` length. Pointers never appear
//! in events, so nothing else needs rewriting on replay.

const std = @import("std");
const Event = @import("../api/event.zig").Event;
const PayloadSlice = @import("../api/types.zig").PayloadSlice;
const forEachPayload = @import("../queue/payload_arena.zig").forEachPayload;

/// The file magic.
pub const magic = "ZGTR";
/// The format version this code writes and reads.
pub const version: u16 = 1;

/// Errors from reading a trace.
pub const ReadError = error{
    /// The magic or version is wrong.
    BadHeader,
    /// A record is malformed or truncated.
    BadRecord,
} || std.Io.Reader.Error || std.mem.Allocator.Error;

/// Writes the file header.
pub fn writeHeader(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(magic);
    try w.writeInt(u16, version, .little);
}

/// Reads and checks the file header.
pub fn readHeader(r: *std.Io.Reader) ReadError!void {
    var m: [4]u8 = undefined;
    r.readSliceAll(&m) catch |e| return if (e == error.EndOfStream) error.BadHeader else e;
    if (!std.mem.eql(u8, &m, magic)) return error.BadHeader;
    const v = r.takeInt(u16, .little) catch |e| return if (e == error.EndOfStream) error.BadHeader else e;
    if (v != version) return error.BadHeader;
}

/// Writes one record. `payloads` holds the bytes of each non-large or large
/// `PayloadSlice` in `ev`, in field order (see `forEachPayload`); each
/// length must match its slice.
pub fn record(w: *std.Io.Writer, t_ns_rel: u64, ev: Event, payloads: []const []const u8) std.Io.Writer.Error!void {
    var payload_len: usize = 0;
    for (payloads) |p| payload_len += p.len;
    var counter: std.Io.Writer.Discarding = .init(&.{});
    encodeEvent(&counter.writer, ev) catch unreachable;
    const fixed_len = counter.fullCount();
    const len = 1 + 8 + fixed_len + 4 + payload_len;
    try w.writeInt(u32, @intCast(len), .little);
    try w.writeByte(@intFromEnum(std.meta.activeTag(ev)));
    try w.writeInt(u64, t_ns_rel, .little);
    try encodeEvent(w, ev);
    try w.writeInt(u32, @intCast(payload_len), .little);
    for (payloads) |p| try w.writeAll(p);
}

/// One decoded record. `payloads` slices point into memory from the `gpa`
/// passed to `next`; `ev`'s `PayloadSlice`s carry lengths only.
pub const Record = struct {
    /// Nanoseconds since the previous record.
    t_ns_rel: u64,
    /// The event, with payload offsets zeroed.
    ev: Event,
    /// All payload bytes, concatenated in field order.
    payload: []u8,
};

/// Reads the next record, or null at the end of the trace. The caller
/// frees `payload` with `gpa`.
pub fn next(r: *std.Io.Reader, gpa: std.mem.Allocator) ReadError!?Record {
    const len = r.takeInt(u32, .little) catch |e| switch (e) {
        error.EndOfStream => return null,
        else => |x| return x,
    };
    const body = r.readAlloc(gpa, len) catch |e| return if (e == error.EndOfStream) error.BadRecord else e;
    defer gpa.free(body);
    var br: std.Io.Reader = .fixed(body);
    return decodeRecord(&br, gpa) catch |e| switch (e) {
        error.EndOfStream => error.BadRecord,
        else => |x| x,
    };
}

fn decodeRecord(br: *std.Io.Reader, gpa: std.mem.Allocator) (ReadError || error{EndOfStream})!Record {
    const tag_int = try br.takeByte();
    const t = try br.takeInt(u64, .little);
    const Tag = std.meta.Tag(Event);
    const tag = std.enums.fromInt(Tag, tag_int) orelse return error.BadRecord;
    var ev: Event = undefined;
    switch (tag) {
        inline else => |k| {
            const P = @FieldType(Event, @tagName(k));
            ev = @unionInit(Event, @tagName(k), try decodeValue(P, br));
        },
    }
    const plen = try br.takeInt(u32, .little);
    var sum: usize = 0;
    forEachPayload(&ev, &sum, struct {
        fn add(s: *usize, p: PayloadSlice) void {
            s.* += p.len;
        }
    }.add);
    if (sum != plen or br.bufferedLen() != plen) return error.BadRecord;
    const payload = try gpa.dupe(u8, br.buffered());
    return .{ .t_ns_rel = t, .ev = ev, .payload = payload };
}

/// Writes `ev`'s fields (not its tag) in trace encoding.
pub fn encodeEvent(w: *std.Io.Writer, ev: Event) std.Io.Writer.Error!void {
    switch (ev) {
        inline else => |payload| try encodeValue(@TypeOf(payload), w, payload),
    }
}

fn Wire(comptime T: type) type {
    const info = @typeInfo(T).int;
    return std.meta.Int(info.signedness, std.mem.alignForward(u16, info.bits, 8));
}

fn encodeValue(comptime T: type, w: *std.Io.Writer, v: T) std.Io.Writer.Error!void {
    if (T == PayloadSlice) return w.writeInt(u32, v.len, .little);
    switch (@typeInfo(T)) {
        .void => {},
        .bool => try w.writeByte(@intFromBool(v)),
        .int => if (@bitSizeOf(T) > 0) try w.writeInt(Wire(T), v, .little),
        .float => try w.writeInt(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(v), .little),
        .@"enum" => |e| try encodeValue(e.tag_type, w, @intFromEnum(v)),
        .optional => |o| if (v) |x| {
            try w.writeByte(1);
            try encodeValue(o.child, w, x);
        } else try w.writeByte(0),
        .array => |a| for (v) |x| try encodeValue(a.child, w, x),
        .@"struct" => |s| {
            if (s.layout == .@"packed") return encodeValue(s.backing_integer.?, w, @bitCast(v));
            inline for (s.fields) |f| try encodeValue(f.type, w, @field(v, f.name));
        },
        else => @compileError("type cannot appear in a trace: " ++ @typeName(T)),
    }
}

fn decodeValue(comptime T: type, r: *std.Io.Reader) (ReadError || error{EndOfStream})!T {
    if (T == PayloadSlice) return .{ .len = try r.takeInt(u32, .little) };
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return switch (try r.takeByte()) {
            0 => false,
            1 => true,
            else => error.BadRecord,
        },
        .int => {
            if (@bitSizeOf(T) == 0) return 0;
            return std.math.cast(T, try r.takeInt(Wire(T), .little)) orelse error.BadRecord;
        },
        .float => return @bitCast(try r.takeInt(std.meta.Int(.unsigned, @bitSizeOf(T)), .little)),
        .@"enum" => |e| {
            const raw = try decodeValue(e.tag_type, r);
            if (!e.is_exhaustive) return @enumFromInt(raw);
            return std.enums.fromInt(T, raw) orelse error.BadRecord;
        },
        .optional => |o| return switch (try r.takeByte()) {
            0 => null,
            1 => try decodeValue(o.child, r),
            else => error.BadRecord,
        },
        .array => |a| {
            var out: T = undefined;
            for (&out) |*x| x.* = try decodeValue(a.child, r);
            return out;
        },
        .@"struct" => |s| {
            if (s.layout == .@"packed") return @bitCast(try decodeValue(s.backing_integer.?, r));
            var out: T = undefined;
            inline for (s.fields) |f| @field(out, f.name) = try decodeValue(f.type, r);
            return out;
        },
        else => @compileError("type cannot appear in a trace: " ++ @typeName(T)),
    }
}

/// Fills an event of a random kind with random field values and payload
/// lengths below `max_payload`. For fuzzing and the round-trip tests.
pub fn randomEvent(rand: std.Random, max_payload: u32) Event {
    const fields = @typeInfo(Event).@"union".fields;
    const pick = rand.uintLessThan(usize, fields.len);
    inline for (fields, 0..) |f, i| {
        if (i == pick) return @unionInit(Event, f.name, randomValue(f.type, rand, max_payload));
    }
    unreachable;
}

fn randomValue(comptime T: type, rand: std.Random, max_payload: u32) T {
    if (T == PayloadSlice) return .{ .len = rand.uintLessThan(u32, max_payload + 1) };
    switch (@typeInfo(T)) {
        .void => return {},
        .bool => return rand.boolean(),
        .int => return rand.int(T),
        .float => return @floatCast(rand.float(f64) * 4096 - 2048),
        .@"enum" => |e| {
            if (e.fields.len == 0) return @enumFromInt(rand.int(e.tag_type));
            const k = rand.uintLessThan(usize, e.fields.len);
            inline for (e.fields, 0..) |f, i| if (i == k) return @enumFromInt(f.value);
            unreachable;
        },
        .optional => |o| return if (rand.boolean()) randomValue(o.child, rand, max_payload) else null,
        .array => |a| {
            var out: T = undefined;
            for (&out) |*x| x.* = randomValue(a.child, rand, max_payload);
            return out;
        },
        .@"struct" => |s| {
            var out: T = undefined;
            inline for (s.fields) |f| {
                @field(out, f.name) = if (comptime std.mem.startsWith(u8, f.name, "_")) 0 else randomValue(f.type, rand, max_payload);
            }
            return out;
        },
        else => @compileError("unsupported: " ++ @typeName(T)),
    }
}

const testing = std.testing;

test "encode/decode roundtrip of random events" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeHeader(&aw.writer);
    var events: [500]Event = undefined;
    var bytes: [256]u8 = undefined;
    for (&events, 0..) |*e, i| {
        e.* = randomEvent(rand, 32);
        var parts: [4][]const u8 = undefined;
        var n: usize = 0;
        const Ctx = struct { parts: *[4][]const u8, n: *usize, bytes: []u8 };
        forEachPayload(e, Ctx{ .parts = &parts, .n = &n, .bytes = &bytes }, struct {
            fn f(c: Ctx, s: PayloadSlice) void {
                c.parts[c.n.*] = c.bytes[0..s.len];
                c.n.* += 1;
            }
        }.f);
        @memset(&bytes, @truncate(i));
        try record(&aw.writer, i, e.*, parts[0..n]);
    }
    var r: std.Io.Reader = .fixed(aw.written());
    try readHeader(&r);
    for (events, 0..) |e, i| {
        const rec = (try next(&r, testing.allocator)).?;
        defer testing.allocator.free(rec.payload);
        try testing.expectEqual(@as(u64, i), rec.t_ns_rel);
        var a: std.Io.Writer.Allocating = .init(testing.allocator);
        defer a.deinit();
        var b: std.Io.Writer.Allocating = .init(testing.allocator);
        defer b.deinit();
        try encodeEvent(&a.writer, e);
        try encodeEvent(&b.writer, rec.ev);
        try testing.expectEqualSlices(u8, a.written(), b.written());
        for (rec.payload) |c| try testing.expectEqual(@as(u8, @truncate(i)), c);
    }
    try testing.expectEqual(null, try next(&r, testing.allocator));
}

test "bad header and truncated record are rejected" {
    var r: std.Io.Reader = .fixed("ZGTX\x01\x00");
    try testing.expectError(error.BadHeader, readHeader(&r));
    var r2: std.Io.Reader = .fixed("\x05\x00\x00\x00\x00\x01");
    try testing.expectError(error.BadRecord, next(&r2, testing.allocator));
    var r3: std.Io.Reader = .fixed("\x03\x00\x00\x00\xff\x00\x00");
    try testing.expectError(error.BadRecord, next(&r3, testing.allocator));
}

test "fuzz: trace reader never crashes" {
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            @memcpy(buf[0..6], magic ++ "\x01\x00");
            const input = buf[0 .. 6 + sm.slice(buf[6..])];
            var r: std.Io.Reader = .fixed(input);
            try readHeader(&r);
            while (true) {
                const rec = next(&r, testing.allocator) catch return orelse return;
                testing.allocator.free(rec.payload);
            }
        }
    }.one, .{});
}
