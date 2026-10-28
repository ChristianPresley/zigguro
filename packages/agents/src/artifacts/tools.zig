//! Artifact tools for agents (E13.F07.S01.T01), through zg_ai's foreign
//! tool contract: `artifact_create`, `artifact_update`, `artifact_read`
//! and `artifact_list`. There is deliberately no save tool: agents write
//! workspace files with E10's file tools.

const std = @import("std");
const zg_ai = @import("zg_ai");
const store_mod = @import("store.zig");
const kinds = @import("kinds.zig");
const runs = @import("../runs/root.zig");
const chart = @import("../chart/root.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;
const ArtifactStore = store_mod.ArtifactStore;
const ArtifactId = store_mod.ArtifactId;

/// Text returned by `artifact_read` is cut at this many bytes.
pub const max_read = 64 << 10;

const kind_enum = "\"enum\":[\"markdown\",\"table\",\"chart\",\"diagram\",\"image\",\"html_source\",\"code\",\"text\"]";

pub const schemas = struct {
    pub const create = "{\"type\":\"object\",\"required\":[\"kind\",\"title\"],\"properties\":{" ++
        "\"kind\":{\"type\":\"string\"," ++ kind_enum ++ "}," ++
        "\"title\":{\"type\":\"string\"}," ++
        "\"content\":{\"type\":\"string\",\"description\":\"Markdown, CSV/JSON table, SVG image, HTML, code or text.\"}," ++
        "\"spec\":{\"description\":\"Chart spec (kind chart), as an object or JSON text.\",\"anyOf\":[" ++ chart.schema.object_json ++ ",{\"type\":\"string\"}]}," ++
        "\"source\":{\"type\":\"string\",\"description\":\"Diagram source (kind diagram).\"}," ++
        "\"language\":{\"type\":\"string\",\"description\":\"Language of kind code.\"}" ++
        "},\"additionalProperties\":false}";
    pub const update = "{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{" ++
        "\"id\":{\"type\":\"string\",\"description\":\"An artifact id like A-0123456789ABC.\"}," ++
        "\"content\":{\"type\":\"string\"}," ++
        "\"spec\":{\"description\":\"Chart spec, as an object or JSON text.\",\"anyOf\":[" ++ chart.schema.object_json ++ ",{\"type\":\"string\"}]}," ++
        "\"source\":{\"type\":\"string\"}," ++
        "\"note\":{\"type\":\"string\",\"description\":\"What changed in this version.\"}" ++
        "},\"additionalProperties\":false}";
    pub const read = "{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{" ++
        "\"id\":{\"type\":\"string\"}," ++
        "\"version\":{\"type\":\"integer\",\"minimum\":1,\"description\":\"Default: the latest.\"}" ++
        "},\"additionalProperties\":false}";
    pub const list = "{\"type\":\"object\",\"properties\":{" ++
        "\"run\":{\"type\":\"string\",\"description\":\"Only this run's artifacts (default: the current run's; \\\"all\\\" for every run).\"}" ++
        "},\"additionalProperties\":false}";
};

pub const tool_list = [_]foreign.ForeignTool{
    .{ .name = "artifact_create", .description = "Create an artifact shown beside the conversation: a document, table, chart, diagram, SVG image, HTML or code. Returns its id.", .input_schema_json = schemas.create },
    .{ .name = "artifact_update", .description = "Add a new version of an artifact (earlier versions are kept).", .input_schema_json = schemas.update },
    .{ .name = "artifact_read", .description = "An artifact's content (a version, or the latest).", .input_schema_json = schemas.read, .read_only = true },
    .{ .name = "artifact_list", .description = "Artifacts of the current run (or another run, or all).", .input_schema_json = schemas.list, .read_only = true },
};

pub const Source = struct {
    store: *ArtifactStore,
    run: ?runs.RunId = null,
    session: ?[]const u8 = null,
    /// The run's project; new artifacts get it.
    project: ?[]const u8 = null,
};

/// Must not move after `exporter`.
pub const ToolExporter = struct {
    src: Source,

    pub fn exporter(self: *ToolExporter) foreign.Exporter {
        return .{ .name = "artifacts", .kind = .agents, .ctx = self, .list = listFn, .call = callFn };
    }

    fn listFn(_: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        return arena.dupe(foreign.ForeignTool, &tool_list);
    }

    fn callFn(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!foreign.Result {
        _ = io;
        const self: *ToolExporter = @ptrCast(@alignCast(ctx));
        const r = try run(&self.src, arena, tool, input_json);
        return .{ .json = r.json };
    }
};

pub const Output = struct { json: []const u8, is_error: bool = false, text: []const u8 = "" };

pub fn run(src: *Source, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    const input = if (input_json.len == 0) "{}" else input_json;
    const out = runTool(src, arena, tool, input, &msg) catch |e| switch (e) {
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

fn bad(msg: *[]const u8, text: []const u8) error{BadInput} {
    msg.* = text;
    return error.BadInput;
}

fn idOf(a: Allocator, s: []const u8, msg: *[]const u8) !ArtifactId {
    return ArtifactId.parse(s) orelse {
        msg.* = try std.fmt.allocPrint(a, "`{s}` is not an artifact id (like A-0123456789ABC); see artifact_list", .{s});
        return error.BadInput;
    };
}

/// The one body field given (`content`, `spec` or `source`), as text.
fn body(a: Allocator, content: ?[]const u8, spec: ?std.json.Value, source: ?[]const u8, msg: *[]const u8) ![]const u8 {
    const n = @as(u8, @intFromBool(content != null)) + @intFromBool(spec != null) + @intFromBool(source != null);
    if (n != 1) return bad(msg, "give exactly one of `content`, `spec` or `source`");
    if (content) |c| return c;
    if (source) |s| return s;
    return switch (spec.?) {
        .string => |s| s,
        else => |v| try std.json.Stringify.valueAlloc(a, v, .{}),
    };
}

fn invalidMsg(a: Allocator, m: []const u8, msg: *[]const u8) error{ BadInput, OutOfMemory } {
    msg.* = std.fmt.allocPrint(a, "invalid artifact: {s}", .{m}) catch return error.OutOfMemory;
    return error.BadInput;
}

fn runTool(src: *Source, a: Allocator, tool: []const u8, input: []const u8, msg: *[]const u8) ![]const u8 {
    const eq = std.mem.eql;
    const opt: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    if (eq(u8, tool, "artifact_create")) {
        const In = struct { kind: kinds.ArtifactKind, title: []const u8, content: ?[]const u8 = null, spec: ?std.json.Value = null, source: ?[]const u8 = null, language: ?[]const u8 = null };
        const in = try parse(In, a, input, msg);
        if (in.spec != null and in.kind != .chart) return bad(msg, "`spec` is for kind chart");
        if (in.source != null and in.kind != .diagram) return bad(msg, "`source` is for kind diagram");
        if (std.mem.trim(u8, in.title, " \t\r\n").len == 0) return bad(msg, "`title` is empty");
        const content = try body(a, in.content, in.spec, in.source, msg);
        var why: []const u8 = "";
        const id = src.store.createChecked(a, .{ .kind = in.kind, .title = in.title, .content = content, .run = src.run, .source_lang = in.language, .session = src.session, .project = src.project }, &why) catch |e| switch (e) {
            error.Invalid => return invalidMsg(a, why, msg),
            else => return e,
        };
        const Out = struct { id: []const u8, version: u32, kind: kinds.ArtifactKind, title: []const u8 };
        return std.json.Stringify.valueAlloc(a, Out{ .id = try a.dupe(u8, &id.text()), .version = 1, .kind = in.kind, .title = in.title }, opt);
    }
    if (eq(u8, tool, "artifact_update")) {
        const In = struct { id: []const u8, content: ?[]const u8 = null, spec: ?std.json.Value = null, source: ?[]const u8 = null, note: ?[]const u8 = null };
        const in = try parse(In, a, input, msg);
        const id = try idOf(a, in.id, msg);
        const content = try body(a, in.content, in.spec, in.source, msg);
        var why: []const u8 = "";
        const prev = (try src.store.get(id, a)) orelse return noArtifact(a, in.id, msg);
        const n = src.store.updateChecked(a, id, content, .{ .note = in.note, .prov = .{ .run = src.run, .session = src.session } }, &why) catch |e| switch (e) {
            error.Invalid => return invalidMsg(a, why, msg),
            error.UnknownArtifact => return noArtifact(a, in.id, msg),
            else => return e,
        };
        const Out = struct { id: []const u8, version: u32, unchanged: bool };
        return std.json.Stringify.valueAlloc(a, Out{ .id = in.id, .version = n, .unchanged = n == prev.latest().n }, opt);
    }
    if (eq(u8, tool, "artifact_read")) {
        const In = struct { id: []const u8, version: ?u32 = null };
        const in = try parse(In, a, input, msg);
        const id = try idOf(a, in.id, msg);
        const meta = (try src.store.get(id, a)) orelse return noArtifact(a, in.id, msg);
        const c = src.store.read(id, in.version, a) catch |e| switch (e) {
            error.UnknownVersion => {
                msg.* = try std.fmt.allocPrint(a, "{s} has versions 1..{d}", .{ in.id, meta.versions.len });
                return error.BadInput;
            },
            else => return e,
        };
        const v = meta.version(c.version).?;
        const Out = struct {
            id: []const u8,
            kind: kinds.ArtifactKind,
            title: []const u8,
            version: u32,
            versions: u32,
            mime: []const u8,
            size: u64,
            width: ?u32 = null,
            height: ?u32 = null,
            content: ?[]const u8 = null,
            truncated: ?bool = null,
            note: ?[]const u8 = null,
        };
        var o: Out = .{ .id = in.id, .kind = meta.kind, .title = meta.title, .version = c.version, .versions = c.versions, .mime = c.mime, .size = c.bytes.len, .note = v.note };
        const text = meta.kind.isText() or std.mem.eql(u8, c.ext, "svg");
        if (text and std.unicode.utf8ValidateSlice(c.bytes)) {
            const cut = c.bytes.len > max_read;
            o.content = if (cut) c.bytes[0..utf8Floor(c.bytes, max_read)] else c.bytes;
            if (cut) o.truncated = true;
        }
        if (meta.kind == .image) {
            o.width = v.width;
            o.height = v.height;
        }
        return std.json.Stringify.valueAlloc(a, o, opt);
    }
    if (eq(u8, tool, "artifact_list")) {
        const In = struct { run: ?[]const u8 = null };
        const in = try parse(In, a, input, msg);
        var filter: store_mod.ListFilter = .{ .run = src.run };
        if (in.run) |r| {
            filter.run = if (eq(u8, r, "all")) null else runs.RunId.parse(r) catch return bad(msg, "`run` is not a run id");
        }
        var items: std.ArrayList(store_mod.Artifact) = .empty;
        try src.store.list(filter, &items, a);
        const Row = struct { id: []const u8, kind: kinds.ArtifactKind, title: []const u8, versions: usize, updated: i64, run: ?[]const u8 = null };
        const rows = try a.alloc(Row, items.items.len);
        for (items.items, rows) |it, *r| r.* = .{ .id = it.id, .kind = it.kind, .title = it.title, .versions = it.versions.len, .updated = it.latest().created, .run = if (filter.run == null) it.run else null };
        return std.json.Stringify.valueAlloc(a, rows, opt);
    }
    return error.UnknownTool;
}

fn noArtifact(a: Allocator, id: []const u8, msg: *[]const u8) error{ BadInput, OutOfMemory } {
    msg.* = std.fmt.allocPrint(a, "no artifact {s}; see artifact_list", .{id}) catch return error.OutOfMemory;
    return error.BadInput;
}

fn utf8Floor(s: []const u8, n: usize) usize {
    var i = n;
    while (i > 0 and i < s.len and (s[i] & 0xC0) == 0x80) i -= 1;
    return i;
}
