const std = @import("std");
const commands = @import("commands.zig");
const daily = @import("daily.zig");
const datefmt = @import("datefmt.zig");
const localtime = @import("localtime.zig");
const templates = @import("templates.zig");
const ni = @import("../index/note_index.zig");
const vault_mod = @import("../vault/vault.zig");

const testing = std.testing;
const FileId = @import("../vault/note.zig").FileId;

fn fid(i: u32) FileId {
    return .{ .index = i, .gen = 0 };
}

const Fill = struct {
    calls: u32 = 0,
    sections: usize = 0,
    context: usize = 0,
    last_ctx: [64]u8 = undefined,
    last_len: usize = 0,

    fn run(ctx: *anyopaque, note_path: []const u8, sections: []const templates.AiSection, context: []const []const u8) void {
        _ = note_path;
        const f: *Fill = @ptrCast(@alignCast(ctx));
        f.calls += 1;
        f.sections = sections.len;
        f.context = context.len;
        const last = context[context.len - 1];
        @memcpy(f.last_ctx[0..last.len], last);
        f.last_len = last.len;
    }
};

const Env = struct {
    tmp: testing.TmpDir,
    files: commands.DirFiles,
    vault: vault_mod.Vault,
    ix: *ni.NoteIndex,
    tz: localtime.LocalTz,
    fill: Fill = .{},
    next_id: u32 = 0,

    fn init(e: *Env, cfg: vault_mod.VaultConfig) !void {
        e.tmp = testing.tmpDir(.{});
        e.files = .{ .dir = e.tmp.dir, .io = testing.io };
        e.vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = cfg };
        e.ix = try ni.NoteIndex.init(testing.allocator, testing.io, &.{e.vault});
        e.tz = .utc(testing.allocator);
        e.fill = .{};
        e.next_id = 0;
    }

    fn deinit(e: *Env) void {
        e.ix.deinit();
        e.tmp.cleanup();
    }

    fn ctx(e: *Env) commands.NotesCtx {
        return .{ .gpa = testing.allocator, .io = testing.io, .ix = e.ix, .vault = &e.vault, .files = e.files.port(), .tz = &e.tz, .ai_fill = .{ .ctx = &e.fill, .run = Fill.run } };
    }

    /// Writes a file and indexes it, as the workspace watcher would.
    fn put(e: *Env, path: []const u8, bytes: []const u8) !void {
        const parent = std.fs.path.dirname(path) orelse "";
        if (parent.len > 0) try e.tmp.dir.createDirPath(testing.io, parent);
        try e.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = bytes });
        try e.index(path);
    }

    fn index(e: *Env, path: []const u8) !void {
        const bytes = try e.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        try e.ix.indexNote(fid(e.next_id), .of(0), path, bytes);
        e.next_id += 1;
        try e.ix.commit();
    }
};

test "daily: path with subfolders and creation from template" {
    var e: Env = undefined;
    try e.init(.{ .daily_dir = "journal", .daily_format = "YYYY/MM/YYYY-MM-DD", .daily_template = "templates/Daily" });
    defer e.deinit();
    try e.put("templates/Daily.md", "# {{title}} ({{date:dddd}})\n{{cursor}}\n## AI\n{{ai: summarize yesterday}}\n");
    try e.put("journal/2026/10/2026-10-20.md", "yesterday\n");
    var c = e.ctx();
    const when: datefmt.DateTime = .{ .date = .{ .y = 2026, .m = 10, .d = 21 }, .h = 8, .min = 0, .s = 0, .utc_offset_s = 0 };
    var o = try c.openDaily(when);
    defer o.deinit(testing.allocator);
    try testing.expect(o.created);
    try testing.expectEqualStrings("journal/2026/10/2026-10-21.md", o.path);
    const text = try e.tmp.dir.readFileAlloc(testing.io, o.path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("# 2026-10-21 (Wednesday)\n\n## AI\n> [!ai] Pending: summarize yesterday\n", text);
    try testing.expectEqual(@as(?u32, 25), o.cursor);
    // The AI hook got the section, the note and yesterday's note.
    try testing.expectEqual(@as(u32, 1), e.fill.calls);
    try testing.expectEqual(@as(usize, 1), e.fill.sections);
    try testing.expectEqual(@as(usize, 2), e.fill.context);
    try testing.expectEqualStrings("journal/2026/10/2026-10-20.md", e.fill.last_ctx[0..e.fill.last_len]);
    // Once indexed, opening again finds it.
    try e.index(o.path);
    var again = try c.openDaily(when);
    defer again.deinit(testing.allocator);
    try testing.expect(!again.created);
    try testing.expect(again.id != null);
    // A missing template is an error; none configured gives an empty note.
    e.vault.config.daily_template = "";
    var bare = try c.openDaily(.{ .date = .{ .y = 2026, .m = 11, .d = 1 }, .h = 0, .min = 0, .s = 0, .utc_offset_s = 0 });
    defer bare.deinit(testing.allocator);
    try testing.expect(bare.created);
    e.vault.config.daily_template = "nope";
    try testing.expectError(error.TemplateNotFound, c.openDaily(.{ .date = .{ .y = 2026, .m = 11, .d = 2 }, .h = 0, .min = 0, .s = 0, .utc_offset_s = 0 }));
    // New note from a template in templates_dir, with clash numbering.
    e.vault.config.new_note_dir = .fixed;
    e.vault.config.new_note_folder = "inbox";
    try e.put("inbox/Idea.md", "taken");
    var n = try c.newFromTemplate("Daily", "Idea", "");
    defer n.deinit(testing.allocator);
    try testing.expectEqualStrings("inbox/Idea 1.md", n.path);
}

test "daily: prev/next by date across months" {
    var e: Env = undefined;
    try e.init(.{ .daily_dir = "daily", .daily_format = "YYYY-MM-DD" });
    defer e.deinit();
    for ([_][]const u8{ "daily/2026-01-30.md", "daily/2026-02-02.md", "daily/2026-03-01.md", "daily/2025-12-31.md", "daily/notes.md", "other/2026-02-10.md" }) |p| try e.put(p, "x");
    var c = e.ctx();
    const view = try e.ix.reader();
    defer view.release();
    var list: std.ArrayList(daily.DailyNote) = .empty;
    defer list.deinit(testing.allocator);
    try daily.listDailyNotes(testing.allocator, view, &e.vault, &list);
    try testing.expectEqual(@as(usize, 4), list.items.len);
    const cases = [_]struct { from: datefmt.Date, dir: daily.Direction, want: ?[]const u8 }{
        .{ .from = .{ .y = 2026, .m = 2, .d = 2 }, .dir = .prev, .want = "daily/2026-01-30.md" },
        .{ .from = .{ .y = 2026, .m = 2, .d = 2 }, .dir = .next, .want = "daily/2026-03-01.md" },
        .{ .from = .{ .y = 2026, .m = 2, .d = 15 }, .dir = .prev, .want = "daily/2026-02-02.md" },
        .{ .from = .{ .y = 2026, .m = 1, .d = 1 }, .dir = .prev, .want = "daily/2025-12-31.md" },
        .{ .from = .{ .y = 2025, .m = 12, .d = 31 }, .dir = .prev, .want = null },
        .{ .from = .{ .y = 2026, .m = 3, .d = 1 }, .dir = .next, .want = null },
        .{ .from = .{ .y = 2025, .m = 1, .d = 1 }, .dir = .next, .want = "daily/2025-12-31.md" },
    };
    for (cases) |cs| {
        var got = try c.step(cs.from, cs.dir);
        defer if (got) |*g| g.deinit(testing.allocator);
        if (cs.want) |w| try testing.expectEqualStrings(w, got.?.path) else try testing.expect(got == null);
    }
}
