//! Fuzz target `mcp_codec`: random bytes decoded as every result type.

const std = @import("std");
const zg_core = @import("zg_core");
const codec = @import("codec.zig");
const M = @import("messages.zig");
const testing = std.testing;

test "fuzz: mcp codec" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const body = buf[0..s.slice(&buf)];
            inline for (comptime std.enums.values(M.Method)) |m| {
                var arena: std.heap.ArenaAllocator = .init(testing.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                var diag: codec.Diagnostic = .{};
                if (codec.decodeResult(M.ResultType(m), a, .{ .bytes = body }, .{ .allow_task = true, .diag = &diag })) |d| {
                    // Whatever decodes must re-encode.
                    _ = try codec.encodeAlloc(a, d);
                } else |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => {},
                }
                _ = codec.decodeParams(M.ParamsType(m), a, .{ .bytes = body }, .{}) catch {};
            }
        }
    }.one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "mcp_codec") });
}
