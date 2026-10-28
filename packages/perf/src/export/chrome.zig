//! The Chrome Trace Event Format writer (E14.F02.S01.T01): JSON Object
//! Format with metadata, complete slices, counters, async spans and flows,
//! streamed to a `std.Io.Writer` without building a DOM. Opens in Perfetto
//! and `chrome://tracing`.

const std = @import("std");
const zg_core = @import("zg_core");
const redact_mod = @import("redact.zig");
const Category = @import("../trace/categories.zig").Category;

const Event = zg_core.trace.Event;
const Kind = zg_core.trace.Kind;
const Site = zg_core.trace.Site;
const Writer = std.Io.Writer;

/// Trace-wide metadata.
pub const Meta = struct {
    pid: i32 = 1,
    process_name: []const u8 = "zigguro",
    redact: redact_mod.Redact = .none,
};

fn siteName(e: Event) []const u8 {
    const s: *const Site = @ptrFromInt(e.site_or_name);
    return s.name;
}

fn sortIndex(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "ui")) return 0;
    if (std.mem.eql(u8, name, "render")) return 1;
    if (std.mem.eql(u8, name, "platform")) return 2;
    return 10;
}

fn writeString(w: *Writer, s: []const u8, redact: redact_mod.Redact) Writer.Error!void {
    if (redact == .paths and redact_mod.isPath(s)) {
        var buf: [512]u8 = undefined;
        return std.json.Stringify.encodeJsonString(redact_mod.redactInto(&buf, s), .{}, w);
    }
    return std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

/// Writes `events` (from `zg_core.trace.collect`) as a Chrome JSON trace.
pub fn writeChrome(gpa: std.mem.Allocator, events: []const Event, meta: Meta, out: *Writer) !void {
    _ = gpa;
    try out.writeAll("{\"displayTimeUnit\":\"ns\",\"otherData\":{\"generator\":\"zigguro zg_perf\"},\"traceEvents\":[\n");
    try out.print("{{\"ph\":\"M\",\"name\":\"process_name\",\"pid\":{d},\"tid\":0,\"args\":{{\"name\":", .{meta.pid});
    try writeString(out, meta.process_name, .none);
    try out.writeAll("}}");
    for (events) |e| {
        const k: Kind = @enumFromInt(e.kind);
        const name = siteName(e);
        try out.writeAll(",\n");
        switch (k) {
            .thread_name => {
                try out.print("{{\"ph\":\"M\",\"name\":\"thread_name\",\"pid\":{d},\"tid\":{d},\"args\":{{\"name\":", .{ meta.pid, e.tid });
                try writeString(out, name, meta.redact);
                try out.print("}}}},\n{{\"ph\":\"M\",\"name\":\"thread_sort_index\",\"pid\":{d},\"tid\":{d},\"args\":{{\"sort_index\":{d}}}}}", .{ meta.pid, e.tid, sortIndex(name) });
            },
            .zone => {
                try out.writeAll("{\"ph\":\"X\",\"name\":");
                try writeString(out, name, meta.redact);
                try out.print(",\"cat\":\"{t}\",\"ts\":{d:.3},\"dur\":{d:.3},\"pid\":{d},\"tid\":{d}}}", .{ Category.ofName(name), us(e.ts), us(@intCast(@max(0, e.value))), meta.pid, e.tid });
            },
            .counter => {
                try out.writeAll("{\"ph\":\"C\",\"name\":");
                try writeString(out, name, meta.redact);
                try out.print(",\"ts\":{d:.3},\"pid\":{d},\"tid\":{d},\"args\":{{\"value\":{d}}}}}", .{ us(e.ts), meta.pid, e.tid, e.value });
            },
            .instant => {
                try out.writeAll("{\"ph\":\"i\",\"s\":\"t\",\"name\":");
                try writeString(out, name, meta.redact);
                try out.print(",\"ts\":{d:.3},\"pid\":{d},\"tid\":{d}}}", .{ us(e.ts), meta.pid, e.tid });
            },
            .async_begin, .async_end, .async_instant => {
                const ph: []const u8 = switch (k) {
                    .async_begin => "b",
                    .async_end => "e",
                    else => "n",
                };
                try out.print("{{\"ph\":\"{s}\",\"name\":", .{ph});
                try writeString(out, name, meta.redact);
                try out.print(",\"cat\":\"{t}\",\"id2\":{{\"local\":\"0x{x}\"}},\"ts\":{d:.3},\"pid\":{d},\"tid\":{d}}}", .{ Category.ofName(name), @as(u64, @bitCast(e.value)), us(e.ts), meta.pid, e.tid });
            },
            .flow_out, .flow_in => {
                const ph: []const u8 = if (k == .flow_out) "s" else "f";
                try out.print("{{\"ph\":\"{s}\",\"name\":\"flow\",\"cat\":\"flow\",\"id\":\"0x{x}\",\"ts\":{d:.3},\"pid\":{d},\"tid\":{d}", .{ ph, @as(u64, @bitCast(e.value)), us(e.ts), meta.pid, e.tid });
                if (k == .flow_in) try out.writeAll(",\"bp\":\"e\"");
                try out.writeAll("}");
            },
        }
    }
    try out.writeAll("\n]}\n");
}

fn site(comptime name: []const u8) usize {
    return @intFromPtr(zg_core.trace.siteFor(@src(), name));
}

test "chrome: parses with std.json and phases valid" {
    const gpa = std.testing.allocator;
    const evs = [_]Event{
        .{ .ts = 0, .site_or_name = site("ui"), .kind = @intFromEnum(Kind.thread_name), .tid = 1, .value = 0 },
        .{ .ts = 1000, .site_or_name = site("gui.frame"), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = 4000 },
        .{ .ts = 2000, .site_or_name = site("gui.layout"), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = 1000 },
        .{ .ts = 2500, .site_or_name = site("perf.c"), .kind = @intFromEnum(Kind.counter), .tid = 1, .value = -3 },
        .{ .ts = 2600, .site_or_name = site("frame"), .kind = @intFromEnum(Kind.instant), .tid = 1, .value = 0 },
        .{ .ts = 1200, .site_or_name = site("ai.request"), .kind = @intFromEnum(Kind.async_begin), .tid = 2, .value = 9 },
        .{ .ts = 1300, .site_or_name = site("ai.first_token"), .kind = @intFromEnum(Kind.async_instant), .tid = 2, .value = 9 },
        .{ .ts = 4000, .site_or_name = site("ai.request"), .kind = @intFromEnum(Kind.async_end), .tid = 2, .value = 9 },
        .{ .ts = 1700, .site_or_name = site("flow"), .kind = @intFromEnum(Kind.flow_out), .tid = 2, .value = 77 },
        .{ .ts = 2100, .site_or_name = site("flow"), .kind = @intFromEnum(Kind.flow_in), .tid = 1, .value = 77 },
    };
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeChrome(gpa, &evs, .{}, &out.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("traceEvents").?.array.items;
    const valid = "MXCibenst f";
    var seen_x: usize = 0;
    for (arr) |ev| {
        const ph = ev.object.get("ph").?.string;
        try std.testing.expect(ph.len == 1 and std.mem.indexOfScalar(u8, valid, ph[0]) != null);
        if (ph[0] == 'X') seen_x += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen_x);
    try std.testing.expectEqual(@as(usize, 1 + 2 + 9), arr.len);
}

test "chrome: X events nest per thread" {
    const gpa = std.testing.allocator;
    const evs = [_]Event{
        .{ .ts = 2000, .site_or_name = site("gui.layout"), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = 1000 },
        .{ .ts = 1000, .site_or_name = site("gui.frame"), .kind = @intFromEnum(Kind.zone), .tid = 1, .value = 4000 },
    };
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeChrome(gpa, &evs, .{ .redact = .paths }, &out.writer);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, out.written(), .{});
    defer parsed.deinit();
    const arr = parsed.value.object.get("traceEvents").?.array.items;
    const inner = arr[1].object;
    const outer = arr[2].object;
    const in_ts = inner.get("ts").?.float;
    const in_end = in_ts + inner.get("dur").?.float;
    const out_ts = outer.get("ts").?.float;
    try std.testing.expect(out_ts <= in_ts and in_end <= out_ts + outer.get("dur").?.float);
}
