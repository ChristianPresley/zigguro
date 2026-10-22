//! The workspace file, `.zigguro/workspace.zon`: a list of root folders plus
//! the vault markers and a settings subtree that E15 owns.
//!
//! ```zon
//! .{
//!     .version = 1,
//!     .folders = .{ .{ .path = "." }, .{ .path = "../docs", .name = "Docs" } },
//!     .vaults = .{"../docs"},
//!     .settings = .{ .editor = .{ .tab_size = 4 } },
//! }
//! ```
//!
//! The typed part is parsed with `std.zon.parse`; `settings` is captured as
//! the raw source bytes of its initializer, so it round-trips byte-exact and
//! its schema stays with E15. Unknown top-level fields produce warnings.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const Diagnostics = zg_core.report.Diagnostics;

/// A parsed workspace file. Memory belongs to the arena passed to `parse`.
pub const WorkspaceFile = struct {
    /// Format version (1).
    version: u32 = 1,
    /// Root folders, relative to the workspace file's directory or absolute.
    folders: []const Folder,
    /// The raw ZON source of the `.settings` initializer, if present.
    settings: ?[]const u8 = null,
    /// Folder paths (relative to the file) that are notes vaults.
    vaults: []const []const u8 = &.{},

    /// One root folder.
    pub const Folder = struct {
        /// The folder path.
        path: []const u8,
        /// Display name (defaults to the folder's basename).
        name: ?[]const u8 = null,
    };

    /// Deep equality (for round-trip tests).
    pub fn eql(a: WorkspaceFile, b: WorkspaceFile) bool {
        if (a.version != b.version or a.folders.len != b.folders.len or a.vaults.len != b.vaults.len) return false;
        for (a.folders, b.folders) |x, y| {
            if (!std.mem.eql(u8, x.path, y.path)) return false;
            if ((x.name == null) != (y.name == null)) return false;
            if (x.name) |n| if (!std.mem.eql(u8, n, y.name.?)) return false;
        }
        for (a.vaults, b.vaults) |x, y| if (!std.mem.eql(u8, x, y)) return false;
        if ((a.settings == null) != (b.settings == null)) return false;
        if (a.settings) |s| if (!std.mem.eql(u8, s, b.settings.?)) return false;
        return true;
    }
};

const Typed = struct {
    version: u32 = 1,
    folders: []const WorkspaceFile.Folder,
    vaults: []const []const u8 = &.{},
};

const known_fields = [_][]const u8{ "version", "folders", "vaults", "settings" };

/// Parses a workspace file. Allocations go to `arena`. Errors are recorded
/// in `diag` with a byte offset and a `line:col` prefix, and the function
/// then fails with `error.InvalidWorkspaceFile`.
pub fn parse(arena: Allocator, src: [:0]const u8, diag: *Diagnostics) !WorkspaceFile {
    var ast = try std.zig.Ast.parse(arena, src, .zon);
    if (ast.errors.len > 0) {
        const e = ast.errors[0];
        const tok_start = ast.tokenStart(e.token);
        const loc = ast.tokenLocation(0, e.token);
        var buf: std.Io.Writer.Allocating = .init(arena);
        ast.renderError(e, &buf.writer) catch {};
        diag.addDetailed(.err, "workspace.syntax", tok_start, "{d}:{d}: {s}", .{ loc.line + 1, loc.column + 1, buf.written() });
        return error.InvalidWorkspaceFile;
    }

    // Find the top-level struct initializer's fields to capture `settings`
    // verbatim and to warn about unknown fields.
    var settings: ?[]const u8 = null;
    var fbuf: [2]std.zig.Ast.Node.Index = undefined;
    const root_expr = ast.nodeData(.root).node;
    if (ast.fullStructInit(&fbuf, root_expr)) |si| {
        for (si.ast.fields) |field| {
            const name_tok = ast.firstToken(field) - 2;
            const name = ast.tokenSlice(name_tok);
            if (std.mem.eql(u8, name, "settings")) {
                const first = ast.tokenStart(ast.firstToken(field));
                const last_tok = ast.lastToken(field);
                const last = ast.tokenStart(last_tok) + ast.tokenSlice(last_tok).len;
                settings = src[first..last];
            } else if (!isKnown(name)) {
                const loc = ast.tokenLocation(0, name_tok);
                diag.addDetailed(.warn, "workspace.unknown_field", ast.tokenStart(name_tok), "{d}:{d}: unknown field '.{s}' ignored", .{ loc.line + 1, loc.column + 1, name });
            }
        }
    }

    var zd: std.zon.parse.Diagnostics = .{};
    const typed = std.zon.parse.fromSliceAlloc(Typed, arena, src, &zd, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            var it = zd.iterateErrors();
            while (it.next()) |e| {
                const loc = e.getLocation(&zd);
                var buf: std.Io.Writer.Allocating = .init(arena);
                e.fmtMessage(&zd).format(&buf.writer) catch {};
                diag.addDetailed(.err, "workspace.schema", null, "{d}:{d}: {s}", .{ loc.line + 1, loc.column + 1, buf.written() });
            }
            return error.InvalidWorkspaceFile;
        },
    };
    return .{ .version = typed.version, .folders = typed.folders, .vaults = typed.vaults, .settings = settings };
}

fn isKnown(name: []const u8) bool {
    for (known_fields) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

/// Writes `wf` as ZON. `settings` is emitted verbatim.
pub fn write(wf: WorkspaceFile, w: *std.Io.Writer) !void {
    try w.print(".{{\n    .version = {d},\n    .folders = .{{\n", .{wf.version});
    for (wf.folders) |f| {
        try w.print("        .{{ .path = \"{f}\"", .{std.zig.fmtString(f.path)});
        if (f.name) |n| try w.print(", .name = \"{f}\"", .{std.zig.fmtString(n)});
        try w.writeAll(" },\n");
    }
    try w.writeAll("    },\n");
    if (wf.vaults.len > 0) {
        try w.writeAll("    .vaults = .{");
        for (wf.vaults, 0..) |v, i| try w.print("{s}\"{f}\"", .{ if (i == 0) "" else ", ", std.zig.fmtString(v) });
        try w.writeAll("},\n");
    }
    if (wf.settings) |s| try w.print("    .settings = {s},\n", .{s});
    try w.writeAll("}\n");
}

/// Imports a VS Code `.code-workspace` (JSON with comments and trailing
/// commas): `folders[].path` and `folders[].name`. Other keys are ignored.
pub fn importCodeWorkspace(arena: Allocator, json_with_comments: []const u8) !WorkspaceFile {
    const clean = try stripJsonc(arena, json_with_comments);
    const Code = struct {
        folders: []const struct { path: []const u8, name: ?[]const u8 = null } = &.{},
    };
    const parsed = try std.json.parseFromSliceLeaky(Code, arena, clean, .{ .ignore_unknown_fields = true });
    const folders = try arena.alloc(WorkspaceFile.Folder, parsed.folders.len);
    for (folders, parsed.folders) |*d, s| d.* = .{ .path = s.path, .name = s.name };
    return .{ .folders = folders };
}

/// Removes `//` and `/* */` comments and trailing commas outside strings.
fn stripJsonc(arena: Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var in_str = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_str) {
            try out.append(arena, c);
            if (c == '\\' and i + 1 < src.len) {
                i += 1;
                try out.append(arena, src[i]);
            } else if (c == '"') in_str = false;
            continue;
        }
        if (c == '"') {
            in_str = true;
            try out.append(arena, c);
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            while (i < src.len and src[i] != '\n') i += 1;
            if (i < src.len) try out.append(arena, '\n');
        } else if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < src.len and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i += 1;
        } else if (c == ',') {
            var j = i + 1;
            while (j < src.len and std.ascii.isWhitespace(src[j])) j += 1;
            if (j < src.len and (src[j] == ']' or src[j] == '}')) continue;
            try out.append(arena, c);
        } else try out.append(arena, c);
    }
    return out.items;
}

test "workspace_file: parse three folders with names and relative paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    const wf = try parse(arena.allocator(),
        \\.{
        \\    .version = 1,
        \\    // comment
        \\    .folders = .{ .{ .path = "." }, .{ .path = "../docs", .name = "Docs" }, .{ .path = "/abs/x" } },
        \\    .vaults = .{"../docs"},
        \\}
    , &diag);
    try std.testing.expectEqual(@as(usize, 3), wf.folders.len);
    try std.testing.expectEqualStrings("../docs", wf.folders[1].path);
    try std.testing.expectEqualStrings("Docs", wf.folders[1].name.?);
    try std.testing.expect(wf.folders[2].name == null);
    try std.testing.expectEqualStrings("../docs", wf.vaults[0]);
    try std.testing.expect(wf.settings == null);
    try std.testing.expect(!diag.hasErrors());
}

test "workspace_file: settings subtree preserved byte-exact" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    const settings =
        \\.{
        \\        .editor = .{ .tab_size = 4, .rulers = .{ 80, 100 } }, // keep me
        \\        .theme = "dark",
        \\    }
    ;
    const src = ".{ .folders = .{ .{ .path = \".\" } }, .future = 3, .settings = " ++ settings ++ " }";
    const wf = try parse(arena.allocator(), src, &diag);
    try std.testing.expectEqualStrings(settings, wf.settings.?);
    try std.testing.expectEqual(@as(usize, 1), diag.messages.items.len);
    try std.testing.expectEqual(.warn, diag.messages.items[0].severity);
}

test "workspace_file: error reports line and column" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostics = .init(std.testing.allocator);
    defer diag.deinit();
    try std.testing.expectError(error.InvalidWorkspaceFile, parse(arena.allocator(), ".{\n    .folders = .{ .{ .path = 3 } },\n}", &diag));
    try std.testing.expect(std.mem.startsWith(u8, diag.messages.items[0].text, "2:"));
    var d2: Diagnostics = .init(std.testing.allocator);
    defer d2.deinit();
    try std.testing.expectError(error.InvalidWorkspaceFile, parse(arena.allocator(), ".{\n  .folders = .{ ,, }\n}", &d2));
    try std.testing.expect(std.mem.startsWith(u8, d2.messages.items[0].text, "2:"));
}

test "workspace_file: write/parse round trip for 50 generated cases" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(50);
    const r = prng.random();
    for (0..50) |_| {
        const n = r.uintAtMost(usize, 4);
        const folders = try a.alloc(WorkspaceFile.Folder, n);
        for (folders, 0..) |*f, i| f.* = .{
            .path = try std.fmt.allocPrint(a, "../dir \"{d}\"\\x{d}", .{ i, r.int(u16) }),
            .name = if (r.boolean()) try std.fmt.allocPrint(a, "Name {d}", .{i}) else null,
        };
        const vaults: []const []const u8 = if (r.boolean()) &.{"notes"} else &.{};
        const wf: WorkspaceFile = .{ .folders = folders, .vaults = vaults, .settings = if (r.boolean()) ".{ .a = 1 }" else null };
        var out: std.Io.Writer.Allocating = .init(a);
        try write(wf, &out.writer);
        var diag: Diagnostics = .init(std.testing.allocator);
        defer diag.deinit();
        const back = try parse(a, try a.dupeZ(u8, out.written()), &diag);
        try std.testing.expect(wf.eql(back));
    }
}

test "workspace_file: import a VS Code .code-workspace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const wf = try importCodeWorkspace(arena.allocator(),
        \\{
        \\  // folders
        \\  "folders": [ { "path": "app" }, { "path": "../lib", "name": "Lib", }, ],
        \\  /* settings */ "settings": { "a": "//not a comment" },
        \\}
    );
    try std.testing.expectEqual(@as(usize, 2), wf.folders.len);
    try std.testing.expectEqualStrings("Lib", wf.folders[1].name.?);
}
