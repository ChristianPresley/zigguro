//! A scripted MCP server on an `InProcPair`, for client tests until the F08
//! conformance mock lands. It records every message it receives and answers
//! according to its `Mode`:
//!
//! - `modern`: `server/discover` succeeds (2026-07-28); `initialize` is
//!   `-32601`.
//! - `legacy`: `server/discover` is `-32601`; `initialize` succeeds.
//! - `silent_discover`: `server/discover` is never answered.
//! - `version_error`: `server/discover` is `-32022` listing only 2025-11-25.
//!
//! Tools (`tools/call` by name): `echo` answers at once, `hang` never
//! answers, `progress` never answers but sends progress every 20 ms,
//! `needcap` fails with `-32021`, `ask` returns `input_required` until
//! called with `inputResponses`. `tools/list` with `ping_first` set sends a
//! `ping` to the client and answers once the client replied (legacy).
//! A test's `script` sees requests (after era detection) and responses
//! first, and may answer them itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_jsonrpc = @import("zg_jsonrpc");
const InProcPair = @import("../transport/in_process.zig");
const Transport = @import("../transport/Transport.zig");

const message = zg_jsonrpc.message;
const Value = std.json.Value;

/// How the server answers `server/discover`.
pub const Mode = enum { modern, legacy, silent_discover, version_error };

/// One received message.
pub const Received = struct {
    method: []const u8,
    /// Request id (null for notifications and responses).
    id: ?i64,
    body: []const u8,
};

/// What a `Script` sees.
pub const Event = union(enum) {
    request: struct { id: i64, method: []const u8, params: Value },
    /// A response from the client to a server request.
    response: struct { body: []const u8 },
};

/// Test-specific behaviour; `func` returns true when it handled `ev`.
pub const Script = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, srv: *MockServer, pair: *InProcPair, ev: Event) bool,
};

/// The server. Initialise in place (`init`); the pair points into it.
pub const MockServer = struct {
    gpa: Allocator,
    io: Io,
    pair: InProcPair,
    mode: Mode,
    /// What `initialize` answers with.
    legacy_version: []const u8 = "2025-11-25",
    /// `tools/list` pings the client before answering.
    ping_first: bool = false,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    log: std.ArrayList(Received) = .empty,
    initialized: bool = false,
    /// Requests other than `initialize`/`ping` received before
    /// `notifications/initialized` (legacy modes).
    violations: u32 = 0,
    ping_answered: bool = false,
    pending_list: ?i64 = null,
    /// One-shot: the next request with this method fails with `err`.
    fail_next: ?struct { method: []const u8, err: Transport.TransportError } = null,
    tasks: Io.Group = .init,
    script: ?Script = null,

    /// Starts a server in `mode`.
    pub fn init(self: *MockServer, gpa: Allocator, io: Io, mode: Mode) void {
        self.* = .{ .gpa = gpa, .io = io, .pair = .init(gpa, io), .mode = mode, .arena = .init(gpa) };
        self.pair.setServer(.{ .ctx = self, .onMessage = onMessage });
    }

    /// Stops background tasks and frees everything.
    pub fn deinit(self: *MockServer) void {
        self.tasks.cancel(self.io);
        self.pair.deinit();
        self.log.deinit(self.gpa);
        self.arena.deinit();
    }

    /// How many messages with `method` arrived.
    pub fn count(self: *MockServer, method: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.log.items) |r| n += @intFromBool(std.mem.eql(u8, r.method, method));
        return n;
    }

    /// The `nth` message with `method`.
    pub fn find(self: *MockServer, method: []const u8, nth: usize) ?Received {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var n: usize = 0;
        for (self.log.items) |r| if (std.mem.eql(u8, r.method, method)) {
            if (n == nth) return r;
            n += 1;
        };
        return null;
    }

    /// The methods received, in order, joined by spaces (into `buf`).
    pub fn methods(self: *MockServer, buf: []u8) []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var w: Io.Writer = .fixed(buf);
        for (self.log.items, 0..) |r, i| {
            if (i > 0) w.writeByte(' ') catch break;
            w.writeAll(r.method) catch break;
        }
        return w.buffered();
    }

    fn onMessage(ctx: ?*anyopaque, pair: *InProcPair, body: []const u8) void {
        const self: *MockServer = @ptrCast(@alignCast(ctx.?));
        self.handle(pair, body) catch |err| std.debug.panic("mock server: {t}", .{err});
    }

    fn handle(self: *MockServer, pair: *InProcPair, body: []const u8) !void {
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const s = scratch.allocator();
        const msg = switch (message.parse(s, body)) {
            .single => |m| m,
            else => return error.BadMessage,
        };
        switch (msg) {
            .response => {
                self.record("(response)", null, body);
                if (self.script) |sc| if (sc.func(sc.ctx, self, pair, .{ .response = .{ .body = body } })) return;
                const list_id = blk: {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    self.ping_answered = true;
                    const id = self.pending_list;
                    self.pending_list = null;
                    break :blk id;
                };
                if (list_id) |id| self.result(pair, id, "{\"tools\":[]}");
            },
            .notification => |n| {
                self.record(n.method, null, body);
                if (std.mem.eql(u8, n.method, "notifications/initialized")) {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    self.initialized = true;
                }
            },
            .request => |r| {
                const id = r.id.int;
                self.record(r.method, id, body);
                const params: Value = if (r.params) |p| try std.json.parseFromSliceLeaky(Value, s, p.bytes, .{}) else .{ .object = .empty };
                const fail: ?Transport.TransportError = blk: {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    if (self.mode != .modern and !self.initialized and !std.mem.eql(u8, r.method, "initialize") and
                        !std.mem.eql(u8, r.method, "ping") and !std.mem.eql(u8, r.method, "server/discover"))
                        self.violations += 1;
                    const f = self.fail_next orelse break :blk null;
                    if (!std.mem.eql(u8, f.method, r.method)) break :blk null;
                    self.fail_next = null;
                    break :blk f.err;
                };
                if (fail) |e| {
                    _ = pair.failRequest(r.id, e);
                    return;
                }
                try self.dispatch(pair, id, r.method, params);
            },
        }
    }

    fn record(self: *MockServer, method: []const u8, id: ?i64, body: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const a = self.arena.allocator();
        const m = a.dupe(u8, method) catch return;
        const b = a.dupe(u8, body) catch return;
        self.log.append(self.gpa, .{ .method = m, .id = id, .body = b }) catch return;
    }

    fn dispatch(self: *MockServer, pair: *InProcPair, id: i64, method: []const u8, params: Value) !void {
        const modern = self.mode == .modern;
        if (std.mem.eql(u8, method, "server/discover")) switch (self.mode) {
            .modern => return self.result(pair, id,
                \\{"resultType":"complete","supportedVersions":["2026-07-28","2025-11-25"],"capabilities":{"tools":{"listChanged":true}},"instructions":"be nice","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"mock","version":"1"}}}
            ),
            .legacy => return self.rpcError(pair, id, -32601, "Method not found", null),
            .silent_discover => return,
            .version_error => return self.rpcError(pair, id, -32022, "Unsupported protocol version",
                \\{"supported":["2025-11-25"],"requested":"2026-07-28"}
            ),
        };
        if (std.mem.eql(u8, method, "initialize")) {
            // A modern-only server: initialize is gone (2026-07-28 major 2).
            if (modern) return self.rpcError(pair, id, -32601, "Method not found", null);
            var buf: [256]u8 = undefined;
            return self.result(pair, id, try std.fmt.bufPrint(&buf,
                \\{{"protocolVersion":"{s}","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"mock","version":"1"}}}}
            , .{self.legacy_version}));
        }
        if (std.mem.eql(u8, method, "ping")) return self.result(pair, id, "{}");
        if (self.script) |sc| if (sc.func(sc.ctx, self, pair, .{ .request = .{ .id = id, .method = method, .params = params } })) return;
        if (std.mem.eql(u8, method, "tools/list")) {
            if (self.ping_first) {
                {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    self.pending_list = id;
                }
                return pair.serverSend("{\"jsonrpc\":\"2.0\",\"id\":\"srv-ping\",\"method\":\"ping\"}");
            }
            return self.result(pair, id, if (modern) "{\"resultType\":\"complete\",\"tools\":[]}" else "{\"tools\":[]}");
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            const name = params.object.get("name").?.string;
            if (std.mem.eql(u8, name, "echo")) return self.result(pair, id, "{\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}");
            if (std.mem.eql(u8, name, "hang")) return;
            if (std.mem.eql(u8, name, "needcap")) return self.rpcError(pair, id, -32021, "Missing required client capability",
                \\{"requiredCapabilities":{"elicitation":{"form":{}}}}
            );
            if (std.mem.eql(u8, name, "ask")) {
                const answered = params.object.get("inputResponses") != null and params.object.get("requestState") != null and
                    std.mem.eql(u8, params.object.get("requestState").?.string, "s1");
                if (!answered) return self.result(pair, id,
                    \\{"resultType":"input_required","inputRequests":{"r1":{"method":"roots/list","params":{}}},"requestState":"s1"}
                );
                return self.result(pair, id, "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"thanks\"}]}");
            }
            if (std.mem.eql(u8, name, "progress")) {
                const meta = params.object.get("_meta").?;
                const token = meta.object.get("progressToken").?.integer;
                return self.tasks.concurrent(self.io, progressLoop, .{ pair, token });
            }
            return self.rpcError(pair, id, -32602, "Unknown tool", null);
        }
        return self.rpcError(pair, id, -32601, "Method not found", null);
    }

    fn progressLoop(pair: *InProcPair, token: i64) Io.Cancelable!void {
        var i: u32 = 0;
        while (true) : (i += 1) {
            try pair.io.sleep(.fromMilliseconds(20), .awake);
            var buf: [160]u8 = undefined;
            const n = std.fmt.bufPrint(&buf,
                \\{{"jsonrpc":"2.0","method":"notifications/progress","params":{{"progressToken":{d},"progress":{d}}}}}
            , .{ token, i }) catch unreachable;
            pair.serverSend(n);
        }
    }

    /// Sends the result `json` for request `id`.
    pub fn result(_: *MockServer, pair: *InProcPair, id: i64, json: []const u8) void {
        var buf: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        message.writeResult(&w, .{ .int = id }, message.RawJson{ .bytes = json }) catch unreachable;
        pair.serverSend(w.buffered());
    }

    /// Sends an error response for request `id`.
    pub fn rpcError(_: *MockServer, pair: *InProcPair, id: i64, code: i32, msg: []const u8, data: ?[]const u8) void {
        var buf: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        if (data) |d|
            message.writeError(&w, .{ .int = id }, code, msg, message.RawJson{ .bytes = d }) catch unreachable
        else
            message.writeError(&w, .{ .int = id }, code, msg, null) catch unreachable;
        pair.serverSend(w.buffered());
    }
};
