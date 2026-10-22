//! The built-in slash commands (E10.F09.S04.T01). This is the table the
//! front ends share: the IDE runs them through E15 palette commands
//! `ai.<name>`, `zg agent`'s REPL through its own handlers; a front end
//! that has no handler for one says so.

const std = @import("std");

pub const BuiltinCommand = struct {
    name: []const u8,
    help: []const u8,
    /// Shown after the name, as in `/model [id]`.
    args_hint: ?[]const u8 = null,
};

pub const all = [_]BuiltinCommand{
    .{ .name = "clear", .help = "Start a new conversation in this session" },
    .{ .name = "compact", .help = "Summarize the conversation to free context", .args_hint = "[focus]" },
    .{ .name = "context", .help = "Show what fills the context window" },
    .{ .name = "memory", .help = "Show the memory files in use" },
    .{ .name = "model", .help = "Show or switch the model", .args_hint = "[id]" },
    .{ .name = "plan", .help = "Enter plan mode, optionally with a prompt", .args_hint = "[prompt]" },
    .{ .name = "mode", .help = "Switch the permission mode", .args_hint = "<mode>" },
    .{ .name = "branch", .help = "Fork the conversation into a new session", .args_hint = "[name]" },
    .{ .name = "rewind", .help = "Go back to an earlier point in the conversation", .args_hint = "[n]" },
    .{ .name = "resume", .help = "Resume a saved session", .args_hint = "[id|name]" },
    .{ .name = "rename", .help = "Rename this session", .args_hint = "<name>" },
    .{ .name = "cost", .help = "Show tokens and cost so far" },
    .{ .name = "agents", .help = "List the subagents" },
    .{ .name = "skills", .help = "List the skills and commands" },
    .{ .name = "hooks", .help = "List the hooks in effect" },
    .{ .name = "export", .help = "Export the conversation as Markdown", .args_hint = "[file]" },
    .{ .name = "init", .help = "Write an AGENTS.md for this project" },
    .{ .name = "help", .help = "List the commands" },
};

pub fn find(name: []const u8) ?*const BuiltinCommand {
    for (&all) |*c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}
