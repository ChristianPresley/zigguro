//! `zg lsp` (E07.F05.S01.T04): the language servers from the command
//! line, printing what the agents' `lsp_*` tools answer (the same calls,
//! so the same text).
//!
//! ```
//! zg lsp diagnostics [PATH...] [--min-severity S] [--timeout-ms N] [--limit N] [--json]
//! zg lsp definition|type-definition|implementation|hover PATH:LINE[:COLUMN] [--name NAME] [--json]
//! zg lsp references PATH:LINE[:COLUMN] [--name NAME] [--limit N] [--json]
//! zg lsp symbols PATH [--depth N] [--json]
//! zg lsp workspace-symbols QUERY [--in FILE] [--limit N] [--json]
//! ```
//!
//! `diagnostics` opens the files, waits until their servers have checked
//! them (`lsp_wait_for_diagnostics`; nothing is open before, so it always
//! waits, `--wait` is accepted for clarity) and prints the errors and
//! warnings; with `--min-severity` it prints `lsp_diagnostics` for each
//! file after the wait instead. With no paths it runs the workspace's
//! check task and prints everything it found. Exit status: 0 nothing at
//! or above the severity (default warning), 1 diagnostics found, 2 bad
//! usage or a failed query. `--json` prints the locations as the tools'
//! structured content, and for diagnostics the settle status and the
//! list (1-based lines and columns).

const std = @import("std");
const Toolchain = @import("Toolchain.zig");
const tools = @import("../agent/tools.zig");
const render = @import("../agent/render.zig");
const Store = @import("../diagnostics/Store.zig");
const CodeIntel = @import("../agent/CodeIntel.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const usage_text =
    \\Usage: zg lsp diagnostics [PATH...] [--min-severity S] [--timeout-ms N] [--limit N] [--json]
    \\       zg lsp definition|type-definition|implementation|hover PATH:LINE[:COLUMN] [--name NAME] [--json]
    \\       zg lsp references PATH:LINE[:COLUMN] [--name NAME] [--limit N] [--json]
    \\       zg lsp symbols PATH [--depth N] [--json]
    \\       zg lsp workspace-symbols QUERY [--in FILE] [--limit N] [--json]
    \\
    \\Options: --workspace DIR   the workspace (default: the current directory)
    \\         --untrusted       treat the workspace as untrusted: no check task, no build on save
    \\         --zig PATH        the Zig executable (for ZLS and the check task)
    \\         --verbose         show the servers' info and log messages
    \\
    \\Lines and columns are 1-based; with --name the symbol is looked up on
    \\the line and up to 3 lines either side. `diagnostics` waits until the
    \\servers have checked the files (with no paths it runs the check task),
    \\then exits 1 when it found errors or warnings (or anything at or above
    \\--min-severity: error, warning, information, hint).
    \\
;

const Cmd = enum { diagnostics, definition, @"type-definition", implementation, hover, references, symbols, @"workspace-symbols" };

const Flags = struct {
    json: bool = false,
    name: ?[]const u8 = null,
    limit: ?u32 = null,
    depth: ?u8 = null,
    min_severity: ?Store.Severity = null,
    timeout_ms: ?u32 = null,
    in: ?[]const u8 = null,
    args: []const []const u8 = &.{},
};

/// Runs `zg lsp ARGS` (after the shared flags were taken).
pub fn cliMain(tc: *Toolchain, args: []const []const u8, out: *Io.Writer, err: *Io.Writer) !u8 {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h")) {
        try (if (args.len > 0) out else err).writeAll(usage_text);
        return if (args.len > 0) 0 else 2;
    }
    const cmd = std.meta.stringToEnum(Cmd, args[0]) orelse {
        try err.print("zg lsp: unknown command '{s}'\n\n{s}", .{ args[0], usage_text });
        return 2;
    };
    var arena_state: std.heap.ArenaAllocator = .init(tc.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var why: []const u8 = "";
    const f = try parseFlags(arena, args[1..], &why) orelse return usage(err, why);
    return switch (cmd) {
        .diagnostics => diagnostics(tc, arena, f, out, err),
        .definition => locate(tc, arena, "lsp_definition", f, out, err),
        .@"type-definition" => locate(tc, arena, "lsp_type_definition", f, out, err),
        .implementation => locate(tc, arena, "lsp_implementation", f, out, err),
        .hover => locate(tc, arena, "lsp_hover", f, out, err),
        .references => locate(tc, arena, "lsp_references", f, out, err),
        .symbols => symbols(tc, arena, f, out, err),
        .@"workspace-symbols" => workspaceSymbols(tc, arena, f, out, err),
    };
}

fn usage(err: *Io.Writer, why: []const u8) !u8 {
    try err.print("zg lsp: {s}\n\n{s}", .{ why, usage_text });
    return 2;
}

fn parseFlags(arena: Allocator, args: []const []const u8, why: *[]const u8) Allocator.Error!?Flags {
    var f: Flags = .{};
    var pos: std.ArrayList([]const u8) = .empty;
    const valued = [_][]const u8{ "--name", "--limit", "--depth", "--min-severity", "--timeout-ms", "--in" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            f.json = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--wait")) continue;
        if (!std.mem.startsWith(u8, a, "--")) {
            try pos.append(arena, a);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, a, '=');
        const flag = a[0 .. eq orelse a.len];
        for (valued) |v| {
            if (std.mem.eql(u8, flag, v)) break;
        } else {
            why.* = try std.fmt.allocPrint(arena, "unknown option {s}", .{flag});
            return null;
        }
        const value = if (eq) |e| a[e + 1 ..] else if (i + 1 < args.len) blk: {
            i += 1;
            break :blk args[i];
        } else {
            why.* = try std.fmt.allocPrint(arena, "{s} needs a value", .{flag});
            return null;
        };
        const bad = bad: {
            if (std.mem.eql(u8, flag, "--name")) {
                f.name = value;
            } else if (std.mem.eql(u8, flag, "--in")) {
                f.in = value;
            } else if (std.mem.eql(u8, flag, "--min-severity")) {
                f.min_severity = if (std.mem.eql(u8, value, "error")) .err else std.meta.stringToEnum(Store.Severity, value) orelse break :bad true;
            } else if (std.mem.eql(u8, flag, "--limit")) {
                f.limit = std.fmt.parseInt(u32, value, 10) catch break :bad true;
            } else if (std.mem.eql(u8, flag, "--depth")) {
                f.depth = std.fmt.parseInt(u8, value, 10) catch break :bad true;
            } else {
                f.timeout_ms = std.fmt.parseInt(u32, value, 10) catch break :bad true;
            }
            break :bad false;
        };
        if (bad) {
            why.* = try std.fmt.allocPrint(arena, "bad value for {s}: {s}", .{ flag, value });
            return null;
        }
    }
    f.args = pos.items;
    return f;
}

/// `PATH:LINE[:COLUMN]`, split from the right (Windows paths have colons).
pub const Loc = struct { path: []const u8, line: u32, column: ?u32 = null };

pub fn parseLoc(s: []const u8) ?Loc {
    const last = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const n1 = std.fmt.parseInt(u32, s[last + 1 ..], 10) catch return null;
    if (std.mem.lastIndexOfScalar(u8, s[0..last], ':')) |prev| {
        if (std.fmt.parseInt(u32, s[prev + 1 .. last], 10)) |n0| {
            if (prev == 0 or n0 == 0 or n1 == 0) return null;
            return .{ .path = s[0..prev], .line = n0, .column = n1 };
        } else |_| {}
    }
    if (last == 0 or n1 == 0) return null;
    return .{ .path = s[0..last], .line = n1 };
}

/// Prints a tool's answer: its text (to `err` when the call failed), or
/// with `--json` its structured content.
fn emit(o: *tools.Output, ok: bool, json: bool, out: *Io.Writer, err: *Io.Writer) !u8 {
    const text = o.text.written();
    if (!ok or o.failed) {
        try err.print("{s}\n", .{text});
        return 2;
    }
    if (json) {
        if (o.structured) |s| {
            try out.print("{s}\n", .{s});
        } else {
            try std.json.Stringify.value(.{ .text = text }, .{}, out);
            try out.writeByte('\n');
        }
        return 0;
    }
    try out.writeAll(text);
    if (text.len == 0 or text[text.len - 1] != '\n') try out.writeByte('\n');
    return 0;
}

fn locate(tc: *Toolchain, arena: Allocator, tool: []const u8, f: Flags, out: *Io.Writer, err: *Io.Writer) !u8 {
    if (f.args.len != 1) return usage(err, "give one PATH:LINE[:COLUMN]");
    const loc = parseLoc(f.args[0]) orelse return usage(err, "the location is PATH:LINE[:COLUMN] (1-based)");
    const In = struct { path: []const u8, line: u32, column: ?u32, name: ?[]const u8, limit: ?u32 };
    const json = try std.json.Stringify.valueAlloc(arena, In{
        .path = loc.path,
        .line = loc.line,
        .column = if (f.name == null) loc.column orelse 1 else null,
        .name = f.name,
        .limit = if (std.mem.eql(u8, tool, "lsp_references")) f.limit else null,
    }, .{ .emit_null_optional_fields = false });
    var o: tools.Output = .init(arena);
    const ok = try tc.tool(arena, tool, json, &o);
    return emit(&o, ok, f.json, out, err);
}

fn symbols(tc: *Toolchain, arena: Allocator, f: Flags, out: *Io.Writer, err: *Io.Writer) !u8 {
    if (f.args.len != 1) return usage(err, "give one PATH");
    const json = try std.json.Stringify.valueAlloc(arena, .{ .path = f.args[0], .depth = f.depth }, .{ .emit_null_optional_fields = false });
    var o: tools.Output = .init(arena);
    const ok = try tc.tool(arena, "lsp_document_symbols", json, &o);
    return emit(&o, ok, f.json, out, err);
}

fn workspaceSymbols(tc: *Toolchain, arena: Allocator, f: Flags, out: *Io.Writer, err: *Io.Writer) !u8 {
    if (f.args.len != 1) return usage(err, "give one QUERY");
    // Servers start with a file of their language: --in, or build.zig.
    const file = f.in orelse "build.zig";
    var call: CodeIntel.Call = .init(tc.rt.io, arena);
    if (tc.ci.resolvePath(&call, file)) |abs| {
        tc.open(abs) catch |e| if (f.in != null) {
            try err.print("zg lsp: could not open {s}: {t}\n", .{ file, e });
            return 2;
        };
        try tc.waitStarted();
    } else |_| if (f.in != null) {
        try err.print("zg lsp: {s}\n", .{call.why});
        return 2;
    }
    const json = try std.json.Stringify.valueAlloc(arena, .{ .query = f.args[0], .limit = f.limit }, .{ .emit_null_optional_fields = false });
    var o: tools.Output = .init(arena);
    const ok = try tc.tool(arena, "lsp_workspace_symbols", json, &o);
    return emit(&o, ok, f.json, out, err);
}

fn diagnostics(tc: *Toolchain, arena: Allocator, f: Flags, out: *Io.Writer, err: *Io.Writer) !u8 {
    const timeout_ms = f.timeout_ms orelse 10_000;
    var keys: std.ArrayList([]const u8) = .empty;
    var status: ?[]const u8 = null;
    var text: std.ArrayList(u8) = .empty;
    if (f.args.len == 0) {
        const s = try tc.runCheckNow(arena, .fromMilliseconds(timeout_ms)) orelse {
            try err.writeAll("zg lsp: give the files to check (with no paths the check task runs, and this workspace has none)\n");
            return 2;
        };
        if (s.err) |m| if (s.exit_code == null) try err.print("'{s}' did not run: {s}\n", .{ s.label, m });
        status = try std.json.Stringify.valueAlloc(arena, .{ .build = s }, .{});
        var o: tools.Output = .init(arena);
        const in = try std.json.Stringify.valueAlloc(arena, .{ .min_severity = severityName(f.min_severity), .limit = f.limit }, .{ .emit_null_optional_fields = false });
        if (!try tc.tool(arena, "lsp_diagnostics", in, &o)) return emit(&o, false, false, out, err);
        try text.appendSlice(arena, o.text.written());
        const snap = tc.store.acquire();
        defer snap.release();
        for (snap.keys()) |k| try keys.append(arena, try arena.dupe(u8, k));
    } else {
        var call: CodeIntel.Call = .init(tc.rt.io, arena);
        for (f.args) |p| {
            const abs = tc.ci.resolvePath(&call, p) catch {
                try err.print("zg lsp: {s}\n", .{call.why});
                return 2;
            };
            // A file no server takes still gets the check task.
            tc.open(abs) catch |e| switch (e) {
                error.OutOfMemory => return e,
                error.NoLanguage => {},
                else => {
                    try err.print("zg lsp: could not open {s}: {t}\n", .{ p, e });
                    return 2;
                },
            };
            try keys.append(arena, try tc.store.keyOfPath(arena, abs));
        }
        const in = try std.json.Stringify.valueAlloc(arena, .{ .paths = f.args, .timeout_ms = timeout_ms }, .{});
        var o: tools.Output = .init(arena);
        if (!try tc.tool(arena, "lsp_wait_for_diagnostics", in, &o)) return emit(&o, false, false, out, err);
        status = o.status;
        if (f.min_severity) |sev| {
            for (f.args, 0..) |p, i| {
                var d: tools.Output = .init(arena);
                const din = try std.json.Stringify.valueAlloc(arena, .{ .path = p, .min_severity = severityName(sev), .limit = f.limit }, .{ .emit_null_optional_fields = false });
                if (!try tc.tool(arena, "lsp_diagnostics", din, &d)) return emit(&d, false, false, out, err);
                if (i > 0) try text.append(arena, '\n');
                try text.appendSlice(arena, d.text.written());
            }
        } else try text.appendSlice(arena, o.text.written());
    }

    const found = try collect(tc, arena, keys.items, f.min_severity orelse .warning);
    if (f.json) {
        try out.print("{{\"status\":{s},\"diagnostics\":", .{status orelse "null"});
        try std.json.Stringify.value(found, .{}, out);
        try out.writeAll("}\n");
    } else {
        try out.writeAll(text.items);
        if (text.items.len == 0 or text.items[text.items.len - 1] != '\n') try out.writeByte('\n');
    }
    return if (found.len > 0) 1 else 0;
}

fn severityName(s: ?Store.Severity) ?[]const u8 {
    return switch (s orelse return null) {
        .err => "error",
        else => |x| @tagName(x),
    };
}

const Found = struct { path: []const u8, line: u32, column: u32, severity: []const u8, message: []const u8, source: []const u8, code: []const u8 };

/// The store's diagnostics of `keys` at or above `min`.
fn collect(tc: *Toolchain, arena: Allocator, keys: []const []const u8, min: Store.Severity) ![]const Found {
    const snap = tc.store.acquire();
    defer snap.release();
    const root = if (tc.opts.roots.len > 0) tc.opts.roots[0] else "";
    var all: std.ArrayList(*const Store.Diagnostic) = .empty;
    var found: std.ArrayList(Found) = .empty;
    for (keys) |k| {
        all.clearRetainingCapacity();
        try snap.forKey(k, arena, &all);
        for (all.items) |d| {
            if (@intFromEnum(d.severity) > @intFromEnum(min)) continue;
            try found.append(arena, .{
                .path = try render.shownPath(arena, root, k),
                .line = d.start.line + 1,
                .column = d.start.character + 1,
                .severity = d.severity.label(),
                .message = try arena.dupe(u8, d.message),
                .source = try arena.dupe(u8, d.source),
                .code = try arena.dupe(u8, d.code),
            });
        }
    }
    return found.items;
}
