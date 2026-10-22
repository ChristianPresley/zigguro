//! Edit-policy rules (E12.F05.S01.T01): the `review` settings section as
//! written in ZON, and its compiled form.
//!
//! ```zon
//! .{
//!     .rules = .{
//!         .{ .paths = .{"docs/**/*.md"}, .agents = .{"docs-writer"}, .max_changed_lines = 200, .action = .auto_accept },
//!         .{ .paths = .{ "**/*.lock", "zig-pkg/**" }, .action = .review_required },
//!         .{ .origins = .{.lsp}, .tools = .{"format"}, .action = .auto_accept },
//!     },
//!     .protected = .{ "secrets/**" },
//! }
//! ```
//!
//! Paths are E08 globs (`zg_ignore.GlobSet`) on workspace-relative paths.
//! `tools` and `agents` are names or globs. Empty lists match anything.
//! A rule whose globs do not compile is reported and ignored, so an
//! invalid `auto_accept` never applies.

const std = @import("std");
const zg_ignore = @import("zg_ignore");
const model = @import("../model/root.zig");

const Allocator = std.mem.Allocator;
const GlobSet = zg_ignore.GlobSet;

pub const RuleAction = enum {
    auto_accept,
    review,
    /// Wins over every `auto_accept` and `review` rule, wherever it is.
    review_required,
};

pub const OriginKind = std.meta.Tag(model.Origin);

pub const Op = enum { create, modify, delete, rename, mode };

/// One rule as written in the settings.
pub const RuleConfig = struct {
    paths: []const []const u8 = &.{"**"},
    tools: []const []const u8 = &.{},
    agents: []const []const u8 = &.{},
    origins: []const OriginKind = &.{},
    /// Empty: every operation.
    ops: []const Op = &.{},
    /// Lines added plus removed; a delete counts every line of the file.
    max_changed_lines: ?u32 = null,
    action: RuleAction,
};

/// The `review` settings section.
pub const Settings = struct {
    rules: []const RuleConfig = &.{},
    /// Added to the default protected paths (`protected.zig`).
    protected: []const []const u8 = &.{},
    saveOnAccept: bool = true,
};

pub const Diagnostic = struct {
    /// The rule, or null for the section itself or the protected list.
    rule: ?u32,
    message: []const u8,
};

/// Parses a `review` section (ZON) into `arena`. A malformed section is
/// one diagnostic and the default settings (review everything).
pub fn parse(arena: Allocator, src: [:0]const u8, diags: *std.ArrayList(Diagnostic)) Allocator.Error!Settings {
    var zd: std.zon.parse.Diagnostics = .{};
    defer zd.deinit(arena);
    return std.zon.parse.fromSliceAlloc(Settings, arena, src, &zd, .{ .ignore_unknown_fields = true, .free_on_error = false }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            const msg = std.fmt.allocPrint(arena, "review settings: {f}", .{zd}) catch "review settings: invalid ZON";
            try diags.append(arena, .{ .rule = null, .message = msg });
            return .{};
        },
    };
}

pub const Rule = struct {
    action: RuleAction,
    paths: GlobSet,
    tools: ?GlobSet,
    agents: ?GlobSet,
    origins: []const OriginKind,
    ops: []const Op,
    max_changed_lines: ?u32,
    /// Its index in the settings, for verdicts and `explain`.
    index: u32,
};

/// What a rule is matched against: one file of a change.
pub const Subject = struct {
    path: []const u8,
    /// The old path of a rename: both must match.
    from: ?[]const u8 = null,
    op: Op,
    origin: OriginKind,
    tool: ?[]const u8 = null,
    agent: ?[]const u8 = null,
    /// Null when unknown.
    changed_lines: ?u32,
};

/// Compiles `cfg`; null (and a diagnostic) when a glob is invalid.
pub fn compile(gpa: Allocator, cfg: RuleConfig, index: u32, diag_arena: Allocator, diags: *std.ArrayList(Diagnostic)) Allocator.Error!?Rule {
    var paths = compileList(gpa, cfg.paths) catch |e| return fail(e, index, "paths", diag_arena, diags);
    var tools: ?GlobSet = null;
    if (cfg.tools.len > 0) tools = compileList(gpa, cfg.tools) catch |e| {
        paths.deinit();
        return fail(e, index, "tools", diag_arena, diags);
    };
    var agents: ?GlobSet = null;
    if (cfg.agents.len > 0) agents = compileList(gpa, cfg.agents) catch |e| {
        paths.deinit();
        if (tools) |*t| t.deinit();
        return fail(e, index, "agents", diag_arena, diags);
    };
    return .{
        .action = cfg.action,
        .paths = paths,
        .tools = tools,
        .agents = agents,
        .origins = cfg.origins,
        .ops = cfg.ops,
        .max_changed_lines = cfg.max_changed_lines,
        .index = index,
    };
}

fn fail(e: anyerror, index: u32, what: []const u8, arena: Allocator, diags: *std.ArrayList(Diagnostic)) Allocator.Error!?Rule {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    const msg = try std.fmt.allocPrint(arena, "rule {d}: invalid {s} pattern ({t}); the rule is ignored", .{ index, what, e });
    try diags.append(arena, .{ .rule = index, .message = msg });
    return null;
}

/// A GlobSet of patterns given one by one. Each is compiled alone first,
/// so a comma inside a name cannot split it silently.
pub fn compileList(gpa: Allocator, patterns: []const []const u8) !GlobSet {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (patterns, 0..) |p, i| {
        if (p.len == 0) return error.InvalidPattern;
        var one = try GlobSet.compile(gpa, p, .{});
        one.deinit();
        if (i > 0) try joined.append(gpa, ',');
        try joined.appendSlice(gpa, p);
    }
    return GlobSet.compile(gpa, joined.items, .{});
}

pub fn deinit(r: *Rule) void {
    r.paths.deinit();
    if (r.tools) |*t| t.deinit();
    if (r.agents) |*a| a.deinit();
}

/// Whether `r` applies to `s`. An unknown line count matches a
/// `review_required` rule and no other (fail closed).
pub fn matches(r: *const Rule, s: Subject) bool {
    if (!r.paths.matches(s.path)) return false;
    if (s.from) |f| if (!r.paths.matches(f)) return false;
    if (r.tools) |*t| if (!t.matches(s.tool orelse return false)) return false;
    if (r.agents) |*a| if (!a.matches(s.agent orelse return false)) return false;
    if (r.origins.len > 0 and std.mem.indexOfScalar(OriginKind, r.origins, s.origin) == null) return false;
    if (r.ops.len > 0 and std.mem.indexOfScalar(Op, r.ops, s.op) == null) return false;
    if (r.max_changed_lines) |max| {
        const n = s.changed_lines orelse return r.action == .review_required;
        if (n > max) return false;
    }
    return true;
}

const testing = std.testing;

test "rules: parse, compile and match" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(Diagnostic) = .empty;
    const s = try parse(arena,
        \\.{ .rules = .{
        \\    .{ .paths = .{"docs/**/*.md"}, .agents = .{"docs-*"}, .max_changed_lines = 10, .action = .auto_accept },
        \\    .{ .paths = .{"docs/{a,b"}, .action = .auto_accept },
        \\    .{ .origins = .{.lsp}, .tools = .{"format"}, .ops = .{.modify}, .action = .auto_accept },
        \\}, .protected = .{"secrets/**"}, .unknown = 1 }
    , &diags);
    try testing.expectEqual(@as(usize, 3), s.rules.len);
    try testing.expectEqualStrings("secrets/**", s.protected[0]);

    var r0 = (try compile(testing.allocator, s.rules[0], 0, arena, &diags)).?;
    defer deinit(&r0);
    try testing.expectEqual(@as(?Rule, null), try compile(testing.allocator, s.rules[1], 1, arena, &diags));
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(@as(?u32, 1), diags.items[0].rule);
    var r2 = (try compile(testing.allocator, s.rules[2], 2, arena, &diags)).?;
    defer deinit(&r2);

    const doc: Subject = .{ .path = "docs/guide/a.md", .op = .modify, .origin = .agent, .agent = "docs-writer", .changed_lines = 4 };
    try testing.expect(matches(&r0, doc));
    var s2 = doc;
    s2.changed_lines = 11;
    try testing.expect(!matches(&r0, s2));
    s2.changed_lines = null;
    try testing.expect(!matches(&r0, s2));
    s2 = doc;
    s2.agent = null;
    try testing.expect(!matches(&r0, s2));
    s2 = doc;
    s2.from = "src/a.md";
    s2.op = .rename;
    try testing.expect(!matches(&r0, s2));
    try testing.expect(matches(&r2, .{ .path = "src/x.zig", .op = .modify, .origin = .lsp, .tool = "format", .changed_lines = 99 }));
    try testing.expect(!matches(&r2, .{ .path = "src/x.zig", .op = .delete, .origin = .lsp, .tool = "format", .changed_lines = 99 }));
    try testing.expect(!matches(&r2, .{ .path = "src/x.zig", .op = .modify, .origin = .agent, .tool = "format", .changed_lines = 99 }));

    var bad: std.ArrayList(Diagnostic) = .empty;
    const d = try parse(arena, ".{ .rules = 5 }", &bad);
    try testing.expectEqual(@as(usize, 0), d.rules.len);
    try testing.expectEqual(@as(usize, 1), bad.items.len);
}
