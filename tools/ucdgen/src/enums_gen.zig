//! Writes the enum block of `enums.zig` from PropertyValueAliases.txt.

const std = @import("std");

const Spec = struct { name: []const u8, prop: []const u8, bits: u8, doc: []const u8 };

/// The enums, their PropertyValueAliases property and bit width.
pub const specs = [_]Spec{
    .{ .name = "GeneralCategory", .prop = "gc", .bits = 5, .doc = "General_Category (groups such as L or LC are excluded)" },
    .{ .name = "GraphemeBreak", .prop = "GCB", .bits = 5, .doc = "Grapheme_Cluster_Break" },
    .{ .name = "IndicConjunctBreak", .prop = "InCB", .bits = 2, .doc = "Indic_Conjunct_Break" },
    .{ .name = "WordBreak", .prop = "WB", .bits = 5, .doc = "Word_Break" },
    .{ .name = "LineBreak", .prop = "lb", .bits = 6, .doc = "Line_Break" },
    .{ .name = "BidiClass", .prop = "bc", .bits = 5, .doc = "Bidi_Class" },
    .{ .name = "BracketType", .prop = "bpt", .bits = 2, .doc = "Bidi_Paired_Bracket_Type" },
    .{ .name = "EastAsianWidth", .prop = "ea", .bits = 3, .doc = "East_Asian_Width" },
    .{ .name = "Script", .prop = "sc", .bits = 8, .doc = "Script" },
    .{ .name = "JoiningType", .prop = "jt", .bits = 3, .doc = "Joining_Type" },
    .{ .name = "QuickCheck", .prop = "NFC_QC", .bits = 2, .doc = "NFC_Quick_Check / NFKC_Quick_Check (Yes, No, Maybe)" },
    .{ .name = "IndicSyllabic", .prop = "InSC", .bits = 6, .doc = "Indic_Syllabic_Category" },
    .{ .name = "IndicPositional", .prop = "InPC", .bits = 5, .doc = "Indic_Positional_Category" },
};

const groups = [_][]const u8{ "C", "L", "LC", "M", "N", "P", "S", "Z" };

fn isIdent(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn writeIdent(w: *std.Io.Writer, s: []const u8) !void {
    if (isIdent(s)) try w.writeAll(s) else try w.print("@\"{s}\"", .{s});
}

/// Writes every enum with its alias map.
pub fn write(a: std.mem.Allocator, w: *std.Io.Writer, pva: []const u8) !void {
    for (specs) |spec| {
        var values: std.ArrayList([]const []const u8) = .empty;
        var lines = std.mem.splitScalar(u8, pva, '\n');
        while (lines.next()) |raw| {
            var s = raw;
            if (std.mem.indexOfScalar(u8, s, '#')) |h| s = s[0..h];
            s = std.mem.trim(u8, s, " \t\r");
            if (s.len == 0) continue;
            var fields: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, s, ';');
            while (it.next()) |f| try fields.append(a, std.mem.trim(u8, f, " \t"));
            if (!std.mem.eql(u8, fields.items[0], spec.prop)) continue;
            const vals = fields.items[1..];
            if (std.mem.eql(u8, spec.prop, "gc")) {
                const is_group = for (groups) |g| {
                    if (std.mem.eql(u8, vals[0], g)) break true;
                } else false;
                if (is_group) continue;
            }
            try values.append(a, vals);
        }
        if (values.items.len > (@as(usize, 1) << @intCast(spec.bits))) return error.EnumTooWide;
        try w.print("/// {s}, by short alias. Order follows PropertyValueAliases.txt.\npub const {s} = enum(u{d}) {{\n", .{ spec.doc, spec.name, spec.bits });
        for (values.items) |v| {
            try w.writeAll("    ");
            try writeIdent(w, v[0]);
            try w.writeAll(",\n");
        }
        try w.print("\n    /// Every alias in PropertyValueAliases.txt (short, long and extra).\n    pub const aliases = std.StaticStringMap({s}).initComptime(.{{\n", .{spec.name});
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (values.items) |v| {
            for (v) |alias| {
                if (std.mem.eql(u8, alias, "n/a")) continue;
                if ((try seen.getOrPut(a, alias)).found_existing) continue;
                try w.print("        .{{ \"{s}\", .", .{alias});
                try writeIdent(w, v[0]);
                try w.writeAll(" },\n");
            }
        }
        try w.print("    }});\n\n    /// The value for any alias, or null.\n    pub fn fromAlias(s: []const u8) ?{s} {{\n        return aliases.get(s);\n    }}\n}};\n\n", .{spec.name});
    }
}

test "enum block for a tiny alias file" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try write(arena.allocator(), &out.writer, "bpt; c ; Close\nbpt; n ; None\ngc ; L ; Letter\ngc ; Lu ; Uppercase_Letter\n");
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "pub const BracketType = enum(u2) {\n    c,\n    n,\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ".{ \"Uppercase_Letter\", .Lu },") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"Letter\"") == null);
}
