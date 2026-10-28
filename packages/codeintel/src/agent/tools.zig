//! The `lsp_*` agent tools (E07.F05.S01.T03, the E07 exporter of
//! E10.F06.S03.T01): the stable contract E10's tool registry and E11's
//! MCP server expose. zg_codeintel sits on zg_ai's layer, so like zg_scm
//! and zg_mcp it is generic over zg_ai's foreign-tool contract:
//!
//! ```zig
//! const X = zg_codeintel.agent.tools.ToolExporter(zg_ai.tools.adapters.foreign);
//! var x: X = .{ .src = .{ .mgr = &mgr, .store = &store, .roots = roots, .ui = ui, .bg = &bg } };
//! services.lsp = x.exporter();
//! ```
//!
//! `specs` lists the tools: names, descriptions written for the model,
//! JSON Schemas (`schemas/<tool>.json`, `additionalProperties: false`)
//! and permission classes. Every tool reads, except `lsp_rename_apply`
//! and `lsp_apply_code_action`, which propose their edit for review and
//! answer with its E12 changeset.
//!
//! Symbols are addressed by a path and a 1-based line with either a
//! 1-based column in characters or the symbol's name, looked up on that
//! line and up to three lines either side (agents are often a line off),
//! or by a qualified name (`std.mem.Allocator`) the workspace symbol
//! search finds. The calls go through `CodeIntel` (CodeIntel.zig), which
//! opens files the editor does not have in the background. Answers are
//! rendered by render.zig; results are MCP `CallToolResult` JSON with one
//! text block (plus `structuredContent` locations), and bad input comes
//! back as `isError` so the model can correct itself.

const std = @import("std");
const Store = @import("../diagnostics/Store.zig");
const CodeIntel = @import("CodeIntel.zig");
const render = @import("render.zig");
const position = @import("../features/position.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const UiPort = CodeIntel.UiPort;
/// The tools' view of the language services. Must not move once used.
pub const Source = CodeIntel;

pub const PermissionClass = enum {
    /// Reads code intelligence only.
    read,
    /// Proposes workspace changes (always through review).
    control,
    /// Runs something (none of the language tools).
    execute,
};

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    permission: PermissionClass,
};

fn schema(comptime name: []const u8) []const u8 {
    return @embedFile("schemas/" ++ name ++ ".json");
}

const symbol_help = " Give the symbol as path + line + name (looked up within 3 lines), path + line + column (characters), or qualified (e.g. std.mem.Allocator).";

/// The tools, in listing order. Names are a contract: keep them stable.
pub const specs = [_]Spec{
    .{ .name = "lsp_definition", .permission = .read, .input_schema_json = schema("lsp_definition"), .description = "Where a symbol is defined: file:line with a short excerpt (several for overloads). Use it to jump from a use to the code behind it instead of searching." ++ symbol_help },
    .{ .name = "lsp_type_definition", .permission = .read, .input_schema_json = schema("lsp_type_definition"), .description = "Where the type of a symbol (a variable, field or parameter) is defined, with an excerpt." ++ symbol_help },
    .{ .name = "lsp_implementation", .permission = .read, .input_schema_json = schema("lsp_implementation"), .description = "Implementations of an interface, abstract method or function pointer type, with excerpts." ++ symbol_help },
    .{ .name = "lsp_references", .permission = .read, .input_schema_json = schema("lsp_references"), .description = "Every reference to a symbol in the workspace, grouped by file with excerpts. More precise than a text search: same-named symbols elsewhere are not included. At most limit (default 200)." ++ symbol_help },
    .{ .name = "lsp_hover", .permission = .read, .input_schema_json = schema("lsp_hover"), .description = "The language server's hover for a symbol: its type or signature and documentation." ++ symbol_help },
    .{ .name = "lsp_document_symbols", .permission = .read, .input_schema_json = schema("lsp_document_symbols"), .description = "The outline of a file: its types, functions, fields and constants with their lines, nested to depth (default 2). Cheaper than reading the whole file to find something." },
    .{ .name = "lsp_workspace_symbols", .permission = .read, .input_schema_json = schema("lsp_workspace_symbols"), .description = "Symbols in the workspace whose names match query (servers match fuzzily), as file:line: kind name. Needs a running language server (one starts when a file of its language is used)." },
    .{ .name = "lsp_call_hierarchy", .permission = .read, .input_schema_json = schema("lsp_call_hierarchy"), .description = "Who calls a function (incoming) or what it calls (outgoing), as a tree depth levels deep (default 2) with each call site's file and line." ++ symbol_help },
    .{ .name = "lsp_diagnostics", .permission = .read, .input_schema_json = schema("lsp_diagnostics"), .description = "Compiler and linter diagnostics from the language servers, for one file or the whole workspace: file:line:column: severity: message [source code]." },
    .{ .name = "lsp_wait_for_diagnostics", .permission = .read, .input_schema_json = schema("lsp_wait_for_diagnostics"), .description = "After editing a file: waits (a few seconds at most) until the language servers have checked the new text, then lists its errors and warnings." },
    .{ .name = "lsp_rename_preview", .permission = .read, .input_schema_json = schema("lsp_rename_preview"), .description = "What renaming a symbol to new_name would change, file by file, without changing anything." ++ symbol_help },
    .{ .name = "lsp_rename_apply", .permission = .control, .input_schema_json = schema("lsp_rename_apply"), .description = "Renames a symbol everywhere the language server knows it is used. The edit is proposed to the user for review (an E12 changeset), not applied directly." ++ symbol_help },
    .{ .name = "lsp_code_actions", .permission = .read, .input_schema_json = schema("lsp_code_actions"), .description = "The language server's quick fixes and refactorings for lines start_line..end_line of a file, each with an id for lsp_apply_code_action (ids last 5 minutes)." },
    .{ .name = "lsp_apply_code_action", .permission = .control, .input_schema_json = schema("lsp_apply_code_action"), .description = "Applies a code action listed by lsp_code_actions. Its edit is proposed to the user for review (an E12 changeset), not applied directly; actions that only run a server command are refused." },
};

/// `Foreign` is `zg_ai.tools.adapters.foreign` (or a test double with the
/// same declarations). Must not move after `exporter`.
pub fn ToolExporter(comptime Foreign: type) type {
    return struct {
        const Self = @This();

        src: Source,
        /// The agent the edits are proposed for.
        agent: u32 = 0,

        pub fn exporter(self: *Self) Foreign.Exporter {
            return .{ .name = "lsp", .kind = .lsp, .ctx = self, .list = list, .call = call };
        }

        fn list(_: *anyopaque, arena: Allocator) anyerror![]const Foreign.ForeignTool {
            const out = try arena.alloc(Foreign.ForeignTool, specs.len);
            for (specs, out) |s, *t| t.* = .{
                .name = s.name,
                .description = s.description,
                .input_schema_json = s.input_schema_json,
                .read_only = s.permission == .read,
                .mutates = s.permission == .control,
            };
            return out;
        }

        fn call(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Foreign.Result {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var out: Output = .init(arena);
            const ok = runAs(&self.src, self.agent, io, arena, tool, input_json, &out) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => blk: {
                    out.text.clearRetainingCapacity();
                    try out.text.writer.print("{s} failed: {t}", .{ tool, e });
                    break :blk false;
                },
            };
            return .{ .json = try resultJson(arena, out.text.written(), !ok, out.structured), .changeset = if (ok) out.changeset else null };
        }
    };
}

/// A call's text, its structured locations and its changeset.
pub const Output = struct {
    text: Io.Writer.Allocating,
    /// `render.structuredJson` of the locations shown.
    structured: ?[]const u8 = null,
    changeset: ?u64 = null,

    pub fn init(arena: Allocator) Output {
        return .{ .text = .init(arena) };
    }
};

const Input = struct {
    path: ?[]const u8 = null,
    min_severity: ?Store.Severity = null,
    limit: ?u32 = null,
    line: ?u32 = null,
    name: ?[]const u8 = null,
    occurrence: ?u32 = null,
    column: ?u32 = null,
    qualified: ?[]const u8 = null,
    include_declaration: ?bool = null,
    depth: ?u8 = null,
    query: ?[]const u8 = null,
    direction: ?CodeIntel.CallDirection = null,
    new_name: ?[]const u8 = null,
    start_line: ?u32 = null,
    end_line: ?u32 = null,
    id: ?u32 = null,
};

/// `runAs` for agent 0, writing only text.
pub fn run(src: *Source, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8, w: *Io.Writer) !bool {
    var out: Output = .init(arena);
    const ok = try runAs(src, 0, io, arena, tool, input_json, &out);
    try w.writeAll(out.text.written());
    return ok;
}

const Tool = enum {
    lsp_definition,
    lsp_type_definition,
    lsp_implementation,
    lsp_references,
    lsp_hover,
    lsp_document_symbols,
    lsp_workspace_symbols,
    lsp_call_hierarchy,
    lsp_diagnostics,
    lsp_wait_for_diagnostics,
    lsp_rename_preview,
    lsp_rename_apply,
    lsp_code_actions,
    lsp_apply_code_action,
};

comptime {
    for (specs, std.meta.fieldNames(Tool)) |s, n| std.debug.assert(std.mem.eql(u8, s.name, n));
}

/// Runs `tool`; false when the input was bad (the text says why).
pub fn runAs(src: *Source, agent: u32, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8, out: *Output) !bool {
    const w = &out.text.writer;
    const t = std.meta.stringToEnum(Tool, tool) orelse return error.UnknownTool;
    const in = parseInput(arena, input_json) catch {
        try w.writeAll("The arguments are not valid for this tool (check names and types against its schema).");
        return false;
    };
    var cx: Cx = .{ .src = src, .io = io, .arena = arena, .out = out, .call = .init(io, arena), .opts = .{ .root = if (src.roots.len > 0) src.roots[0] else "" } };
    return switch (t) {
        .lsp_diagnostics => diagnostics(src, arena, in, w),
        .lsp_wait_for_diagnostics => cx.waitForDiagnostics(in),
        .lsp_definition => cx.navigate(in, .definition),
        .lsp_type_definition => cx.navigate(in, .type_definition),
        .lsp_implementation => cx.navigate(in, .implementation),
        .lsp_references => cx.references(in),
        .lsp_hover => cx.hover(in),
        .lsp_document_symbols => cx.documentSymbols(in),
        .lsp_workspace_symbols => cx.workspaceSymbols(in),
        .lsp_call_hierarchy => cx.callHierarchy(in),
        .lsp_rename_preview => cx.rename(in, null),
        .lsp_rename_apply => cx.rename(in, agent),
        .lsp_code_actions => cx.codeActions(in),
        .lsp_apply_code_action => cx.applyCodeAction(in, agent),
    };
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
        include_declaration: ?bool = null,
        depth: ?u8 = null,
        query: ?[]const u8 = null,
        direction: ?[]const u8 = null,
        new_name: ?[]const u8 = null,
        start_line: ?u32 = null,
        end_line: ?u32 = null,
        id: ?u32 = null,
    };
    const r = try std.json.parseFromSliceLeaky(Raw, arena, if (json.len == 0) "{}" else json, .{});
    var in: Input = .{
        .path = r.path,
        .limit = r.limit,
        .line = r.line,
        .name = r.name,
        .occurrence = r.occurrence,
        .column = r.column,
        .qualified = r.qualified,
        .include_declaration = r.include_declaration,
        .depth = r.depth,
        .query = r.query,
        .new_name = r.new_name,
        .start_line = r.start_line,
        .end_line = r.end_line,
        .id = r.id,
    };
    if (r.min_severity) |s| {
        in.min_severity = for ([_]Store.Severity{ .err, .warning, .information, .hint }) |v| {
            if (std.mem.eql(u8, s, v.label()) or (v == .err and std.mem.eql(u8, s, "error")) or (v == .information and std.mem.eql(u8, s, "information"))) break v;
        } else return error.BadSeverity;
    }
    if (r.direction) |d| in.direction = std.meta.stringToEnum(CodeIntel.CallDirection, d) orelse return error.BadDirection;
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

const max_limit = 500;

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
        try names.append(arena, try render.shownPath(arena, if (src.roots.len > 0) src.roots[0] else "", relative(src, k)));
    }

    var counts: [4]usize = @splat(0);
    var files: usize = 0;
    var listed: usize = 0;
    var body: std.ArrayList(u8) = .empty;
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
            try body.append(arena, '\n');
            try render.writeDiagnostic(arena, &body, name, .{
                .path = name,
                .line = d.start.line,
                .column = d.start.character,
                .severity = d.severity.label(),
                .message = d.message,
                .source = d.source,
                .code = d.code,
            });
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
    try w.writeAll(body.items);
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

// ------------------------------------------------------- the CodeIntel tools

/// One tool call.
const Cx = struct {
    src: *Source,
    io: Io,
    arena: Allocator,
    out: *Output,
    call: CodeIntel.Call,
    opts: render.RenderOpts,
    /// File texts fetched for excerpts and columns, by path.
    texts: std.StringArrayHashMapUnmanaged(?File) = .empty,

    const File = struct { text: []const u8, lines: []const usize };

    fn w(cx: *Cx) *Io.Writer {
        return &cx.out.text.writer;
    }

    fn file(cx: *Cx, path: []const u8) ?File {
        const gop = cx.texts.getOrPut(cx.arena, path) catch return null;
        if (!gop.found_existing) {
            gop.value_ptr.* = null;
            const t = (cx.src.fileText(&cx.call, path) catch null) orelse return null;
            gop.value_ptr.* = .{ .text = t, .lines = render.lineIndex(cx.arena, t) catch return null };
        }
        return gop.value_ptr.*;
    }

    fn text(cx: *Cx, path: []const u8) ?[]const u8 {
        return if (cx.file(path)) |f| f.text else null;
    }

    fn lookup(ctx: *anyopaque, path: []const u8) ?[]const u8 {
        const cx: *Cx = @ptrCast(@alignCast(ctx));
        return cx.text(path);
    }

    /// `l` as a render target: columns in characters when the text is known.
    fn target(cx: *Cx, l: CodeIntel.Location, kind: []const u8, name: []const u8) render.Target {
        var t: render.Target = .{ .path = l.path, .line = l.range.start.line, .column = l.range.start.character, .end_line = l.range.end.line, .end_column = l.range.end.character, .kind = kind, .name = name };
        if (l.is_file) if (cx.file(l.path)) |f| {
            const enc = position.encodingOf(l.enc);
            t.column = render.charColumn(render.lineAt(f.text, f.lines, t.line), t.column, enc);
            t.end_column = render.charColumn(render.lineAt(f.text, f.lines, t.end_line), t.end_column, enc);
        };
        return t;
    }

    fn shown(cx: *Cx, path: []const u8) []const u8 {
        return render.shownPath(cx.arena, cx.opts.root, path) catch path;
    }

    /// The failure as the model reads it; false when its input was wrong.
    fn failed(cx: *Cx, e: CodeIntel.Error, at: []const u8) !bool {
        const call = &cx.call;
        const out = cx.w();
        switch (e) {
            error.OutOfMemory => return e,
            error.OutsideWorkspace => {
                try out.print("{s}.", .{call.why});
                return false;
            },
            error.Ambiguous => {
                try out.print("{s}:", .{call.why});
                for (call.candidates) |c| {
                    try out.print("\n- {s}{s}{s} ({s})", .{ c.container orelse "", if (c.container != null) "." else "", c.name, kindLabel(c.kind) });
                    if (c.location) |l| try out.print(" {s}:{d}", .{ cx.shown(l.path), l.range.start.line + 1 });
                }
                return true;
            },
            error.NoServer => {
                const ext = std.fs.path.extension(at[0 .. std.mem.lastIndexOfScalar(u8, at, ':') orelse at.len]);
                if (ext.len > 0)
                    try out.print("No language server for {s} files: {s}. Configure one under lsp.servers, or search the text with the grep tool.", .{ ext, call.why })
                else
                    try out.print("No answer for {s}: {s}. Search the text with the grep tool instead.", .{ at, call.why });
                return true;
            },
            else => {
                try out.print("No answer for {s}: {s}.", .{ at, call.why });
                return true;
            },
        }
    }

    /// The symbol the input names (null: the input was wrong, said why).
    fn ref(cx: *Cx, in: Input) !?CodeIntel.SymbolRef {
        if (in.qualified) |q| return .{ .qualified = q };
        const path = in.path orelse {
            try cx.w().writeAll("`path` (with `line`) or `qualified` is required.");
            return null;
        };
        const line = in.line orelse {
            try cx.w().writeAll("`line` is required with `path`.");
            return null;
        };
        if (in.name) |n| return .{ .name_on_line = .{ .path = path, .line = line, .name = n, .occurrence = in.occurrence orelse 1 } };
        return .{ .position = .{ .path = path, .line = line, .column = in.column } };
    }

    fn where(cx: *Cx, in: Input) []const u8 {
        if (in.qualified) |q| return q;
        return std.fmt.allocPrint(cx.arena, "{s}:{d}", .{ in.path orelse "", in.line orelse 0 }) catch "the symbol";
    }

    fn adjusted(cx: *Cx, in: Input) !void {
        if (cx.call.adjusted_line) |l| try cx.w().print("(found on line {d}, not {d})\n", .{ l, in.line.? });
    }

    fn locations(cx: *Cx, ls: []const CodeIntel.Location, noun: render.Noun, total: usize) !void {
        const ts = try cx.arena.alloc(render.Target, ls.len);
        for (ls, ts) |l, *t| t.* = cx.target(l, "", "");
        try cx.w().writeAll(try render.renderTargets(cx.arena, ts, cx.opts, .{ .ctx = cx, .get = lookup }, noun, total));
        cx.out.structured = try render.structuredJson(cx.arena, ts, cx.opts);
    }

    fn navigate(cx: *Cx, in: Input, kind: CodeIntel.NavKind) !bool {
        const r = try cx.ref(in) orelse return false;
        const ls = cx.src.definition(&cx.call, r, kind) catch |e| return cx.failed(e, cx.where(in));
        try cx.adjusted(in);
        const noun: render.Noun = switch (kind) {
            .definition => .{ .one = "definition", .many = "definitions" },
            .declaration => .{ .one = "declaration", .many = "declarations" },
            .type_definition => .{ .one = "type definition", .many = "type definitions" },
            .implementation => .{ .one = "implementation", .many = "implementations" },
        };
        try cx.locations(ls, noun, 0);
        return true;
    }

    fn references(cx: *Cx, in: Input) !bool {
        const r = try cx.ref(in) orelse return false;
        const res = cx.src.references(&cx.call, r, in.include_declaration orelse true, @min(in.limit orelse 200, 2000)) catch |e| return cx.failed(e, cx.where(in));
        try cx.adjusted(in);
        try cx.locations(res.locations, .{ .one = "reference", .many = "references" }, res.total);
        return true;
    }

    fn hover(cx: *Cx, in: Input) !bool {
        const r = try cx.ref(in) orelse return false;
        const md = cx.src.hover(&cx.call, r) catch |e| return cx.failed(e, cx.where(in));
        try cx.adjusted(in);
        try cx.w().writeAll(if (md) |m| try render.markdownToText(cx.arena, m) else "No hover information here.");
        return true;
    }

    fn documentSymbols(cx: *Cx, in: Input) !bool {
        const path = in.path orelse {
            try cx.w().writeAll("`path` is required.");
            return false;
        };
        const syms = cx.src.documentSymbols(&cx.call, path, in.depth orelse 2) catch |e| return cx.failed(e, path);
        const out = cx.w();
        if (syms.len == 0) {
            try out.print("No symbols in {s}.", .{path});
            return true;
        }
        try out.print("{s}: {d} symbol{s}", .{ cx.shown(syms[0].location.?.path), syms.len, plural(syms.len) });
        var max_line: u32 = 0;
        for (syms) |s| if (s.location) |l| {
            max_line = @max(max_line, l.range.start.line + 1);
        };
        const width = std.fmt.count("{d}", .{max_line});
        const ts = try cx.arena.alloc(render.Target, syms.len);
        for (syms, ts) |s, *t| {
            const l = s.location.?;
            t.* = cx.target(l, kindLabel(s.kind), s.name);
            try out.print("\n{d:>[1]}  ", .{ l.range.start.line + 1, width });
            try out.splatByteAll(' ', @as(usize, s.depth) * 2);
            try out.print("{s} {s}", .{ kindLabel(s.kind), s.name });
            if (s.detail) |d| if (d.len > 0) try out.print("  {s}", .{firstLine(d)});
        }
        cx.out.structured = try render.structuredJson(cx.arena, ts, cx.opts);
        return true;
    }

    fn workspaceSymbols(cx: *Cx, in: Input) !bool {
        const q = in.query orelse {
            try cx.w().writeAll("`query` is required.");
            return false;
        };
        const syms = cx.src.workspaceSymbols(&cx.call, q, @min(in.limit orelse 50, max_limit)) catch |e| return cx.failed(e, q);
        var ts: std.ArrayList(render.Target) = .empty;
        for (syms) |s| {
            const l = s.location orelse continue;
            const label = if (s.container) |c| try std.fmt.allocPrint(cx.arena, "{s} {s} (in {s})", .{ kindLabel(s.kind), s.name, c }) else try std.fmt.allocPrint(cx.arena, "{s} {s}", .{ kindLabel(s.kind), s.name });
            var t: render.Target = .{ .path = l.path, .line = l.range.start.line, .column = l.range.start.character, .end_line = l.range.end.line, .end_column = l.range.end.character, .kind = kindLabel(s.kind), .name = label };
            // No range: the file only.
            if (t.line == std.math.maxInt(u32)) {
                t.line = 0;
                t.column = 0;
                t.end_line = 0;
                t.end_column = 0;
            }
            try ts.append(cx.arena, t);
        }
        // A list of places, no excerpts.
        try cx.w().writeAll(try render.renderTargets(cx.arena, ts.items, cx.opts, null, .{ .one = "symbol", .many = "symbols" }, 0));
        cx.out.structured = try render.structuredJson(cx.arena, ts.items, cx.opts);
        return true;
    }

    fn callHierarchy(cx: *Cx, in: Input) !bool {
        const r = try cx.ref(in) orelse return false;
        const dir = in.direction orelse .incoming;
        const nodes = cx.src.callHierarchy(&cx.call, r, dir, in.depth orelse 2, @min(in.limit orelse 60, 300)) catch |e| return cx.failed(e, cx.where(in));
        try cx.adjusted(in);
        const out = cx.w();
        if (nodes.len == 0) {
            try out.writeAll("No call hierarchy here (not a function, or the server has none).");
            return true;
        }
        try out.writeAll(if (dir == .incoming) "Callers (indented under what they call):" else "Calls (indented under their caller):");
        const ts = try cx.arena.alloc(render.Target, nodes.len);
        for (nodes, ts) |n, *t| {
            t.* = cx.target(n.location, kindLabel(n.kind), n.name);
            try out.writeByte('\n');
            try out.splatByteAll(' ', @as(usize, n.depth) * 2);
            try out.print("{s} {s}  {s}:{d}:{d}", .{ kindLabel(n.kind), n.name, cx.shown(n.location.path), t.line + 1, t.column + 1 });
            if (n.calls > 1) try out.print("  ({d} calls)", .{n.calls});
            if (n.repeated) try out.writeAll("  (recursive, see above)");
        }
        cx.out.structured = try render.structuredJson(cx.arena, ts, cx.opts);
        return true;
    }

    fn waitForDiagnostics(cx: *Cx, in: Input) !bool {
        const path = in.path orelse {
            try cx.w().writeAll("`path` is required.");
            return false;
        };
        const abs = try resolve(cx.src, cx.arena, path, cx.w()) orelse return false;
        const sd = cx.src.settle orelse {
            try cx.w().writeAll("Waiting for diagnostics is not available here; use lsp_diagnostics.");
            return true;
        };
        const summary = sd.afterAgentEdit(cx.io, cx.arena, abs) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.Canceled => {
                try cx.w().writeAll("Canceled.");
                return true;
            },
        };
        if (summary) |s| try cx.w().writeAll(s) else try cx.w().print("No errors or warnings in {s}.", .{path});
        return true;
    }

    fn rename(cx: *Cx, in: Input, agent: ?u32) !bool {
        const r = try cx.ref(in) orelse return false;
        const new_name = in.new_name orelse {
            try cx.w().writeAll("`new_name` is required.");
            return false;
        };
        const out = cx.w();
        if (agent) |id| {
            const cs = cx.src.renameApply(&cx.call, r, new_name, id) catch |e| return cx.failed(e, cx.where(in));
            cx.out.changeset = cs;
            try out.print("Proposed for review as changeset {d}: rename to {s}. Nothing changes until the user accepts it.", .{ cs, new_name });
            return true;
        }
        const sum = cx.src.renamePreview(&cx.call, r, new_name) catch |e| return cx.failed(e, cx.where(in));
        try cx.adjusted(in);
        try out.print("{s}: {d} edit{s} in {d} file{s} (nothing changed; lsp_rename_apply proposes it for review):", .{ sum.label, sum.edits, plural(sum.edits), sum.files.len, plural(sum.files.len) });
        try writeFiles(cx, sum.files);
        return true;
    }

    fn codeActions(cx: *Cx, in: Input) !bool {
        const path = in.path orelse {
            try cx.w().writeAll("`path` is required.");
            return false;
        };
        const start = in.start_line orelse {
            try cx.w().writeAll("`start_line` is required.");
            return false;
        };
        const acts = cx.src.codeActions(&cx.call, path, .{ start, in.end_line orelse start }) catch |e| return cx.failed(e, path);
        const out = cx.w();
        if (acts.len == 0) {
            try out.print("No code actions for {s}:{d}.", .{ path, start });
            return true;
        }
        try out.print("{d} code action{s} (apply one with lsp_apply_code_action and its id):", .{ acts.len, plural(acts.len) });
        for (acts) |a| {
            try out.print("\n#{d} ", .{a.id});
            if (a.kind.len > 0) try out.print("[{s}] ", .{a.kind});
            try out.writeAll(a.title);
            if (a.preferred) try out.writeAll(" (preferred)");
            if (a.disabled) |why| try out.print(" (unavailable: {s})", .{why});
        }
        return true;
    }

    fn applyCodeAction(cx: *Cx, in: Input, agent: u32) !bool {
        const id = in.id orelse {
            try cx.w().writeAll("`id` is required.");
            return false;
        };
        const cs = cx.src.applyCodeAction(&cx.call, id, agent) catch |e| {
            if (e == error.NotFound) {
                try cx.w().print("{s}.", .{cx.call.why});
                return false;
            }
            return cx.failed(e, "the code action");
        };
        cx.out.changeset = cs;
        try cx.w().print("Proposed for review as changeset {d}. Nothing changes until the user accepts it.", .{cs});
        return true;
    }
};

fn writeFiles(cx: *Cx, files: []const CodeIntel.FileEdit) !void {
    const out = cx.w();
    for (files) |f| switch (f.op) {
        .edit => try out.print("\n{s} ({d} edit{s})", .{ cx.shown(f.path), f.edits, plural(f.edits) }),
        .create => try out.print("\n{s} (created)", .{cx.shown(f.path)}),
        .delete => try out.print("\n{s} (deleted)", .{cx.shown(f.path)}),
        .rename => try out.print("\n{s} (renamed to {s})", .{ cx.shown(f.path), cx.shown(f.to.?) }),
    };
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

/// A symbol kind as source code says it.
fn kindLabel(k: anytype) []const u8 {
    return switch (k) {
        .File => "file",
        .Module => "module",
        .Namespace => "namespace",
        .Package => "package",
        .Class => "class",
        .Method => "method",
        .Property => "property",
        .Field => "field",
        .Constructor => "constructor",
        .Enum => "enum",
        .Interface => "interface",
        .Function => "fn",
        .Variable => "var",
        .Constant => "const",
        .String => "string",
        .Number => "number",
        .Boolean => "bool",
        .Array => "array",
        .Object => "object",
        .Key => "key",
        .Null => "null",
        .EnumMember => "enum member",
        .Struct => "struct",
        .Event => "event",
        .Operator => "operator",
        .TypeParameter => "type parameter",
        else => "symbol",
    };
}

/// An MCP `CallToolResult` with one text block, and the locations as
/// `structuredContent` when there are any.
fn resultJson(arena: Allocator, text: []const u8, is_error: bool, structured: ?[]const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const Content = struct { content: []const struct { type: []const u8 = "text", text: []const u8 } };
    const head = try std.json.Stringify.valueAlloc(arena, Content{ .content = &.{.{ .text = text }} }, .{});
    try out.appendSlice(arena, head[0 .. head.len - 1]);
    if (structured) |s| if (!is_error) try out.print(arena, ",\"structuredContent\":{{\"locations\":{s}}}", .{s});
    try out.print(arena, ",\"isError\":{}}}", .{is_error});
    return out.items;
}
