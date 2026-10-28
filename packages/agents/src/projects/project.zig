//! The project file format (E13.F09.S01.T01): `.zigguro/projects/<slug>/`
//! holds `project.zon` (title, description, knowledge items, run defaults,
//! pinned) and a free-form `instructions.md`. The slug is the directory
//! name. Parsing reports the first problem with its line and column;
//! unknown fields are errors. `write` emits the canonical ZON that `parse`
//! reads back unchanged.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const format_version: u32 = 1;
pub const dir_rel = ".zigguro/projects";
pub const file_name = "project.zon";
pub const instructions_name = "instructions.md";
/// `instructions.md` beyond this is cut (with a warning).
pub const max_instructions = 32 * 1024;

/// One source of project knowledge.
pub const KnowledgeItem = union(enum) {
    /// Files under a workspace folder matching a glob (relative to it).
    folder: struct { path: []const u8, glob: []const u8 = "**/*" },
    /// Notes matching an E08 notes query (`tag:#book`).
    notes_query: []const u8,
    /// One workspace file.
    file: []const u8,
    /// Research source notes matching a query (E13.F05).
    source: []const u8,
};

/// Used by runs started in the project when they name none.
pub const Defaults = struct {
    agent_def: ?[]const u8 = null,
    model: ?[]const u8 = null,
    profile: ?[]const u8 = null,
};

/// `project.zon` as written.
pub const ProjectFile = struct {
    version: u32 = format_version,
    title: []const u8,
    description: []const u8 = "",
    knowledge: []const KnowledgeItem = &.{},
    defaults: Defaults = .{},
    pinned: bool = false,
};

pub const Project = struct {
    slug: []const u8,
    title: []const u8,
    description: []const u8 = "",
    knowledge: []const KnowledgeItem = &.{},
    defaults: Defaults = .{},
    pinned: bool = false,

    pub fn file(p: *const Project) ProjectFile {
        return .{ .title = p.title, .description = p.description, .knowledge = p.knowledge, .defaults = p.defaults, .pinned = p.pinned };
    }

    pub fn fromFile(slug: []const u8, f: ProjectFile) Project {
        return .{ .slug = slug, .title = f.title, .description = f.description, .knowledge = f.knowledge, .defaults = f.defaults, .pinned = f.pinned };
    }
};

pub const Problem = struct {
    line: u32 = 0,
    column: u32 = 0,
    message: []const u8,
};

/// `[a-z0-9][a-z0-9-]{0,63}`.
pub fn validSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s, 0..) |c, i| switch (c) {
        'a'...'z', '0'...'9' => {},
        '-' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

/// Parses `project.zon` of `slug` into `arena`; on failure `problem` says
/// why (in `arena`).
pub fn parse(arena: Allocator, slug: []const u8, source: [:0]const u8, problem: *Problem) error{ OutOfMemory, Invalid }!Project {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena);
    const f = std.zon.parse.fromSliceAlloc(ProjectFile, arena, source, &diag, .{ .free_on_error = false }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            var it = diag.iterateErrors();
            const first = it.next() orelse {
                problem.* = .{ .message = "invalid ZON" };
                return error.Invalid;
            };
            const loc = first.getLocation(&diag);
            problem.* = .{
                .line = @intCast(loc.line + 1),
                .column = @intCast(loc.column + 1),
                .message = try std.fmt.allocPrint(arena, "{f}", .{first.fmtMessage(&diag)}),
            };
            return error.Invalid;
        },
    };
    if (validateFile(&f)) |msg| {
        problem.* = .{ .message = msg };
        return error.Invalid;
    }
    return .fromFile(try arena.dupe(u8, slug), f);
}

/// What ZON cannot check. Null when valid; the message is static.
pub fn validateFile(f: *const ProjectFile) ?[]const u8 {
    if (f.version != format_version) return "unsupported version (expected 1)";
    if (std.mem.trim(u8, f.title, " \t").len == 0) return "title must not be empty";
    if (f.title.len > 200) return "title is longer than 200 bytes";
    for (f.knowledge) |k| switch (k) {
        .folder => |d| {
            if (!relPath(d.path)) return "knowledge folder must be a workspace-relative path";
            if (d.glob.len == 0) return "knowledge folder glob must not be empty";
        },
        .file => |p| if (!relPath(p)) return "knowledge file must be a workspace-relative path",
        .notes_query, .source => |q| if (std.mem.trim(u8, q, " ").len == 0) return "knowledge query must not be empty",
    };
    return null;
}

/// Relative, `/`-separated, no `..` or empty segments.
pub fn relPath(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or std.mem.indexOfScalar(u8, p, '\\') != null) return false;
    if (p.len >= 2 and p[1] == ':') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// The canonical `project.zon`.
pub fn write(w: *std.Io.Writer, f: ProjectFile) std.Io.Writer.Error!void {
    try w.print(".{{\n    .version = {d},\n    .title = {f},\n", .{ f.version, quoted(f.title) });
    if (f.description.len > 0) try w.print("    .description = {f},\n", .{quoted(f.description)});
    if (f.knowledge.len > 0) {
        try w.writeAll("    .knowledge = .{\n");
        for (f.knowledge) |k| switch (k) {
            .folder => |d| {
                try w.print("        .{{ .folder = .{{ .path = {f}", .{quoted(d.path)});
                if (!std.mem.eql(u8, d.glob, "**/*")) try w.print(", .glob = {f}", .{quoted(d.glob)});
                try w.writeAll(" } },\n");
            },
            .notes_query => |q| try w.print("        .{{ .notes_query = {f} }},\n", .{quoted(q)}),
            .file => |p| try w.print("        .{{ .file = {f} }},\n", .{quoted(p)}),
            .source => |q| try w.print("        .{{ .source = {f} }},\n", .{quoted(q)}),
        };
        try w.writeAll("    },\n");
    }
    const d = f.defaults;
    if (d.agent_def != null or d.model != null or d.profile != null) {
        try w.writeAll("    .defaults = .{");
        var first = true;
        inline for (.{ "agent_def", "model", "profile" }) |name| if (@field(d, name)) |v| {
            try w.print("{s} .{s} = {f}", .{ if (first) "" else ",", name, quoted(v) });
            first = false;
        };
        try w.writeAll(" },\n");
    }
    if (f.pinned) try w.writeAll("    .pinned = true,\n");
    try w.writeAll("}\n");
}

pub fn writeAlloc(a: Allocator, f: ProjectFile) Allocator.Error![]u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    write(&w.writer, f) catch return error.OutOfMemory;
    return w.toOwnedSlice();
}

const Quoted = struct {
    s: []const u8,
    pub fn format(q: Quoted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('"');
        try std.zig.stringEscape(q.s, w);
        try w.writeByte('"');
    }
};

fn quoted(s: []const u8) Quoted {
    return .{ .s = s };
}
