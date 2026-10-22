//! `CallCtx`: what a tool, resource or prompt handler gets besides its
//! arguments (E11.F05.S01.T02): memory, the era, the client's
//! capabilities, cancellation, progress, logs and user input.
//!
//! Input is MRTR-style for both eras: `elicit`, `sample` and `roots`
//! return the answer when this invocation carries it, and otherwise record
//! the request and return `error.InputRequired`, which the dispatcher turns
//! into an `input_required` result with a sealed `requestState` (modern)
//! or into server-to-client requests on the session (legacy,
//! `legacy_requests.zig`) before calling the handler again. Handlers must
//! therefore be re-entrant: free of side effects up to their last input
//! request, or guarded with `once`. `setState` carries private state to
//! the next round (sealed for modern clients).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("../protocol/root.zig");
const Server = @import("Server.zig");
const Hub = @import("subscriptions.zig");

const messages = protocol.messages;
const Revision = protocol.Revision;
const RequestId = protocol.RequestId;

/// Why an input call did not return an answer.
pub const InputError = error{
    /// Recorded; the dispatcher asks the client and calls again.
    InputRequired,
    /// The client did not declare the capability (`missing_capability`
    /// names it); the handler may catch this and degrade.
    CapabilityMissing,
    /// The client refused (a legacy JSON-RPC error answer).
    Declined,
    Canceled,
    OutOfMemory,
};

/// One request being served by user code.
pub const CallCtx = struct {
    server: *Server,
    conn: *Server.Conn,
    /// Request-lifetime memory; results may borrow from it.
    arena: Allocator,
    id: RequestId,
    era: protocol.revision.Era,
    revision: Revision,
    /// What the client declared (per request for modern clients).
    client_caps: protocol.ClientCapabilities = .empty,
    progress_token: ?protocol.ProgressToken = null,
    /// Minimum level of `log` notifications; null sends none.
    log_level: ?messages.LoggingLevel = null,
    canceled: std.atomic.Value(bool) = .init(false),

    /// Answers carried by this invocation.
    input_responses: messages.InputResponses = .{},
    /// Keys the client refused (legacy).
    declined: std.ArrayList([]const u8) = .empty,
    /// Requests recorded by this invocation.
    input_requests: std.ArrayList(messages.InputRequests.Entry) = .empty,
    /// The capability behind the last `CapabilityMissing`.
    missing_capability: ?[]const u8 = null,
    /// The MRTR round this invocation answers (0 for the first).
    round: u8 = 0,
    prev_state: ?[]const u8 = null,
    next_state: ?[]const u8 = null,
    last_progress: ?f64 = null,
    last_progress_at: ?Io.Timestamp = null,

    /// Whether the client cancelled the request (or went away).
    pub fn isCanceled(cc: *const CallCtx) bool {
        return cc.canceled.load(.acquire);
    }

    /// The connection's principal.
    pub fn principal(cc: *const CallCtx) ?[]const u8 {
        return cc.conn.principal;
    }

    /// Progress notifications at most this often.
    pub const progress_interval: Io.Duration = .fromMilliseconds(50);

    /// Reports progress when the client asked for it. Values that do not
    /// increase, and updates within `progress_interval` of the last, are
    /// dropped.
    pub fn progress(cc: *CallCtx, value: f64, total: ?f64, msg: ?[]const u8) void {
        const token = cc.progress_token orelse return;
        if (cc.isCanceled()) return;
        if (cc.last_progress) |l| if (value <= l) return;
        const now = Io.Timestamp.now(cc.server.io, .awake);
        if (cc.last_progress_at) |t| if (t.durationTo(now).nanoseconds < progress_interval.nanoseconds) return;
        cc.last_progress = value;
        cc.last_progress_at = now;
        Hub.sendNotification(cc.conn, .{ .progress = .{ .progress_token = token, .progress = value, .total = total, .message = msg } });
    }

    /// Sends a log notification about this request if `level` is at or
    /// above the requested minimum. Members whose names look secret are
    /// replaced with `"[redacted]"`.
    pub fn log(cc: *CallCtx, level: messages.LoggingLevel, data: Value) void {
        const min = cc.log_level orelse return;
        if (@intFromEnum(level) < @intFromEnum(min)) return;
        if (cc.isCanceled()) return;
        const clean = scrub(cc.arena, data) catch return;
        Hub.sendNotification(cc.conn, .{ .message = .{ .level = level, .logger = cc.server.opts.info.name, .data = clean } });
    }

    /// Asks the user to fill a form or visit a URL.
    pub fn elicit(cc: *CallCtx, key: []const u8, req: messages.ElicitParams) InputError!messages.ElicitResult {
        if (try cc.answered(key)) |r| if (r == .elicitation) return r.elicitation;
        const caps = cc.client_caps;
        switch (req.kind()) {
            // `elicitation: {}` is form mode.
            .form => if (!caps.has("elicitation.form") and !emptyObject(caps.get("elicitation"))) return cc.missing("elicitation.form"),
            .url => if (!caps.has("elicitation.url")) return cc.missing("elicitation.url"),
        }
        return cc.record(key, .{ .elicitation = req });
    }

    /// Asks the client's model for a completion (deprecated in 2026-07-28).
    pub fn sample(cc: *CallCtx, key: []const u8, req: messages.CreateMessageParams) InputError!messages.CreateMessageResult {
        if (try cc.answered(key)) |r| if (r == .sampling) return r.sampling;
        if (!cc.client_caps.has("sampling")) return cc.missing("sampling");
        if (req.tools != null and !cc.client_caps.has("sampling.tools")) return cc.missing("sampling.tools");
        return cc.record(key, .{ .sampling = req });
    }

    /// The client's roots (deprecated in 2026-07-28).
    pub fn roots(cc: *CallCtx, key: []const u8) InputError![]const messages.Root {
        if (try cc.answered(key)) |r| if (r == .roots) return r.roots.roots;
        if (!cc.client_caps.has("roots")) return cc.missing("roots");
        return cc.record(key, .{ .roots = .{} });
    }

    /// The state the handler set in the previous round.
    pub fn state(cc: *const CallCtx) ?[]const u8 {
        return cc.prev_state;
    }

    /// Carries `bytes` to the next round (sealed for modern clients).
    pub fn setState(cc: *CallCtx, bytes: []const u8) void {
        cc.next_state = cc.arena.dupe(u8, bytes) catch null;
    }

    /// True the first time the server sees `nonce` (an LRU of the last
    /// 10,000): at-most-once effects across MRTR rounds, which may be
    /// replayed within the `requestState` expiry.
    pub fn once(cc: *CallCtx, nonce: []const u8) bool {
        return cc.server.consumeOnce(nonce);
    }

    /// A fresh id for a URL elicitation (keep it with `setState` to
    /// complete it in a later round).
    pub fn newElicitationId(cc: *CallCtx) error{OutOfMemory}![]const u8 {
        return @import("legacy_requests.zig").uuid4(cc.arena, cc.server.io);
    }

    /// Ends a URL elicitation the handler started (2025-11-25): sends
    /// `notifications/elicitation/complete`.
    pub fn completeElicitation(cc: *CallCtx, elicitation_id: []const u8) void {
        if (cc.era != .legacy) return;
        Hub.sendNotification(cc.conn, .{ .elicitation_complete = .{ .elicitation_id = elicitation_id } });
    }

    fn answered(cc: *CallCtx, key: []const u8) InputError!?messages.InputResponse {
        if (cc.isCanceled()) return error.Canceled;
        for (cc.declined.items) |k| if (std.mem.eql(u8, k, key)) return error.Declined;
        return cc.input_responses.get(key);
    }

    fn missing(cc: *CallCtx, cap: []const u8) InputError {
        cc.missing_capability = cap;
        return error.CapabilityMissing;
    }

    fn record(cc: *CallCtx, key: []const u8, req: messages.InputRequest) InputError {
        for (cc.input_requests.items) |e| if (std.mem.eql(u8, e.key, key)) return error.InputRequired;
        try cc.input_requests.append(cc.arena, .{ .key = try cc.arena.dupe(u8, key), .value = req });
        return error.InputRequired;
    }
};

fn emptyObject(v: ?Value) bool {
    const x = v orelse return false;
    return x == .object and x.object.count() == 0;
}

const secret_words = [_][]const u8{ "password", "passwd", "secret", "token", "apikey", "api_key", "authorization", "cookie", "credential", "private_key", "privatekey" };

/// Whether member name `k` looks like it holds a secret.
pub fn looksSecret(k: []const u8) bool {
    var buf: [64]u8 = undefined;
    if (k.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, k);
    for (secret_words) |w| if (std.mem.indexOf(u8, lower, w) != null) return true;
    return false;
}

/// A copy of `v` with secret-looking members redacted.
pub fn scrub(a: Allocator, v: Value) Allocator.Error!Value {
    switch (v) {
        .object => |o| {
            var out: std.json.ObjectMap = .empty;
            try out.ensureTotalCapacity(a, o.count());
            var it = o.iterator();
            while (it.next()) |e| out.putAssumeCapacity(e.key_ptr.*, if (looksSecret(e.key_ptr.*)) .{ .string = "[redacted]" } else try scrub(a, e.value_ptr.*));
            return .{ .object = out };
        },
        .array => |arr| {
            var out: std.json.Array = .init(a);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |x| out.appendAssumeCapacity(try scrub(a, x));
            return .{ .array = out };
        },
        else => return v,
    }
}

test "ctx: scrub redacts secret-looking members" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try protocol.codec.parseValue(a, "{\"user\":\"ada\",\"API_KEY\":\"k\",\"nested\":[{\"accessToken\":\"t\",\"n\":1}]}");
    const out = try std.json.Stringify.valueAlloc(a, try scrub(a, v), .{});
    try std.testing.expectEqualStrings("{\"user\":\"ada\",\"API_KEY\":\"[redacted]\",\"nested\":[{\"accessToken\":\"[redacted]\",\"n\":1}]}", out);
}
