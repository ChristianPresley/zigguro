//! Extension SDK tests against a scripted host.

const std = @import("std");
const zg_core = @import("zg_core");
const jsonrpc = @import("zg_jsonrpc");
const client = @import("client.zig");
const protocol = @import("protocol.zig");

const testing = std.testing;
const Io = std.Io;
const PipePair = jsonrpc.testing.PipePair;
const ScriptedPeer = jsonrpc.testing.ScriptedPeer;
const Extension = client.Extension;

const Fixture = struct {
    rt: zg_core.Runtime,
    pipe: *PipePair,
    ext: *Extension,

    fn init(f: *Fixture) !void {
        f.rt.initTesting();
        f.pipe = try PipePair.init(testing.allocator, testing.io, 1 << 20);
        f.ext = try Extension.init(&f.rt, f.pipe.a_reader, f.pipe.a_writer, .{ .capabilities = .{ .views = &.{"hello.tree"} } });
    }

    fn deinit(f: *Fixture) void {
        f.pipe.closeB();
        f.ext.deinit();
        f.pipe.deinit();
        _ = f.rt.deinit();
    }

    fn host(f: *Fixture) ScriptedPeer {
        return .init(testing.allocator, .content_length, f.pipe.b_reader, f.pipe.b_writer);
    }
};

fn say(e: *Extension, args: ?std.json.Value, arena: std.mem.Allocator) anyerror!?std.json.Value {
    const name = if (args) |a| a.object.get("name").?.string else "world";
    const choice = try e.showMessage(arena, .info, try std.fmt.allocPrint(arena, "hello, {s}", .{name}), &.{"OK"});
    return .{ .string = choice orelse "none" };
}

fn fail(_: *Extension, _: ?std.json.Value, _: std.mem.Allocator) anyerror!?std.json.Value {
    return error.Boom;
}

fn expectScript(peer: *ScriptedPeer, script: []const u8) !void {
    peer.run(script) catch |e| {
        if (peer.failure) |fl| std.debug.print("script line {d}: got {s}\n", .{ fl.line, fl.got });
        return e;
    };
}

test "sdk: lifecycle, command dispatch with a host round trip, errors, exit" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.ext.onCommand("hello.say", say);
    try f.ext.onCommand("hello.fail", fail);
    try f.ext.start();
    var host = f.host();
    defer host.deinit();

    try expectScript(&host,
        \\> {"jsonrpc":"2.0","id":1,"method":"command/execute","params":{"id":"hello.say"}}
        \\< {"jsonrpc":"2.0","id":1,"error":{"code":-32003,"message":"command before initialized"}}
        \\> {"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2026-10","host":{"name":"zigguro","version":"0.1.0"},"extension":{"id":"acme.hello","root":"/r","storageDir":"/s","globalStorageDir":"/g"}}}
        \\< {"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2026-10","capabilities":{"documentSync":false,"decorations":false,"views":["hello.tree"],"configurationSections":[]}}}
        \\> {"jsonrpc":"2.0","method":"initialized","params":{}}
        \\> {"jsonrpc":"2.0","method":"activate","params":{"event":"onCommand:hello.say"}}
    );
    try f.ext.waitInitialized(.{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expectEqualStrings("acme.hello", f.ext.host.?.extension.id);

    try expectScript(&host,
        \\> {"jsonrpc":"2.0","id":3,"method":"command/execute","params":{"id":"hello.say","args":{"name":"zig"}}}
        \\< {"jsonrpc":"2.0","id":1,"method":"window/showMessage","params":{"severity":"info","message":"hello, zig","actions":["OK"]}}
        \\> {"jsonrpc":"2.0","id":1,"result":"OK"}
        \\< {"jsonrpc":"2.0","id":3,"result":"OK"}
        \\> {"jsonrpc":"2.0","id":4,"method":"command/execute","params":{"id":"nope"}}
        \\< {"jsonrpc":"2.0","id":4,"error":{"code":-32601,"message":"unknown command"}}
        \\> {"jsonrpc":"2.0","id":5,"method":"command/execute","params":{"id":"hello.fail"}}
        \\< {"jsonrpc":"2.0","id":5,"error":{"code":-32603,"message":"command 'hello.fail' failed: Boom"}}
        \\> {"jsonrpc":"2.0","id":6,"method":"shutdown"}
        \\< {"jsonrpc":"2.0","id":6,"result":null}
        \\> {"jsonrpc":"2.0","method":"exit"}
    );
    try f.ext.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try testing.expect(f.ext.shutdown_requested.load(.acquire));
    try testing.expectEqual(@as(u32, 1), f.ext.activations.load(.acquire));
}

test "sdk: unsupported protocol version is refused" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.ext.start();
    var host = f.host();
    defer host.deinit();
    try expectScript(&host,
        \\> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01","host":{"name":"h","version":"0"},"extension":{"id":"a.b","root":"/","storageDir":"/","globalStorageDir":"/"}}}
        \\< {"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"unsupported protocolVersion"}}
    );
}

test "sdk: host closing the connection ends run" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.ext.start();
    f.pipe.closeB();
    try f.ext.done.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
}

fn tree(_: *Extension, params: ?std.json.Value, arena: std.mem.Allocator) anyerror!?std.json.Value {
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "id", params.?.object.get("viewId").?);
    return .{ .object = root };
}

test "sdk: onRequest handles other host requests" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.ext.onRequest(protocol.methods.view_resolve, tree);
    try f.ext.start();
    var host = f.host();
    defer host.deinit();
    try expectScript(&host,
        \\> {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-10","host":{"name":"h","version":"0"},"extension":{"id":"a.b","root":"/","storageDir":"/","globalStorageDir":"/"}}}
        \\< {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2026-10","capabilities":{"documentSync":false,"decorations":false,"views":["hello.tree"],"configurationSections":[]}}}
        \\> {"jsonrpc":"2.0","method":"initialized","params":{}}
    );
    try f.ext.waitInitialized(.{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    try expectScript(&host,
        \\> {"jsonrpc":"2.0","id":2,"method":"view/resolve","params":{"viewId":"hello.tree"}}
        \\< {"jsonrpc":"2.0","id":2,"result":{"id":"hello.tree"}}
    );
}
