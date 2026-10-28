//! Project tools for agents (E13.F09.S01.T01), through zg_ai's
//! foreign-tool contract. All three only read:
//! `project_info{}` describes the project, `project_knowledge_list{query?}`
//! lists its knowledge files (filtered by a case-insensitive substring of
//! path or title) and `project_knowledge_read{path, offset?, limit?}`
//! returns one of them. A path outside the project's knowledge, or one the
//! deny policy marks secret, is refused.

const std = @import("std");
const zg_ai = @import("zg_ai");
const project = @import("project.zig");
const knowledge = @import("knowledge.zig");
const Context = @import("context.zig").Context;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;

/// Bytes `project_knowledge_read` returns at most per call.
pub const max_read = 64 * 1024;

pub const schemas = struct {
    pub const info = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
    pub const list = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"Keeps files whose path or title contains this text.\"}},\"additionalProperties\":false}";
    pub const read = "{\"type\":\"object\",\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"A workspace-relative path from project_knowledge_list.\"},\"offset\":{\"type\":\"integer\",\"description\":\"Byte offset to start at.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Bytes to return (at most 65536).\"}},\"additionalProperties\":false}";
};

pub const tool_list = [_]foreign.ForeignTool{
    .{ .name = "project_info", .description = "The current project: title, description, run defaults and knowledge sources.", .input_schema_json = schemas.info, .read_only = true },
    .{ .name = "project_knowledge_list", .description = "List the project's knowledge files (path, title, size, modified).", .input_schema_json = schemas.list, .read_only = true },
    .{ .name = "project_knowledge_read", .description = "Read one of the project's knowledge files.", .input_schema_json = schemas.read, .read_only = true },
};

/// Must not move after `exporter`.
pub const ToolExporter = struct {
    ctx: *Context,
    /// The run's project; null uses the active project.
    project: ?[]const u8 = null,
    max_list: u32 = 500,

    pub fn exporter(self: *ToolExporter) foreign.Exporter {
        return .{ .name = "project", .kind = .agents, .ctx = self, .list = listFn, .call = callFn };
    }

    fn listFn(_: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        return arena.dupe(foreign.ForeignTool, &tool_list);
    }

    fn callFn(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!foreign.Result {
        _ = io;
        const self: *ToolExporter = @ptrCast(@alignCast(ctx));
        const r = try run(self, arena, tool, input_json);
        return .{ .json = r.json };
    }
};

pub const Output = struct { json: []const u8, is_error: bool = false, text: []const u8 = "" };

pub fn run(t: *ToolExporter, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    const input = if (input_json.len == 0) "{}" else input_json;
    const out = runTool(t, arena, tool, input, &msg) catch |e| switch (e) {
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
    return .{ .json = try std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = out == null }, .{}), .is_error = out == null, .text = text };
}

fn parse(comptime T: type, a: Allocator, input: []const u8, msg: *[]const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, input, .{ .allocate = .alloc_always }) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "invalid input: {t}", .{e});
        return error.BadInput;
    };
}

fn runTool(t: *ToolExporter, a: Allocator, tool: []const u8, input: []const u8, msg: *[]const u8) ![]const u8 {
    const c = t.ctx;
    const store = c.store;
    const v = store.view();
    defer store.release(v);
    const slug = t.project orelse store.active() orelse {
        msg.* = "no project is active";
        return error.BadInput;
    };
    const p = v.get(slug) orelse {
        msg.* = try std.fmt.allocPrint(a, "no project \"{s}\"", .{slug});
        return error.BadInput;
    };
    if (std.mem.eql(u8, tool, "project_info")) {
        _ = try parse(struct {}, a, input, msg);
        const Item = struct { kind: []const u8, value: []const u8, glob: ?[]const u8 = null };
        const items = try a.alloc(Item, p.knowledge.len);
        for (p.knowledge, items) |k, *it| it.* = switch (k) {
            .folder => |d| .{ .kind = "folder", .value = d.path, .glob = d.glob },
            .notes_query => |q| .{ .kind = "notes_query", .value = q },
            .file => |f| .{ .kind = "file", .value = f },
            .source => |q| .{ .kind = "source", .value = q },
        };
        const R = struct { slug: []const u8, title: []const u8, description: []const u8, defaults: project.Defaults, knowledge: []const Item };
        return std.json.Stringify.valueAlloc(a, R{ .slug = p.slug, .title = p.title, .description = p.description, .defaults = p.defaults, .knowledge = items }, .{ .emit_null_optional_fields = false });
    }
    if (std.mem.eql(u8, tool, "project_knowledge_list")) {
        const In = struct { query: ?[]const u8 = null };
        const in = try parse(In, a, input, msg);
        const idx = try knowledge.build(c.io, a, p, c.env, .{ .max_entries = std.math.maxInt(u32), .max_tokens = std.math.maxInt(u32), .max_walk = c.limits.max_walk });
        var w: Io.Writer.Allocating = .init(a);
        var n: u32 = 0;
        var more: u32 = 0;
        for (idx.entries) |e| {
            if (in.query) |q| if (!containsIgnoreCase(e.path, q) and !containsIgnoreCase(e.title, q)) continue;
            if (n == t.max_list) {
                more += 1;
                continue;
            }
            n += 1;
            knowledge.writeEntry(&w.writer, e) catch return error.OutOfMemory;
            w.writer.writeByte('\n') catch return error.OutOfMemory;
        }
        if (more > 0) w.writer.print("+{d} more (narrow the query)\n", .{more}) catch return error.OutOfMemory;
        if (n == 0) w.writer.writeAll("(no matching knowledge files)\n") catch return error.OutOfMemory;
        for (idx.warnings) |x| w.writer.print("warning: {s}\n", .{x}) catch return error.OutOfMemory;
        return w.written();
    }
    if (std.mem.eql(u8, tool, "project_knowledge_read")) {
        const In = struct { path: []const u8, offset: u64 = 0, limit: u32 = max_read };
        const in = try parse(In, a, input, msg);
        if (!try knowledge.contains(a, p, c.env, in.path)) {
            msg.* = try std.fmt.allocPrint(a, "\"{s}\" is not one of the project's knowledge files", .{in.path});
            return error.BadInput;
        }
        const f = c.env.root.openFile(c.io, in.path, .{}) catch |e| {
            msg.* = try std.fmt.allocPrint(a, "cannot open {s}: {t}", .{ in.path, e });
            return error.BadInput;
        };
        defer f.close(c.io);
        const size = (try f.stat(c.io)).size;
        const buf = try a.alloc(u8, @min(in.limit, max_read));
        const got = try f.readPositionalAll(c.io, buf, in.offset);
        const end = in.offset + got;
        if (end < size) return std.fmt.allocPrint(a, "{s}\n\n[bytes {d}-{d} of {d}; read more with offset {d}]", .{ buf[0..got], in.offset, end, size, end });
        return buf[0..got];
    }
    return error.UnknownTool;
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}
