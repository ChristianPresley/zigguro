//! `edit_file` and `multi_edit` (E10.F06.S02.T02): exact string
//! replacement, proposed through `Files` (E05 `AgentEditSession` in the
//! IDE), never written here.
//!
//! The agent must have read the file first. `edit_file` proposes a
//! `str_replace`, so E05 can rebase it over the user's typing.
//! `multi_edit` applies its edits in order to the text the agent sees and
//! proposes the result as one whole-file change: if any edit fails, none
//! is proposed.

const std = @import("std");
const proto = @import("zg_ai_proto");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;
const FileTools = files.FileTools;

pub const edit_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean","default":false}},"required":["path","old_string","new_string"],"additionalProperties":false}
;

pub const multi_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"edits":{"type":"array","minItems":1,"items":{"$ref":"#/$defs/edit"}}},"required":["path","edits"],"$defs":{"edit":{"type":"object","properties":{"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["old_string","new_string"]}}}
;

pub fn editSpec(ft: *FileTools) proto.ToolSpec {
    return .{
        .name = "edit_file",
        .description = "Replace old_string with new_string in a file. old_string must match exactly once (including whitespace) unless replace_all is set. Read the file first.",
        .input_schema_json = edit_schema,
        .read_only = false,
        .effects = .{ .writes_workspace = true },
        .handler = .{ .ctx = ft, .call = editCall },
    };
}

pub fn multiEditSpec(ft: *FileTools) proto.ToolSpec {
    return .{
        .name = "multi_edit",
        .description = "Apply several exact replacements to one file in order, all or nothing. Each edit sees the result of the ones before it. Read the file first.",
        .input_schema_json = multi_schema,
        .read_only = false,
        .effects = .{ .writes_workspace = true },
        .handler = .{ .ctx = ft, .call = multiCall },
    };
}

/// The file as the agent may edit it, or the error text.
const Target = union(enum) {
    ok: struct { r: files.Resolved, read: files.Read },
    err: []const u8,
};

fn target(ft: *FileTools, c: *proto.ToolCall, path: []const u8) proto.ToolError!Target {
    const a = c.arena;
    const r = switch (try ft.open(c, path, .write)) {
        .ok => |r| r,
        .denied => |why| return .{ .err = try std.fmt.allocPrint(a, "Permission denied: {s}", .{why}) },
    };
    switch (ft.files.kindAs(c.io, r.abs, c.agent)) {
        .missing => return .{ .err = try std.fmt.allocPrint(a, "File not found: {s}. Use write_file to create it.", .{r.rel}) },
        .directory => return .{ .err = try std.fmt.allocPrint(a, "{s} is a directory.", .{r.rel}) },
        .file => {},
    }
    if (ft.tracker.version(c.agent, r.abs) == null)
        return .{ .err = try std.fmt.allocPrint(a, "Read {s} with read_file before editing it.", .{r.rel}) };
    const read = ft.files.readAs(c.io, a, r.abs, std.math.maxInt(usize), c.agent) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return .{ .err = try std.fmt.allocPrint(a, "Could not read {s}: {s}", .{ r.rel, @errorName(e) }) },
    };
    return .{ .ok = .{ .r = r, .read = read } };
}

fn origin(c: *proto.ToolCall) files.Origin {
    return .{ .agent = c.agent, .turn = c.turn, .tool = c.name, .tool_call_id = c.id };
}

/// Records the agent's own change as read.
fn track(ft: *FileTools, c: *proto.ToolCall, abs: []const u8, o: files.Outcome, after: []const u8) Allocator.Error!void {
    if (o != .applied) return;
    try ft.tracker.wrote(c.agent, abs, o.applied.version, std.mem.count(u8, after, "\n") + 1);
}

fn proposeErr(a: Allocator, rel: []const u8, e: anyerror) proto.ToolError!proto.ToolOutput {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => files.errOut(a, try std.fmt.allocPrint(a, "Could not edit {s}: {s}", .{ rel, @errorName(e) })),
    };
}

fn editCall(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
    const ft: *FileTools = @ptrCast(@alignCast(ctx));
    const a = c.arena;
    const path = files.str(c.input, "path") orelse return files.errOut(a, "edit_file needs a \"path\" string.");
    const old = files.str(c.input, "old_string") orelse return files.errOut(a, "edit_file needs an \"old_string\" string.");
    const new = files.str(c.input, "new_string") orelse return files.errOut(a, "edit_file needs a \"new_string\" string.");
    if (old.len == 0) return files.errOut(a, "old_string is empty; use write_file to create or overwrite a file.");
    if (std.mem.eql(u8, old, new)) return files.errOut(a, "old_string and new_string are identical; nothing to change.");
    const occ: files.Occurrence = if (files.boolean(c.input, "replace_all")) .all else .unique;
    const t = switch (try target(ft, c, path)) {
        .ok => |t| t,
        .err => |msg| return files.errOut(a, msg),
    };
    // What the agent's view becomes, for the diff.
    const after = switch (try files.strReplace(a, t.read.bytes, old, new, occ)) {
        .ok => |ok| ok.text,
        else => null,
    };
    const o = ft.files.propose(c.io, a, t.r.abs, .{ .str_replace = .{ .old = old, .new = new, .occurrence = occ } }, origin(c)) catch |e|
        return proposeErr(a, t.r.rel, e);
    try track(ft, c, t.r.abs, o, after orelse t.read.bytes);
    return FileTools.withNotes(c, t.read.notes, try ft.withDiagnostics(c, t.r.abs, o, try files.outcomeText(a, t.r.rel, "edit", o, t.read.bytes, after orelse t.read.bytes, ft.cfg.diff_lines)));
}

fn multiCall(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
    const ft: *FileTools = @ptrCast(@alignCast(ctx));
    const a = c.arena;
    const path = files.str(c.input, "path") orelse return files.errOut(a, "multi_edit needs a \"path\" string.");
    const edits = if (c.input == .object) c.input.object.get("edits") else null;
    if (edits == null or edits.? != .array or edits.?.array.items.len == 0) return files.errOut(a, "multi_edit needs a non-empty \"edits\" array.");
    const t = switch (try target(ft, c, path)) {
        .ok => |t| t,
        .err => |msg| return files.errOut(a, msg),
    };
    var text = t.read.bytes;
    for (edits.?.array.items, 0..) |e, i| {
        const old = files.str(e, "old_string") orelse return files.errOut(a, try std.fmt.allocPrint(a, "Edit {d} needs old_string and new_string; no edits were made.", .{i}));
        const new = files.str(e, "new_string") orelse return files.errOut(a, try std.fmt.allocPrint(a, "Edit {d} needs old_string and new_string; no edits were made.", .{i}));
        if (old.len == 0 or std.mem.eql(u8, old, new))
            return files.errOut(a, try std.fmt.allocPrint(a, "Edit {d}: old_string must be non-empty and differ from new_string; no edits were made.", .{i}));
        const occ: files.Occurrence = if (files.boolean(e, "replace_all")) .all else .unique;
        text = switch (try files.strReplace(a, text, old, new, occ)) {
            .ok => |ok| ok.text,
            .not_found => return files.errOut(a, try std.fmt.allocPrint(a, "Edit {d}: {s} No edits were made.", .{ i, try files.rejectionText(a, t.r.rel, .not_found) })),
            .not_unique => |n| return files.errOut(a, try std.fmt.allocPrint(a, "Edit {d}: {s} No edits were made.", .{ i, try files.rejectionText(a, t.r.rel, .{ .not_unique = n }) })),
        };
    }
    const o = ft.files.propose(c.io, a, t.r.abs, .{ .whole_file = .{ .text = text, .base_version = t.read.version } }, origin(c)) catch |e|
        return proposeErr(a, t.r.rel, e);
    try track(ft, c, t.r.abs, o, text);
    return FileTools.withNotes(c, t.read.notes, try ft.withDiagnostics(c, t.r.abs, o, try files.outcomeText(a, t.r.rel, try std.fmt.allocPrint(a, "{d} edits", .{edits.?.array.items.len}), o, t.read.bytes, text, ft.cfg.diff_lines)));
}
