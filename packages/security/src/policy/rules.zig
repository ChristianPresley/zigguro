//! Permission rules: parsing, matchers and the compiled rule set
//! (E16.F02.S01.T01).
//!
//! Grammar: `Tool` or `Tool(specifier)`. The tool name is
//! `[A-Za-z0-9_.*-]+`; the specifier runs to the final `)` and may contain
//! parentheses (`run_command(echo $(date))` is a literal command pattern).
//!
//! | Rule | Matches |
//! |---|---|
//! | `read_file`, `run_command`, `web_fetch` | every call of that tool |
//! | `run_command(npm test *)` | a simple command; `*` is any text |
//! | `read_file(./.env*)`, `edit_file(//etc/**)` | gitignore-style path (see glob.zig) |
//! | `web_fetch(domain:*.example.com)` | host (see domain.zig) |
//! | `mcp__github__*`, `mcp__github__create_issue` | MCP tools by name |
//! | `scm(push)` | SCM actions |
//! | `ui(open_uri:vscode:*)`, `ui(clipboard_read)` | UI effects |
//! | `task(explore)` | subagent types |
//!
//! Claude Code spellings (`Bash`, `Read`, `Edit`, `Write`, `WebFetch`,
//! `WebSearch`, `Glob`, `Grep`) are accepted as aliases.
//!
//! A specifier that cannot be interpreted for its tool fails closed: a deny
//! or ask rule still guards the exact literal; an allow rule approves
//! nothing and the parse reports a warning.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glob = @import("glob.zig");
const domain = @import("domain.zig");

/// Rule polarity.
pub const RuleKind = enum { allow, ask, deny };

/// Settings layers, highest precedence first.
pub const Layer = enum(u8) { managed, cli, workspace_local, workspace, user, session, builtin };

/// Where a rule came from, for messages and audit.
pub const Source = struct {
    layer: Layer,
    file: ?[]const u8 = null,
    index: u32 = 0,
};

/// Errors from `parse`.
pub const ParseError = error{ EmptyRule, UnbalancedParen, BadToolName, BadPattern, BadDomain, UnsupportedSpecifier, OutOfMemory };

/// How a tool's specifier is interpreted.
pub const SpecKind = enum { none, path, command, domain, scm, ui, task };

/// Associates a tool name with its specifier kind; E10/E11 can pass more
/// through `Context.tool_kinds`.
pub const ToolKind = struct { name: []const u8, kind: SpecKind };

/// Built-in tool → specifier kinds.
pub const builtin_tool_kinds = [_]ToolKind{
    .{ .name = "read_file", .kind = .path },
    .{ .name = "edit_file", .kind = .path },
    .{ .name = "write_file", .kind = .path },
    .{ .name = "multi_edit", .kind = .path },
    .{ .name = "list_dir", .kind = .path },
    .{ .name = "glob", .kind = .path },
    .{ .name = "grep", .kind = .path },
    .{ .name = "run_command", .kind = .command },
    .{ .name = "web_fetch", .kind = .domain },
    .{ .name = "web_search", .kind = .domain },
    .{ .name = "scm", .kind = .scm },
    .{ .name = "ui", .kind = .ui },
    .{ .name = "task", .kind = .task },
};

/// Claude Code tool names accepted as aliases.
pub const aliases = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Bash", "run_command" },
    .{ "Read", "read_file" },
    .{ "Edit", "edit_file" },
    .{ "Write", "write_file" },
    .{ "MultiEdit", "multi_edit" },
    .{ "WebFetch", "web_fetch" },
    .{ "WebSearch", "web_search" },
    .{ "Glob", "glob" },
    .{ "Grep", "grep" },
    .{ "LS", "list_dir" },
    .{ "Task", "task" },
});

/// Matches tool names: exact, `*`, or `prefix*` (`mcp__github__*`).
pub const ToolPattern = struct {
    text: []const u8,

    /// True when `name` matches.
    pub fn matches(p: ToolPattern, name: []const u8) bool {
        if (p.isWildcard()) return std.mem.startsWith(u8, name, p.text[0 .. p.text.len - 1]);
        return std.mem.eql(u8, p.text, name);
    }

    /// True for `*` and `prefix*`.
    pub fn isWildcard(p: ToolPattern) bool {
        return p.text.len > 0 and p.text[p.text.len - 1] == '*';
    }
};

/// A command pattern: literal text with `*` matching any run of
/// characters (spaces included). A trailing ` *` also matches the bare
/// prefix (`npm test *` matches `npm test`).
pub const CommandPattern = struct {
    text: []const u8,

    /// True when the normalised simple command matches.
    pub fn matches(p: CommandPattern, simple_command: []const u8) bool {
        if (matchStar(p.text, simple_command)) return true;
        if (std.mem.endsWith(u8, p.text, " *")) return std.mem.eql(u8, p.text[0 .. p.text.len - 2], simple_command);
        return false;
    }

    /// True when the pattern has no wildcard (only exact rules approve
    /// exec-wrapper commands).
    pub fn isExact(p: CommandPattern) bool {
        return std.mem.indexOfScalar(u8, p.text, '*') == null;
    }
};

/// `*`-only glob over a whole string (no `?`, no segments).
pub fn matchStar(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pat.len and pat[p] != '*' and pat[p] == s[i]) {
            p += 1;
            i += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            mark = i;
            p += 1;
        } else if (star) |sp| {
            p = sp + 1;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// The interpreted specifier.
pub const Specifier = union(enum) {
    none,
    command: CommandPattern,
    path: glob.PathPattern,
    domain: domain.DomainPattern,
    scm: []const u8,
    /// `*`-glob over `open_uri:<uri>`, `clipboard_read`, `clipboard_write`, `paste_control`.
    ui: []const u8,
    task: []const u8,
    /// Uninterpretable: deny/ask guard the exact literal, allow never matches.
    raw: []const u8,
};

/// One parsed rule.
pub const Rule = struct {
    kind: RuleKind,
    tool: ToolPattern,
    spec: Specifier,
    source: Source,
    /// The rule as written, for messages.
    text: []const u8,

    /// `deny run_command(rm *)` (user settings.zon:3).
    pub fn format(r: *const Rule, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{t} {s} ({t}", .{ r.kind, r.text, r.source.layer });
        if (r.source.file) |f| try w.print(" {s}:{d}", .{ f, r.source.index });
        try w.writeAll(")");
    }
};

/// Parse context: anchors for paths plus extra tool kinds.
pub const Context = struct {
    anchors: glob.Anchors,
    tool_kinds: []const ToolKind = &.{},
};

/// The specifier kind of `tool` (MCP and unknown tools take none).
pub fn specKindOf(ctx: Context, tool: []const u8) SpecKind {
    for (ctx.tool_kinds) |k| if (std.mem.eql(u8, k.name, tool)) return k.kind;
    for (builtin_tool_kinds) |k| if (std.mem.eql(u8, k.name, tool)) return k.kind;
    return .none;
}

/// Parses one rule. `warning` (optional) receives a message when an allow
/// rule's specifier is unusable.
pub fn parse(arena: Allocator, text_in: []const u8, kind: RuleKind, source: Source, ctx: Context) ParseError!Rule {
    return parseWarn(arena, text_in, kind, source, ctx, null);
}

/// `parse` with a warning out-parameter.
pub fn parseWarn(arena: Allocator, text_in: []const u8, kind: RuleKind, source: Source, ctx: Context, warning: ?*?[]const u8) ParseError!Rule {
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    if (text.len == 0) return error.EmptyRule;
    const open = std.mem.indexOfScalar(u8, text, '(');
    const name_raw = if (open) |o| text[0..o] else text;
    if (name_raw.len == 0) return error.BadToolName;
    for (name_raw, 0..) |c, i| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '*';
        if (!ok) return error.BadToolName;
        if (c == '*' and i != name_raw.len - 1) return error.BadToolName;
    }
    const name = aliases.get(name_raw) orelse name_raw;
    var rule: Rule = .{
        .kind = kind,
        .tool = .{ .text = try arena.dupe(u8, name) },
        .spec = .none,
        .source = source,
        .text = try arena.dupe(u8, text),
    };
    const o = open orelse return rule;
    if (text[text.len - 1] != ')') return error.UnbalancedParen;
    const body = text[o + 1 .. text.len - 1];
    // Parentheses inside must balance.
    var depth: i32 = 0;
    for (body) |c| {
        if (c == '(') depth += 1;
        if (c == ')') depth -= 1;
        if (depth < 0) return error.UnbalancedParen;
    }
    if (depth != 0) return error.UnbalancedParen;
    if (body.len == 0 or std.mem.eql(u8, body, "*")) return rule; // `tool()` / `tool(*)` = whole tool
    if (rule.tool.isWildcard()) return error.UnsupportedSpecifier;

    const sk = specKindOf(ctx, name);
    rule.spec = interpret(arena, sk, body, ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            if (kind == .allow) {
                if (warning) |w| w.* = try std.fmt.allocPrint(arena, "allow rule `{s}` has an unusable specifier ({t}); it approves nothing", .{ text, err });
            }
            break :blk .{ .raw = try arena.dupe(u8, body) };
        },
    };
    return rule;
}

fn interpret(arena: Allocator, sk: SpecKind, body: []const u8, ctx: Context) ParseError!Specifier {
    return switch (sk) {
        .none => error.UnsupportedSpecifier,
        .command => .{ .command = .{ .text = try normalizeSpaces(arena, body) } },
        .path => .{ .path = glob.compile(arena, body, ctx.anchors) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.BadPattern => return error.BadPattern,
        } },
        .domain => blk: {
            const prefix = "domain:";
            if (!std.mem.startsWith(u8, body, prefix)) return error.UnsupportedSpecifier;
            break :blk .{ .domain = domain.parse(arena, body[prefix.len..]) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.BadDomain => return error.BadDomain,
            } };
        },
        .scm => .{ .scm = try arena.dupe(u8, body) },
        .ui => .{ .ui = try arena.dupe(u8, body) },
        .task => .{ .task = try arena.dupe(u8, body) },
    };
}

fn normalizeSpaces(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |w| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, w);
    }
    return out.toOwnedSlice(arena);
}

/// What a rule is matched against (the engine derives targets from
/// `contracts.Resource`s).
pub const Target = union(enum) {
    /// The tool call as a whole (no resource).
    none,
    path: struct { abs: []const u8, is_dir: bool = false },
    /// A normalised simple command.
    command: struct { text: []const u8, exec_wrapper: bool = false },
    host: struct { host: []const u8, port: ?u16 = null },
    scm: []const u8,
    /// `open_uri:<uri>`, `clipboard_read`, ...
    ui: []const u8,
    task: []const u8,

    fn literal(t: Target) []const u8 {
        return switch (t) {
            .none => "",
            .path => |p| p.abs,
            .command => |c| c.text,
            .host => |h| h.host,
            .scm, .ui, .task => |s| s,
        };
    }
};

/// True when `r`'s specifier matches `t` (the tool name is checked by the
/// caller).
pub fn specMatches(r: *const Rule, t: Target) bool {
    return switch (r.spec) {
        .none => true,
        .raw => |lit| r.kind != .allow and std.mem.eql(u8, lit, t.literal()),
        .command => |c| switch (t) {
            .command => |cmd| (!cmd.exec_wrapper or r.kind != .allow or c.isExact()) and c.matches(cmd.text),
            else => false,
        },
        .path => |*p| switch (t) {
            .path => |pt| p.matches(pt.abs, pt.is_dir),
            else => false,
        },
        .domain => |d| switch (t) {
            .host => |h| d.matches(h.host, h.port),
            else => false,
        },
        .scm => |s| switch (t) {
            .scm => |a| matchStar(s, a),
            else => false,
        },
        .ui => |s| switch (t) {
            .ui => |a| matchStar(s, a),
            else => false,
        },
        .task => |s| switch (t) {
            .task => |a| matchStar(s, a),
            else => false,
        },
    };
}

/// A compiled, immutable rule set: rules bucketed by (kind, exact tool)
/// plus a wildcard-tool bucket, each in precedence order (layer, then
/// source index). Safe to share across threads.
pub const RuleSet = struct {
    rules: []const Rule,
    exact: [3]std.StringHashMapUnmanaged([]const u32),
    wildcard: [3][]const u32,

    /// An empty set.
    pub const empty: RuleSet = .{ .rules = &.{}, .exact = .{ .empty, .empty, .empty }, .wildcard = .{ &.{}, &.{}, &.{} } };

    /// Compiles `rules` (copied; rule strings stay borrowed).
    pub fn compile(gpa: Allocator, rules_in: []const Rule) !RuleSet {
        const rules = try gpa.dupe(Rule, rules_in);
        errdefer gpa.free(rules);
        std.mem.sort(Rule, rules, {}, struct {
            fn lt(_: void, a: Rule, b: Rule) bool {
                if (a.source.layer != b.source.layer) return @intFromEnum(a.source.layer) < @intFromEnum(b.source.layer);
                return a.source.index < b.source.index;
            }
        }.lt);
        var rs: RuleSet = .{ .rules = rules, .exact = .{ .empty, .empty, .empty }, .wildcard = .{ &.{}, &.{}, &.{} } };
        errdefer rs.deinit(gpa);
        var lists: [3]std.StringArrayHashMapUnmanaged(std.ArrayList(u32)) = .{ .empty, .empty, .empty };
        defer for (&lists) |*l| {
            for (l.values()) |*v| v.deinit(gpa);
            l.deinit(gpa);
        };
        var wild: [3]std.ArrayList(u32) = .{ .empty, .empty, .empty };
        defer for (&wild) |*w| w.deinit(gpa);
        for (rules, 0..) |r, i| {
            const k = @intFromEnum(r.kind);
            if (r.tool.isWildcard()) {
                try wild[k].append(gpa, @intCast(i));
            } else {
                const gop = try lists[k].getOrPut(gpa, r.tool.text);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(gpa, @intCast(i));
            }
        }
        for (0..3) |k| {
            rs.wildcard[k] = try wild[k].toOwnedSlice(gpa);
            var it = lists[k].iterator();
            while (it.next()) |e| {
                const ids = try e.value_ptr.toOwnedSlice(gpa);
                rs.exact[k].put(gpa, e.key_ptr.*, ids) catch |err| {
                    gpa.free(ids);
                    return err;
                };
            }
        }
        return rs;
    }

    /// Frees the buckets and the rule array.
    pub fn deinit(rs: *RuleSet, gpa: Allocator) void {
        for (&rs.exact) |*m| {
            var it = m.valueIterator();
            while (it.next()) |v| gpa.free(v.*);
            m.deinit(gpa);
        }
        for (rs.wildcard) |w| gpa.free(w);
        gpa.free(rs.rules);
        rs.* = .empty;
    }

    /// The highest-precedence rule of `kind` that matches `tool` and `t`.
    /// Allocates nothing.
    pub fn firstMatch(rs: *const RuleSet, kind: RuleKind, tool: []const u8, t: Target) ?*const Rule {
        const k = @intFromEnum(kind);
        const exact: []const u32 = rs.exact[k].get(tool) orelse &.{};
        const wild = rs.wildcard[k];
        var a: usize = 0;
        var b: usize = 0;
        // Merge the two ordered lists so precedence is preserved.
        while (a < exact.len or b < wild.len) {
            const take_exact = b >= wild.len or (a < exact.len and exact[a] < wild[b]);
            const idx = if (take_exact) exact[a] else wild[b];
            if (take_exact) a += 1 else b += 1;
            const r = &rs.rules[idx];
            if (!take_exact and !r.tool.matches(tool)) continue;
            if (specMatches(r, t)) return r;
        }
        return null;
    }
};

const test_ctx: Context = .{ .anchors = .{ .workspace_root = "/w", .settings_root = "/w/.zigguro", .home = "/home/u", .windows = false } };

const Golden = struct { text: []const u8, tool: []const u8 = "", spec: ?std.meta.Tag(Specifier) = null, err: ?ParseError = null };

test "rules: parse table" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]Golden{
        .{ .text = "read_file", .tool = "read_file", .spec = .none },
        .{ .text = "run_command", .tool = "run_command", .spec = .none },
        .{ .text = "run_command()", .tool = "run_command", .spec = .none },
        .{ .text = "run_command(*)", .tool = "run_command", .spec = .none },
        .{ .text = "run_command(npm test *)", .tool = "run_command", .spec = .command },
        .{ .text = "run_command(echo $(date))", .tool = "run_command", .spec = .command },
        .{ .text = "Bash(git status)", .tool = "run_command", .spec = .command },
        .{ .text = "read_file(./.env*)", .tool = "read_file", .spec = .path },
        .{ .text = "Read(~/.ssh/**)", .tool = "read_file", .spec = .path },
        .{ .text = "edit_file(//etc/**)", .tool = "edit_file", .spec = .path },
        .{ .text = "Edit(/local.zon)", .tool = "edit_file", .spec = .path },
        .{ .text = "write_file(src/**)", .tool = "write_file", .spec = .path },
        .{ .text = "multi_edit(*.zig)", .tool = "multi_edit", .spec = .path },
        .{ .text = "list_dir(build/)", .tool = "list_dir", .spec = .path },
        .{ .text = "glob(./docs/**)", .tool = "glob", .spec = .path },
        .{ .text = "grep(~/)", .tool = "grep", .spec = .path },
        .{ .text = "web_fetch(domain:*.example.com)", .tool = "web_fetch", .spec = .domain },
        .{ .text = "WebFetch(domain:github.com)", .tool = "web_fetch", .spec = .domain },
        .{ .text = "web_search(domain:*)", .tool = "web_search", .spec = .domain },
        .{ .text = "web_fetch(domain:[::1]:8080)", .tool = "web_fetch", .spec = .domain },
        .{ .text = "mcp__github__*", .tool = "mcp__github__*", .spec = .none },
        .{ .text = "mcp__github__create_issue", .tool = "mcp__github__create_issue", .spec = .none },
        .{ .text = "*", .tool = "*", .spec = .none },
        .{ .text = "scm(push)", .tool = "scm", .spec = .scm },
        .{ .text = "scm(rewrite_immutable)", .tool = "scm", .spec = .scm },
        .{ .text = "ui(open_uri:vscode:*)", .tool = "ui", .spec = .ui },
        .{ .text = "ui(clipboard_read)", .tool = "ui", .spec = .ui },
        .{ .text = "task(explore)", .tool = "task", .spec = .task },
        .{ .text = "  read_file  ", .tool = "read_file", .spec = .none },
        // Unusable specifiers fall back to raw.
        .{ .text = "web_fetch(github.com)", .tool = "web_fetch", .spec = .raw },
        .{ .text = "read_file(!keep)", .tool = "read_file", .spec = .raw },
        .{ .text = "web_fetch(domain:a b)", .tool = "web_fetch", .spec = .raw },
        .{ .text = "mcp__fs__read(x)", .tool = "mcp__fs__read", .spec = .raw },
        .{ .text = "my_tool(x)", .tool = "my_tool", .spec = .raw },
        // Errors.
        .{ .text = "", .err = error.EmptyRule },
        .{ .text = "   ", .err = error.EmptyRule },
        .{ .text = "(x)", .err = error.BadToolName },
        .{ .text = "run command", .err = error.BadToolName },
        .{ .text = "run_command(ls", .err = error.UnbalancedParen },
        .{ .text = "run_command(ls))", .err = error.UnbalancedParen },
        .{ .text = "run_command((ls)", .err = error.UnbalancedParen },
        .{ .text = "a*b", .err = error.BadToolName },
        .{ .text = "mcp__*(x)", .err = error.UnsupportedSpecifier },
    };
    for (cases) |c| {
        const got = parse(a, c.text, .deny, .{ .layer = .user, .file = "settings.zon", .index = 0 }, test_ctx);
        if (c.err) |e| {
            try std.testing.expectError(e, got);
            continue;
        }
        const r = got catch |e| {
            std.debug.print("case {s}: {t}\n", .{ c.text, e });
            return e;
        };
        try std.testing.expectEqualStrings(c.tool, r.tool.text);
        try std.testing.expectEqual(c.spec.?, std.meta.activeTag(r.spec));
    }
}

test "rules: error messages carry rule text and source" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = try parse(arena.allocator(), "run_command(rm *)", .deny, .{ .layer = .user, .file = "settings.zon", .index = 3 }, test_ctx);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("deny run_command(rm *) (user settings.zon:3)", try std.fmt.bufPrint(&buf, "{f}", .{&r}));
}

test "command: trailing space-star matches bare prefix" {
    const p: CommandPattern = .{ .text = "npm test *" };
    try std.testing.expect(p.matches("npm test"));
    try std.testing.expect(p.matches("npm test --watch"));
    try std.testing.expect(!p.matches("npm testing"));
    const q: CommandPattern = .{ .text = "git * --force" };
    try std.testing.expect(q.matches("git push origin --force"));
    try std.testing.expect(!q.matches("git push"));
    try std.testing.expect((CommandPattern{ .text = "ls" }).isExact());
}

test "INV-03 allow with unusable specifier approves nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var warning: ?[]const u8 = null;
    const allow = try parseWarn(a, "web_fetch(github.com)", .allow, .{ .layer = .user }, test_ctx, &warning);
    try std.testing.expect(warning != null);
    const deny = try parse(a, "web_fetch(github.com)", .deny, .{ .layer = .user }, test_ctx);
    const t: Target = .{ .host = .{ .host = "github.com" } };
    try std.testing.expect(!specMatches(&allow, t));
    try std.testing.expect(specMatches(&deny, t));
}

test "rules: rule set precedence and wildcard merge" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gpa = std.testing.allocator;
    const list = [_]Rule{
        try parse(a, "run_command(git *)", .allow, .{ .layer = .user, .index = 0 }, test_ctx),
        try parse(a, "*", .allow, .{ .layer = .workspace, .index = 0 }, test_ctx),
        try parse(a, "mcp__gh__*", .deny, .{ .layer = .user, .index = 1 }, test_ctx),
        try parse(a, "read_file(.env*)", .deny, .{ .layer = .managed, .index = 0 }, test_ctx),
    };
    var rs: RuleSet = try .compile(gpa, &list);
    defer rs.deinit(gpa);
    const r = rs.firstMatch(.allow, "run_command", .{ .command = .{ .text = "git status" } }).?;
    try std.testing.expectEqualStrings("*", r.text); // workspace layer beats user
    try std.testing.expectEqualStrings("mcp__gh__*", rs.firstMatch(.deny, "mcp__gh__x", .none).?.text);
    try std.testing.expect(rs.firstMatch(.deny, "mcp__fs__x", .none) == null);
    try std.testing.expect(rs.firstMatch(.deny, "read_file", .{ .path = .{ .abs = "/w/a/.env.prod" } }) != null);
    try std.testing.expect(rs.firstMatch(.deny, "read_file", .{ .path = .{ .abs = "/w/a/env" } }) == null);
}

test "rules: exec wrappers need an exact allow" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try parse(a, "run_command(find *)", .allow, .{ .layer = .user }, test_ctx);
    const exact = try parse(a, "run_command(find . -delete)", .allow, .{ .layer = .user }, test_ctx);
    const deny = try parse(a, "run_command(find *)", .deny, .{ .layer = .user }, test_ctx);
    const t: Target = .{ .command = .{ .text = "find . -delete", .exec_wrapper = true } };
    try std.testing.expect(!specMatches(&prefix, t));
    try std.testing.expect(specMatches(&exact, t));
    try std.testing.expect(specMatches(&deny, t));
}

test "fuzz: rules parse never crashes" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const input = buf[0..smith.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            for ([_]RuleKind{ .allow, .deny }) |k| {
                const r = parse(arena.allocator(), input, k, .{ .layer = .user }, test_ctx) catch continue;
                // Round trip: the stored text re-parses to the same tool.
                const again = try parse(arena.allocator(), r.text, k, .{ .layer = .user }, test_ctx);
                try std.testing.expectEqualStrings(r.tool.text, again.tool.text);
                _ = specMatches(&r, .{ .command = .{ .text = input } });
                _ = specMatches(&r, .{ .path = .{ .abs = "/w/x" } });
            }
        }
    }.f, .{});
}
