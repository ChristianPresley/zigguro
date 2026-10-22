//! Imports a VS Code `keybindings.json` (JSONC): maps command ids through
//! `presets/vscode_commands.zon`, converts removals, checks key specs and
//! when-clauses, reports conflicts with the current keymap, and renders the
//! accepted entries as `keybindings.zon` text to append.

const std = @import("std");
const keyspec = @import("keyspec.zig");
const keymap_mod = @import("keymap.zig");
const jsonc = @import("../jsonc.zig");
const zon_load = @import("../zon_load.zig");
const diag = @import("../diag.zig");
const context = @import("../when/context.zig");
const When = @import("../when/when.zig").When;

const Allocator = std.mem.Allocator;
const Platform = keyspec.Platform;
const Keymap = keymap_mod.Keymap;
const Node = zon_load.Node;

const table = @import("presets/vscode_commands.zon");

/// VS Code command id → zigguro command id.
pub const command_map = std.StaticStringMap([]const u8).initComptime(blk: {
    var kvs: [table.len]struct { []const u8, []const u8 } = undefined;
    for (table, 0..) |e, i| kvs[i] = .{ e[0], e[1] };
    break :blk kvs;
});

/// VS Code context keys whose zigguro name differs.
pub const context_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "terminalTextSelected", "terminal.hasSelection" },
    .{ "suggestWidgetVisible", "suggestWidgetVisible" },
    .{ "inlineSuggestionVisible", "ghostVisible" },
    .{ "listFocus", "inputFocus" },
    .{ "searchViewletVisible", "activeViewlet" },
});

/// The outcome of one imported entry.
pub const Status = enum { mapped, unmapped, conflict, invalid_key, invalid_when };

/// One entry of the import report.
pub const KbImportItem = struct {
    vscode: []const u8,
    /// Mapped command (with a leading '-' for removals), or null.
    zigguro: ?[]const u8,
    /// Key spec in canonical config form (or the original text if invalid).
    key: []const u8,
    when: ?[]const u8,
    /// Args as ZON text.
    args: ?[]const u8 = null,
    status: Status,
    note: []const u8 = "",
};

/// Parses `src` and returns one item per entry. Everything is allocated in
/// `arena`. `km`, when given, is checked for conflicts; `keys` decides
/// which when-clause keys are known (unknown ones are noted, not rejected).
pub fn importVsCodeKeybindings(arena: Allocator, src: []const u8, plat: Platform, km: ?*const Keymap, keys: *context.ContextKeyService) ![]KbImportItem {
    var diags = diag.Diags.init(arena);
    var doc = jsonc.loadJsonc(arena, src, &diags) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return error.InvalidJson,
    };
    _ = &doc;
    const entries = switch (doc.root.v) {
        .array => |a| a,
        else => return error.InvalidJson,
    };
    var out: std.ArrayList(KbImportItem) = .empty;
    for (entries) |e| {
        if (e.v != .object) continue;
        try out.append(arena, try importOne(arena, e, plat, km, keys));
    }
    return out.items;
}

fn str(n: ?Node) ?[]const u8 {
    const x = n orelse return null;
    return switch (x.v) {
        .string => |s| s,
        else => null,
    };
}

fn importOne(arena: Allocator, e: Node, plat: Platform, km: ?*const Keymap, keys: *context.ContextKeyService) !KbImportItem {
    const raw_cmd = str(e.get("command")) orelse "";
    const key_text = str(e.get("key")) orelse "";
    const when_text = str(e.get("when"));
    var item: KbImportItem = .{ .vscode = raw_cmd, .zigguro = null, .key = key_text, .when = when_text, .status = .mapped };

    if (e.get("args")) |a| if (a.v != .null) {
        const v = try zon_load.toValue(arena, a);
        var aw: std.Io.Writer.Allocating = .init(arena);
        v.writeZon(&aw.writer) catch return error.OutOfMemory;
        item.args = aw.written();
    };

    // Key.
    var spec: ?keyspec.KeySpec = null;
    if (key_text.len > 0) {
        var d = diag.Diags.init(arena);
        spec = keyspec.parse(key_text, plat, &d);
        if (spec == null) {
            item.status = .invalid_key;
            item.note = if (d.items().len > 0) d.items()[0].message else "invalid key";
            return item;
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        keyspec.format(spec.?, plat, .config, null, &aw.writer) catch return error.OutOfMemory;
        item.key = aw.written();
    }

    // Command.
    const removal = raw_cmd.len > 0 and raw_cmd[0] == '-';
    const bare = if (removal) raw_cmd[1..] else raw_cmd;
    const mapped = command_map.get(bare) orelse {
        item.status = .unmapped;
        item.note = "no zigguro equivalent";
        return item;
    };
    item.zigguro = if (removal) try std.fmt.allocPrint(arena, "-{s}", .{mapped}) else mapped;

    // When-clause.
    if (when_text) |wt| {
        const translated = try translateWhen(arena, wt);
        item.when = translated;
        var d = diag.Diags.init(arena);
        var w = When.compile(arena, translated, null, &d) catch |x| switch (x) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWhen => {
                item.status = .invalid_when;
                item.note = if (d.items().len > 0) d.items()[0].message else "invalid when-clause";
                return item;
            },
        };
        defer w.deinit();
        var unknown: std.ArrayList(u8) = .empty;
        for (w.keys) |k| {
            if (std.mem.startsWith(u8, k.name, "config.")) continue;
            if (keys.find(k.name) != null) continue;
            if (std.mem.indexOf(u8, unknown.items, k.name) != null) continue;
            if (unknown.items.len > 0) try unknown.appendSlice(arena, ", ");
            try unknown.appendSlice(arena, k.name);
        }
        if (unknown.items.len > 0) item.note = try std.fmt.allocPrint(arena, "unknown context keys (always false): {s}", .{unknown.items});
    }

    // Conflict: a live binding of the same keys to another command.
    if (!removal and spec != null) if (km) |k| {
        for (k.byFirst(spec.?.strokes[0])) |bi| {
            const b = &k.bindings[bi];
            if (!b.spec.eql(spec.?) or b.isDisable()) continue;
            if (std.mem.eql(u8, b.command, mapped)) continue;
            const same_when = (b.when == null and item.when == null) or
                (b.when != null and item.when != null and std.mem.eql(u8, b.when.?.text, item.when.?));
            if (b.when == null or item.when == null or same_when) {
                item.status = .conflict;
                item.note = try std.fmt.allocPrint(arena, "replaces {s}", .{b.command});
                break;
            }
        }
    };
    return item;
}

fn translateWhen(arena: Allocator, src: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (std.ascii.isAlphabetic(c) or c == '_' or c == '$') {
            var j = i;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_' or src[j] == '.' or src[j] == ':' or src[j] == '$' or src[j] == '-')) j += 1;
            const word = src[i..j];
            try out.appendSlice(arena, context_map.get(word) orelse word);
            i = j;
        } else if (c == '\'' or c == '/') {
            // Copy literals and regexes verbatim.
            var j = i + 1;
            while (j < src.len and src[j] != c) : (j += 1) {
                if (src[j] == '\\') j += 1;
            }
            j = @min(j + 1, src.len);
            try out.appendSlice(arena, src[i..j]);
            i = j;
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

/// Writes the entries with status `mapped` or `conflict` as keybindings.zon
/// entries (one per line, VS Code id in a comment).
pub fn renderEntries(items: []const KbImportItem, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (items) |it| {
        if (it.status != .mapped and it.status != .conflict) continue;
        try w.print("    // imported from VS Code: {s}\n", .{it.vscode});
        try w.print("    .{{ .key = \"{f}\", .command = \"{f}\"", .{ std.zig.fmtString(it.key), std.zig.fmtString(it.zigguro.?) });
        if (it.when) |wt| try w.print(", .when = \"{f}\"", .{std.zig.fmtString(wt)});
        if (it.args) |a| try w.print(", .args = {s}", .{a});
        try w.writeAll(" },\n");
    }
}

/// Returns `existing` (a keybindings.zon source, possibly empty) with the
/// accepted entries appended inside its top-level array.
pub fn appendImported(arena: Allocator, existing: []const u8, items: []const KbImportItem) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const trimmed = std.mem.trimEnd(u8, existing, " \t\r\n");
    if (trimmed.len == 0) {
        w.writeAll(".{\n") catch return error.OutOfMemory;
        renderEntries(items, w) catch return error.OutOfMemory;
        w.writeAll("}\n") catch return error.OutOfMemory;
        return aw.written();
    }
    if (trimmed[trimmed.len - 1] != '}') return error.InvalidZon;
    var head = std.mem.trimEnd(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n");
    w.writeAll(head) catch return error.OutOfMemory;
    // Keep the list well-formed: add a comma after the last entry if needed.
    if (head.len > 0 and head[head.len - 1] != ',' and head[head.len - 1] != '{') w.writeByte(',') catch return error.OutOfMemory;
    w.writeByte('\n') catch return error.OutOfMemory;
    renderEntries(items, w) catch return error.OutOfMemory;
    w.writeAll("}\n") catch return error.OutOfMemory;
    head = aw.written();
    return head;
}
