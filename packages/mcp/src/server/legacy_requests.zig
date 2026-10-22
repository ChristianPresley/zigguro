//! Server-to-client requests for legacy sessions (E11.F05.S01.T02): when a
//! handler records input requests on a legacy connection, each becomes an
//! `elicitation/create`, `sampling/createMessage` or `roots/list` request
//! on the session (stdout for stdio, the call's stream for HTTP), and the
//! handler runs again in-process with the answers. Nothing is sealed: the
//! state stays in memory. We never answer with `-32042`; we can always ask
//! inline.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const zg_jsonrpc = @import("zg_jsonrpc");
const protocol = @import("../protocol/root.zig");
const Server = @import("Server.zig");
const ctx_mod = @import("ctx.zig");

const messages = protocol.messages;
const codec = protocol.codec;
const message = zg_jsonrpc.message;
const CallCtx = ctx_mod.CallCtx;
const Conn = Server.Conn;

/// A request we sent and its answer.
pub const OutRequest = struct {
    id: u64,
    done: bool = false,
    /// The result JSON (owned by the server's allocator).
    result: ?[]u8 = null,
    err_code: ?i32 = null,
};

const id_prefix = "zg-srv-";

/// Asks the client and waits for its answer, parsed into `cc.arena`.
/// A JSON-RPC error answer is `error.Declined`.
pub fn ask(cc: *CallCtx, method: []const u8, params: anytype) (ctx_mod.InputError || error{ Timeout, ConnectionClosed })!Value {
    const conn = cc.conn;
    const s = conn.server;
    var out: OutRequest = .{ .id = undefined };
    {
        conn.mutex.lockUncancelable(s.io);
        defer conn.mutex.unlock(s.io);
        if (conn.closed) return error.ConnectionClosed;
        out.id = conn.out_next;
        conn.out_next += 1;
        try conn.out_pending.append(s.gpa, &out);
    }
    defer {
        conn.mutex.lockUncancelable(s.io);
        for (conn.out_pending.items, 0..) |p, i| if (p == &out) {
            _ = conn.out_pending.swapRemove(i);
            break;
        };
        conn.mutex.unlock(s.io);
        if (out.result) |r| s.gpa.free(r);
    }
    var idbuf: [32]u8 = undefined;
    const id_str = std.fmt.bufPrint(&idbuf, id_prefix ++ "{d}", .{out.id}) catch unreachable;
    var aw: Io.Writer.Allocating = .init(cc.arena);
    message.writeRequest(&aw.writer, .{ .str = id_str }, method, codec.json(params)) catch return error.OutOfMemory;
    conn.send(aw.written());

    const deadline = Io.Timestamp.now(s.io, .awake).addDuration(s.opts.server_request_timeout);
    while (true) {
        {
            conn.mutex.lockUncancelable(s.io);
            defer conn.mutex.unlock(s.io);
            if (out.done) break;
            if (conn.closed) return error.ConnectionClosed;
        }
        if (cc.isCanceled()) return error.Canceled;
        if (Io.Timestamp.now(s.io, .awake).nanoseconds >= deadline.nanoseconds) return error.Timeout;
        s.io.sleep(.fromMilliseconds(2), .awake) catch return error.Canceled;
    }
    if (out.err_code != null) return error.Declined;
    return codec.parseValue(cc.arena, out.result orelse "{}") catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Declined,
    };
}

/// Routes a client's response to the request waiting for it.
pub fn onResponse(conn: *Conn, r: message.Response) void {
    const s = conn.server;
    const str = switch (r.id) {
        .str => |x| x,
        else => return,
    };
    if (!std.mem.startsWith(u8, str, id_prefix)) return;
    const id = std.fmt.parseInt(u64, str[id_prefix.len..], 10) catch return;
    const result: ?[]u8 = if (r.result) |res| s.gpa.dupe(u8, res.bytes) catch return else null;
    conn.mutex.lockUncancelable(s.io);
    defer conn.mutex.unlock(s.io);
    for (conn.out_pending.items) |p| if (p.id == id and !p.done) {
        p.done = true;
        p.result = result;
        if (r.err) |e| p.err_code = e.code;
        return;
    };
    if (result) |x| s.gpa.free(x);
}

/// Resolves `cc`'s recorded input requests on the session: answers go to
/// `input_responses`, refusals to `declined`.
pub fn roundTrip(cc: *CallCtx) ctx_mod.InputError!void {
    var entries: std.ArrayList(messages.InputResponses.Entry) = .empty;
    try entries.appendSlice(cc.arena, cc.input_responses.entries);
    for (cc.input_requests.items) |e| {
        var req = e.value;
        if (req == .elicitation and req.elicitation.kind() == .url and req.elicitation.elicitation_id == null and
            protocol.revision.has(cc.revision, .elicitation_url))
            req.elicitation.elicitation_id = try uuid4(cc.arena, cc.server.io);
        if (req == .unknown) {
            try cc.declined.append(cc.arena, e.key);
            continue;
        }
        const v = switch (req) {
            .unknown => unreachable,
            inline else => |p| ask(cc, req.method(), p),
        } catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try cc.declined.append(cc.arena, e.key);
                continue;
            },
        };
        const resp: ?messages.InputResponse = switch (req) {
            .elicitation => if (codec.decodeFromValue(messages.ElicitResult, cc.arena, v, .{})) |x| .{ .elicitation = x } else |_| null,
            .sampling => if (codec.decodeFromValue(messages.CreateMessageResult, cc.arena, v, .{})) |x| .{ .sampling = x } else |_| null,
            .roots => if (codec.decodeFromValue(messages.ListRootsResult, cc.arena, v, .{})) |x| .{ .roots = x } else |_| null,
            .unknown => null,
        };
        if (resp) |x| {
            try entries.append(cc.arena, .{ .key = e.key, .value = x });
        } else try cc.declined.append(cc.arena, e.key);
    }
    cc.input_responses = .{ .entries = entries.items };
    cc.input_requests.clearRetainingCapacity();
}

/// A random (version 4) UUID, for 2025-11-25 URL elicitation ids.
pub fn uuid4(a: Allocator, io: Io) Allocator.Error![]u8 {
    var b: [16]u8 = undefined;
    io.randomSecure(&b) catch io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = std.fmt.bytesToHex(b, .lower);
    return std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] });
}

test "legacy requests: uuid4 shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const u = try uuid4(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(36, u.len);
    try std.testing.expectEqual('4', u[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", u[19]) != null);
}
