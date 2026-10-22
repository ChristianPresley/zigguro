//! Work-done and partial-result progress (`$/progress`) for every server.
//!
//! A token is usable once the server created it
//! (`window/workDoneProgress/create`) or the client issued it (a
//! `workDoneToken` / `partialResultToken` in one of its requests); progress
//! for any other token is dropped. Partial-result tokens forward each
//! value to the owning request's sink; work-done tokens move through
//! begin, report and end and reach the listeners as `ProgressEvent`s.
//!
//! Reports are coalesced to at most one per `min_interval` (100 ms) per
//! server; begin and end are always delivered. Listeners and sinks run on
//! the reader loop without the tracker lock held. Thread-safe.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("../gen/protocol.zig");
const ServerId = @import("host.zig").ServerId;

const log = std.log.scoped(.lsp);

pub const ProgressKind = enum { begin, report, end };

pub const ProgressEvent = struct {
    server: ServerId,
    token: protocol.ProgressToken,
    kind: ProgressKind,
    /// The begin title (repeated on report and end).
    title: ?[]const u8 = null,
    message: ?[]const u8 = null,
    percentage: ?u32 = null,
    cancellable: ?bool = null,
};

pub const ProgressListener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, e: ProgressEvent) void,
};

/// Receives the partial results of one request, as JSON text valid during
/// the call.
pub const PartialSink = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, value_json: []const u8) void,
};

/// Sends `window/workDoneProgress/cancel` for a server.
pub const Canceler = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, token: protocol.ProgressToken) void,
};

const TokenState = enum { created, issued, active };

const Token = struct {
    state: TokenState,
    /// The token as the server knows it (owned).
    token: protocol.ProgressToken,
    title: ?[]u8 = null,
    cancellable: bool = false,
};

const Server = struct {
    active: u32 = 0,
    last_emit_ns: ?i96 = null,
    canceler: ?Canceler = null,
};

pub const ProgressTracker = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    /// By `key(server, token)` (owned keys).
    tokens: std.StringHashMapUnmanaged(Token) = .empty,
    partials: std.StringHashMapUnmanaged(PartialSink) = .empty,
    servers: std.AutoHashMapUnmanaged(ServerId, Server) = .empty,
    listeners: std.ArrayList(ProgressListener) = .empty,
    next_issued: u64 = 1,
    min_interval: Io.Duration = .fromMilliseconds(100),

    pub fn init(gpa: Allocator, io: Io) ProgressTracker {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(t: *ProgressTracker) void {
        var it = t.tokens.iterator();
        while (it.next()) |kv| {
            t.gpa.free(kv.key_ptr.*);
            t.freeToken(kv.value_ptr);
        }
        t.tokens.deinit(t.gpa);
        var pit = t.partials.keyIterator();
        while (pit.next()) |k| t.gpa.free(k.*);
        t.partials.deinit(t.gpa);
        t.servers.deinit(t.gpa);
        t.listeners.deinit(t.gpa);
        t.* = undefined;
    }

    fn freeToken(t: *ProgressTracker, tok: *Token) void {
        if (tok.title) |s| t.gpa.free(s);
        if (tok.token == .string) t.gpa.free(tok.token.string);
    }

    /// Adds a listener. Call before progress flows.
    pub fn subscribe(t: *ProgressTracker, l: ProgressListener) !void {
        try t.listeners.append(t.gpa, l);
    }

    /// Starts tracking `server`; `canceler` sends its cancel notification.
    pub fn addServer(t: *ProgressTracker, server: ServerId, canceler: ?Canceler) !void {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        try t.servers.put(t.gpa, server, .{ .canceler = canceler });
    }

    /// Forgets `server` (it stopped or crashed): its active progress ends.
    pub fn removeServer(t: *ProgressTracker, server: ServerId) void {
        var ended: std.ArrayList(ProgressEvent) = .empty;
        defer ended.deinit(t.gpa);
        var titles: std.ArrayList([]u8) = .empty;
        defer {
            for (titles.items) |s| t.gpa.free(s);
            titles.deinit(t.gpa);
        }
        var strings: std.ArrayList([]const u8) = .empty;
        defer {
            for (strings.items) |s| t.gpa.free(s);
            strings.deinit(t.gpa);
        }
        {
            t.mutex.lockUncancelable(t.io);
            defer t.mutex.unlock(t.io);
            _ = t.servers.remove(server);
            var doomed: std.ArrayList([]const u8) = .empty;
            defer doomed.deinit(t.gpa);
            var it = t.tokens.iterator();
            while (it.next()) |kv| if (keyServer(kv.key_ptr.*) == server) {
                doomed.append(t.gpa, kv.key_ptr.*) catch continue;
            };
            for (doomed.items) |k| {
                const kv = t.tokens.fetchRemove(k).?;
                var tok = kv.value;
                if (tok.state == .active) ended.append(t.gpa, .{ .server = server, .token = tok.token, .kind = .end, .title = tok.title }) catch {};
                if (tok.title) |s| titles.append(t.gpa, s) catch t.gpa.free(s);
                if (tok.token == .string) strings.append(t.gpa, tok.token.string) catch t.gpa.free(tok.token.string);
                tok.title = null;
                t.gpa.free(kv.key);
            }
            doomed.clearRetainingCapacity();
            var pit = t.partials.keyIterator();
            while (pit.next()) |k| if (keyServer(k.*) == server) doomed.append(t.gpa, k.*) catch continue;
            for (doomed.items) |k| {
                _ = t.partials.remove(k);
                t.gpa.free(k);
            }
        }
        for (ended.items) |e| t.emit(e);
    }

    /// `window/workDoneProgress/create` from `server`.
    pub fn create(t: *ProgressTracker, server: ServerId, token: protocol.ProgressToken) !void {
        try t.addToken(server, token, .created);
    }

    /// Issues a work-done or partial-result token for one of the client's
    /// requests; the string lives in `buf`. `release` it when the request
    /// is done.
    pub fn issue(t: *ProgressTracker, server: ServerId, buf: *[32]u8) !protocol.ProgressToken {
        t.mutex.lockUncancelable(t.io);
        const n = t.next_issued;
        t.next_issued += 1;
        t.mutex.unlock(t.io);
        const tok: protocol.ProgressToken = .{ .string = std.fmt.bufPrint(buf, "zg/{d}", .{n}) catch unreachable };
        try t.addToken(server, tok, .issued);
        return tok;
    }

    /// Forgets a client-issued token and its partial sink.
    pub fn release(t: *ProgressTracker, server: ServerId, token: protocol.ProgressToken) void {
        var kbuf: [key_max]u8 = undefined;
        const k = key(&kbuf, server, token) orelse return;
        var ended: ?ProgressEvent = null;
        var tok_copy: ?Token = null;
        {
            t.mutex.lockUncancelable(t.io);
            defer t.mutex.unlock(t.io);
            if (t.partials.fetchRemove(k)) |kv| t.gpa.free(kv.key);
            if (t.tokens.fetchRemove(k)) |kv| {
                t.gpa.free(kv.key);
                if (kv.value.state == .active) {
                    if (t.servers.getPtr(server)) |s| s.active -|= 1;
                    ended = .{ .server = server, .token = kv.value.token, .kind = .end, .title = kv.value.title };
                }
                tok_copy = kv.value;
            }
        }
        if (ended) |e| t.emit(e);
        if (tok_copy) |*tc| t.freeToken(tc);
    }

    /// Routes `$/progress` values for `token` to `sink` (a request's
    /// `partialResultToken`).
    pub fn addPartial(t: *ProgressTracker, server: ServerId, token: protocol.ProgressToken, sink: PartialSink) !void {
        var kbuf: [key_max]u8 = undefined;
        const k = key(&kbuf, server, token) orelse return error.TokenTooLong;
        const owned = try t.gpa.dupe(u8, k);
        errdefer t.gpa.free(owned);
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const gop = try t.partials.getOrPut(t.gpa, owned);
        if (gop.found_existing) t.gpa.free(owned);
        gop.value_ptr.* = sink;
    }

    fn addToken(t: *ProgressTracker, server: ServerId, token: protocol.ProgressToken, st: TokenState) !void {
        var kbuf: [key_max]u8 = undefined;
        const k = key(&kbuf, server, token) orelse return error.TokenTooLong;
        const owned = try t.gpa.dupe(u8, k);
        errdefer t.gpa.free(owned);
        var tok: Token = .{ .state = st, .token = token };
        if (token == .string) tok.token = .{ .string = try t.gpa.dupe(u8, token.string) };
        errdefer t.freeToken(&tok);
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        const gop = try t.tokens.getOrPut(t.gpa, owned);
        if (gop.found_existing) {
            // A server re-creating a live token restarts it.
            t.gpa.free(owned);
            if (gop.value_ptr.state == .active) if (t.servers.getPtr(server)) |s| {
                s.active -|= 1;
            };
            t.freeToken(gop.value_ptr);
        }
        gop.value_ptr.* = tok;
    }

    /// Handles one `$/progress` notification from `server`.
    pub fn onProgress(t: *ProgressTracker, server: ServerId, params_json: []const u8, arena: Allocator) void {
        const P = struct { token: protocol.ProgressToken, value: Value };
        const p = std.json.parseFromSliceLeaky(P, arena, params_json, .{ .ignore_unknown_fields = true }) catch {
            log.debug("$/progress: bad params", .{});
            return;
        };
        var kbuf: [key_max]u8 = undefined;
        const k = key(&kbuf, server, p.token) orelse return;

        t.mutex.lockUncancelable(t.io);
        if (t.partials.get(k)) |sink| {
            t.mutex.unlock(t.io);
            const text = std.json.Stringify.valueAlloc(arena, p.value, .{}) catch return;
            sink.func(sink.ctx, text);
            return;
        }
        var ev = t.workDone(server, k, p.value) catch null;
        // The event must not point into the tracker once unlocked.
        if (ev) |*e| {
            e.token = p.token;
            e.title = if (e.title) |s| arena.dupe(u8, s) catch null else null;
        }
        t.mutex.unlock(t.io);
        if (ev) |e| {
            t.emit(e);
            if (e.kind == .end) t.finishEnd(server, p.token);
        }
    }

    /// Applies a work-done value under the lock; returns the event to emit.
    fn workDone(t: *ProgressTracker, server: ServerId, k: []const u8, v: Value) !?ProgressEvent {
        const tok = t.tokens.getPtr(k) orelse {
            log.debug("$/progress for unknown token", .{});
            return null;
        };
        if (v != .object) return null;
        const o = v.object;
        const kind_v = o.get("kind") orelse return null;
        if (kind_v != .string) return null;
        const kind = std.meta.stringToEnum(ProgressKind, kind_v.string) orelse return null;
        const srv = t.servers.getPtr(server);
        var ev: ProgressEvent = .{
            .server = server,
            .token = tok.token,
            .kind = kind,
            .message = str(o.get("message")),
            .percentage = pct(o.get("percentage")),
        };
        switch (kind) {
            .begin => {
                if (tok.state == .active) return null;
                tok.state = .active;
                if (srv) |s| s.active += 1;
                if (str(o.get("title"))) |title| tok.title = try t.gpa.dupe(u8, title);
                tok.cancellable = boolean(o.get("cancellable")) orelse false;
                ev.cancellable = tok.cancellable;
            },
            .report => {
                if (tok.state != .active) return null;
                if (boolean(o.get("cancellable"))) |c| tok.cancellable = c;
                ev.cancellable = boolean(o.get("cancellable"));
                if (srv) |s| if (s.last_emit_ns) |last| {
                    if (t.now() - last < t.min_interval.nanoseconds) return null;
                };
            },
            .end => {
                if (tok.state != .active) return null;
                tok.state = .created;
                if (srv) |s| s.active -|= 1;
            },
        }
        ev.title = tok.title;
        if (srv) |s| s.last_emit_ns = t.now();
        return ev;
    }

    /// After an end event: a server-created token is done for good.
    fn finishEnd(t: *ProgressTracker, server: ServerId, token: protocol.ProgressToken) void {
        var kbuf: [key_max]u8 = undefined;
        const k = key(&kbuf, server, token) orelse return;
        t.mutex.lockUncancelable(t.io);
        var removed: ?std.StringHashMapUnmanaged(Token).KV = null;
        if (t.tokens.get(k)) |tok| if (tok.state == .created) {
            removed = t.tokens.fetchRemove(k);
        };
        t.mutex.unlock(t.io);
        if (removed) |*kv| {
            t.gpa.free(kv.key);
            t.freeToken(&kv.value);
        }
    }

    fn emit(t: *ProgressTracker, e: ProgressEvent) void {
        for (t.listeners.items) |l| l.func(l.ctx, e);
    }

    fn now(t: *ProgressTracker) i96 {
        return Io.Clock.Timestamp.now(t.io, .awake).raw.nanoseconds;
    }

    /// Work-done progress running on `server` (settle detection).
    pub fn activeCount(t: *ProgressTracker, server: ServerId) u32 {
        t.mutex.lockUncancelable(t.io);
        defer t.mutex.unlock(t.io);
        return if (t.servers.get(server)) |s| s.active else 0;
    }

    /// Asks `server` to cancel `token` (`window/workDoneProgress/cancel`),
    /// if it is active and cancellable.
    pub fn cancel(t: *ProgressTracker, server: ServerId, token: protocol.ProgressToken) void {
        var kbuf: [key_max]u8 = undefined;
        const k = key(&kbuf, server, token) orelse return;
        t.mutex.lockUncancelable(t.io);
        const ok = if (t.tokens.get(k)) |tok| tok.state == .active and tok.cancellable else false;
        const c = if (t.servers.get(server)) |s| s.canceler else null;
        t.mutex.unlock(t.io);
        if (ok) if (c) |cn| cn.func(cn.ctx, token);
    }
};

const key_max = 512;

/// `<server>:i<n>` or `<server>:s<string>`; null if too long.
fn key(buf: *[key_max]u8, server: ServerId, token: protocol.ProgressToken) ?[]const u8 {
    return switch (token) {
        .integer => |n| std.fmt.bufPrint(buf, "{d}:i{d}", .{ server, n }),
        .string => |s| std.fmt.bufPrint(buf, "{d}:s{s}", .{ server, s }),
    } catch null;
}

fn keyServer(k: []const u8) ?ServerId {
    const colon = std.mem.indexOfScalar(u8, k, ':') orelse return null;
    return std.fmt.parseInt(ServerId, k[0..colon], 10) catch null;
}

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn boolean(v: ?Value) ?bool {
    const x = v orelse return null;
    return if (x == .bool) x.bool else null;
}

fn pct(v: ?Value) ?u32 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |n| @intCast(std.math.clamp(n, 0, 100)),
        .float => |f| @intFromFloat(std.math.clamp(f, 0, 100)),
        else => null,
    };
}
