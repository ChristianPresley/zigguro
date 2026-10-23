//! Language-server tools for agents (E07.F05.S01.T03, the E07 exporter
//! of E10.F06.S03.T01). zg_codeintel sits on zg_ai's layer, so like
//! zg_scm and zg_mcp it is generic over zg_ai's foreign-tool contract:
//!
//! ```zig
//! const X = zg_codeintel.agent.tools.ToolExporter(zg_ai.tools.adapters.foreign);
//! var x: X = .{ .src = .{ .mgr = &mgr, .store = &store, .roots = roots, .ui = ui } };
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
//! Symbols are addressed by a 1-based line and either a 1-based column in
//! characters or the symbol's name, looked up on that line and up to
//! three lines either side (agents are often a line off). Only files open
//! in the editor have language servers. Calls run on the agent's worker:
//! the parts that touch documents and the manager run on the UI thread
//! through `UiPort`, and server requests carry a deadline so their answer
//! always comes. Results are MCP `CallToolResult` JSON with one text
//! block; bad input comes back as `isError` so the model can correct
//! itself.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const Store = @import("../diagnostics/Store.zig");
const position = @import("../features/position.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = zg_lsp.client.Client;
const protocol = zg_lsp.protocol;
const registry = zg_editor.model.api.registry;

/// Runs work on the UI thread.
pub const UiPort = struct {
    ctx: *anyopaque,
    /// Runs `f(arg)` on the UI thread and returns once it has run; false
    /// when it could not be queued (nothing ran).
    run: *const fn (ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) bool,
};

pub const Source = struct {
    mgr: *Manager,
    store: *Store,
    /// Workspace roots (absolute); relative paths resolve against the
    /// first, and paths outside every root are refused.
    roots: []const []const u8,
    ui: UiPort,
    /// Deadline of each server request.
    timeout: Io.Duration = .fromSeconds(15),
};

const max_limit = 500;

const diagnostics_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File to report on, absolute or relative to the workspace root. Omit for every file with diagnostics."},"min_severity":{"type":"string","enum":["error","warning","information","hint"],"description":"Default: warning."},"limit":{"type":"integer","minimum":1,"maximum":500,"description":"Most diagnostics listed (default 50)."}},"additionalProperties":false}
;
const symbol_schema =
    \\{"type":"object","properties":{"path":{"type":"string","description":"File, absolute or relative to the workspace root; it must be open in the editor."},"line":{"type":"integer","minimum":1,"description":"1-based line."},"name":{"type":"string","description":"The symbol's name; looked up on the line and up to 3 lines either side."},"occurrence":{"type":"integer","minimum":1,"description":"Which match of name on the line (default 1)."},"column":{"type":"integer","minimum":1,"description":"1-based column in characters, when name is not given."}},"required":["path","line"],"additionalProperties":false}
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
};

/// False when the input was bad (the text says why).
pub fn run(src: *const Source, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8, w: *Io.Writer) !bool {
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
    };
    const r = try std.json.parseFromSliceLeaky(Raw, arena, if (json.len == 0) "{}" else json, .{});
    var in: Input = .{ .path = r.path, .limit = r.limit, .line = r.line, .name = r.name, .occurrence = r.occurrence, .column = r.column };
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
    const style = src.store.style;
    const sep: []const u8 = if (style == .windows) "\\" else "/";
    const abs = if (registry.isAbsolute(path, style) or src.roots.len == 0) path else try std.mem.concat(arena, u8, &.{ src.roots[0], sep, path });
    const norm = try registry.normalizePath(arena, abs, style);
    const key = try registry.pathKey(arena, norm, style);
    for (src.roots) |root| {
        const rk = try registry.pathKey(arena, try registry.normalizePath(arena, root, style), style);
        if (std.mem.startsWith(u8, key, rk) and (key.len == rk.len or key[rk.len] == '/' or key[rk.len] == '\\' or rk[rk.len - 1] == '/' or rk[rk.len - 1] == '\\')) return norm;
    }
    try w.print("{s} is outside the workspace.", .{path});
    return null;
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

fn Pending(comptime M: protocol.Method) type {
    return struct {
        io: Io,
        done: Io.Event = .unset,
        result: Client.Result(M) = undefined,

        fn onResult(ctx: ?*anyopaque, r: Client.Result(M)) void {
            const p: *@This() = @ptrCast(@alignCast(ctx.?));
            p.result = r;
            p.done.set(p.io);
        }
    };
}

/// The UI-thread half of a symbol request: find the document, the server
/// and the position, then send the request.
fn Ask(comptime M: protocol.Method) type {
    return struct {
        src: *const Source,
        arena: Allocator,
        abs: []const u8,
        in: Input,
        feature: Manager.Feature,
        pending: *Pending(M),
        /// Why nothing was sent (null: sent).
        refused: ?[]const u8 = null,
        adjusted_line: ?u32 = null,

        fn onUi(arg: *anyopaque) void {
            const a: *@This() = @ptrCast(@alignCast(arg));
            a.refused = a.send() catch |e| blk: {
                const why: []const u8 = std.fmt.allocPrint(a.arena, "the request failed: {t}", .{e}) catch "out of memory";
                break :blk why;
            };
        }

        fn send(a: *@This()) !?[]const u8 {
            const mgr = a.src.mgr;
            const h = try mgr.docs.findFile(a.abs) orelse return "the file is not open in the editor, so no language server has it";
            if (mgr.docMatch(h) == null) return "no language server handles this file (unknown language, or the folder is not trusted)";
            var clients: [1]*Client = undefined;
            if (mgr.clientsFor(h, a.feature, &clients) == 0) return try std.fmt.allocPrint(a.arena, "no running language server provides {t} for this file", .{a.feature});
            const c = clients[0];
            const doc = mgr.docs.get(h).?;
            const line0 = a.in.line.? - 1;
            if (line0 >= doc.tree.lineCount()) return try std.fmt.allocPrint(a.arena, "line {d} is past the end of the file ({d} lines)", .{ a.in.line.?, doc.tree.lineCount() });
            var m: position.Mapper = .{ .gpa = mgr.gpa, .tree = &doc.tree, .enc = position.encodingOf(c.encoding()) };
            defer m.deinit();
            const at = (try locate(&m, line0, a.in)) orelse return try std.fmt.allocPrint(a.arena, "\"{s}\" is not on line {d} or within 3 lines of it", .{ a.in.name.?, a.in.line.? });
            if (at.line != line0) a.adjusted_line = @intCast(at.line + 1);
            const pos = try m.positionOf(at.offset);
            const uri = mgr.docs.uri(h).?;
            _ = try c.request(M, .{ .textDocument = .{ .uri = uri }, .position = pos }, .{ .doc = mgr.docMatch(h), .timeout = a.src.timeout }, .{ .ctx = a.pending, .func = Pending(M).onResult });
            return null;
        }
    };
}

/// The byte offset the input points at: the named symbol on the line (or
/// near it), or the column (default: the first non-blank character).
fn locate(m: *position.Mapper, line0: u64, in: Input) !?struct { line: u64, offset: u64 } {
    const lines = m.tree.lineCount();
    if (in.name) |name| {
        if (name.len == 0) return null;
        // The line itself, then 1, 2 and 3 lines away (before, then after).
        const order = [_]i64{ 0, -1, 1, -2, 2, -3, 3 };
        for (order) |d| {
            const l = @as(i64, @intCast(line0)) + d;
            if (l < 0 or l >= lines) continue;
            const start = m.cursor.seek(m.tree, @intCast(l));
            const text = try m.cursor.text(m.tree, m.gpa, &m.scratch);
            m.text_line = std.math.maxInt(u64);
            if (findWord(text, name, if (d == 0) in.occurrence orelse 1 else 1)) |i| return .{ .line = @intCast(l), .offset = start + i };
        }
        return null;
    }
    const start = m.cursor.seek(m.tree, line0);
    const text = try m.cursor.text(m.tree, m.gpa, &m.scratch);
    m.text_line = std.math.maxInt(u64);
    const i = if (in.column) |col|
        zg_core.utf8.columnToByte(text, col - 1, .utf32)
    else
        std.mem.indexOfNone(u8, text, " \t") orelse 0;
    return .{ .line = line0, .offset = start + i };
}

/// The byte index of the `n`-th whole-word match of `word` in `text`.
fn findWord(text: []const u8, word: []const u8, n: u32) ?usize {
    var seen: u32 = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, word)) |i| {
        from = i + 1;
        const before_ok = i == 0 or !isWordByte(text[i - 1]);
        const after_ok = i + word.len == text.len or !isWordByte(text[i + word.len]);
        if (!before_ok or !after_ok) continue;
        seen += 1;
        if (seen == n) return i;
    }
    return null;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn symbolTool(src: *const Source, io: Io, arena: Allocator, which: Which, in: Input, w: *Io.Writer) !bool {
    const path = in.path orelse {
        try w.writeAll("`path` is required.");
        return false;
    };
    if (in.line == null) {
        try w.writeAll("`line` is required.");
        return false;
    }
    const abs = try resolve(src, arena, path, w) orelse return false;
    return switch (which) {
        .hover => ask(.@"textDocument/hover", .hover, src, io, arena, abs, path, in, w),
        .definition => ask(.@"textDocument/definition", .definition, src, io, arena, abs, path, in, w),
    };
}

fn ask(comptime M: protocol.Method, feature: Manager.Feature, src: *const Source, io: Io, arena: Allocator, abs: []const u8, path: []const u8, in: Input, w: *Io.Writer) !bool {
    const gpa = src.mgr.gpa;
    const p = try gpa.create(Pending(M));
    p.* = .{ .io = io };
    var a: Ask(M) = .{ .src = src, .arena = arena, .abs = abs, .in = in, .feature = feature, .pending = p };
    if (!src.ui.run(src.ui.ctx, Ask(M).onUi, &a)) a.refused = "the editor is not taking requests";
    if (a.refused) |why| {
        gpa.destroy(p);
        try w.print("No answer for {s}:{d}: {s}.", .{ path, in.line.?, why });
        return true;
    }
    // Requests carry a deadline, so the answer always comes.
    p.done.waitUncancelable(io);
    defer {
        p.result.deinit();
        gpa.destroy(p);
    }
    if (a.adjusted_line) |l| try w.print("(found on line {d}, not {d})\n", .{ l, in.line.? });
    const value = switch (p.result) {
        .ok => |o| o.value,
        .timeout => {
            try w.writeAll("The language server did not answer in time.");
            return true;
        },
        else => |r| {
            try w.print("The language server gave no answer ({t}).", .{r});
            return true;
        },
    };
    switch (M) {
        .@"textDocument/hover" => try writeHover(w, value),
        .@"textDocument/definition" => try writeDefinition(src, arena, w, value),
        else => comptime unreachable,
    }
    return true;
}

fn writeHover(w: *Io.Writer, value: ?protocol.Hover) !void {
    const h = value orelse return w.writeAll("No hover information here.");
    switch (h.contents) {
        .markup_content => |m| try w.writeAll(m.value),
        .marked_string => |s| try writeMarked(w, s),
        .marked_string_array => |arr| for (arr, 0..) |s, i| {
            if (i > 0) try w.writeAll("\n\n");
            try writeMarked(w, s);
        },
    }
}

fn writeMarked(w: *Io.Writer, s: protocol.MarkedString) !void {
    switch (s) {
        .string => |t| try w.writeAll(t),
        .marked_string_with_language => |m| try w.print("```{s}\n{s}\n```", .{ m.language, m.value }),
    }
}

fn writeDefinition(src: *const Source, arena: Allocator, w: *Io.Writer, value: ?protocol.TextDocumentDefinitionResult) !void {
    const r = value orelse return w.writeAll("No definition found.");
    var n: usize = 0;
    switch (r) {
        .definition => |d| switch (d) {
            .location => |l| try writeLocation(src, arena, w, l.uri, l.range, &n),
            .location_array => |ls| for (ls) |l| try writeLocation(src, arena, w, l.uri, l.range, &n),
        },
        .definition_link_array => |ls| for (ls) |l| try writeLocation(src, arena, w, l.targetUri, l.targetSelectionRange, &n),
    }
    if (n == 0) try w.writeAll("No definition found.");
}

fn writeLocation(src: *const Source, arena: Allocator, w: *Io.Writer, uri: []const u8, range: protocol.Range, n: *usize) !void {
    if (n.* > 0) try w.writeByte('\n');
    n.* += 1;
    const shown = blk: {
        const d = zg_lsp.uri.docUriFromLsp(arena, uri) catch break :blk uri;
        break :blk switch (d) {
            .file => |p| relativePath(src, registry.normalizePath(arena, p, src.store.style) catch p),
            .untitled, .virtual => |s| s,
        };
    };
    // Columns are the server's units; close enough for an agent to read.
    try w.print("{s}:{d}:{d}", .{ shown, range.start.line + 1, range.start.character + 1 });
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
