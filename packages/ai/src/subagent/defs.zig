//! Subagent definitions (E10.F09.S01.T01): Markdown files whose
//! frontmatter describes the agent and whose body is its system prompt.
//!
//! Definitions come from roots in precedence order (for example the
//! project's `.zigguro/agents`, then the user's, then the built-ins); the
//! first definition of a name wins. Loading reads only what the index
//! needs; `body` re-reads the file when the agent is spawned.
//!
//! Frontmatter keys: `name` (unique, at most 64 characters, no `:`),
//! `description` (required), `tools` and `disallowed-tools` (a sequence or
//! a comma-separated string; Claude Code names such as `Read` or `Bash`
//! are accepted), `model` (an id, an alias, `fast` or `inherit`),
//! `permission-mode`, `skills`, `max-turns`, `isolation` (`shared` or
//! `workspace`), `background` and `effort`.

const std = @import("std");
const fm = @import("../context/frontmatter.zig");
const resume_mod = @import("../session/resume.zig");
const request = @import("../provider/request.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const PermissionMode = resume_mod.PermissionMode;

pub const DefSource = enum { builtin, user, project, plugin, cli };

pub const DefRoot = struct {
    dir: []const u8,
    source: DefSource,
};

pub const Isolation = enum { shared, workspace };

pub const AgentDef = struct {
    name: []const u8,
    description: []const u8,
    /// The system prompt; empty until `body` reads it (file definitions).
    prompt: []const u8 = "",
    /// Allowed tools (registry names); null allows every tool.
    tools: ?[]const []const u8 = null,
    disallowed_tools: []const []const u8 = &.{},
    /// An id, an alias, `fast` (the cheapest model of the parent's
    /// provider unless an alias says otherwise) or `inherit`; null inherits.
    model: ?[]const u8 = null,
    permission_mode: ?PermissionMode = null,
    skills: []const []const u8 = &.{},
    max_turns: ?u32 = null,
    isolation: Isolation = .shared,
    background: bool = true,
    effort: ?request.Effort = null,
    source: DefSource,
    /// The file the body is read from; null when `prompt` is set.
    path: ?[]const u8 = null,

    /// The system prompt, read from the file on first use.
    pub fn body(d: *const AgentDef, io: Io, arena: Allocator) ![]const u8 {
        const path = d.path orelse return d.prompt;
        const src = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes));
        const doc = try fm.parse(arena, src, null);
        return std.mem.trim(u8, doc.body, " \t\r\n");
    }
};

pub const max_file_bytes = 256 * 1024;
pub const max_name_len = 64;

/// The built-in definitions (lowest precedence).
pub const builtin_sources = [_]struct { []const u8, []const u8 }{
    .{ "explore", @embedFile("builtin_agents/explore.md") },
    .{ "plan", @embedFile("builtin_agents/plan.md") },
    .{ "general", @embedFile("builtin_agents/general.md") },
};

/// Frontmatter as written.
const Front = struct {
    name: []const u8,
    description: []const u8,
    tools: ?[]const []const u8 = null,
    disallowed_tools: []const []const u8 = &.{},
    model: ?[]const u8 = null,
    permission_mode: ?PermissionMode = null,
    skills: []const []const u8 = &.{},
    max_turns: ?u32 = null,
    isolation: Isolation = .shared,
    background: bool = true,
    effort: ?request.Effort = null,
    color: ?[]const u8 = null,
};

pub const ParseError = error{ InvalidDefinition, OutOfMemory };

/// Parses one definition. With `keep_body`, the body becomes `prompt`.
pub fn parseDef(arena: Allocator, src: []const u8, source: DefSource, path: ?[]const u8, keep_body: bool, diag: ?*[]const u8) ParseError!AgentDef {
    var d: fm.Diag = .{};
    const doc = fm.parse(arena, src, &d) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => invalid(diag, "the frontmatter is not valid YAML"),
    };
    const meta = doc.meta orelse return invalid(diag, "no frontmatter");
    const f = fm.decode(Front, arena, meta, &d) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.MissingField => invalid(diag, if (d.message.len > 0) d.message else "a required key is missing"),
        error.TypeMismatch => invalid(diag, if (d.message.len > 0) d.message else "a key has the wrong type"),
    };
    if (f.name.len == 0 or f.name.len > max_name_len or std.mem.indexOfScalar(u8, f.name, ':') != null)
        return invalid(diag, "name must be 1-64 characters without ':'");
    if (f.description.len == 0) return invalid(diag, "description is empty");
    return .{
        .name = f.name,
        .description = f.description,
        .prompt = if (keep_body) std.mem.trim(u8, doc.body, " \t\r\n") else "",
        .tools = if (f.tools) |t| try mapNames(arena, t) else null,
        .disallowed_tools = try mapNames(arena, f.disallowed_tools),
        .model = f.model,
        .permission_mode = f.permission_mode,
        .skills = f.skills,
        .max_turns = f.max_turns,
        .isolation = f.isolation,
        .background = f.background,
        .effort = f.effort,
        .source = source,
        .path = if (keep_body) null else path,
    };
}

/// Loads the definitions under `roots` (in precedence order: the first
/// definition of a name wins), then the built-ins. A file that does not
/// parse is skipped with a warning in `warnings`.
pub fn loadDefs(io: Io, arena: Allocator, roots: []const DefRoot, out: *std.ArrayList(AgentDef), warnings: ?*std.ArrayList([]const u8)) !void {
    for (roots) |root| {
        var dir = Io.Dir.cwd().openDir(io, root.dir, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind == .file and std.mem.endsWith(u8, e.name, ".md")) try names.append(arena, try arena.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |n| {
            const path = try std.fs.path.join(arena, &.{ root.dir, n });
            const src = dir.readFileAlloc(io, n, arena, .limited(max_file_bytes)) catch |e| {
                if (warnings) |w| try w.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ path, @errorName(e) }));
                continue;
            };
            var why: []const u8 = "";
            const def = parseDef(arena, src, root.source, path, false, &why) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidDefinition => {
                    if (warnings) |w| try w.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ path, why }));
                    continue;
                },
            };
            try add(arena, out, def);
        }
    }
    for (builtin_sources) |b| try add(arena, out, parseDef(arena, b[1], .builtin, null, true, null) catch unreachable);
}

fn add(arena: Allocator, out: *std.ArrayList(AgentDef), def: AgentDef) Allocator.Error!void {
    if (find(out.items, def.name) != null) return;
    try out.append(arena, def);
}

/// The definition named `name`.
pub fn find(defs: []const AgentDef, name: []const u8) ?*const AgentDef {
    for (defs) |*d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

/// Claude Code tool names and their zigguro equivalents.
pub const compat_aliases = [_]struct { []const u8, []const u8 }{
    .{ "Read", "read_file" },
    .{ "Edit", "edit_file" },
    .{ "MultiEdit", "multi_edit" },
    .{ "Write", "write_file" },
    .{ "Bash", "run_command" },
    .{ "BashOutput", "command_output" },
    .{ "KillBash", "kill_command" },
    .{ "KillShell", "kill_command" },
    .{ "Grep", "grep" },
    .{ "Glob", "glob" },
    .{ "LS", "list_dir" },
    .{ "WebFetch", "web_fetch" },
    .{ "WebSearch", "web_search" },
    .{ "Task", "task" },
    .{ "Agent", "task" },
    .{ "TodoWrite", "todo_write" },
};

/// Maps compat names; other names stay as they are.
pub fn mapNames(arena: Allocator, names: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, names.len);
    for (names, out) |n, *o| {
        o.* = n;
        for (compat_aliases) |c| if (std.mem.eql(u8, c[0], n)) {
            o.* = c[1];
            break;
        };
    }
    return out;
}

fn invalid(diag: ?*[]const u8, why: []const u8) error{InvalidDefinition} {
    if (diag) |d| d.* = why;
    return error.InvalidDefinition;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}
