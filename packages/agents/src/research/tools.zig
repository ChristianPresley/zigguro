//! Source tools for agents (E13.F05.S01.T01), through zg_ai's foreign-tool
//! contract: `source_capture{url}` saves a page to the source library
//! (an E12 changeset), `source_search{query}` finds captured sources,
//! `source_read{id, blocks?}` returns a source's passages with their
//! block indices for citing.

const std = @import("std");
const zg_ai = @import("zg_ai");
const sources = @import("sources.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;
const SourceLibrary = sources.SourceLibrary;

pub const schemas = struct {
    pub const capture = "{\"type\":\"object\",\"required\":[\"url\"],\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"An http(s) URL.\"}},\"additionalProperties\":false}";
    pub const search = "{\"type\":\"object\",\"required\":[\"query\"],\"properties\":{\"query\":{\"type\":\"string\"},\"limit\":{\"type\":\"integer\"}},\"additionalProperties\":false}";
    pub const read = "{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"string\",\"description\":\"A source id from source_search or source_capture.\"},\"blocks\":{\"type\":\"array\",\"items\":{\"type\":\"integer\"},\"minItems\":2,\"maxItems\":2,\"description\":\"First and last block index to return (default: all).\"}},\"additionalProperties\":false}";
};

pub const tool_list = [_]foreign.ForeignTool{
    .{ .name = "source_capture", .description = "Save a web page to the source library as a note (captured once per canonical URL).", .input_schema_json = schemas.capture, .mutates = true },
    .{ .name = "source_search", .description = "Find captured sources by words in their title, URL, site or text.", .input_schema_json = schemas.search, .read_only = true },
    .{ .name = "source_read", .description = "A captured source's passages, numbered by block index for citations.", .input_schema_json = schemas.read, .read_only = true },
};

pub const Source = struct {
    lib: *SourceLibrary,
    run: ?@import("../runs/root.zig").RunId = null,
    max_hits: u32 = 20,
};

/// Must not move after `exporter`.
pub const ToolExporter = struct {
    src: Source,

    pub fn exporter(self: *ToolExporter) foreign.Exporter {
        return .{ .name = "sources", .kind = .agents, .ctx = self, .list = listFn, .call = callFn };
    }

    fn listFn(_: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        return arena.dupe(foreign.ForeignTool, &tool_list);
    }

    fn callFn(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!foreign.Result {
        _ = io;
        const self: *ToolExporter = @ptrCast(@alignCast(ctx));
        const r = try run(&self.src, arena, tool, input_json);
        return .{ .json = r.json, .changeset = r.changeset };
    }
};

pub const Output = struct { json: []const u8, changeset: ?u64 = null, is_error: bool = false, text: []const u8 = "" };

pub fn run(src: *Source, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    var cs: ?u64 = null;
    const input = if (input_json.len == 0) "{}" else input_json;
    const out = runTool(src, arena, tool, input, &msg, &cs) catch |e| switch (e) {
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

fn runTool(src: *Source, a: Allocator, tool: []const u8, input: []const u8, msg: *[]const u8, cs: *?u64) ![]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, tool, "source_capture")) {
        const In = struct { url: []const u8 };
        const in = try parse(In, a, input, msg);
        const r = try src.lib.capture(in.url, .{ .run = src.run });
        cs.* = r.changeset;
        const Out = struct { result: []const u8, id: ?[]const u8 = null, path: ?[]const u8 = null };
        return std.json.Stringify.valueAlloc(a, Out{ .result = @tagName(r.kind), .id = if (r.id) |id| try a.dupe(u8, &id) else null, .path = r.path }, .{ .emit_null_optional_fields = false });
    }
    if (eq(u8, tool, "source_search")) {
        const In = struct { query: []const u8, limit: ?u32 = null };
        const in = try parse(In, a, input, msg);
        const hits = try src.lib.search(a, in.query, @min(in.limit orelse src.max_hits, 100));
        const H = struct { id: []const u8, title: []const u8, url: []const u8, site: []const u8 };
        const rows = try a.alloc(H, hits.len);
        for (hits, rows) |h, *r| r.* = .{ .id = try a.dupe(u8, &h.id), .title = h.title, .url = h.url, .site = h.site };
        return std.json.Stringify.valueAlloc(a, rows, .{});
    }
    if (eq(u8, tool, "source_read")) {
        const In = struct { id: []const u8, blocks: ?[2]u32 = null };
        const in = try parse(In, a, input, msg);
        if (in.id.len != 32) {
            msg.* = "id must be a 32-character source id";
            return error.BadInput;
        }
        const id: sources.SourceId = in.id[0..32].*;
        const s = src.lib.get(id) orelse {
            msg.* = try std.fmt.allocPrint(a, "no source {s}; see source_search", .{in.id});
            return error.BadInput;
        };
        const all = try src.lib.blocks(id, a);
        var lo: usize = 0;
        var hi: usize = all.len;
        if (in.blocks) |r| {
            lo = @min(r[0], all.len);
            hi = @min(@as(usize, r[1]) + 1, all.len);
            if (hi < lo) hi = lo;
        }
        const B = struct { index: u32, text: []const u8 };
        const bs = try a.alloc(B, hi - lo);
        for (all[lo..hi], bs) |b, *o| o.* = .{ .index = b.index, .text = b.text };
        const Out = struct { id: []const u8, title: []const u8, url: []const u8, published: ?[]const u8, blocks_total: usize, blocks: []const B };
        return std.json.Stringify.valueAlloc(a, Out{ .id = in.id, .title = s.title, .url = s.url, .published = s.published, .blocks_total = all.len, .blocks = bs }, .{ .emit_null_optional_fields = false });
    }
    return error.UnknownTool;
}
