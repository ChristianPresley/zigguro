//! Shared setup for the headless tests: a model registry, a scripted
//! provider, a test tool, an agent manager and captured stdout/stderr.

const std = @import("std");
const proto = @import("zg_ai_proto");
const AgentManager = @import("../loop/Manager.zig");
const deps = @import("../loop/deps.zig");
const reg = @import("../models/registry.zig");
const scripted = @import("../provider/scripted.zig");
const Provider = @import("../provider/Provider.zig");
const ratelimit = @import("../provider/ratelimit.zig");
const args = @import("args.zig");
const print = @import("print.zig");
const exit_codes = @import("exit_codes.zig");

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
    \\    },
    \\}
;

/// A fixed session id, so outputs are stable.
pub const session_id: proto.SessionId = 0x0192_0000_0000_0000_0000_0000_0000_0001;

/// `run`: executes, counts calls and answers "ran".
pub const RunTool = struct {
    calls: std.atomic.Value(u32) = .init(0),

    pub fn spec(t: *RunTool) proto.ToolSpec {
        return .{
            .name = "run",
            .description = "Runs a command.",
            .input_schema_json = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}}}",
            .read_only = false,
            .handler = .{ .ctx = t, .call = call },
            .effects = .{ .executes = true },
            .permission = .execute,
        };
    }

    fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const t: *RunTool = @ptrCast(@alignCast(ctx));
        _ = t.calls.fetchAdd(1, .acq_rel);
        return proto.ToolOutput.text(c.arena, "ran", false) catch error.OutOfMemory;
    }
};

pub const Harness = struct {
    registry: reg.ModelRegistry,
    sp: *scripted.ScriptedProvider,
    provider: Provider,
    manager: *AgentManager,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    tool: RunTool = .{},
    specs: [1]proto.ToolSpec = undefined,
    tools: deps.StaticTools = undefined,
    clock: ratelimit.FakeClock = .init(0),
    arena: std.heap.ArenaAllocator,

    pub fn init(h: *Harness, turns: []const []const Step) !void {
        h.* = .{
            .registry = .init(testing.allocator, io, catalog),
            .sp = try .init(testing.allocator, turns, .all),
            .provider = undefined,
            .manager = undefined,
            .out = .init(testing.allocator),
            .err = .init(testing.allocator),
            .arena = .init(testing.allocator),
        };
        h.provider = h.sp.provider();
        h.specs[0] = h.tool.spec();
        h.tools = .{ .specs = &h.specs };
        h.manager = try AgentManager.init(testing.allocator, io, .{ .registry = &h.registry, .providers = .fixed(&h.provider), .tools = h.tools.tools() });
    }

    /// Serves the agent from `p` instead of the scripted provider.
    pub fn useProvider(h: *Harness, p: *const Provider) void {
        h.manager.deps.providers = .fixed(p);
    }

    pub fn deinit(h: *Harness) void {
        h.manager.deinit();
        h.provider.deinit();
        h.registry.deinit();
        h.out.deinit();
        h.err.deinit();
        h.arena.deinit();
    }

    pub fn env(h: *Harness) args.Env {
        return .{ .err = &h.err.writer, .default_model = "m", .session = session_id, .clock = h.clock.clock(), .cwd = "/work" };
    }

    pub fn options(h: *Harness, argv: []const [:0]const u8) !args.HeadlessOptions {
        var o = try args.parseArgs(h.arena.allocator(), argv);
        o.env = h.env();
        return o;
    }

    pub fn run(h: *Harness, o: args.HeadlessOptions, stdin: []const u8) !exit_codes.ExitCode {
        var in: std.Io.Reader = .fixed(stdin);
        return print.runPrint(io, testing.allocator, h.manager, o, &h.out.writer, &in);
    }

    pub fn stdout(h: *Harness) []const u8 {
        return h.out.written();
    }

    pub fn stderr(h: *Harness) []const u8 {
        return h.err.written();
    }

    /// The text of the last user message of request `i`.
    pub fn lastUserText(h: *Harness, i: usize) []const u8 {
        const msgs = h.sp.requests()[i].messages;
        const m = msgs[msgs.len - 1];
        for (m.content) |b| if (b == .text) return b.text.text;
        return "";
    }
};
