//! The note template renderer (E08.F07.S02.T01), after Obsidian's core
//! Templates plugin: `{{title}}`, `{{date}}` (YYYY-MM-DD), `{{time}}`
//! (HH:mm), `{{date:FMT}}`, `{{time:FMT}}`, `{{cursor}}` (the first one
//! places the cursor, later ones vanish), `{{selection}}`,
//! `{{clipboard}}`, and `{{ai: instruction}}`, which becomes a
//! `> [!ai] Pending: instruction` placeholder for the AI fill. `\{{`
//! writes a literal `{{`. Unknown variables stay as written.

const std = @import("std");
const datefmt = @import("datefmt.zig");

const Allocator = std.mem.Allocator;

pub const TemplateVars = struct {
    title: []const u8,
    now: datefmt.DateTime,
    selection: ?[]const u8 = null,
    clipboard: ?[]const u8 = null,
};

pub const AiSection = struct {
    /// The placeholder's bytes in `Rendered.text`.
    placeholder_range: [2]u32,
    instruction: []const u8,
};

pub const Rendered = struct {
    text: []u8,
    cursor: ?u32,
    /// Instructions point into the template.
    ai_sections: []const AiSection,

    pub fn deinit(r: *Rendered, gpa: Allocator) void {
        gpa.free(r.text);
        gpa.free(r.ai_sections);
    }
};

pub fn renderTemplate(gpa: Allocator, tpl: []const u8, vars: TemplateVars) !Rendered {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var ai: std.ArrayList(AiSection) = .empty;
    errdefer ai.deinit(gpa);
    var cursor: ?u32 = null;
    var cursor_seen = false;
    var i: usize = 0;
    while (i < tpl.len) {
        if (tpl[i] == '\\' and std.mem.startsWith(u8, tpl[i + 1 ..], "{{")) {
            try out.appendSlice(gpa, "{{");
            i += 3;
            continue;
        }
        if (!std.mem.startsWith(u8, tpl[i..], "{{")) {
            try out.append(gpa, tpl[i]);
            i += 1;
            continue;
        }
        const close = std.mem.indexOfPos(u8, tpl, i + 2, "}}") orelse {
            try out.appendSlice(gpa, tpl[i..]);
            break;
        };
        const raw = tpl[i .. close + 2];
        const inner = std.mem.trim(u8, tpl[i + 2 .. close], " \t");
        i = close + 2;
        const colon = std.mem.indexOfScalar(u8, inner, ':');
        const name = std.mem.trim(u8, inner[0 .. colon orelse inner.len], " \t");
        const arg: ?[]const u8 = if (colon) |c| std.mem.trim(u8, inner[c + 1 ..], " \t") else null;
        if (std.ascii.eqlIgnoreCase(name, "title") and arg == null) {
            try out.appendSlice(gpa, vars.title);
        } else if (std.ascii.eqlIgnoreCase(name, "date") or std.ascii.eqlIgnoreCase(name, "time")) {
            const default: []const u8 = if (std.ascii.eqlIgnoreCase(name, "date")) "YYYY-MM-DD" else "HH:mm";
            const fmt = if (arg) |a| (if (a.len > 0) a else default) else default;
            const text = try datefmt.formatAlloc(gpa, fmt, vars.now);
            defer gpa.free(text);
            try out.appendSlice(gpa, text);
        } else if (std.ascii.eqlIgnoreCase(name, "cursor") and arg == null) {
            if (!cursor_seen) cursor = @intCast(out.items.len);
            cursor_seen = true;
        } else if (std.ascii.eqlIgnoreCase(name, "selection") and arg == null) {
            try out.appendSlice(gpa, vars.selection orelse "");
        } else if (std.ascii.eqlIgnoreCase(name, "clipboard") and arg == null) {
            try out.appendSlice(gpa, vars.clipboard orelse "");
        } else if (std.ascii.eqlIgnoreCase(name, "ai") and arg != null and arg.?.len > 0) {
            const start: u32 = @intCast(out.items.len);
            try out.appendSlice(gpa, "> [!ai] Pending: ");
            try out.appendSlice(gpa, arg.?);
            try ai.append(gpa, .{ .placeholder_range = .{ start, @intCast(out.items.len) }, .instruction = arg.? });
        } else {
            try out.appendSlice(gpa, raw);
        }
    }
    const ai_owned = try ai.toOwnedSlice(gpa);
    errdefer gpa.free(ai_owned);
    return .{ .text = try out.toOwnedSlice(gpa), .cursor = cursor, .ai_sections = ai_owned };
}

const testing = std.testing;

const now: datefmt.DateTime = .{ .date = .{ .y = 2026, .m = 10, .d = 21 }, .h = 9, .min = 5, .s = 7, .utc_offset_s = 7200 };

test "templates: variables, cursor, escapes, unknown left verbatim" {
    const tpl = "# {{title}}\nCreated {{date}} {{time}} ({{ date : dddd, MMMM Do }}, {{time:h A}})\n{{cursor}}body {{cursor}}\nsel={{selection}} clip={{clipboard}}\n\\{{title}} {{unknown}} {{title:x}} {{ open";
    var r = try renderTemplate(testing.allocator, tpl, .{ .title = "Plan", .now = now, .selection = "SEL" });
    defer r.deinit(testing.allocator);
    const want = "# Plan\nCreated 2026-10-21 09:05 (Wednesday, October 21st, 9 AM)\nbody \nsel=SEL clip=\n{{title}} {{unknown}} {{title:x}} {{ open";
    try testing.expectEqualStrings(want, r.text);
    try testing.expectEqual(@as(?u32, @intCast(std.mem.indexOf(u8, want, "body").?)), r.cursor);
    try testing.expectEqual(@as(usize, 0), r.ai_sections.len);
}

test "templates: ai sections produce placeholders and ranges" {
    const tpl = "# {{title}}\n## Summary\n{{ai: summarize yesterday's note}}\n## Ideas\n{{ai:list three ideas}}\n{{ai:}}\n";
    var r = try renderTemplate(testing.allocator, tpl, .{ .title = "Day", .now = now });
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.ai_sections.len);
    const s0 = r.ai_sections[0];
    try testing.expectEqualStrings("summarize yesterday's note", s0.instruction);
    try testing.expectEqualStrings("> [!ai] Pending: summarize yesterday's note", r.text[s0.placeholder_range[0]..s0.placeholder_range[1]]);
    const s1 = r.ai_sections[1];
    try testing.expectEqualStrings("> [!ai] Pending: list three ideas", r.text[s1.placeholder_range[0]..s1.placeholder_range[1]]);
    try testing.expect(std.mem.endsWith(u8, r.text, "{{ai:}}\n"));
}
