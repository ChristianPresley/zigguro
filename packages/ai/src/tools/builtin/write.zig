//! `write_file` (E10.F06.S02.T02): creates a file, or replaces one the
//! agent has read, through `Files` (an E12 create entry or an E05
//! whole-file proposal in the IDE), never written here.

const std = @import("std");
const proto = @import("zg_ai_proto");
const files = @import("files.zig");

const FileTools = files.FileTools;

pub const schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}
;

pub fn spec(ft: *FileTools) proto.ToolSpec {
    return .{
        .name = "write_file",
        .description = "Create a file with the given content, or replace an existing file you have read. Prefer edit_file for changes to existing files.",
        .input_schema_json = schema,
        .read_only = false,
        .effects = .{ .writes_workspace = true },
        .handler = .{ .ctx = ft, .call = call },
    };
}

fn lineCount(s: []const u8) usize {
    if (s.len == 0) return 0;
    return std.mem.count(u8, s, "\n") + @intFromBool(s[s.len - 1] != '\n');
}

fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
    const ft: *FileTools = @ptrCast(@alignCast(ctx));
    const a = c.arena;
    const path = files.str(c.input, "path") orelse return files.errOut(a, "write_file needs a \"path\" string.");
    const content = files.str(c.input, "content") orelse return files.errOut(a, "write_file needs a \"content\" string.");
    const r = switch (try ft.open(c, path, .write)) {
        .ok => |r| r,
        .denied => |why| return files.errOut(a, try std.fmt.allocPrint(a, "Permission denied: {s}", .{why})),
    };
    const origin: files.Origin = .{ .agent = c.agent, .turn = c.turn, .tool = c.name, .tool_call_id = c.id };
    switch (ft.files.kindAs(c.io, r.abs, c.agent)) {
        .directory => return files.errOut(a, try std.fmt.allocPrint(a, "{s} is a directory.", .{r.rel})),
        .missing => {
            const o = ft.files.propose(c.io, a, r.abs, .{ .create = .{ .text = content } }, origin) catch |e| return failed(a, r.rel, e);
            const n = lineCount(content);
            return switch (o) {
                .applied => |ap| blk: {
                    try ft.tracker.wrote(c.agent, r.abs, ap.version, n);
                    break :blk ft.withDiagnostics(c, r.abs, o, try files.textOut(a, try std.fmt.allocPrint(a, "Created {s} ({d} lines).", .{ r.rel, n })));
                },
                .pending => |p| files.textOut(a, try std.fmt.allocPrint(a, "Proposed new file {s} ({d} lines) in {s} — pending review.", .{ r.rel, n, try files.changesetName(a, p.changeset) })),
                .rejected => |rej| files.errOut(a, try files.rejectionText(a, r.rel, rej)),
            };
        },
        .file => {},
    }
    const base = ft.tracker.version(c.agent, r.abs) orelse
        return files.errOut(a, try std.fmt.allocPrint(a, "{s} already exists; read it with read_file before overwriting it.", .{r.rel}));
    const before = ft.files.readAs(c.io, a, r.abs, std.math.maxInt(usize), c.agent) catch |e| return failed(a, r.rel, e);
    const o = ft.files.propose(c.io, a, r.abs, .{ .whole_file = .{ .text = content, .base_version = base } }, origin) catch |e| return failed(a, r.rel, e);
    if (o == .applied) try ft.tracker.wrote(c.agent, r.abs, o.applied.version, lineCount(content));
    return files.FileTools.withNotes(c, before.notes, try ft.withDiagnostics(c, r.abs, o, try files.outcomeText(a, r.rel, "write", o, before.bytes, content, ft.cfg.diff_lines)));
}

fn failed(a: std.mem.Allocator, rel: []const u8, e: anyerror) proto.ToolError!proto.ToolOutput {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => files.errOut(a, try std.fmt.allocPrint(a, "Could not write {s}: {s}", .{ rel, @errorName(e) })),
    };
}
