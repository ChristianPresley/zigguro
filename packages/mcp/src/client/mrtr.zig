//! The MRTR retry engine (E11.F03.S03.T01): `runWithInput` sends a
//! request that may need user input and answers it through the server's
//! `InputBroker` (see `input.zig` for the sequence).
//!
//! `Client.request` owns the loop itself: each `input_required` round is
//! checked (method allowed, every key's method declared), answered here,
//! and retried with a new id and progress token, the original params,
//! `inputResponses` and `requestState` byte for byte. Here the keys of a
//! round are resolved concurrently, failed keys are omitted (the server
//! re-asks), and the outer cancel token reaches every pending resolution.
//! A legacy `tools/call` failing with `-32042` presents its URL
//! elicitations, waits for their completion notifications and retries
//! once.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol/root.zig");
const Client = @import("Client.zig");
const request = @import("request.zig");
const input = @import("input.zig");

const M = protocol.messages;
const Method = protocol.Method;
const ServerInput = input.ServerInput;
const RequestError = request.RequestError;

/// Sends `Mt` to `si`'s client, resolving input requests through its
/// broker. `o.input` is replaced; `o.cancel` (or a private token) also
/// cancels pending prompts.
pub fn runWithInput(si: *ServerInput, comptime Mt: Method, params: M.ParamsType(Mt), o: request.CallOptions) RequestError!M.ResultType(Mt) {
    const c = si.client orelse return error.ConnectionClosed;
    var own_token: request.CancelToken = .init(si.io);
    var info_local: request.ErrorInfo = .{};
    var opts = o;
    if (opts.cancel == null) opts.cancel = &own_token;
    if (opts.error_info == null) opts.error_info = &info_local;
    const origin: input.Origin = .{
        .method = Mt,
        .name = nameOf(Mt, params),
        .principal = si.opts.principal,
        .cancel = opts.cancel.?,
    };
    try si.pushActive(&origin);
    defer si.popActive(&origin);
    var round: Round = .{ .si = si, .origin = &origin };
    defer round.deinit();
    opts.input = .{ .ctx = &round, .func = Round.answer };

    var url_retried = false;
    while (true) {
        return c.request(Mt, params, opts) catch |err| {
            const info = opts.error_info.?;
            if (Mt == .tools_call and err == error.ServerError and !url_retried and
                info.code == protocol.errors.url_elicitation_required)
            {
                url_retried = true;
                try urlElicitations(si, &origin, info.data, opts.arena);
                continue;
            }
            return err;
        };
    }
}

fn nameOf(comptime Mt: Method, params: M.ParamsType(Mt)) ?[]const u8 {
    const P = M.ParamsType(Mt);
    if (@hasField(P, "name")) return params.name;
    if (@hasField(P, "uri")) return params.uri;
    return null;
}

/// The state of one call's input rounds: per-key arenas live until the
/// call returns (the retry encodes the answers from them).
const Round = struct {
    si: *ServerInput,
    origin: *const input.Origin,
    slots: std.ArrayList([]Slot) = .empty,

    const Slot = struct {
        arena: std.heap.ArenaAllocator,
        resp: input.InputResponse = .{ .failed = "not admitted" },
        admitted: bool = false,

        fn run(slot: *Slot, si: *ServerInput, ic: input.InputContext, req: input.InputRequest) Io.Cancelable!void {
            slot.resp = si.resolveAdmitted(ic, req, slot.arena.allocator());
        }
    };

    fn deinit(r: *Round) void {
        for (r.slots.items) |ss| for (ss) |*s| s.arena.deinit();
        r.slots.deinit(r.si.gpa);
    }

    fn answer(ctx: ?*anyopaque, arena: Allocator, reqs: M.InputRequests) anyerror!?M.InputResponses {
        const r: *Round = @ptrCast(@alignCast(ctx.?));
        const si = r.si;
        const n = reqs.entries.len;
        const slots = try arena.alloc(Slot, n);
        for (slots) |*s| s.* = .{ .arena = .init(si.gpa) };
        r.slots.append(si.gpa, slots) catch |err| {
            for (slots) |*s| s.arena.deinit();
            return err;
        };
        const values = try arena.alloc(input.InputRequest, n);
        for (reqs.entries, values) |e, *v| v.* = e.value;
        const ok = try arena.alloc(bool, n);
        si.admit(values, ok);

        // Independent dialogs can show together; the host may serialize.
        var group: Io.Group = .init;
        for (reqs.entries, slots, ok) |e, *slot, admitted| {
            if (!admitted) {
                slot.resp = .{ .failed = "rate limited" };
                continue;
            }
            const ic = si.context(r.origin.*, e.key, r.origin.cancel);
            group.concurrent(si.io, Slot.run, .{ slot, si, ic, e.value }) catch
                Slot.run(slot, si, ic, e.value) catch {};
        }
        group.await(si.io) catch |err| {
            r.origin.cancel.cancel("canceled");
            group.cancel(si.io);
            return err;
        };
        if (r.origin.cancel.isCanceled()) return error.Canceled;

        var out: std.ArrayList(M.InputResponses.Entry) = .empty;
        for (reqs.entries, slots) |e, slot| {
            const v: M.InputResponse = switch (slot.resp) {
                .failed => continue,
                .elicitation => |x| .{ .elicitation = x },
                .sampling => |x| .{ .sampling = x },
                .roots => |x| .{ .roots = x },
            };
            try out.append(arena, .{ .key = e.key, .value = v });
        }
        return .{ .entries = out.items };
    }
};

/// The legacy `-32042` flow: every URL elicitation must be accepted, then
/// completed by the server, before the single retry.
fn urlElicitations(si: *ServerInput, origin: *const input.Origin, data: ?std.json.Value, arena: Allocator) RequestError!void {
    const d = data orelse return error.ProtocolViolation;
    const parsed = protocol.codec.decodeFromValue(protocol.errors.UrlElicitationRequiredData, arena, d, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProtocolViolation,
    };
    const els = parsed.elicitations;
    const reqs = try arena.alloc(input.InputRequest, els.len);
    for (els, reqs) |e, *q| q.* = .{ .elicitation = e };
    const ok = try arena.alloc(bool, els.len);
    si.admit(reqs, ok);
    var all = true;
    for (els, reqs, ok) |e, q, admitted| {
        if (!admitted) {
            all = false;
            continue;
        }
        if (!all or e.kind() != .url) {
            si.release();
            all = false;
            continue;
        }
        const ic = si.context(origin.*, e.elicitation_id orelse "", origin.cancel);
        const resp = si.resolveAdmitted(ic, q, arena);
        if (resp != .elicitation or resp.elicitation.action != .accept) all = false;
    }
    if (origin.cancel.isCanceled()) return error.Canceled;
    if (!all) return error.InputDeclined;

    const deadline = Io.Timestamp.now(si.io, .awake).addDuration(si.opts.url_completion_timeout);
    for (els) |e| {
        const id = e.elicitation_id orelse continue;
        while (!si.takeCompleted(id)) {
            if (origin.cancel.isCanceled()) return error.Canceled;
            if (Io.Timestamp.now(si.io, .awake).nanoseconds >= deadline.nanoseconds) return error.Timeout;
            si.io.sleep(.fromMilliseconds(10), .awake) catch return error.Canceled;
        }
    }
}
