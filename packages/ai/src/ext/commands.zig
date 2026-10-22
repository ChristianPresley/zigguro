//! Slash commands (E10.F09.S04.T01): parsing `/name args`, resolving the
//! name to a built-in command or a user-invocable skill (built-ins win,
//! as in Claude Code), `/help` text, and registering both with E15's
//! command palette. zg_ai cannot import zg_config (same layer), so the
//! palette is a `PaletteSink` the app adapts to `CommandRegistry.register`.

const std = @import("std");
const skills = @import("skills.zig");
const builtin_commands = @import("builtin_commands.zig");

const Allocator = std.mem.Allocator;

pub const BuiltinCommand = builtin_commands.BuiltinCommand;

pub const Invocation = struct {
    name: []const u8,
    /// Everything after the name, trimmed.
    args: []const u8,
};

/// `/name args`; null when `line` is not a command (a path such as
/// `/usr/bin` is not one either: names have no `/`).
pub fn parse(line: []const u8) ?Invocation {
    const t = std.mem.trim(u8, line, " \t\r\n");
    if (t.len < 2 or t[0] != '/') return null;
    const end = std.mem.indexOfAny(u8, t, " \t\n") orelse t.len;
    const name = t[1..end];
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ':' or c == '.')) return null;
    return .{ .name = name, .args = std.mem.trim(u8, t[end..], " \t\r\n") };
}

pub const Resolved = union(enum) {
    builtin: *const BuiltinCommand,
    skill: *const skills.Skill,
    unknown,
};

pub const CommandRegistry = struct {
    index: ?*skills.SkillIndex = null,
    builtins: []const BuiltinCommand = &builtin_commands.all,

    pub fn resolve(r: CommandRegistry, name: []const u8) Resolved {
        for (r.builtins) |*b| if (std.mem.eql(u8, b.name, name)) return .{ .builtin = b };
        if (r.index) |ix| if (ix.find(name)) |s| if (s.user_invocable) return .{ .skill = s };
        return .unknown;
    }

    /// The `/help` text: built-ins, then skills and commands.
    pub fn help(r: CommandRegistry, arena: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "Commands:\n");
        for (r.builtins) |b| try line(arena, &out, b.name, b.args_hint, b.help);
        if (r.index) |ix| {
            var first = true;
            for (try ix.list(arena)) |s| {
                if (!s.user_invocable) continue;
                if (first) try out.appendSlice(arena, "\nSkills and commands:\n");
                first = false;
                try line(arena, &out, s.name, s.argument_hint, s.description);
            }
        }
        return out.items;
    }

    fn line(arena: Allocator, out: *std.ArrayList(u8), name: []const u8, hint: ?[]const u8, text: []const u8) Allocator.Error!void {
        try out.print(arena, "  /{s}", .{name});
        if (hint) |h| try out.print(arena, " {s}", .{h});
        try out.print(arena, "  {s}\n", .{text});
    }
};

/// One palette command.
pub const PaletteEntry = struct {
    /// `ai.<name>` for built-ins, `ai.skill.<name>` for skills.
    id: []const u8,
    title: []const u8,
    description: []const u8,
    /// `/name args` hint for the palette's argument box.
    args_hint: ?[]const u8 = null,
};

/// E15's `CommandRegistry`, adapted by the app.
pub const PaletteSink = struct {
    ctx: *anyopaque,
    add: *const fn (ctx: *anyopaque, entry: PaletteEntry) anyerror!void,
};

/// Registers every built-in and user-invocable skill. Strings live in
/// `arena`, which must outlive the registrations.
pub fn registerWithPalette(arena: Allocator, sink: PaletteSink, index: ?*skills.SkillIndex, builtins: []const BuiltinCommand) !void {
    for (builtins) |b| try sink.add(sink.ctx, .{
        .id = try std.fmt.allocPrint(arena, "ai.{s}", .{b.name}),
        .title = try std.fmt.allocPrint(arena, "AI: /{s}", .{b.name}),
        .description = b.help,
        .args_hint = b.args_hint,
    });
    const ix = index orelse return;
    for (try ix.list(arena)) |s| {
        if (!s.user_invocable) continue;
        try sink.add(sink.ctx, .{
            .id = try std.fmt.allocPrint(arena, "ai.skill.{s}", .{s.name}),
            .title = try std.fmt.allocPrint(arena, "AI: /{s}", .{s.name}),
            .description = s.description,
            .args_hint = s.argument_hint,
        });
    }
}

test parse {
    const t = std.testing;
    const inv = parse("  /deploy staging --fast ").?;
    try t.expectEqualStrings("deploy", inv.name);
    try t.expectEqualStrings("staging --fast", inv.args);
    try t.expectEqualStrings("", parse("/help").?.args);
    try t.expect(parse("/usr/bin/ls") == null);
    try t.expect(parse("hello /x") == null);
    try t.expect(parse("/") == null);
}
