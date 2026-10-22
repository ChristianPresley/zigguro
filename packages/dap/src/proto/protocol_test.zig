//! Tests for the generated DAP types (`gen/protocol.zig`) and their JSON
//! support (`json.zig`).

const std = @import("std");
const testing = std.testing;
const options = @import("zg_options");
const protocol = @import("../gen/protocol.zig");
const json = @import("json.zig");
const Value = std.json.Value;

/// Deep JSON equality; numbers compare by value.
fn valueEql(a: Value, b: Value) bool {
    const na = number(a);
    const nb = number(b);
    if (na != null or nb != null) return na != null and nb != null and na.? == nb.?;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!valueEql(p, q)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!valueEql(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        else => unreachable,
    };
}

fn number(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Parses `bytes` as `T`, re-encodes it and checks the result is
/// semantically equal to the input.
fn roundTrip(comptime T: type, gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) !void {
    if (T == void) {
        std.debug.print("{s}: this message has no such payload\n", .{name});
        return error.BadName;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const typed = json.parse(T, a, bytes) catch |err| {
        std.debug.print("{s}: decode as {s} failed: {t}\n", .{ name, @typeName(T), err });
        return err;
    };
    const out = try std.json.Stringify.valueAlloc(a, typed, .{});
    const want = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
    const got = try std.json.parseFromSliceLeaky(Value, a, out, .{});
    if (!valueEql(want, got)) {
        std.debug.print("{s}: round trip differs\n  in:  {s}\n  out: {s}\n", .{ name, std.mem.trim(u8, bytes, "\n"), out });
        return error.TestUnexpectedResult;
    }
}

const Kind = enum { arguments, body, event };

/// Decodes and round-trips one golden payload named
/// `<arguments|body|event>.<command or event>[.<variant>].json`.
fn checkFile(gpa: std.mem.Allocator, file: []const u8, bytes: []const u8) !void {
    var parts = std.mem.splitScalar(u8, file, '.');
    const kind = std.meta.stringToEnum(Kind, parts.next().?) orelse return error.BadName;
    const name = parts.next() orelse return error.BadName;
    switch (kind) {
        .arguments, .body => {
            const c = protocol.command_names.get(name) orelse return error.BadName;
            switch (c) {
                inline else => |cc| {
                    const Info = protocol.RequestInfo(cc);
                    return switch (kind) {
                        .arguments => roundTrip(Info.Arguments, gpa, file, bytes),
                        else => roundTrip(Info.ResponseBody, gpa, file, bytes),
                    };
                },
            }
        },
        .event => {
            const ev = protocol.event_names.get(name) orelse return error.BadName;
            switch (ev) {
                inline else => |ce| return roundTrip(protocol.EventBody(ce), gpa, file, bytes),
            }
        },
    }
}

test "dapgen: roundtrip golden" {
    const io = testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "testdata/protocol", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
        const bytes = try dir.readFileAlloc(io, e.name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        try checkFile(testing.allocator, e.name, bytes);
        n += 1;
    }
    try testing.expect(n >= 15);
}

test "dapgen: open enum preserves unknown value" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try json.parse(protocol.EventBody(.stopped), a, "{\"reason\":\"foo\",\"threadId\":1}");
    try testing.expectEqualStrings("foo", body.reason.other);
    const known = try json.parse(protocol.EventBody(.stopped), a, "{\"reason\":\"function breakpoint\"}");
    try testing.expect(known.reason.is(.@"function breakpoint"));
    // Closed enums absorb unknown values instead of failing.
    const g = try json.parse(protocol.SteppingGranularity, a, "\"opcode\"");
    try testing.expectEqual(protocol.SteppingGranularity._unknown, g);
}

test "dapgen: optional fields omitted when stringified" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args: protocol.InitializeRequestArguments = .{ .adapterID = "lldb-dap", .linesStartAt1 = true };
    try testing.expectEqualStrings("{\"adapterID\":\"lldb-dap\",\"linesStartAt1\":true}", try std.json.Stringify.valueAlloc(a, args, .{}));
    // Required-nullable fields are written as null.
    const info: protocol.RequestInfo(.dataBreakpointInfo).ResponseBody = .{ .dataId = null, .description = "x" };
    try testing.expectEqualStrings("{\"dataId\":null,\"description\":\"x\"}", try std.json.Stringify.valueAlloc(a, info, .{}));
}

test "dapgen: message envelopes carry literal discriminators" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const req: protocol.ContinueRequest = .{ .seq = 4, .arguments = .{ .threadId = 1 } };
    try testing.expectEqualStrings(
        "{\"seq\":4,\"type\":\"request\",\"command\":\"continue\",\"arguments\":{\"threadId\":1}}",
        try std.json.Stringify.valueAlloc(a, req, .{}),
    );
    const ev = try json.parse(protocol.StoppedEvent, a, "{\"seq\":9,\"type\":\"event\",\"event\":\"stopped\",\"body\":{\"reason\":\"step\"}}");
    try testing.expectEqual(@as(i64, 9), ev.seq);
}

test "dapgen: tables" {
    try testing.expect(protocol.RequestInfo(.initialize).ResponseBody == protocol.Capabilities);
    try testing.expect(protocol.RequestInfo(.launch).Arguments == protocol.LaunchRequestArguments);
    try testing.expect(protocol.RequestInfo(.configurationDone).ResponseBody == void);
    try testing.expect(protocol.RequestInfo(.runInTerminal).reverse);
    try testing.expect(protocol.RequestInfo(.startDebugging).reverse);
    try testing.expect(!protocol.RequestInfo(.launch).reverse);
    try testing.expectEqual(protocol.Command.@"continue", protocol.command_names.get("continue").?);
    try testing.expectEqual(protocol.ReverseCommand.runInTerminal, protocol.reverse_command_names.get("runInTerminal").?);
    try testing.expectEqual(protocol.EventKind.progressStart, protocol.event_names.get("progressStart").?);
    try testing.expectEqual(@as(usize, 64), protocol.schema_sha256.len);
    // Every command and event of the schema is in the tables.
    try testing.expectEqual(@as(usize, 45 + 1), @typeInfo(protocol.Command).@"enum".fields.len);
    try testing.expectEqual(@as(usize, 17 + 1), @typeInfo(protocol.EventKind).@"enum".fields.len);
}

test "fuzz: dap protocol decode" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            inline for (@typeInfo(protocol.EventKind).@"enum".fields) |f| {
                const B = protocol.EventBody(@field(protocol.EventKind, f.name));
                if (B != void) {
                    _ = json.parse(B, arena.allocator(), input) catch {};
                    _ = arena.reset(.retain_capacity);
                }
            }
            inline for (@typeInfo(protocol.Command).@"enum".fields) |f| {
                const B = protocol.RequestInfo(@field(protocol.Command, f.name)).ResponseBody;
                if (B != void) {
                    _ = json.parse(B, arena.allocator(), input) catch {};
                    _ = arena.reset(.retain_capacity);
                }
            }
        }
    }.one, .{});
}
