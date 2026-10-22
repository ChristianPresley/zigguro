//! User input for MCP servers (E11.F03.S03): one `InputBroker`, which the
//! host implements, answers every request a server makes for input:
//! modern MRTR `inputRequests` (`mrtr.zig`), legacy server-to-client
//! requests (`legacy_server_requests.zig`) and legacy `-32042` URL
//! elicitations. It is the only path from zg_mcp to the user.
//!
//! A modern call that needs input (MRTR "Client Requirements"):
//!
//! ```text
//! host        runWithInput            server          broker (host UI)
//!  |  call -----> |  tools/call id=1 ----> |                 |
//!  |              | <-- input_required ---  |                 |
//!  |              |     {inputRequests: {a: elicit, b: sample},
//!  |              |      requestState: S}   |                 |
//!  |              |  check a, b declared    |                 |
//!  |              |  admit (rate limit)     |                 |
//!  |              |  resolve(a) ---------------------------->  |  dialogs
//!  |              |  resolve(b) ---------------------------->  |  (together)
//!  |              | <------------------- answers / failures -- |
//!  |              |  tools/call id=2 ----> |   new id, same params,
//!  |              |    {inputResponses: {a, b minus failed},  |
//!  |              |     requestState: S byte for byte}         |
//!  |              | <-- complete --------- |                 |
//!  | <- result -- |                        |                 |
//! ```
//!
//! Safety (ELICIT "Security"): the broker always learns which server asks
//! (`InputContext.server_id`), so the UI shows it. Each server may have at
//! most `max_open` input requests open and must wait `min_prompt_interval`
//! between prompts (the keys of one round count as one prompt); the excess
//! is declined and logged. zg_mcp never accepts an elicitation by itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol/root.zig");
const Client = @import("Client.zig");
const request = @import("request.zig");

const M = protocol.messages;
const CancelToken = request.CancelToken;
const log = std.log.scoped(.mcp_input);

/// What a server asks for: `sampling`, `elicitation` (form or URL) or
/// `roots` (`unknown` is never passed to the broker).
pub const InputRequest = M.InputRequest;

/// The broker's answer. A user's decline of an elicitation is an
/// `elicitation` answer with `action = decline`; `failed` means the
/// request could not be answered at all (modern: the key is omitted from
/// `inputResponses`; legacy: a JSON-RPC error).
pub const InputResponse = union(enum) {
    elicitation: M.ElicitResult,
    sampling: M.CreateMessageResult,
    roots: M.ListRootsResult,
    failed: []const u8,
};

/// Who started the call that needs input.
pub const Principal = enum { user, agent };

/// Where an input request comes from; the UI must show `server_id`.
pub const InputContext = struct {
    /// The configured server name.
    server_id: []const u8,
    server_info: ?protocol.Implementation,
    /// The call the request belongs to; null when unknown (legacy requests
    /// outside or among several calls).
    origin_method: ?protocol.Method,
    /// The tool or prompt name, or the resource URI.
    origin_name: ?[]const u8,
    principal: Principal,
    /// The `inputRequests` key (modern), the request method (legacy) or the
    /// elicitation id (`-32042`).
    key: []const u8,
    /// Fires when the call is canceled or over: stop waiting for the user.
    cancel: *CancelToken,
};

/// The host's side. `resolve` runs on a worker task: it posts UI and
/// blocks until the user answers or `ic.cancel` fires. Memory comes from
/// `arena`.
pub const InputBroker = struct {
    ctx: ?*anyopaque,
    resolve: *const fn (ctx: ?*anyopaque, ic: InputContext, req: InputRequest, arena: Allocator) anyerror!InputResponse,
    /// Legacy URL mode: the server reports the out-of-band step finished.
    elicitationComplete: ?*const fn (ctx: ?*anyopaque, server_id: []const u8, elicitation_id: []const u8) void = null,
};

/// The call input is resolved for; lives on `runWithInput`'s stack.
pub const Origin = struct {
    method: protocol.Method,
    name: ?[]const u8,
    principal: Principal,
    cancel: *CancelToken,
};

/// Input handling for one server: the broker, the rate limit and the
/// calls in flight. Initialise in place before `Client.connect` (its
/// handlers go into the options), then `attach`. Must not move.
pub const ServerInput = struct {
    pub const Options = struct {
        /// The configured server name; must outlive `self`.
        server_id: []const u8,
        principal: Principal = .agent,
        max_open: u32 = 5,
        min_prompt_interval: Io.Duration = .fromSeconds(1),
        /// How long the `-32042` flow waits for `notifications/elicitation/complete`.
        url_completion_timeout: Io.Duration = .fromSeconds(300),
    };

    /// A legacy request's cancel token, canceled when its call ends.
    const Pending = struct { origin: ?*const Origin, token: *CancelToken };

    gpa: Allocator,
    io: Io,
    broker: InputBroker,
    opts: Options,
    client: ?*Client = null,
    mutex: Io.Mutex = .init,
    open: u32 = 0,
    last_prompt: ?Io.Timestamp = null,
    /// Input requests declined by the rate limit.
    declined: u32 = 0,
    active: std.ArrayList(*const Origin) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    /// Recently completed URL elicitation ids (bounded).
    completed: std.ArrayList([]u8) = .empty,

    const max_completed = 64;

    pub fn init(self: *ServerInput, gpa: Allocator, io: Io, broker: InputBroker, opts: Options) void {
        self.* = .{ .gpa = gpa, .io = io, .broker = broker, .opts = opts };
    }

    /// Requests using `self` must have returned.
    pub fn deinit(self: *ServerInput) void {
        for (self.completed.items) |id| self.gpa.free(id);
        self.completed.deinit(self.gpa);
        self.active.deinit(self.gpa);
        self.pending.deinit(self.gpa);
    }

    /// Binds the connected client.
    pub fn attach(self: *ServerInput, c: *Client) void {
        self.client = c;
    }

    /// For `Client.Options.on_server_request`: legacy sampling,
    /// elicitation and roots requests go to the broker.
    pub fn serverRequestHandler(self: *ServerInput) Client.ServerRequestHandler {
        return legacy.handler(self);
    }

    /// For `Client.Options.on_notification`, or call `onNotification` from
    /// the host's own handler.
    pub fn notificationHandler(self: *ServerInput) Client.NotificationHandler {
        return .{ .ctx = self, .func = notificationThunk };
    }

    fn notificationThunk(ctx: ?*anyopaque, n: protocol.Notification) void {
        const self: *ServerInput = @ptrCast(@alignCast(ctx.?));
        self.onNotification(n);
    }

    /// Handles `notifications/elicitation/complete`; ignores the rest.
    pub fn onNotification(self: *ServerInput, n: protocol.Notification) void {
        legacy.onNotification(self, n);
    }

    /// The host's workspace roots changed: tells a legacy server that
    /// declared interest (`roots.listChanged`).
    pub fn rootsChanged(self: *ServerInput) request.RequestError!void {
        return legacy.rootsChanged(self);
    }

    /// Admits a batch of input requests (one round or one legacy request):
    /// `ok[i]` says whether `reqs[i]` may reach the broker.
    pub fn admit(self: *ServerInput, reqs: []const InputRequest, ok: []bool) void {
        const now = Io.Timestamp.now(self.io, .awake);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var prompts = false;
        for (reqs) |r| prompts = prompts or r != .roots;
        const too_soon = prompts and if (self.last_prompt) |t|
            t.durationTo(now).nanoseconds < self.opts.min_prompt_interval.nanoseconds
        else
            false;
        if (prompts and !too_soon) self.last_prompt = now;
        for (reqs, ok) |r, *o| {
            o.* = !(too_soon and r != .roots) and self.open < self.opts.max_open;
            if (o.*) {
                self.open += 1;
            } else {
                self.declined += 1;
                log.info("{s}: {s} declined ({s})", .{ self.opts.server_id, r.method(), if (too_soon) "less than the minimum interval since the last prompt" else "too many open input requests" });
            }
        }
    }

    /// Calls the broker for an admitted request and releases its slot.
    pub fn resolveAdmitted(self: *ServerInput, ic: InputContext, req: InputRequest, arena: Allocator) InputResponse {
        defer self.release();
        if (req == .unknown) return .{ .failed = "unsupported input request" };
        return self.broker.resolve(self.broker.ctx, ic, req, arena) catch |err| .{ .failed = @errorName(err) };
    }

    /// A context for `key` in `origin`.
    pub fn context(self: *ServerInput, origin: ?Origin, key: []const u8, cancel: *CancelToken) InputContext {
        return .{
            .server_id = self.opts.server_id,
            .server_info = if (self.client) |c| c.serverInfo().server_info else null,
            .origin_method = if (origin) |o| o.method else null,
            .origin_name = if (origin) |o| o.name else null,
            .principal = if (origin) |o| o.principal else self.opts.principal,
            .key = key,
            .cancel = cancel,
        };
    }

    pub fn pushActive(self: *ServerInput, o: *const Origin) Allocator.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.active.append(self.gpa, o);
    }

    /// Ends `o`: legacy prompts it started are canceled.
    pub fn popActive(self: *ServerInput, o: *const Origin) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.active.items, 0..) |a, i| if (a == o) {
            _ = self.active.swapRemove(i);
            break;
        };
        for (self.pending.items) |*p| if (p.origin == o) {
            p.token.cancel("the call ended");
            p.origin = null;
        };
    }

    /// The single call in flight and a copy of it in `arena` (legacy
    /// correlation).
    pub const Active = struct { ptr: *const Origin, copy: Origin };

    pub fn soleActive(self: *ServerInput, arena: Allocator) Allocator.Error!?Active {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active.items.len != 1) return null;
        const p = self.active.items[0];
        var o = p.*;
        if (o.name) |n| o.name = try arena.dupe(u8, n);
        return .{ .ptr = p, .copy = o };
    }

    /// Releases an admitted slot that never reached the broker.
    pub fn release(self: *ServerInput) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.open -= 1;
    }

    pub fn addPending(self: *ServerInput, p: Pending) Allocator.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // The origin may have ended while the request was being decoded.
        if (p.origin) |o| if (std.mem.indexOfScalar(*const Origin, self.active.items, o) == null) p.token.cancel("the call ended");
        try self.pending.append(self.gpa, p);
    }

    pub fn removePending(self: *ServerInput, token: *CancelToken) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.pending.items, 0..) |p, i| if (p.token == token) {
            _ = self.pending.swapRemove(i);
            return;
        };
    }

    /// Records a completed URL elicitation.
    pub fn noteCompleted(self: *ServerInput, id: []const u8) void {
        const copy = self.gpa.dupe(u8, id) catch return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.completed.items.len == max_completed) self.gpa.free(self.completed.orderedRemove(0));
        self.completed.append(self.gpa, copy) catch self.gpa.free(copy);
    }

    /// Whether `id` completed; forgets it if so.
    pub fn takeCompleted(self: *ServerInput, id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.completed.items, 0..) |c, i| if (std.mem.eql(u8, c, id)) {
            self.gpa.free(self.completed.orderedRemove(i));
            return true;
        };
        return false;
    }
};

const legacy = @import("legacy_server_requests.zig");

const testing = std.testing;

test "input: admission limits open requests and prompt interval" {
    var si: ServerInput = undefined;
    si.init(testing.allocator, testing.io, .{ .ctx = null, .resolve = undefined }, .{ .server_id = "s", .min_prompt_interval = .fromSeconds(60) });
    defer si.deinit();
    const elicit: InputRequest = .{ .elicitation = .{ .message = "?" } };
    const roots: InputRequest = .{ .roots = .{} };
    var ok: [6]bool = undefined;
    si.admit(&.{ elicit, elicit, elicit, elicit, elicit, elicit }, &ok);
    try testing.expectEqualSlices(bool, &.{ true, true, true, true, true, false }, &ok);
    si.open = 0;
    // A second prompt inside the interval is declined; roots are not prompts.
    si.admit(&.{ elicit, roots }, ok[0..2]);
    try testing.expectEqualSlices(bool, &.{ false, true }, ok[0..2]);
    try testing.expectEqual(2, si.declined);
}
