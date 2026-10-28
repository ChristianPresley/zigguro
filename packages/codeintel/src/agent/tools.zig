//! Language-server tools for agents (E07.F05.S01.T03, the E07 exporter
//! of E10.F06.S03.T01). zg_codeintel sits on zg_ai's layer, so like
//! zg_scm and zg_mcp it is generic over zg_ai's foreign-tool contract:
//!
//! ```zig
//! const X = zg_codeintel.agent.tools.ToolExporter(zg_ai.tools.adapters.foreign);
//! var x: X = .{ .src = .{ .mgr = &mgr, .store = &store, .roots = roots, .ui = ui, .bg = &bg } };
//! services.lsp = x.exporter();
//! ```
//!
//! Tools, all read-only:
//! - `lsp_diagnostics`: errors and warnings (or every severity) of one
//!   file or of the whole workspace, from the diagnostic store;
//! - `lsp_hover`: the server's hover text (type, signature, docs) for a
//!   symbol;
//! - `lsp_definition`: where a symbol is defined.
//!
//! Symbols are addressed by a path and a 1-based line with either a
//! 1-based column in characters or the symbol's name, looked up on that
//! line and up to three lines either side (agents are often a line off),
//! or by a qualified name (`std.mem.Allocator`) the workspace symbol
//! search finds. The calls go through `CodeIntel` (CodeIntel.zig), which
//! opens files the editor does not have in the background. Results are
//! MCP `CallToolResult` JSON with one text block; bad input comes back
//! as `isError` so the model can correct itself.

const std = @import("std");
const Store = @import("../diagnostics/Store.zig");
const CodeIntel = @import("CodeIntel.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const UiPort = CodeIntel.UiPort;
/// The tools' view of the language services. Must not move once used.
pub const Source = CodeIntel;

const max_limit = 500;

const diagnostics_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File to report on, absolute or relative to the workspace root. Omit for every file with diagnostics."},"min_severity":{"type":"string","enum":["error","warning","information","hint"],"description":"Default: warning."},"limit":{"type":"integer","minimum":1,"maximum":500,"description":"Most diagnostics listed (default 50)."}},"additionalProperties":false}
;
const symbol_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File, absolute or relative to the workspace root."},"line":{"type":"integer","minimum":1,"description":"1-based line (with path)."},"name":{"type":"string","description":"The symbol's name; looked up on the line and up to 3 lines either side."},"occurrence":{"type":"integer","minimum":1,"description":"Which match of name on the line (default 1)."},"column":{"type":"integer","minimum":1,"description":"1-based column in characters, when name is not given."},"qualified":{"type":"string","description":"Instead of path and line: the symbol's qualified name, such as std.mem.Allocator, found by a workspace symbol search."}},"additionalProperties":false}
;

/// `Foreign` is `zg_ai.tools.adapters.foreign` (or a test double with the
/// same declarations). Must not move after `exporter`.
pub fn ToolExporter(comptime Foreign: type) type {
    return struct {
        const Self = @This();

        src: Source,

        pub fn exporter(self: *Self) Foreign.Exporter {
            return .{ .name = "lsp", .kind = .lsp, .ctx = self, .list = list, .call = call };
        }

        fn list(_: *anyopaque, arena: Allocator) anyerror![]const Foreign.ForeignTool {
            return arena.dupe(Foreign.ForeignTool, &.{
                .{ .name = "lsp_diagnostics", .description = "Compiler and linter diagnostics from the language servers, for one file or the whole workspace: file:line:column, severity, message and source.", .input_schema_json = diagnostics_schema, .read_only = true },
                .{ .name = "lsp_hover", .description = "The language server's hover for a symbol: its type or signature and documentation.", .input_schema_json = symbol_schema, .read_only = true },
                .{ .name = "lsp_definition", .description = "Where a symbol is defined, as file:line:column (several for overloads).", .input_schema_json = symbol_schema, .read_only = true },
            });
        }

        fn call(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Foreign.Result {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var text: Io.Writer.Allocating = .init(arena);
            const ok = run(&self.src, io, arena, tool, input_json, &text.writer) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => blk: {
                    text.clearRetainingCapacity();
                    try text.writer.print("{s} failed: {t}", .{ tool, e });
                    break :blk false;
                },
            };
            return .{ .json = try resultJson(arena, text.written(), !ok) };
        }
    };
}

const Input = struct {
    path: ?[]const u8 = null,
    min_severity: ?Store.Severity = null,
    limit: ?u32 = null,
    line: ?u32 = null,
    name: ?[]const u8 = null,
    occurrence: ?u32 = null,
    column: ?u32 = null,
    qualified: ?[]const u8 = null,
};

/// False when the input was bad (the text says why).
pub fn run(src: *Source, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8, w: *Io.Writer) !bool {
    const in = parseInput(arena, input_json) catch {
        try w.writeAll("The arguments are not valid for this tool (check names and types against its schema).");
        return false;
    };
    if (std.mem.eql(u8, tool, "lsp_diagnostics")) return diagnostics(src, arena, in, w);
    const which: Which = if (std.mem.eql(u8, tool, "lsp_hover")) .hover else if (std.mem.eql(u8, tool, "lsp_definition")) .definition else return error.UnknownTool;
    return symbolTool(src, io, arena, which, in, w);
}

fn parseInput(arena: Allocator, json: []const u8) !Input {
    const Raw = struct {
        path: ?[]const u8 = null,
        min_severity: ?[]const u8 = null,
        limit: ?u32 = null,
        line: ?u32 = null,
        name: ?[]const u8 = null,
        occurrence: ?u32 = null,
        column: ?u32 = null,
        qualified: ?[]const u8 = null,
    };
    const r = try std.json.parseFromSliceLeaky(Raw, arena, if (json.len == 0) "{}" else json, .{});
    var in: Input = .{ .path = r.path, .limit = r.limit, .line = r.line, .name = r.name, .occurrence = r.occurrence, .column = r.column, .qualified = r.qualified };
    if (r.min_severity) |s| {
        in.min_severity = for ([_]Store.Severity{ .err, .warning, .information, .hint }) |v| {
            if (std.mem.eql(u8, s, v.label()) or (v == .err and std.mem.eql(u8, s, "error")) or (v == .information and std.mem.eql(u8, s, "information"))) break v;
        } else return error.BadSeverity;
    }
    return in;
}

/// `path` made absolute and checked against the roots; null (with the
/// reason written) when refused.
fn resolve(src: *const Source, arena: Allocator, path: []const u8, w: *Io.Writer) !?[]const u8 {
    var call: CodeIntel.Call = .init(undefined, arena);
    return src.resolvePath(&call, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            try w.print("{s}.", .{call.why});
            return null;
        },
    };
}

// ------------------------------------------------------------ diagnostics

fn diagnostics(src: *const Source, arena: Allocator, in: Input, w: *Io.Writer) !bool {
    const min = @intFromEnum(in.min_severity orelse .warning);
    const limit = @min(in.limit orelse 50, max_limit);
    const snap = src.store.acquire();
    defer snap.release();
    var keys: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    if (in.path) |p| {
        const abs = try resolve(src, arena, p, w) orelse return false;
        try keys.append(arena, try src.store.keyOfPath(arena, abs));
        try names.append(arena, p);
    } else for (snap.keys()) |k| {
        try keys.append(arena, k);
        try names.append(arena, relative(src, k));
    }

    var counts: [4]usize = @splat(0);
    var files: usize = 0;
    var listed: usize = 0;
    var body: Io.Writer.Allocating = .init(arena);
    var all: std.ArrayList(*const Store.Diagnostic) = .empty;
    for (keys.items, names.items) |k, name| {
        all.clearRetainingCapacity();
        try snap.forKey(k, arena, &all);
        var any = false;
        for (all.items) |d| {
            if (@intFromEnum(d.severity) > min) continue;
            counts[@intFromEnum(d.severity) - 1] += 1;
            any = true;
            if (listed == limit) continue;
            listed += 1;
            try body.writer.print("\n{s}:{d}:{d}: {s}: ", .{ name, d.start.line + 1, d.start.character + 1, d.severity.label() });
            try body.writer.writeAll(d.message[0 .. std.mem.indexOfScalar(u8, d.message, '\n') orelse d.message.len]);
            if (d.code.len > 0 or d.source.len > 0) try body.writer.print(" [{s}{s}{s}]", .{ d.source, if (d.code.len > 0 and d.source.len > 0) " " else "", d.code });
        }
        if (any) files += 1;
    }
    const total = counts[0] + counts[1] + counts[2] + counts[3];
    if (total == 0) {
        if (in.path) |p| try w.print("No diagnostics for {s}", .{p}) else try w.writeAll("No diagnostics in the workspace");
        try w.writeAll(if (min == 1) " at error severity." else if (min == 2) " at warning severity or above." else ".");
        if (in.path != null and snap.bucket(keys.items[0]) == null) try w.writeAll(" (Only files open in the editor are checked by language servers.)");
        return true;
    }
    try w.print("{d} error{s}, {d} warning{s}", .{ counts[0], plural(counts[0]), counts[1], plural(counts[1]) });
    if (min > 2) try w.print(", {d} other", .{counts[2] + counts[3]});
    if (in.path == null) try w.print(" in {d} file{s}", .{ files, plural(files) });
    try w.writeAll(":");
    try w.writeAll(body.written());
    if (total > listed) try w.print("\n... and {d} more (raise limit to see them).", .{total - listed});
    return true;
}

/// A key shown relative to the first root when inside it.
fn relative(src: *const Source, key: []const u8) []const u8 {
    if (src.roots.len == 0) return key;
    // Keys are case-folded on Windows: compare the same way.
    const root = src.roots[0];
    if (key.len > root.len + 1 and std.ascii.eqlIgnoreCase(key[0..root.len], root) and (key[root.len] == '/' or key[root.len] == '\\')) return key[root.len + 1 ..];
    return key;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

// --------------------------------------------------------- hover, definition

const Which = enum { hover, definition };

/// The symbol the input names.
fn refOf(in: Input, w: *Io.Writer) !?CodeIntel.SymbolRef {
    if (in.qualified) |q| return .{ .qualified = q };
    const path = in.path orelse {
        try w.writeAll("`path` (with `line`) or `qualified` is required.");
        return null;
    };
    const line = in.line orelse {
        try w.writeAll("`line` is required with `path`.");
        return null;
    };
    if (in.name) |n| return .{ .name_on_line = .{ .path = path, .line = line, .name = n, .occurrence = in.occurrence orelse 1 } };
    return .{ .position = .{ .path = path, .line = line, .column = in.column } };
}

fn symbolTool(src: *Source, io: Io, arena: Allocator, which: Which, in: Input, w: *Io.Writer) !bool {
    const ref = try refOf(in, w) orelse return false;
    var call: CodeIntel.Call = .init(io, arena);
    const where = if (in.qualified) |q| q else try std.fmt.allocPrint(arena, "{s}:{d}", .{ in.path.?, in.line.? });
    switch (which) {
        .hover => {
            const text = src.hover(&call, ref) catch |e| return failed(&call, e, where, w);
            try adjusted(&call, in, w);
            try w.writeAll(text orelse "No hover information here.");
        },
        .definition => {
            const ls = src.definition(&call, ref, .definition) catch |e| return failed(&call, e, where, w);
            try adjusted(&call, in, w);
            if (ls.len == 0) try w.writeAll("No definition found.");
            for (ls, 0..) |l, i| {
                if (i > 0) try w.writeByte('\n');
                try writeLocation(src, w, l);
            }
        },
    }
    return true;
}

fn adjusted(call: *const CodeIntel.Call, in: Input, w: *Io.Writer) !void {
    if (call.adjusted_line) |l| try w.print("(found on line {d}, not {d})\n", .{ l, in.line.? });
}

/// The failure as the model reads it; false when its input was wrong.
fn failed(call: *const CodeIntel.Call, e: CodeIntel.Error, where: []const u8, w: *Io.Writer) !bool {
    if (e == error.OutOfMemory) return e;
    switch (e) {
        error.OutsideWorkspace => {
            try w.print("{s}.", .{call.why});
            return false;
        },
        error.Ambiguous => {
            try w.print("{s}:", .{call.why});
            for (call.candidates) |c| {
                try w.print("\n- {s}{s}{s} ({t})", .{ c.container orelse "", if (c.container != null) "." else "", c.name, c.kind });
                if (c.location) |l| try w.print(" {s}:{d}", .{ l.path, l.range.start.line + 1 });
            }
            return true;
        },
        else => {
            try w.print("No answer for {s}: {s}.", .{ where, call.why });
            return true;
        },
    }
}

fn writeLocation(src: *const Source, w: *Io.Writer, l: CodeIntel.Location) !void {
    const shown = if (l.is_file) relativePath(src, l.path) else l.path;
    // Columns are the server's units; close enough for an agent to read.
    try w.print("{s}:{d}:{d}", .{ shown, l.range.start.line + 1, l.range.start.character + 1 });
}

fn relativePath(src: *const Source, p: []const u8) []const u8 {
    for (src.roots) |root| {
        if (p.len > root.len + 1 and std.mem.startsWith(u8, p, root) and (p[root.len] == '/' or p[root.len] == '\\')) return p[root.len + 1 ..];
    }
    return p;
}

/// An MCP `CallToolResult` with one text block.
fn resultJson(arena: Allocator, text: []const u8, is_error: bool) Allocator.Error![]const u8 {
    const R = struct {
        content: []const struct { type: []const u8 = "text", text: []const u8 },
        isError: bool,
    };
    return std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = is_error }, .{});
}
