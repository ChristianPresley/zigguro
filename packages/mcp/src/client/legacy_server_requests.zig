//! Legacy server-to-client requests through the InputBroker
//! (E11.F03.S03.T01): `sampling/createMessage`, `elicitation/create` and
//! `roots/list` arrive as JSON-RPC requests (`ping` is the client's own),
//! `notifications/elicitation/complete` ends a URL elicitation, and we send
//! `notifications/roots/list_changed` when the workspace roots change.
//!
//! A request is tied to the single call in flight when there is exactly
//! one (2025-11-25 `io.modelcontextprotocol/related-task` correlation
//! waits for tasks, F03.S04); otherwise its origin is unknown. Its prompt
//! is canceled when that call ends.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol/root.zig");
const Client = @import("Client.zig");
const request = @import("request.zig");
const input = @import("input.zig");

const Value = std.json.Value;
const ServerInput = input.ServerInput;

/// JSON-RPC code for a request the user (or the rate limit) refused,
/// as in the sampling spec's "User rejected sampling request".
pub const user_rejected: i32 = -1;

pub fn handler(si: *ServerInput) Client.ServerRequestHandler {
    return .{ .ctx = si, .func = serverRequest };
}

fn serverRequest(ctx: ?*anyopaque, arena: Allocator, method: []const u8, params: ?Value) anyerror!Client.ServerReply {
    const si: *ServerInput = @ptrCast(@alignCast(ctx.?));
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, "method", .{ .string = method });
    if (params) |p| try obj.put(arena, "params", p);
    const req = protocol.codec.decodeFromValue(protocol.messages.InputRequest, arena, .{ .object = obj }, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return .{ .err = .{ .code = protocol.errors.invalid_params, .message = "Invalid params" } },
    };
    if (req == .unknown) return .{ .err = .{ .code = protocol.errors.method_not_found, .message = "Method not found" } };

    var ok: [1]bool = undefined;
    si.admit(&.{req}, &ok);
    if (!ok[0]) return .{ .err = .{ .code = user_rejected, .message = "Too many requests for user input" } };

    const active = si.soleActive(arena) catch |err| {
        si.release();
        return err;
    };
    var token: request.CancelToken = .init(si.io);
    si.addPending(.{ .origin = if (active) |a| a.ptr else null, .token = &token }) catch |err| {
        si.release();
        return err;
    };
    defer si.removePending(&token);
    const resp = si.resolveAdmitted(si.context(if (active) |a| a.copy else null, method, &token), req, arena);
    return switch (resp) {
        .failed => |why| .{ .err = .{ .code = user_rejected, .message = why } },
        inline else => |v| .{ .result = try protocol.codec.encodeAlloc(arena, v) },
    };
}

pub fn onNotification(si: *ServerInput, n: protocol.Notification) void {
    if (n != .elicitation_complete) return;
    const id = n.elicitation_complete.elicitation_id;
    si.noteCompleted(id);
    if (si.broker.elicitationComplete) |f| f(si.broker.ctx, si.opts.server_id, id);
}

pub fn rootsChanged(si: *ServerInput) request.RequestError!void {
    const c = si.client orelse return;
    const info = c.serverInfo();
    // Deprecated in 2026-07-28: only legacy sessions declared `roots.listChanged`.
    if (info.era != .legacy or !c.opts.features.roots) return;
    try c.notify(.{ .roots_list_changed = .{} });
}
