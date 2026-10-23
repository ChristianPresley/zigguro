//! Document-mode shortcuts (E13.F04.S01.T02): one-click requests on a
//! selection ("Shorten", "Change tone: friendly", ...). Each is a prompt
//! template with `{{selection}}`, `{{section_title}}` and its parameters;
//! the prompt library (F08) can override a template under `doc/<id>`.
//! Expanding one gives the prompt the agent pane sends, scoped to the
//! selection.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const ParamSpec = union(enum) {
    /// Ordered steps, e.g. reading levels.
    slider: []const []const u8,
    choice: []const []const u8,
    /// Free text, with its name.
    text: []const u8,

    pub fn name(p: ParamSpec) []const u8 {
        return switch (p) {
            .slider => "level",
            .choice => "choice",
            .text => |n| n,
        };
    }
};

pub const Shortcut = struct {
    id: []const u8,
    label: []const u8,
    template: []const u8,
    params: []const ParamSpec = &.{},
    /// A default key, if any.
    key: ?[]const u8 = null,
    /// Works without a selection (on the section, or at the cursor).
    needs_selection: bool = true,
};

const reading_levels = [_][]const u8{ "elementary", "middle school", "high school", "college", "graduate" };
const tones = [_][]const u8{ "formal", "friendly", "concise", "persuasive" };

pub const default_shortcuts = [_]Shortcut{
    .{ .id = "suggest_edits", .label = "Suggest edits", .template = "Suggest specific edits to improve this passage from \"{{section_title}}\". Propose each change with doc_propose_edit; do not rewrite text that is fine.\n\n{{selection}}" },
    .{ .id = "shorten", .label = "Shorten", .template = "Make this passage from \"{{section_title}}\" about half as long, keeping its meaning and voice. Propose the change with doc_propose_edit.\n\n{{selection}}" },
    .{ .id = "lengthen", .label = "Lengthen", .template = "Expand this passage from \"{{section_title}}\" with more detail and examples, in the same voice. Propose the change with doc_propose_edit.\n\n{{selection}}" },
    .{ .id = "reading_level", .label = "Reading level", .template = "Rewrite this passage from \"{{section_title}}\" for a {{level}} reading level. Propose the change with doc_propose_edit.\n\n{{selection}}", .params = &.{.{ .slider = &reading_levels }} },
    .{ .id = "polish", .label = "Polish", .template = "Polish this passage from \"{{section_title}}\": smoother sentences and word choice, same meaning. Propose the change with doc_propose_edit.\n\n{{selection}}" },
    .{ .id = "fix_grammar", .label = "Fix grammar", .template = "Fix spelling, grammar and punctuation in this passage from \"{{section_title}}\", changing nothing else. Propose each fix with doc_propose_edit.\n\n{{selection}}" },
    .{ .id = "change_tone", .label = "Change tone", .template = "Rewrite this passage from \"{{section_title}}\" in a {{choice}} tone. Propose the change with doc_propose_edit.\n\n{{selection}}", .params = &.{.{ .choice = &tones }} },
    .{ .id = "translate", .label = "Translate", .template = "Translate this passage from \"{{section_title}}\" into {{language}}. Propose the change with doc_propose_edit.\n\n{{selection}}", .params = &.{.{ .text = "language" }} },
    .{ .id = "summarize_above", .label = "Summarize above", .template = "Write a short summary of everything above this point in \"{{section_title}}\" and insert it with doc_insert at the cursor.\n\n{{selection}}", .needs_selection = false },
    .{ .id = "continue_writing", .label = "Continue writing", .template = "Continue writing \"{{section_title}}\" from where it ends, in the same voice, and insert it with doc_insert.\n\n{{selection}}", .needs_selection = false },
};

pub fn find(id: []const u8) ?*const Shortcut {
    for (&default_shortcuts) |*s| if (std.mem.eql(u8, s.id, id)) return s;
    return null;
}

pub const Var = struct { name: []const u8, value: []const u8 };

/// Overrides from the prompt library: the template for `doc/<id>`, if the
/// user has one.
pub const TemplateLookup = struct {
    ctx: ?*anyopaque = null,
    get: *const fn (ctx: ?*anyopaque, key: []const u8) ?[]const u8,
};

/// `template` with each `{{name}}` replaced by its value (unknown names
/// become empty; `{{{{` is a literal `{{`).
pub fn expand(a: Allocator, template: []const u8, vars: []const Var) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{{{{")) {
            try out.appendSlice(a, "{{");
            i += 4;
            continue;
        }
        if (std.mem.startsWith(u8, template[i..], "{{")) {
            if (std.mem.indexOfPos(u8, template, i + 2, "}}")) |close| {
                const name = std.mem.trim(u8, template[i + 2 .. close], " ");
                for (vars) |v| if (std.mem.eql(u8, v.name, name)) {
                    try out.appendSlice(a, v.value);
                    break;
                };
                i = close + 2;
                continue;
            }
        }
        try out.append(a, template[i]);
        i += 1;
    }
    return out.items;
}

/// The prompt for shortcut `s` on `selection` in the section titled
/// `section_title`, with parameter values `params` (in `s.params` order;
/// missing ones take the first choice). The library's override wins.
pub fn prompt(a: Allocator, s: *const Shortcut, selection: []const u8, section_title: []const u8, params: []const []const u8, lookup: ?TemplateLookup) Allocator.Error![]const u8 {
    var template = s.template;
    if (lookup) |l| {
        const key = try std.fmt.allocPrint(a, "doc/{s}", .{s.id});
        if (l.get(l.ctx, key)) |t| template = t;
    }
    var vars: std.ArrayList(Var) = .empty;
    try vars.append(a, .{ .name = "selection", .value = selection });
    try vars.append(a, .{ .name = "section_title", .value = section_title });
    for (s.params, 0..) |p, i| {
        const given = if (i < params.len) params[i] else "";
        const value = if (given.len > 0) given else switch (p) {
            .slider => |o| o[@min(2, o.len - 1)],
            .choice => |o| o[0],
            .text => "",
        };
        try vars.append(a, .{ .name = p.name(), .value = value });
    }
    return expand(a, template, vars.items);
}
