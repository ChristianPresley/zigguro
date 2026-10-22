//! The InputBroker paths (E11.F03.S03.T01) against `MockServer` scripts
//! and a scripted `TestBroker`: modern MRTR rounds, legacy server
//! requests, `-32042` URL elicitation and the rate limit.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const protocol = @import("../protocol/root.zig");
const Client = @import("Client.zig");
const request = @import("request.zig");
const input = @import("input.zig");
const mrtr = @import("mrtr.zig");
const mock = @import("../testing/mock_server.zig");
const InProcPair = @import("../transport/in_process.zig");

const io = testing.io;
const gpa = testing.allocator;
const Value = std.json.Value;
const M = protocol.messages;

const TestBroker = struct {
    const Mode = enum { answer, wait_pair, wait_cancel };

    mode: Mode = .answer,
    mutex: Io.Mutex = .init,
    calls: std.atomic.Value(u32) = .init(0),
    inside: std.atomic.Value(u32) = .init(0),
    saw_cancel: bool = false,
    arena: std.heap.ArenaAllocator = .init(gpa),
    /// The last context's strings.
    server_id: []const u8 = "",
    origin_method: ?protocol.Method = null,
    origin_name: ?[]const u8 = null,
    key: []const u8 = "",
    completed: ?[]const u8 = null,

    fn broker(b: *TestBroker) input.InputBroker {
        return .{ .ctx = b, .resolve = resolve, .elicitationComplete = complete };
    }

    fn deinit(b: *TestBroker) void {
        b.arena.deinit();
    }

    fn resolve(ctx: ?*anyopaque, ic: input.InputContext, req: input.InputRequest, arena: Allocator) anyerror!input.InputResponse {
        const b: *TestBroker = @ptrCast(@alignCast(ctx.?));
        _ = b.calls.fetchAdd(1, .monotonic);
        {
            b.mutex.lockUncancelable(io);
            defer b.mutex.unlock(io);
            const a = b.arena.allocator();
            b.server_id = try a.dupe(u8, ic.server_id);
            b.origin_method = ic.origin_method;
            b.origin_name = if (ic.origin_name) |n| try a.dupe(u8, n) else null;
            b.key = try a.dupe(u8, ic.key);
        }
        switch (b.mode) {
            .answer => {},
            .wait_pair => {
                _ = b.inside.fetchAdd(1, .monotonic);
                var waited: u32 = 0;
                while (b.inside.load(.monotonic) < 2) : (waited += 1) {
                    if (waited > 500) return error.NotConcurrent;
                    try io.sleep(.fromMilliseconds(5), .awake);
                }
            },
            .wait_cancel => {
                var waited: u32 = 0;
                while (!ic.cancel.isCanceled()) : (waited += 1) {
                    if (waited > 1000) return error.NeverCanceled;
                    try io.sleep(.fromMilliseconds(5), .awake);
                }
                b.mutex.lockUncancelable(io);
                defer b.mutex.unlock(io);
                b.saw_cancel = true;
                return error.Canceled;
            },
        }
        return switch (req) {
            .elicitation => |e| .{ .elicitation = .{
                .action = .accept,
                .content = if (e.kind() == .form) try protocol.codec.parseValue(arena, "{\"name\":\"Ada\"}") else null,
            } },
            .sampling => blk: {
                const blocks = try arena.alloc(protocol.ContentBlock, 1);
                blocks[0] = .textBlock("sampled");
                break :blk .{ .sampling = .{ .role = .assistant, .content = .{ .items = blocks, .single = true }, .model = "m" } };
            },
            .roots => .{ .roots = .{ .roots = &.{.{ .uri = "file:///work", .name = "work" }} } },
            .unknown => .{ .failed = "unknown" },
        };
    }

    fn complete(ctx: ?*anyopaque, _: []const u8, id: []const u8) void {
        const b: *TestBroker = @ptrCast(@alignCast(ctx.?));
        b.mutex.lockUncancelable(io);
        defer b.mutex.unlock(io);
        b.completed = b.arena.allocator().dupe(u8, id) catch null;
    }
};

/// Tools answered by the script: `input_required` until called with
/// `inputResponses` or `requestState` (per tool), legacy server requests
/// and `-32042`.
const Script = struct {
    /// The tools/call waiting for a legacy server request's answer.
    pending_call: ?i64 = null,
    auth_calls: u32 = 0,

    fn script(s: *Script) mock.Script {
        return .{ .ctx = s, .func = handle };
    }

    fn handle(ctx: ?*anyopaque, srv: *mock.MockServer, pair: *InProcPair, ev: mock.Event) bool {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        switch (ev) {
            .response => |r| {
                const id = s.pending_call orelse return false;
                s.pending_call = null;
                // Echo the client's answer as the tool's text.
                var buf: [2048]u8 = undefined;
                var w: Io.Writer = .fixed(&buf);
                w.writeAll("{\"content\":[{\"type\":\"text\",\"text\":") catch unreachable;
                std.json.Stringify.value(r.body, .{}, &w) catch unreachable;
                w.writeAll("}]}") catch unreachable;
                srv.result(pair, id, w.buffered());
                return true;
            },
            .request => |r| {
                if (std.mem.eql(u8, r.method, "tools/list")) {
                    srv.result(pair, r.id, "{\"resultType\":\"input_required\",\"inputRequests\":{\"a\":{\"method\":\"roots/list\"}}}");
                    return true;
                }
                if (!std.mem.eql(u8, r.method, "tools/call")) return false;
                const name = r.params.object.get("name").?.string;
                const answered = r.params.object.get("inputResponses") != null;
                const done = "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}";
                if (std.mem.eql(u8, name, "form")) {
                    srv.result(pair, r.id, if (answered) done else
                        \\{"resultType":"input_required","inputRequests":{"e1":{"method":"elicitation/create","params":{"message":"Name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}},"requestState":"v1.\"sealed\"/é\u0001"}
                    );
                } else if (std.mem.eql(u8, name, "nostate")) {
                    srv.result(pair, r.id, if (answered) done else
                        \\{"resultType":"input_required","inputRequests":{"r":{"method":"roots/list"}}}
                    );
                } else if (std.mem.eql(u8, name, "stateonly")) {
                    srv.result(pair, r.id, if (r.params.object.get("requestState") != null) done else
                        \\{"resultType":"input_required","requestState":"s"}
                    );
                } else if (std.mem.eql(u8, name, "forever")) {
                    srv.result(pair, r.id, "{\"resultType\":\"input_required\",\"inputRequests\":{\"r\":{\"method\":\"roots/list\"}}}");
                } else if (std.mem.eql(u8, name, "sample")) {
                    srv.result(pair, r.id, if (answered) done else
                        \\{"resultType":"input_required","inputRequests":{"s":{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"hi"}}],"maxTokens":5}}}}
                    );
                } else if (std.mem.eql(u8, name, "both")) {
                    srv.result(pair, r.id, if (answered) done else
                        \\{"resultType":"input_required","inputRequests":{"e":{"method":"elicitation/create","params":{"message":"Name?"}},"s":{"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"hi"}}],"maxTokens":5}}}}
                    );
                } else if (std.mem.eql(u8, name, "six")) {
                    srv.result(pair, r.id, if (answered) done else
                        \\{"resultType":"input_required","inputRequests":{"k1":{"method":"elicitation/create","params":{"message":"1"}},"k2":{"method":"elicitation/create","params":{"message":"2"}},"k3":{"method":"elicitation/create","params":{"message":"3"}},"k4":{"method":"elicitation/create","params":{"message":"4"}},"k5":{"method":"elicitation/create","params":{"message":"5"}},"k6":{"method":"elicitation/create","params":{"message":"6"}}}}
                    );
                } else if (std.mem.eql(u8, name, "book")) {
                    s.pending_call = r.id;
                    pair.serverSend(
                        \\{"jsonrpc":"2.0","id":"e1","method":"elicitation/create","params":{"message":"Name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}
                    );
                } else if (std.mem.eql(u8, name, "roots")) {
                    s.pending_call = r.id;
                    pair.serverSend("{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"roots/list\"}");
                } else if (std.mem.eql(u8, name, "auth")) {
                    s.auth_calls += 1;
                    if (s.auth_calls > 1) {
                        srv.result(pair, r.id, "{\"content\":[{\"type\":\"text\",\"text\":\"signed in\"}]}");
                    } else {
                        srv.rpcError(pair, r.id, -32042, "URL elicitation required",
                            \\{"elicitations":[{"mode":"url","message":"Sign in","url":"https://example.com/auth","elicitationId":"el1"}]}
                        );
                        pair.serverSend("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/elicitation/complete\",\"params\":{\"elicitationId\":\"el1\"}}");
                    }
                } else return false;
                return true;
            },
        }
    }
};

const Fixture = struct {
    rt: zg_core.Runtime,
    srv: mock.MockServer,
    script: Script,
    broker: TestBroker,
    si: input.ServerInput,
    client: *Client,
    arena: std.heap.ArenaAllocator,

    fn init(f: *Fixture, mode: mock.Mode, features: protocol.capabilities.ClientFeatures) !void {
        f.rt.initTesting();
        f.srv.init(gpa, io, mode);
        f.script = .{};
        f.srv.script = f.script.script();
        f.broker = .{};
        f.arena = .init(gpa);
        f.si.init(gpa, io, f.broker.broker(), .{ .server_id = "srv", .min_prompt_interval = .zero });
        f.client = try Client.connect(&f.rt, gpa, .{ .in_process = &f.srv.pair }, .{
            .client_info = .{ .name = "zigguro-test", .version = "0.0.1" },
            .features = features,
            .on_server_request = f.si.serverRequestHandler(),
            .on_notification = f.si.notificationHandler(),
        });
        f.si.attach(f.client);
    }

    fn deinit(f: *Fixture) void {
        f.client.close();
        f.si.deinit();
        f.srv.deinit();
        f.broker.deinit();
        f.arena.deinit();
        _ = f.rt.deinit();
    }

    fn opts(f: *Fixture) request.CallOptions {
        return .{ .arena = f.arena.allocator() };
    }

    fn call(f: *Fixture, name: []const u8) request.RequestError!M.CallToolResult {
        return mrtr.runWithInput(&f.si, .tools_call, .{ .name = name }, f.opts());
    }

    /// The params of the `nth` tools/call the server received.
    fn sent(f: *Fixture, nth: usize) !Value {
        const body = f.srv.find("tools/call", nth).?.body;
        const v = try std.json.parseFromSliceLeaky(Value, f.arena.allocator(), body, .{});
        return v.object.get("params").?;
    }
};

test "mrtr: elicitation round then complete; retry has new id and identical requestState" {
    var f: Fixture = undefined;
    try f.init(.modern, .{});
    defer f.deinit();
    const r = try f.call("form");
    try testing.expectEqualStrings("done", r.content[0].text.text);
    try testing.expectEqual(1, f.broker.calls.load(.monotonic));
    try testing.expectEqualStrings("srv", f.broker.server_id);
    try testing.expectEqualStrings("form", f.broker.origin_name.?);
    try testing.expectEqual(protocol.Method.tools_call, f.broker.origin_method.?);
    try testing.expectEqualStrings("e1", f.broker.key);
    try testing.expect(f.srv.find("tools/call", 0).?.id.? != f.srv.find("tools/call", 1).?.id.?);
    const retry = try f.sent(1);
    try testing.expectEqualStrings("v1.\"sealed\"/é\u{1}", retry.object.get("requestState").?.string);
    const e1 = retry.object.get("inputResponses").?.object.get("e1").?;
    try testing.expectEqualStrings("accept", e1.object.get("action").?.string);
    try testing.expectEqualStrings("Ada", e1.object.get("content").?.object.get("name").?.string);
    // A fresh progress token per retry.
    const t0 = (try f.sent(0)).object.get("_meta").?.object.get("progressToken").?.integer;
    const t1 = retry.object.get("_meta").?.object.get("progressToken").?.integer;
    try testing.expect(t0 != t1);
}

test "mrtr: requestState absent => not sent" {
    var f: Fixture = undefined;
    try f.init(.modern, .{});
    defer f.deinit();
    _ = try f.call("nostate");
    const retry = try f.sent(1);
    try testing.expect(retry.object.get("requestState") == null);
    try testing.expectEqualStrings("file:///work", retry.object.get("inputResponses").?.object.get("r").?.object.get("roots").?.array.items[0].object.get("uri").?.string);
}

test "mrtr: only requestState => immediate retry" {
    var f: Fixture = undefined;
    try f.init(.modern, .{});
    defer f.deinit();
    _ = try f.call("stateonly");
    try testing.expectEqual(0, f.broker.calls.load(.monotonic));
    const retry = try f.sent(1);
    try testing.expectEqualStrings("s", retry.object.get("requestState").?.string);
    try testing.expect(retry.object.get("inputResponses") == null);
}

test "mrtr: max rounds => TooManyInputRounds" {
    var f: Fixture = undefined;
    try f.init(.modern, .{});
    defer f.deinit();
    var o = f.opts();
    o.max_input_rounds = 3;
    try testing.expectError(error.TooManyInputRounds, mrtr.runWithInput(&f.si, .tools_call, .{ .name = "forever" }, o));
    try testing.expectEqual(4, f.srv.count("tools/call"));
    try testing.expectEqual(3, f.broker.calls.load(.monotonic));
}

test "mrtr: undeclared capability => ProtocolViolation, broker not called" {
    var f: Fixture = undefined;
    try f.init(.modern, .{ .sampling = false });
    defer f.deinit();
    var info: request.ErrorInfo = .{};
    var o = f.opts();
    o.error_info = &info;
    try testing.expectError(error.ProtocolViolation, mrtr.runWithInput(&f.si, .tools_call, .{ .name = "sample" }, o));
    try testing.expectEqual(0, f.broker.calls.load(.monotonic));
    try testing.expect(std.mem.indexOf(u8, info.detail, "sampling/createMessage") != null);
    try testing.expectEqual(1, f.srv.count("tools/call"));
}

test "mrtr: parallel elicitation+sampling keys" {
    var f: Fixture = undefined;
    try f.init(.modern, .{});
    defer f.deinit();
    // Each resolution waits until both are in progress.
    f.broker.mode = .wait_pair;
    _ = try f.call("both");
    try testing.expectEqual(2, f.broker.calls.load(.monotonic));
    const responses = (try f.sent(1)).object.get("inputResponses").?.object;
    try testing.expectEqualStrings("accept", responses.get("e").?.object.get("action").?.string);
    try testing.expectEqualStrings("m", responses.get("s").?.object.get("model").?.string);
}

test "mrtr: input_required on tools/list => violation" {
    var f: Fixture = undefined;
    try f.init(.modern, .{});
    defer f.deinit();
    try testing.expectError(error.ProtocolViolation, mrtr.runWithInput(&f.si, .tools_list, .{}, f.opts()));
    try testing.expectEqual(0, f.broker.calls.load(.monotonic));
}

test "mrtr: outer cancel cancels broker" {
    var f: Fixture = undefined;
    try f.init(.modern, .{});
    defer f.deinit();
    f.broker.mode = .wait_cancel;
    var tok: request.CancelToken = .init(io);
    const Canceler = struct {
        fn run(t: *request.CancelToken) Io.Cancelable!void {
            try io.sleep(.fromMilliseconds(30), .awake);
            t.cancel("user pressed stop");
        }
    };
    var fut = try io.concurrent(Canceler.run, .{&tok});
    defer fut.cancel(io) catch {};
    var o = f.opts();
    o.cancel = &tok;
    try testing.expectError(error.Canceled, mrtr.runWithInput(&f.si, .tools_call, .{ .name = "form" }, o));
    try testing.expect(f.broker.saw_cancel);
    try testing.expectEqual(1, f.srv.count("tools/call"));
    try testing.expectEqual(0, f.si.open);
}

test "legacy: elicitation/create routed with origin tool name" {
    var f: Fixture = undefined;
    try f.init(.legacy, .{});
    defer f.deinit();
    const r = try f.call("book");
    try testing.expectEqualStrings("srv", f.broker.server_id);
    try testing.expectEqualStrings("book", f.broker.origin_name.?);
    try testing.expectEqual(protocol.Method.tools_call, f.broker.origin_method.?);
    try testing.expectEqualStrings("elicitation/create", f.broker.key);
    // The server saw the user's answer.
    try testing.expect(std.mem.indexOf(u8, r.content[0].text.text, "\"id\":\"e1\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.content[0].text.text, "\"action\":\"accept\"") != null);
    try testing.expect(std.mem.indexOf(u8, r.content[0].text.text, "\"name\":\"Ada\"") != null);
}

test "legacy: -32042 flow with complete notification" {
    var f: Fixture = undefined;
    try f.init(.legacy, .{});
    defer f.deinit();
    const r = try f.call("auth");
    try testing.expectEqualStrings("signed in", r.content[0].text.text);
    try testing.expectEqual(2, f.srv.count("tools/call"));
    try testing.expectEqual(1, f.broker.calls.load(.monotonic));
    try testing.expectEqualStrings("el1", f.broker.key);
    var waited: u32 = 0;
    while (f.broker.completed == null and waited < 200) : (waited += 1) try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expectEqualStrings("el1", f.broker.completed.?);
}

test "legacy: roots/list answered; roots list_changed sent on change" {
    var f: Fixture = undefined;
    try f.init(.legacy, .{});
    defer f.deinit();
    const r = try f.call("roots");
    try testing.expect(std.mem.indexOf(u8, r.content[0].text.text, "file:///work") != null);
    try testing.expectEqualStrings("roots/list", f.broker.key);
    try f.si.rootsChanged();
    var waited: u32 = 0;
    while (f.srv.count("notifications/roots/list_changed") == 0 and waited < 200) : (waited += 1) try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expectEqual(1, f.srv.count("notifications/roots/list_changed"));
}

test "rate limit: 6th concurrent request auto-declined" {
    var f: Fixture = undefined;
    try f.init(.modern, .{});
    defer f.deinit();
    _ = try f.call("six");
    try testing.expectEqual(5, f.broker.calls.load(.monotonic));
    try testing.expectEqual(1, f.si.declined);
    const responses = (try f.sent(1)).object.get("inputResponses").?.object;
    try testing.expectEqual(5, responses.count());
    try testing.expect(responses.get("k6") == null);
    try testing.expectEqual(0, f.si.open);
}
