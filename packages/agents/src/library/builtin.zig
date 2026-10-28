//! Built-in library entries (E13.F08.S02.T01): the document-mode actions
//! (`doc/<id>`, from `docs.shortcuts`) and the research prompts
//! (`research/*`, the deep-research workflow's prompts) and the bundled
//! workflow templates' prompts (`workflow/*`). A project or user file with
//! the same id overrides one.

const std = @import("std");
const template = @import("template.zig");
const shortcuts = @import("../docs/shortcuts.zig");

pub const Builtin = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    tags: []const []const u8 = &.{},
    variables: []const template.VarDecl = &.{},
    body: []const u8,
};

const effort_choices = [_][]const u8{ "quick", "standard", "deep" };

const research = [_]Builtin{
    .{
        .id = "research/lead",
        .title = "Research lead planner",
        .description = "Decompose a research question into non-overlapping sub-questions",
        .tags = &.{ "research", "planning" },
        .variables = &.{
            .{ .name = "question", .kind = .multiline, .required = true },
            .{ .name = "effort", .kind = .choice, .options = &effort_choices, .default = "standard" },
        },
        .body = @embedFile("../research/prompts/lead.md"),
    },
    .{
        .id = "research/researcher",
        .title = "Researcher",
        .description = "Answer one sub-question from primary sources and return cited findings",
        .tags = &.{ "research", "web" },
        .variables = &.{
            .{ .name = "question", .kind = .multiline, .required = true },
            .{ .name = "subquestion", .kind = .multiline, .required = true },
            .{ .name = "max_tool_calls", .kind = .number },
        },
        .body = @embedFile("../research/prompts/researcher.md"),
    },
    .{
        .id = "research/synthesize",
        .title = "Research synthesis",
        .description = "Write a cited report from researchers' findings",
        .tags = &.{ "research", "writing" },
        .variables = &.{
            .{ .name = "question", .kind = .multiline, .required = true },
            .{ .name = "findings", .kind = .multiline, .required = true },
        },
        .body = @embedFile("../research/prompts/synthesize.md"),
    },
};

fn wfVar(comptime name: []const u8, comptime required: bool) template.VarDecl {
    return .{ .name = name, .kind = .multiline, .required = required };
}

const workflows = [_]Builtin{
    .{
        .id = "workflow/audit-file",
        .title = "Audit one file",
        .description = "Find instances of a problem in one file (audit-files workflow)",
        .tags = &.{ "workflow", "audit" },
        .variables = &.{ wfVar("file", true), wfVar("check", true) },
        .body = @embedFile("../workflow/templates/prompts/audit-file.md"),
    },
    .{
        .id = "workflow/verify-findings",
        .title = "Verify audit findings",
        .description = "Skeptically re-check another auditor's findings (audit-files workflow)",
        .tags = &.{ "workflow", "audit" },
        .variables = &.{ wfVar("findings", false), wfVar("check", true) },
        .body = @embedFile("../workflow/templates/prompts/verify-findings.md"),
    },
    .{
        .id = "workflow/judge-findings",
        .title = "Judge verified findings",
        .description = "Merge two reviewers' verified findings (audit-files workflow)",
        .tags = &.{ "workflow", "audit" },
        .variables = &.{wfVar("candidates", false)},
        .body = @embedFile("../workflow/templates/prompts/judge-findings.md"),
    },
    .{
        .id = "workflow/rank-findings",
        .title = "Rank audit findings",
        .description = "Write the ranked audit report (audit-files workflow)",
        .tags = &.{ "workflow", "audit", "writing" },
        .variables = &.{ wfVar("findings", false), wfVar("check", true) },
        .body = @embedFile("../workflow/templates/prompts/rank-findings.md"),
    },
    .{
        .id = "workflow/migrate-file",
        .title = "Migrate one file",
        .description = "Apply a change to one file and check it (migrate-files workflow)",
        .tags = &.{ "workflow", "refactor" },
        .variables = &.{ wfVar("file", true), wfVar("instructions", true), wfVar("verify_cmd", true) },
        .body = @embedFile("../workflow/templates/prompts/migrate-file.md"),
    },
    .{
        .id = "workflow/review-file",
        .title = "Review one file's changes",
        .description = "Review the diff of one file (review-changes workflow)",
        .tags = &.{ "workflow", "review" },
        .variables = &.{ wfVar("file", true), wfVar("revset", true) },
        .body = @embedFile("../workflow/templates/prompts/review-file.md"),
    },
    .{
        .id = "workflow/review-summary",
        .title = "Summarize review comments",
        .description = "Merge and rank per-file review comments (review-changes workflow)",
        .tags = &.{ "workflow", "review", "writing" },
        .variables = &.{wfVar("comments", false)},
        .body = @embedFile("../workflow/templates/prompts/review-summary.md"),
    },
    .{
        .id = "workflow/fix",
        .title = "Fix until a command passes",
        .description = "One round of fixing a failing command (fix-until-green workflow)",
        .tags = &.{ "workflow", "fix" },
        .variables = &.{ wfVar("cmd", true), wfVar("failure", false) },
        .body = @embedFile("../workflow/templates/prompts/fix.md"),
    },
};

const doc_entries: [shortcuts.default_shortcuts.len]Builtin = blk: {
    var out: [shortcuts.default_shortcuts.len]Builtin = undefined;
    for (shortcuts.default_shortcuts, &out) |s, *o| {
        var vars: []const template.VarDecl = &.{.{ .name = "section_title", .kind = .text }};
        for (s.params) |p| {
            const d: template.VarDecl = switch (p) {
                .slider => |opts| .{ .name = p.name(), .kind = .choice, .options = opts, .default = opts[@min(2, opts.len - 1)] },
                .choice => |opts| .{ .name = p.name(), .kind = .choice, .options = opts, .default = opts[0] },
                .text => |n| .{ .name = n, .kind = .text, .required = true },
            };
            vars = vars ++ &[_]template.VarDecl{d};
        }
        o.* = .{
            .id = "doc/" ++ s.id,
            .title = s.label,
            .description = "Document action: " ++ s.label,
            .tags = &.{ "doc", "writing" },
            .variables = vars,
            .body = s.template,
        };
    }
    break :blk out;
};

const all_entries = doc_entries ++ research ++ workflows;

pub fn entries() []const Builtin {
    return &all_entries;
}

pub fn find(id: []const u8) ?*const Builtin {
    for (&all_entries) |*b| if (std.mem.eql(u8, b.id, id)) return b;
    return null;
}
