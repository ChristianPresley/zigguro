//! Request ids and progress tokens.

const std = @import("std");
const zg_jsonrpc = @import("zg_jsonrpc");
const codec = @import("codec.zig");
const Value = std.json.Value;
const Stringify = std.json.Stringify;

/// A JSON-RPC request id: an integer or a string. MCP forbids `null` ids on
/// requests (BASIC "Requests"); `null` appears only in error responses to
/// unreadable requests. Never an f64.
pub const RequestId = zg_jsonrpc.message.Id;

/// A progress token: an integer or a string chosen by the requester.
pub const ProgressToken = union(enum) {
    int: i64,
    str: []const u8,

    /// Codec hook: accepts a JSON integer or string.
    pub fn jsonDecode(ctx: *codec.Ctx, v: Value) codec.DecodeError!ProgressToken {
        return switch (v) {
            .integer => |i| .{ .int = i },
            .string => |s| .{ .str = s },
            else => ctx.fail(error.TypeMismatch),
        };
    }

    /// Codec hook.
    pub fn jsonEncode(t: ProgressToken, s: *Stringify) Stringify.Error!void {
        switch (t) {
            .int => |i| try s.write(i),
            .str => |x| try s.write(x),
        }
    }

    /// Value equality.
    pub fn eql(a: ProgressToken, b: ProgressToken) bool {
        return switch (a) {
            .int => |x| b == .int and b.int == x,
            .str => |x| b == .str and std.mem.eql(u8, x, b.str),
        };
    }
};

/// Decodes a request id; `null` is rejected unless `allow_null`.
pub fn decodeId(ctx: *codec.Ctx, v: Value, allow_null: bool) codec.DecodeError!RequestId {
    return switch (v) {
        .integer => |i| .{ .int = i },
        .string => |s| .{ .str = s },
        .null => if (allow_null) .null else ctx.fail(error.TypeMismatch),
        else => ctx.fail(error.TypeMismatch),
    };
}
