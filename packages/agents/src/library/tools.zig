//! Prompt library tools for agents (E13.F08.S02.T01), through zg_ai's
//! foreign-tool contract: `library_search{query}` and `library_get{id}`
//! read house prompts; `library_create{id, title, body, ...}` writes a new
//! project prompt as an E12 changeset.

const std = @import("std");
const zg_ai = @import("zg_ai");
const PromptLibrary = @import("index.zig");
const template = @import("template.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;

pub const schemas = struct {
    pub const search = "{\"type\":\"object\",\"required\":[\"query\"],\"properties\":{\"query\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}},\"additionalProperties\":false}";
    pub const get = "{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"An entry id from library_search, e.g. research/lead.\"}},\"additionalProperties\":false}";
    pub const create = "{\"type\":\"object\",\"required\":[\"id\",\"title\",\"body\"],\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"Path-like id: lowercase letters, digits, . _ - and / between segments.\"},\"title\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"body\":{\"type\":\"string\",\"description\":\"Prompt text; {{name}} declares a variable.\"}},\"additionalProperties\":false}";
};

pub const tool_list = [_]foreign.ForeignTool{
    .{ .name = "library_search", .description = "Find prompts, prompt templates and skills in the prompt library.", .input_schema_json = schemas.search, .read_only = true },
    .{ .name = "library_get", .description = "A library entry's text and its template variables.", .input_schema_json = schemas.get, .read_only = true },
    .{ .name = "library_create", .description = "Add a prompt to the project's prompt library (reviewed before it is written).", .input_schema_json = schemas.create, .mutates = true },
};

/// Must not move after `exporter`.
pub const ToolExporter = struct {
    lib: *PromptLibrary,
    max_hits: u32 = 20,

    pub fn exporter(self: *ToolExporter) foreign.Exporter {
        return .{ .name = "library", .kind = .agents, .ctx = self, .list = listFn, .call = callFn };
    }

    fn listFn(_: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        return arena.dupe(foreign.ForeignTool, &tool_list);
    }

    fn callFn(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!foreign.Result {
        _ = io;
        const self: *ToolExporter = @ptrCast(@alignCast(ctx));
        const r = try run(self, arena, tool, input_json);
        return .{ .json = r.json, .changeset = r.changeset };
    }
};

pub const Output = struct { json: []const u8, changeset: ?u64 = null, is_error: bool = false, text: []const u8 = "" };

pub fn run(t: *ToolExporter, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    var cs: ?u64 = null;
    const input = if (input_json.len == 0) "{}" else input_json;
    const out = runTool(t, arena, tool, input, &msg, &cs) catch |e| switch (e) {
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

fn parse(comptime T: type, a: Allocator, input: []const u8, msg: *[]const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, input, .{ .allocate = .alloc_always }) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "invalid input: {t}", .{e});
        return error.BadInput;
    };
}

fn runTool(t: *ToolExporter, a: Allocator, tool: []const u8, input: []const u8, msg: *[]const u8, cs: *?u64) ![]const u8 {
    const lib = t.lib;
    if (std.mem.eql(u8, tool, "library_search")) {
        const In = struct { query: []const u8, limit: ?u32 = null };
        const in = try parse(In, a, input, msg);
        var hits: std.ArrayList(PromptLibrary.Hit) = .empty;
        try lib.search(in.query, @min(in.limit orelse t.max_hits, t.max_hits), &hits, a);
        const Row = struct { id: []const u8, title: []const u8, description: []const u8, source: []const u8, tags: []const []const u8 };
        const rows = try a.alloc(Row, hits.items.len);
        for (hits.items, rows) |h, *r| r.* = .{ .id = h.entry.id, .title = h.entry.title, .description = h.entry.description, .source = @tagName(h.entry.source), .tags = h.entry.tags };
        return std.json.Stringify.valueAlloc(a, rows, .{});
    }
    if (std.mem.eql(u8, tool, "library_get")) {
        const In = struct { id: []const u8 };
        const in = try parse(In, a, input, msg);
        const e = lib.get(in.id) orelse {
            msg.* = try std.fmt.allocPrint(a, "no library entry \"{s}\"", .{in.id});
            return error.BadInput;
        };
        const b = try lib.body(in.id, a);
        const V = struct { name: []const u8, type: []const u8, options: []const []const u8, default: ?[]const u8, required: bool };
        const vars = try a.alloc(V, e.variables.len);
        for (e.variables, vars) |d, *v| v.* = .{ .name = d.name, .type = @tagName(d.kind), .options = d.options, .default = d.default, .required = d.required };
        const R = struct { id: []const u8, title: []const u8, source: []const u8, variables: []const V, body: []const u8 };
        return std.json.Stringify.valueAlloc(a, R{ .id = e.id, .title = e.title, .source = @tagName(e.source), .variables = vars, .body = b }, .{});
    }
    if (std.mem.eql(u8, tool, "library_create")) {
        const In = struct { id: []const u8, title: []const u8, description: []const u8 = "", tags: []const []const u8 = &.{}, body: []const u8 };
        const in = try parse(In, a, input, msg);
        if (!PromptLibrary.validId(in.id)) {
            msg.* = "invalid id: use lowercase letters, digits, '.', '_' and '-', with '/' between segments";
            return error.BadInput;
        }
        const created = lib.create(a, .project, .{
            .id = in.id,
            .title = in.title,
            .description = in.description,
            .tags = in.tags,
            .variables = try template.detectVariables(a, in.body),
            .body = in.body,
        }) catch |e| switch (e) {
            error.AlreadyExists => {
                msg.* = try std.fmt.allocPrint(a, "\"{s}\" already exists in the project library", .{in.id});
                return error.BadInput;
            },
            else => return e,
        };
        cs.* = created.changeset;
        return std.fmt.allocPrint(a, "proposed {s} at .zigguro/prompts/{s} for review", .{ created.id, created.path });
    }
    return error.UnknownTool;
}
