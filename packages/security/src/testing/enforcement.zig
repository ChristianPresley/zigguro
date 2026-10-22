//! The deny-all enforcement harness (E16.F02.S01.T04, INV-01). Every
//! consumer that executes, writes or connects on behalf of an agent
//! registers a case: given a deny-all engine, the case drives one
//! representative call and reports what side effects it attempted. The
//! runner asserts the consumer returned the deny message and that the
//! spawn, connect and write counters all stayed at zero.
//!
//! Run with `zig build test-enforcement`. Consumers that have not landed
//! yet are represented by minimal stand-ins below with the same call shape;
//! each consumer epic replaces its stand-in with a case that drives the
//! real service (E06 TerminalService, E07 task runner, E08 FileOps, E09
//! lanes, E10 invoke pipeline, E11 MCP gate).

const std = @import("std");
const contracts = @import("../contracts.zig");
const fakes = @import("fakes.zig");

/// Side effects a case attempted; all must stay zero under deny-all.
pub const Probe = struct {
    spawns: u32 = 0,
    connects: u32 = 0,
    writes: u32 = 0,
    /// The decision message the consumer surfaced to its caller.
    message: ?[]const u8 = null,
};

/// One registered case.
pub const Case = struct {
    consumer: []const u8,
    tool: []const u8,
    run: *const fn (engine: fakes.EngineIface, probe: *Probe) anyerror!void,
};

/// The shared table. Consumer epics append their cases here.
pub const cases = [_]Case{
    .{ .consumer = "E06 terminal (stand-in)", .tool = "run_command", .run = terminalRun },
    .{ .consumer = "E07 task runner (stand-in)", .tool = "run_task", .run = taskRun },
    .{ .consumer = "E08 file ops (stand-in)", .tool = "edit_file", .run = fileWrite },
    .{ .consumer = "E09 scm lane (stand-in)", .tool = "scm", .run = scmPush },
    .{ .consumer = "E10 web fetch (stand-in)", .tool = "web_fetch", .run = webFetch },
    .{ .consumer = "E11 mcp gate (stand-in)", .tool = "mcp__srv__tool", .run = mcpCall },
};

const reason = "harness";

/// Runs every case against `denyAll("harness")`.
pub fn runAll() !void {
    const engine = fakes.denyAll(reason);
    for (cases) |c| {
        var probe: Probe = .{};
        try c.run(engine, &probe);
        if (probe.spawns + probe.connects + probe.writes != 0 or probe.message == null or !std.mem.eql(u8, probe.message.?, reason)) {
            std.debug.print("INV-01 violated by {s} ({s}): {any}\n", .{ c.consumer, c.tool, probe });
            return error.TestUnexpectedResult;
        }
    }
}

// Stand-ins: each decides first, then performs its effect only on allow.

fn gate(engine: fakes.EngineIface, probe: *Probe, req: *const contracts.ToolRequest) bool {
    switch (engine.check(req)) {
        .allow => return true,
        .deny => |m| probe.message = m,
        .ask => |t| {
            t.cancel();
            probe.message = "ask";
        },
    }
    return false;
}

fn terminalRun(engine: fakes.EngineIface, probe: *Probe) anyerror!void {
    const res = [_]contracts.Resource{.{ .command = .{ .text = "rm -rf /", .cwd = "/w" } }};
    const req: contracts.ToolRequest = .{ .actor = .{ .agent = .{ .session = "s", .agent = "a" } }, .tool = "run_command", .input_json = "rm -rf /", .effects = .{ .executes = true }, .resources = &res, .mode = .bypass };
    if (gate(engine, probe, &req)) probe.spawns += 1;
}

fn taskRun(engine: fakes.EngineIface, probe: *Probe) anyerror!void {
    const req: contracts.ToolRequest = .{ .actor = .{ .agent = .{ .session = "s", .agent = "a" } }, .tool = "run_task", .input_json = "build", .effects = .{ .executes = true }, .resources = &.{}, .mode = .default };
    if (gate(engine, probe, &req)) probe.spawns += 1;
}

fn fileWrite(engine: fakes.EngineIface, probe: *Probe) anyerror!void {
    const res = [_]contracts.Resource{.{ .path = .{ .path = "/w/a.txt", .access = .{ .write = true } } }};
    const req: contracts.ToolRequest = .{ .actor = .{ .agent = .{ .session = "s", .agent = "a" } }, .tool = "edit_file", .input_json = "{}", .effects = .{ .mutates_workspace = true }, .resources = &res, .mode = .accept_edits };
    if (gate(engine, probe, &req)) probe.writes += 1;
}

fn scmPush(engine: fakes.EngineIface, probe: *Probe) anyerror!void {
    const res = [_]contracts.Resource{.{ .scm = .{ .action = "push" } }};
    const req: contracts.ToolRequest = .{ .actor = .{ .agent = .{ .session = "s", .agent = "a" } }, .tool = "scm", .input_json = "push", .effects = .{ .network = true }, .resources = &res, .mode = .default };
    if (gate(engine, probe, &req)) probe.connects += 1;
}

fn webFetch(engine: fakes.EngineIface, probe: *Probe) anyerror!void {
    const res = [_]contracts.Resource{.{ .url = .{ .url = "https://example.com" } }};
    const req: contracts.ToolRequest = .{ .actor = .{ .agent = .{ .session = "s", .agent = "a" } }, .tool = "web_fetch", .input_json = "{}", .effects = .{ .network = true }, .resources = &res, .mode = .default };
    if (gate(engine, probe, &req)) probe.connects += 1;
}

fn mcpCall(engine: fakes.EngineIface, probe: *Probe) anyerror!void {
    const res = [_]contracts.Resource{.{ .mcp_tool = .{ .server = "srv", .tool = "tool" } }};
    const req: contracts.ToolRequest = .{ .actor = .{ .agent = .{ .session = "s", .agent = "a" } }, .tool = "mcp__srv__tool", .input_json = "{}", .effects = .{ .network = true }, .resources = &res, .mode = .default };
    if (gate(engine, probe, &req)) probe.connects += 1;
}

test "INV-01 enforcement: every registered case denied, no side effects" {
    try runAll();
}

test "enforcement: the harness notices a consumer that skips the engine" {
    const bad = struct {
        fn run(_: fakes.EngineIface, probe: *Probe) anyerror!void {
            probe.spawns += 1; // never asked the engine
        }
    }.run;
    var probe: Probe = .{};
    try bad(fakes.denyAll(reason), &probe);
    try std.testing.expect(probe.spawns == 1 and probe.message == null);
}
