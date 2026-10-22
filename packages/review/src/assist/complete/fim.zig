//! FIM prompt templates (E12.F07.S01.T02): how a fill-in-the-middle
//! request becomes the raw prompt of a completion-only model. Templates
//! are data (`templates.zon`, from each model card); this file only knows
//! the two orders and the repository-level layout.
//!
//! - PSM: `prefix_tok prefix suffix_tok suffix middle_tok`.
//! - SPM (Bavarian et al. 2022): `suffix_tok suffix prefix_tok prefix
//!   middle_tok`.
//! - Repository level (templates with `repo_tok` and `file_sep_tok`, as in
//!   the Qwen2.5-Coder report and the llama.cpp server): `repo_tok name`,
//!   then `file_sep_tok path\ntext` per neighbour snippet, then
//!   `file_sep_tok path\n` and the FIM triplet. Other templates get the
//!   triplet alone.

const std = @import("std");
const context = @import("context.zig");

const Allocator = std.mem.Allocator;
const CompletionRequest = context.CompletionRequest;

pub const FimTemplate = struct {
    name: []const u8,
    order: enum { psm, spm },
    prefix_tok: []const u8,
    suffix_tok: []const u8,
    middle_tok: []const u8,
    file_sep_tok: ?[]const u8 = null,
    repo_tok: ?[]const u8 = null,
    /// Tokens that end the middle.
    eot: []const []const u8,

    pub fn repoLevel(t: *const FimTemplate) bool {
        return t.file_sep_tok != null and t.repo_tok != null;
    }
};

/// The built-in templates.
pub const catalog: []const FimTemplate = @import("templates.zon");

/// The template called `name`, if any.
pub fn find(templates: []const FimTemplate, name: []const u8) ?*const FimTemplate {
    for (templates) |*t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

/// The prompt for `req` (in `arena`). `repo_name` empty: no
/// repository-level layout.
pub fn render(arena: Allocator, t: *const FimTemplate, req: *const CompletionRequest, repo_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (t.repoLevel() and repo_name.len > 0) {
        const sep = t.file_sep_tok.?;
        try out.print(arena, "{s}{s}\n", .{ t.repo_tok.?, repo_name });
        for (req.extras) |s| {
            try out.print(arena, "{s}{s}\n{s}", .{ sep, s.path, s.text });
            if (!std.mem.endsWith(u8, s.text, "\n")) try out.append(arena, '\n');
        }
        try out.print(arena, "{s}{s}\n", .{ sep, req.path });
    }
    switch (t.order) {
        .psm => try out.print(arena, "{s}{s}{s}{s}{s}", .{ t.prefix_tok, req.prefix, t.suffix_tok, req.suffix, t.middle_tok }),
        .spm => try out.print(arena, "{s}{s}{s}{s}{s}", .{ t.suffix_tok, req.suffix, t.prefix_tok, req.prefix, t.middle_tok }),
    }
    return out.items;
}

/// The request's stops plus the template's end tokens.
pub fn stops(arena: Allocator, t: *const FimTemplate, req: *const CompletionRequest) ![]const []const u8 {
    return std.mem.concat(arena, []const u8, &.{ req.stop, t.eot });
}
