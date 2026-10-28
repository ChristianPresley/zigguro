//! The prompt library (E13.F08.S02): reusable prompts, templates with
//! variables, document actions, research prompts and E10 skills in one
//! searchable index. Format: docs/formats/prompts.md.

pub const template = @import("template.zig");
pub const entry = @import("entry.zig");
pub const builtin = @import("builtin.zig");
pub const PromptLibrary = @import("index.zig");
pub const tools = @import("tools.zig");

pub const Entry = entry.Entry;
pub const EntrySource = entry.EntrySource;
pub const VarDecl = template.VarDecl;
pub const Var = template.Var;
pub const RenderCtx = template.RenderCtx;

test {
    _ = @import("template_test.zig");
    _ = @import("index_test.zig");
}
