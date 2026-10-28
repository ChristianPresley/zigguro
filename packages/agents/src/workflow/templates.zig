//! The workflow templates shipped with zigguro (E13.F08.S01.T02):
//! `audit-files`, `migrate-files`, `review-changes` and
//! `fix-until-green`. Their prompts are prompt library entries
//! (`workflow/*`, `library/builtin.zig`), so a project can reword a step
//! by adding `.zigguro/prompts/workflow/<id>.md`; a project workflow with
//! the same name replaces a template.

const std = @import("std");

pub const Template = struct {
    name: []const u8,
    source: [:0]const u8,
};

pub const all = [_]Template{
    .{ .name = "audit-files", .source = @embedFile("templates/audit-files.zon") },
    .{ .name = "migrate-files", .source = @embedFile("templates/migrate-files.zon") },
    .{ .name = "review-changes", .source = @embedFile("templates/review-changes.zon") },
    .{ .name = "fix-until-green", .source = @embedFile("templates/fix-until-green.zon") },
};

pub fn find(name: []const u8) ?*const Template {
    for (&all) |*t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}
