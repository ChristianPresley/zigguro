//! Workflow tools for agents (E13.F08.S01.T03), through zg_ai's
//! foreign-tool contract: `workflow_list` lists the project's workflows,
//! `workflow_run{name, args}` starts one (validated first),
//! `workflow_status{run}` reads its progress, and
//! `workflow_create{name, zon}` validates a new definition and proposes it
//! as an E12 changeset (`.zigguro/workflows/<name>.zon`).

const std = @import("std");
const zg_ai = @import("zg_ai");
const run = @import("../runs/run.zig");
const WorkflowEngine = @import("exec.zig");
const parse = @import("parse.zig");
const validate_mod = @import("validate.zig");
const def = @import("def.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;

/// Where workflow definitions come from (`.zigguro/workflows/` in the app).
pub const Catalog = struct {
    ctx: *anyopaque,
    list: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]const Summary,
    /// The source of workflow `name`, or null.
    load: *const fn (ctx: *anyopaque, arena: Allocator, name: []const u8) anyerror!?Source,
    /// Proposes `bytes` as `<name>.zon` for review; returns the changeset.
    write: *const fn (ctx: *anyopaque, name: []const u8, bytes: []const u8) anyerror!?u64,
};

pub const Summary = struct { name: []const u8, description: []const u8 = "" };
pub const Source = struct { text: [:0]const u8, schema_files: ?validate_mod.SchemaFiles = null };

pub const schemas = struct {
    pub const list = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
    pub const run = "{\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"},\"args\":{\"type\":\"object\",\"description\":\"The workflow's arguments.\"}},\"additionalProperties\":false}";
    pub const status = "{\"type\":\"object\",\"required\":[\"run\"],\"properties\":{\"run\":{\"type\":\"string\",\"description\":\"The run id workflow_run returned.\"}},\"additionalProperties\":false}";
    pub const create = "{\"type\":\"object\",\"required\":[\"name\",\"zon\"],\"properties\":{\"name\":{\"type\":\"string\"},\"zon\":{\"type\":\"string\",\"description\":\"The workflow definition (docs/formats/workflow.md).\"}},\"additionalProperties\":false}";
};

pub const tool_list = [_]foreign.ForeignTool{
    .{ .name = "workflow_list", .description = "List the project's workflows (multi-agent fan-out/fan-in plans).", .input_schema_json = schemas.list, .read_only = true },
    .{ .name = "workflow_run", .description = "Start a workflow; returns its run id at once.", .input_schema_json = schemas.run },
    .{ .name = "workflow_status", .description = "Progress of a workflow run: status, steps, agents and cost.", .input_schema_json = schemas.status, .read_only = true },
    .{ .name = "workflow_create", .description = "Add a workflow to the project (validated, then reviewed before it is written).", .input_schema_json = schemas.create, .mutates = true },
};

/// Must not move after `exporter`.
pub const ToolExporter = struct {
    eng: *WorkflowEngine,
    catalog: Catalog,
    /// Checks applied before `workflow_run` and `workflow_create`.
    env: validate_mod.ValidateEnv = .{},

    pub fn exporter(self: *ToolExporter) foreign.Exporter {
        return .{ .name = "workflow", .kind = .agents, .ctx = self, .list = listFn, .call = callFn };
    }

    fn listFn(_: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        return arena.dupe(foreign.ForeignTool, &tool_list);
    }

    fn callFn(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!foreign.Result {
        _ = io;
        const self: *ToolExporter = @ptrCast(@alignCast(ctx));
        const r = try runTool(self, arena, tool, input_json);
        return .{ .json = r.json, .changeset = r.changeset };
    }
};

pub const Output = struct { json: []const u8, changeset: ?u64 = null, is_error: bool = false, text: []const u8 = "" };

pub fn runTool(t: *ToolExporter, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    var cs: ?u64 = null;
    const input = if (input_json.len == 0) "{}" else input_json;
    const out = dispatch(t, arena, tool, input, &msg, &cs) catch |e| switch (e) {
        error.OutOfMemory, error.UnknownTool => return e,
        error.BadInput => null,
        else => blk: {
            msg = try std.fmt.allocPrint(arena, "{s} failed: {t}", .{ tool, e });
            break :blk null;
        },
    };
    const text = out orelse msg;
    const Block = struct { type: []const u8 = "text", text: []const u8 };
    const R = struct { content: []const Block, isError: bool };
    return .{ .json = try std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = out == null }, .{}), .changeset = cs, .is_error = out == null, .text = text };
}

fn parseIn(comptime T: type, a: Allocator, input: []const u8, msg: *[]const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, input, .{ .allocate = .alloc_always }) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "invalid input: {t}", .{e});
        return error.BadInput;
    };
}

/// Parses and validates `src`; diagnostics become the error message.
fn load(t: *ToolExporter, a: Allocator, src: [:0]const u8, schema_files: ?validate_mod.SchemaFiles, msg: *[]const u8) !parse.Parsed {
    var env = t.env;
    if (schema_files) |sf| env.schema_files = sf;
    var diags: parse.Diagnostics = .init(a);
    return parse.parseDef(t.eng.gpa, src, env, &diags) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            var w: Io.Writer.Allocating = .init(a);
            diags.format("workflow", &w.writer) catch return error.OutOfMemory;
            msg.* = try std.fmt.allocPrint(a, "the workflow is not valid:\n{s}", .{w.written()});
            return error.BadInput;
        },
    };
}

fn dispatch(t: *ToolExporter, a: Allocator, tool: []const u8, input: []const u8, msg: *[]const u8, cs: *?u64) ![]const u8 {
    const cat = t.catalog;
    if (std.mem.eql(u8, tool, "workflow_list")) {
        return std.json.Stringify.valueAlloc(a, try cat.list(cat.ctx, a), .{});
    }
    if (std.mem.eql(u8, tool, "workflow_run")) {
        const In = struct { name: []const u8, args: ?std.json.Value = null };
        const in = try parseIn(In, a, input, msg);
        const src = try cat.load(cat.ctx, a, in.name) orelse {
            msg.* = try std.fmt.allocPrint(a, "no workflow \"{s}\"", .{in.name});
            return error.BadInput;
        };
        var p = try load(t, a, src.text, src.schema_files, msg);
        defer p.deinit();
        const id = t.eng.start(&p.def, in.args orelse .null, .{ .source = src.text, .schema_files = src.schema_files }) catch |e| switch (e) {
            error.MissingArgument => {
                msg.* = "a required argument is missing";
                return error.BadInput;
            },
            else => return e,
        };
        return std.fmt.allocPrint(a, "{{\"run\":\"{s}\",\"status\":\"working\"}}", .{&id.text()});
    }
    if (std.mem.eql(u8, tool, "workflow_status")) {
        const In = struct { run: []const u8 };
        const in = try parseIn(In, a, input, msg);
        const id = run.RunId.parse(in.run) catch {
            msg.* = "invalid run id";
            return error.BadInput;
        };
        const p = try t.eng.progress(id, a) orelse {
            msg.* = try std.fmt.allocPrint(a, "no workflow run {s} in this session", .{in.run});
            return error.BadInput;
        };
        const Step = struct { id: []const u8, phase: ?[]const u8, state: []const u8, done: u32, failed: u32, total: u32, running: u32, @"error": ?[]const u8 };
        const steps = try a.alloc(Step, p.steps.len);
        for (p.steps, steps) |s, *o| o.* = .{ .id = s.id, .phase = s.phase, .state = @tagName(s.state), .done = s.done, .failed = s.failed, .total = s.total, .running = s.running, .@"error" = s.error_ };
        const R = struct { name: []const u8, status: []const u8, agents: u32, cost_micros: u64, waiting_at_gate: ?[]const u8, @"error": ?[]const u8, steps: []const Step };
        return std.json.Stringify.valueAlloc(a, R{
            .name = p.name,
            .status = @tagName(p.status),
            .agents = p.agents,
            .cost_micros = p.cost.micros,
            .waiting_at_gate = if (p.gate) |g| g.title else null,
            .@"error" = p.error_,
            .steps = steps,
        }, .{});
    }
    if (std.mem.eql(u8, tool, "workflow_create")) {
        const In = struct { name: []const u8, zon: []const u8 };
        const in = try parseIn(In, a, input, msg);
        if (!def.validName(in.name)) {
            msg.* = "invalid name: use [a-z][a-z0-9-]*";
            return error.BadInput;
        }
        var p = try load(t, a, try a.dupeZ(u8, in.zon), null, msg);
        defer p.deinit();
        if (!std.mem.eql(u8, p.def.name, in.name)) {
            msg.* = try std.fmt.allocPrint(a, "the definition's .name is \"{s}\", expected \"{s}\"", .{ p.def.name, in.name });
            return error.BadInput;
        }
        cs.* = try cat.write(cat.ctx, in.name, in.zon);
        return std.fmt.allocPrint(a, "proposed .zigguro/workflows/{s}.zon for review", .{in.name});
    }
    return error.UnknownTool;
}
