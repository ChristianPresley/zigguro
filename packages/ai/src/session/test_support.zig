//! Shared setup for the resume, fork and rewind tests: a session store in
//! a temporary directory, a model registry, a scripted provider and an
//! agent manager.

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const store_mod = @import("store.zig");
const writer_mod = @import("writer.zig");
const Agent = @import("../loop/Agent.zig");
const AgentManager = @import("../loop/Manager.zig");
const scripted = @import("../provider/scripted.zig");
const Provider = @import("../provider/Provider.zig");
const reg = @import("../models/registry.zig");

const testing = std.testing;
pub const io = testing.io;
pub const Step = scripted.ScriptedProvider.Step;
pub const script = scripted.script;

pub const catalog: [:0]const u8 =
    \\.{
    \\    .retrieved = "test",
    \\    .models = .{
    \\        .{ .id = "m", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 1_000_000, .output_per_mtok_micros = 5_000_000 } },
    \\        .{ .id = "m2", .context_window = 200_000, .max_output = 32_000, .base = .claude,
    \\           .price = .{ .input_per_mtok_micros = 1_000_000, .output_per_mtok_micros = 5_000_000 } },
    \\    },
    \\}
;

pub const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    store: store_mod.SessionStore,
    registry: reg.ModelRegistry,
    sp: *scripted.ScriptedProvider,
    provider: Provider,
    manager: *AgentManager,

    pub fn init(f: *Fixture, turns: []const []const Step) !void {
        f.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .store = undefined, .registry = .init(testing.allocator, io, catalog), .sp = try .init(testing.allocator, turns, .all), .provider = undefined, .manager = undefined };
        f.provider = f.sp.provider();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try f.tmp.dir.realPath(io, &buf);
        f.store = try .init(testing.allocator, buf[0..n], "/work/repo");
        f.manager = try AgentManager.init(testing.allocator, io, .{ .registry = &f.registry, .providers = .fixed(&f.provider) });
    }

    pub fn deinit(f: *Fixture) void {
        f.manager.deinit();
        f.provider.deinit();
        f.registry.deinit();
        f.store.deinit();
        f.tmp.cleanup();
        f.arena.deinit();
    }

    pub fn msg(f: *Fixture, role: proto.Role, t: []const u8) proto.Message {
        const b = f.arena.allocator().alloc(proto.ContentBlock, 1) catch unreachable;
        b[0] = .{ .text = .{ .text = t } };
        return .{ .role = role, .content = b };
    }

    pub fn event(kind: []const u8, data: []const u8) records.Record {
        return .{ .event = .{ .kind = kind, .data_json = data } };
    }

    /// Writes a session with `recs` numbered 1, 2, ...; returns its id.
    pub fn write(f: *Fixture, model: []const u8, recs: []const records.Record) !proto.SessionId {
        const w = try f.store.create(io, .{ .cwd = "/work/repo", .model = model });
        defer w.close();
        for (recs, 1..) |r, i| try w.append(i, r);
        return w.id;
    }

    /// A live agent of a new session, logging to it.
    pub fn liveAgent(f: *Fixture, d: Agent.Deps) !struct { agent: *Agent, writer: *writer_mod.SessionWriter } {
        const w = try f.store.create(io, .{ .cwd = "/work/repo", .model = "m" });
        errdefer w.close();
        var with_log = d;
        with_log.session = w.sessionLog();
        const a = try f.manager.createWith(.{ .model = "m", .session = w.id }, with_log);
        _ = try a.subscribe(w.subscriber());
        return .{ .agent = a, .writer = w };
    }

    /// The manager's deps.
    pub fn deps(f: *Fixture) Agent.Deps {
        return f.manager.deps;
    }
};

/// "u"/"a" per message, plus "r" for tool results.
pub fn roles(buf: []u8, msgs: []const proto.Message) []const u8 {
    for (msgs, 0..) |m, i| {
        buf[i] = if (m.role == .assistant) 'a' else blk: {
            for (m.content) |b| if (b == .tool_result) break :blk 'r';
            break :blk 'u';
        };
    }
    return buf[0..msgs.len];
}

/// Text of the first text block of `m`.
pub fn firstText(m: proto.Message) []const u8 {
    for (m.content) |b| if (b == .text) return b.text.text;
    return "";
}
