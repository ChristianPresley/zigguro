//! Skills and commands (E10.F09.S04.T01), compatible with Claude Code.
//!
//! A skill is `<root>/<name>/SKILL.md` plus any supporting files in its
//! directory; a command is `<root>/**/<name>.md`, a skill without a
//! directory. Roots are the managed, user and project `skills` and
//! `commands` directories (`.zigguro/…`, and `.claude/…` in compat mode);
//! nested `<subdir>/.zigguro/skills` join once the agent works in that
//! subdirectory (`activateFor`). On a name collision managed beats user
//! beats project, and within one source a skill beats a command.
//!
//! Loading parses only the frontmatter; the body is read when the skill
//! is invoked. `expand` substitutes the arguments (`substitute.zig`) and
//! runs the shell injections, `` !`cmd` `` inline and ```` ```! ````
//! fenced blocks, through a `Shell` whose permission check never prompts:
//! a refused or failed command aborts the invocation.

const std = @import("std");
const proto = @import("zg_ai_proto");
const fm = @import("../context/frontmatter.zig");
const rules = @import("../context/rules.zig");
const assembler = @import("../context/assembler.zig");
const defs = @import("../subagent/defs.zig");
const host_mod = @import("../tools/builtin/terminal_host.zig");
const run_mod = @import("../tools/builtin/run.zig");
const sub = @import("substitute.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// In precedence order.
pub const Source = enum { managed, user, project, plugin };
pub const Kind = enum { skills, commands };

pub const Root = struct {
    dir: []const u8,
    source: Source,
    kind: Kind = .skills,
};

pub const Context = enum { @"inline", fork };

pub const max_file_bytes = 256 * 1024;
pub const max_name_len = 64;
/// Claude Code's limit for a skill's listing entry.
pub const max_listing_chars = 1536;
/// Supporting files listed for the model.
pub const max_supporting_files = 50;

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    when_to_use: ?[]const u8 = null,
    argument_hint: ?[]const u8 = null,
    /// Named arguments, `$name` in the body.
    arguments: []const []const u8 = &.{},
    disable_model_invocation: bool = false,
    user_invocable: bool = true,
    /// Rules (`Bash(git add:*)`) pre-approved while the skill runs, with
    /// Claude Code tool names mapped.
    allowed_tools: []const []const u8 = &.{},
    model: ?[]const u8 = null,
    context: Context = .@"inline",
    /// The subagent for `context: fork`; `general` when null.
    agent: ?[]const u8 = null,
    /// Globs that gate the model listing (relative to the project).
    paths: []const []const u8 = &.{},
    /// The skill's directory; empty for commands.
    dir: []const u8,
    body_path: []const u8,
    source: Source,
    kind: Kind,

    /// The Markdown body, read now.
    pub fn body(s: *const Skill, io: Io, arena: Allocator) ![]const u8 {
        const src = try Io.Dir.cwd().readFileAlloc(io, s.body_path, arena, .limited(max_file_bytes));
        const doc = try fm.parse(arena, src, null);
        return std.mem.trim(u8, doc.body, " \t\r\n");
    }

    /// Files next to SKILL.md (paths relative to `dir`, sorted).
    pub fn supportingFiles(s: *const Skill, io: Io, arena: Allocator) ![]const []const u8 {
        if (s.dir.len == 0) return &.{};
        var dir = Io.Dir.cwd().openDir(io, s.dir, .{ .iterate = true }) catch return &.{};
        defer dir.close(io);
        var w = try dir.walk(arena);
        defer w.deinit();
        var out: std.ArrayList([]const u8) = .empty;
        while (w.next(io) catch null) |e| {
            if (e.kind != .file or std.mem.eql(u8, e.path, "SKILL.md")) continue;
            try out.append(arena, try arena.dupe(u8, e.path));
            if (out.items.len >= max_supporting_files) break;
        }
        std.mem.sort([]const u8, out.items, {}, lessThan);
        return out.items;
    }

    /// The listing text: description and when to use it, cut to `max`
    /// bytes on a character boundary.
    pub fn summary(s: *const Skill, arena: Allocator, max: usize) Allocator.Error![]const u8 {
        const full = if (s.when_to_use) |w| try std.fmt.allocPrint(arena, "{s} ({s})", .{ s.description, w }) else s.description;
        if (full.len <= max) return full;
        var end = max -| "…".len;
        while (end > 0 and (full[end] & 0xC0) == 0x80) end -= 1;
        return std.fmt.allocPrint(arena, "{s}…", .{full[0..end]});
    }
};

/// Frontmatter as written.
const Front = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    when_to_use: ?[]const u8 = null,
    argument_hint: ?fm.Node = null,
    arguments: []const []const u8 = &.{},
    disable_model_invocation: bool = false,
    user_invocable: bool = true,
    allowed_tools: []const []const u8 = &.{},
    model: ?[]const u8 = null,
    context: Context = .@"inline",
    agent: ?[]const u8 = null,
    paths: []const []const u8 = &.{},
};

pub const ParseError = error{ InvalidSkill, OutOfMemory };

/// Parses a SKILL.md or command file. `default_name` is the directory or
/// file name; a file without frontmatter is a command with defaults.
pub fn parseSkill(arena: Allocator, src: []const u8, default_name: []const u8, dir: []const u8, body_path: []const u8, source: Source, kind: Kind, diag: ?*[]const u8) ParseError!Skill {
    var d: fm.Diag = .{};
    const doc = fm.parse(arena, src, &d) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => invalid(diag, "the frontmatter is not valid YAML"),
    };
    const f: Front = if (doc.meta) |meta| fm.decode(Front, arena, meta, &d) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.MissingField, error.TypeMismatch => invalid(diag, if (d.message.len > 0) d.message else "a key has the wrong type"),
    } else .{};
    const name = f.name orelse default_name;
    if (name.len == 0 or name.len > max_name_len) return invalid(diag, "name must be 1-64 characters");
    for (name) |c| if (std.ascii.isWhitespace(c) or c == '/' or c == '\\') return invalid(diag, "name must not contain spaces or slashes");
    return .{
        .name = name,
        .description = f.description orelse firstParagraph(doc.body),
        .when_to_use = f.when_to_use,
        .argument_hint = if (f.argument_hint) |h| try hintText(arena, h) else null,
        .arguments = f.arguments,
        .disable_model_invocation = f.disable_model_invocation,
        .user_invocable = f.user_invocable,
        .allowed_tools = try mapRules(arena, f.allowed_tools),
        .model = f.model,
        .context = f.context,
        .agent = f.agent,
        .paths = f.paths,
        .dir = dir,
        .body_path = body_path,
        .source = source,
        .kind = kind,
    };
}

/// `argument-hint: [issue] [branch]` is YAML flow syntax; keep it as text.
fn hintText(arena: Allocator, n: fm.Node) Allocator.Error![]const u8 {
    switch (n) {
        .scalar => |s| return s,
        .seq => |items| {
            var out: std.ArrayList(u8) = .empty;
            for (items, 0..) |it, k| {
                if (k > 0) try out.append(arena, ' ');
                try out.print(arena, "[{s}]", .{if (it == .scalar) it.scalar else "…"});
            }
            return out.items;
        },
        .map => return "",
    }
}

/// The first paragraph that is not a heading, on one line, for files
/// without a description.
fn firstParagraph(body: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        return l[0..@min(l.len, 250)];
    }
    return "";
}

/// Maps `Bash(git add:*)` to `run_command(git add:*)`.
fn mapRules(arena: Allocator, texts: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, texts.len);
    for (texts, out) |t, *o| {
        const open = std.mem.indexOfScalar(u8, t, '(') orelse t.len;
        const tool = std.mem.trim(u8, t[0..open], " ");
        const mapped = (try defs.mapNames(arena, &.{tool}))[0];
        o.* = if (std.mem.eql(u8, mapped, tool)) t else try std.mem.concat(arena, u8, &.{ mapped, t[open..] });
    }
    return out;
}

fn invalid(diag: ?*[]const u8, why: []const u8) error{InvalidSkill} {
    if (diag) |d| d.* = why;
    return error.InvalidSkill;
}

pub const SkillIndex = struct {
    gpa: Allocator,
    io: Io,
    arena: std.heap.ArenaAllocator,
    mutex: Io.Mutex = .init,
    /// Pointers stay valid until `deinit`.
    skills: std.ArrayList(*Skill) = .empty,
    /// Root directories already read (nested activation reads each once).
    roots_seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Files skipped, with why.
    warnings: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator, io: Io) SkillIndex {
        return .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
    }

    /// Reads every root (in any order: precedence decides collisions).
    pub fn load(gpa: Allocator, io: Io, roots: []const Root) !SkillIndex {
        var ix: SkillIndex = .init(gpa, io);
        errdefer ix.deinit();
        for (roots) |r| try ix.addRoot(r);
        return ix;
    }

    pub fn deinit(ix: *SkillIndex) void {
        ix.skills.deinit(ix.gpa);
        ix.roots_seen.deinit(ix.gpa);
        ix.warnings.deinit(ix.gpa);
        ix.arena.deinit();
    }

    /// Reads one root; a missing directory adds nothing.
    pub fn addRoot(ix: *SkillIndex, root: Root) !void {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        const a = ix.arena.allocator();
        const key = try a.dupe(u8, root.dir);
        const seen = try ix.roots_seen.getOrPut(ix.gpa, key);
        if (seen.found_existing) return;
        var dir = Io.Dir.cwd().openDir(ix.io, root.dir, .{ .iterate = true }) catch return;
        defer dir.close(ix.io);
        var found: std.ArrayList([]const u8) = .empty;
        switch (root.kind) {
            .skills => {
                var it = dir.iterate();
                while (try it.next(ix.io)) |e| if (e.kind == .directory or e.kind == .sym_link) try found.append(a, try a.dupe(u8, e.name));
            },
            .commands => {
                var w = try dir.walk(ix.gpa);
                defer w.deinit();
                while (w.next(ix.io) catch null) |e| {
                    if (e.kind == .file and std.mem.endsWith(u8, e.basename, ".md")) try found.append(a, try a.dupe(u8, e.path));
                }
            },
        }
        std.mem.sort([]const u8, found.items, {}, lessThan);
        for (found.items) |rel| {
            const is_skill = root.kind == .skills;
            const file_rel = if (is_skill) try std.fs.path.join(a, &.{ rel, "SKILL.md" }) else rel;
            const src = dir.readFileAlloc(ix.io, file_rel, a, .limited(max_file_bytes)) catch |e| {
                if (is_skill and e == error.FileNotFound) continue;
                try ix.warn("{s}{c}{s}: {s}", .{ root.dir, std.fs.path.sep, file_rel, @errorName(e) });
                continue;
            };
            const path = try std.fs.path.join(a, &.{ root.dir, file_rel });
            const skill_dir = if (is_skill) try std.fs.path.join(a, &.{ root.dir, rel }) else "";
            const default_name = if (is_skill) rel else std.fs.path.stem(std.fs.path.basename(rel));
            var why: []const u8 = "";
            const s = parseSkill(a, src, default_name, skill_dir, path, root.source, root.kind, &why) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidSkill => {
                    try ix.warn("{s}: {s}", .{ path, why });
                    continue;
                },
            };
            try ix.put(s);
        }
    }

    fn put(ix: *SkillIndex, s: Skill) !void {
        const p = try ix.arena.allocator().create(Skill);
        p.* = s;
        for (ix.skills.items) |*slot| if (std.mem.eql(u8, slot.*.name, s.name)) {
            if (outranks(s, slot.*.*)) slot.* = p;
            return;
        };
        try ix.skills.append(ix.gpa, p);
    }

    fn warn(ix: *SkillIndex, comptime fmt: []const u8, args: anytype) !void {
        try ix.warnings.append(ix.gpa, try std.fmt.allocPrint(ix.arena.allocator(), fmt, args));
    }

    /// Adds the nested `.zigguro/skills` (and `.claude/skills` in compat
    /// mode) of every directory from `project_dir` down to `path`'s.
    pub fn activateFor(ix: *SkillIndex, project_dir: []const u8, path: []const u8, compat: bool) !void {
        var scratch: std.heap.ArenaAllocator = .init(ix.gpa);
        defer scratch.deinit();
        const s = scratch.allocator();
        const abs = if (std.fs.path.isAbsolute(path)) path else try std.fs.path.join(s, &.{ project_dir, path });
        var dirs: std.ArrayList([]const u8) = .empty;
        var d = std.fs.path.dirname(abs) orelse return;
        while (d.len > project_dir.len and std.mem.startsWith(u8, d, project_dir)) {
            try dirs.append(s, d);
            d = std.fs.path.dirname(d) orelse break;
        }
        for (dirs.items) |dir| {
            try ix.addRoot(.{ .dir = try std.fs.path.join(s, &.{ dir, ".zigguro", "skills" }), .source = .project });
            if (compat) try ix.addRoot(.{ .dir = try std.fs.path.join(s, &.{ dir, ".claude", "skills" }), .source = .project });
        }
    }

    pub fn find(ix: *SkillIndex, name: []const u8) ?*const Skill {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        for (ix.skills.items) |s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    /// A snapshot of the skills, sorted by name (in `arena`).
    pub fn list(ix: *SkillIndex, arena: Allocator) Allocator.Error![]const *const Skill {
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        const out = try arena.alloc(*const Skill, ix.skills.items.len);
        for (ix.skills.items, out) |s, *o| o.* = s;
        std.mem.sort(*const Skill, out, {}, byName);
        return out;
    }

    /// What the model sees: skills it may invoke, sorted by name, each
    /// cut to `max_chars_each`. A skill with `paths` is listed only once
    /// one of `touched` (project-relative) matches.
    pub fn modelListing(ix: *SkillIndex, arena: Allocator, max_chars_each: usize, touched: []const []const u8) Allocator.Error![]const assembler.SkillSummary {
        var out: std.ArrayList(assembler.SkillSummary) = .empty;
        for (try ix.list(arena)) |s| {
            if (s.disable_model_invocation) continue;
            if (s.paths.len > 0) {
                var hit = false;
                for (touched) |t| hit = hit or rules.matchesAny(s.paths, t);
                if (!hit) continue;
            }
            try out.append(arena, .{ .name = s.name, .description = try s.summary(arena, max_chars_each) });
        }
        return out.items;
    }
};

fn outranks(new: Skill, old: Skill) bool {
    const a = @intFromEnum(new.source);
    const b = @intFromEnum(old.source);
    if (a != b) return a < b;
    return new.kind == .skills and old.kind == .commands;
}

fn byName(_: void, x: *const Skill, y: *const Skill) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// The standard roots under `project_dir`, then the user's and managed
/// configuration directories (either may be null), with `.claude` in
/// compat mode.
pub fn standardRoots(arena: Allocator, project_dir: []const u8, user_dir: ?[]const u8, managed_dir: ?[]const u8, compat: bool) Allocator.Error![]const Root {
    var out: std.ArrayList(Root) = .empty;
    const pairs = [_]struct { []const u8, Kind }{ .{ "skills", .skills }, .{ "commands", .commands } };
    if (managed_dir) |m| for (pairs) |p| try out.append(arena, .{ .dir = try std.fs.path.join(arena, &.{ m, p[0] }), .source = .managed, .kind = p[1] });
    if (user_dir) |u| for (pairs) |p| try out.append(arena, .{ .dir = try std.fs.path.join(arena, &.{ u, p[0] }), .source = .user, .kind = p[1] });
    for ([_][]const u8{ ".zigguro", ".claude" }) |base| {
        if (!compat and std.mem.eql(u8, base, ".claude")) continue;
        for (pairs) |p| try out.append(arena, .{ .dir = try std.fs.path.join(arena, &.{ project_dir, base, p[0] }), .source = .project, .kind = p[1] });
    }
    return out.items;
}

// -- expansion -------------------------------------------------------

pub const ShellResult = union(enum) {
    /// The command's output.
    ok: []const u8,
    /// The permission rules refused it, with why.
    denied: []const u8,
    /// It could not run, timed out or exited non-zero, with why.
    failed: []const u8,
};

/// Runs injected commands. The permission check must not prompt.
pub const Shell = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, owner: proto.AgentRef, command: []const u8, cwd: []const u8) Io.Cancelable!ShellResult,
};

pub const ExpandCtx = struct {
    /// `skill_dir` is taken from the skill.
    vars: sub.Vars = .{},
    owner: proto.AgentRef = .{ .session = 0, .agent = 0 },
    shell: ?Shell = null,
    /// `ai.skills.disableShellExecution`.
    disable_shell: bool = false,
    max_injection_bytes: usize = 16 * 1024,
    /// Why expansion failed.
    diag: ?*[]const u8 = null,
};

pub const Expanded = struct {
    text: []const u8,
    injections: u32 = 0,
};

pub const ExpandError = error{ ReadFailed, ShellDenied, ShellFailed, OutOfMemory, Canceled };

pub const disabled_text = "[shell command execution is disabled by ai.skills.disableShellExecution]";

/// The skill's body with `args_raw` substituted and the injected commands
/// replaced by their output.
pub fn expand(io: Io, arena: Allocator, s: *const Skill, args_raw: []const u8, ctx: ExpandCtx) ExpandError!Expanded {
    const raw = s.body(io, arena) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (ctx.diag) |d| d.* = std.fmt.allocPrint(arena, "cannot read {s}: {s}", .{ s.body_path, @errorName(e) }) catch "cannot read the skill";
            return error.ReadFailed;
        },
    };
    var vars = ctx.vars;
    vars.skill_dir = s.dir;
    const text = try sub.substitute(arena, raw, args_raw, s.arguments, vars);
    return inject(io, arena, text, ctx);
}

/// Runs the `` !`cmd` `` and ```` ```! ```` injections in `text`.
/// Ordinary code fences are left alone.
pub fn inject(io: Io, arena: Allocator, text: []const u8, ctx: ExpandCtx) ExpandError!Expanded {
    var out: std.ArrayList(u8) = .empty;
    var n: u32 = 0;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        const t = std.mem.trimStart(u8, line, " ");
        if (!in_fence and std.mem.startsWith(u8, t, "```!")) {
            var cmd: std.ArrayList(u8) = .empty;
            var closed = false;
            while (lines.next()) |l| {
                if (std.mem.eql(u8, std.mem.trim(u8, l, " \t\r"), "```")) {
                    closed = true;
                    break;
                }
                if (cmd.items.len > 0) try cmd.append(arena, '\n');
                try cmd.appendSlice(arena, l);
            }
            if (!closed) return fail(ctx, arena, "a ```! block is not closed", .{}, error.ShellFailed);
            try out.appendSlice(arena, try runOne(io, arena, cmd.items, ctx));
            n += 1;
            continue;
        }
        if (std.mem.startsWith(u8, t, "```")) {
            in_fence = !in_fence;
            try out.appendSlice(arena, line);
            continue;
        }
        if (in_fence) {
            try out.appendSlice(arena, line);
            continue;
        }
        var i: usize = 0;
        while (i < line.len) {
            const at = std.mem.indexOfPos(u8, line, i, "!`") orelse break;
            const ok_before = at == 0 or std.ascii.isWhitespace(line[at - 1]) or line[at - 1] == '(';
            const close = std.mem.indexOfScalarPos(u8, line, at + 2, '`');
            if (!ok_before or close == null or close.? == at + 2) {
                try out.appendSlice(arena, line[i .. at + 2]);
                i = at + 2;
                continue;
            }
            try out.appendSlice(arena, line[i..at]);
            try out.appendSlice(arena, try runOne(io, arena, line[at + 2 .. close.?], ctx));
            n += 1;
            i = close.? + 1;
        }
        try out.appendSlice(arena, line[i..]);
    }
    return .{ .text = out.items, .injections = n };
}

fn runOne(io: Io, arena: Allocator, command: []const u8, ctx: ExpandCtx) ExpandError![]const u8 {
    if (ctx.disable_shell) return disabled_text;
    const sh = ctx.shell orelse return fail(ctx, arena, "shell commands cannot run here (`{s}`)", .{command}, error.ShellFailed);
    const r = try sh.run(sh.ctx, io, arena, ctx.owner, command, ctx.vars.project_dir);
    switch (r) {
        .ok => |o| {
            const trimmed = std.mem.trimEnd(u8, o, "\r\n");
            if (trimmed.len <= ctx.max_injection_bytes) return trimmed;
            var end = ctx.max_injection_bytes;
            while (end > 0 and (trimmed[end] & 0xC0) == 0x80) end -= 1;
            return std.fmt.allocPrint(arena, "{s}\n[output truncated]", .{trimmed[0..end]});
        },
        .denied => |why| return fail(ctx, arena, "`{s}` was not run: {s}", .{ command, why }, error.ShellDenied),
        .failed => |why| return fail(ctx, arena, "`{s}` failed: {s}", .{ command, why }, error.ShellFailed),
    }
}

fn fail(ctx: ExpandCtx, arena: Allocator, comptime fmt: []const u8, args: anytype, e: ExpandError) ExpandError {
    if (ctx.diag) |d| d.* = std.fmt.allocPrint(arena, fmt, args) catch "the skill could not be expanded";
    return e;
}

/// A `Shell` over a terminal host (E06 hidden task terminals in the IDE,
/// `ProcessHost` in `zg agent`), checked by an E16 command policy that
/// must not prompt: anything but allow refuses the command.
pub const HostShell = struct {
    host: host_mod.TerminalHost,
    policy: ?run_mod.CommandPolicy = null,
    timeout_ms: u64 = 30_000,

    pub fn shell(h: *HostShell) Shell {
        return .{ .ctx = h, .run = run };
    }

    fn run(ctx: *anyopaque, io: Io, arena: Allocator, owner: proto.AgentRef, command: []const u8, cwd: []const u8) Io.Cancelable!ShellResult {
        const h: *HostShell = @ptrCast(@alignCast(ctx));
        const session = h.host.create(io, owner, false) catch |e| return .{ .failed = @errorName(e) };
        const dir: ?[]const u8 = if (cwd.len > 0) cwd else null;
        if (h.policy) |p| switch (try p.check(p.ctx, io, .{ .command = command, .cwd = dir, .session = session, .agent = owner })) {
            .allow, .allow_edited => {},
            .deny => |why| return .{ .denied = why },
        };
        const job = h.host.start(io, session, command, dir) catch |e| return .{ .failed = @errorName(e) };
        const status = try h.host.wait(io, job, h.timeout_ms, null);
        const lines = h.host.lines(arena, job, 0) catch return .{ .failed = "out of memory" };
        const text = std.mem.join(arena, "\n", lines) catch return .{ .failed = "out of memory" };
        return switch (status) {
            .exited => |code| if (code == 0) .{ .ok = text } else .{ .failed = std.fmt.allocPrint(arena, "exit code {d}{s}{s}", .{ code, if (text.len > 0) ": " else "", tail(text) }) catch "failed" },
            .running => blk: {
                h.host.interrupt(io, job);
                break :blk .{ .failed = std.fmt.allocPrint(arena, "timed out after {d} s", .{h.timeout_ms / 1000}) catch "timed out" };
            },
            .killed => .{ .failed = "killed" },
            .failed => |why| .{ .failed = why },
        };
    }

    fn tail(text: []const u8) []const u8 {
        return if (text.len > 400) text[text.len - 400 ..] else text;
    }
};
