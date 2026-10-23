//! Daily notes (E08.F07.S02.T01): a day's note lives at
//! `daily_dir/<daily_format>.md` (a `/` in the format makes subfolders).
//! Existing daily notes are the notes under `daily_dir` whose path parses
//! with the format; navigation binary-searches them by date.

const std = @import("std");
const datefmt = @import("datefmt.zig");
const note_index = @import("../index/note_index.zig");
const vault_mod = @import("../vault/vault.zig");
const names = @import("../index/names.zig");

const Allocator = std.mem.Allocator;
const Date = datefmt.Date;
const FileId = @import("../vault/note.zig").FileId;

pub const DailyNote = struct { date: Date, id: FileId };

/// The vault-relative path of `date`'s note.
pub fn dailyPath(a: Allocator, cfg: *const vault_mod.VaultConfig, date: Date) ![]u8 {
    const name = try datefmt.formatAlloc(a, cfg.daily_format, .{ .date = date, .h = 0, .min = 0, .s = 0, .utc_offset_s = null });
    defer a.free(name);
    const dir = std.mem.trim(u8, cfg.daily_dir, "/");
    if (dir.len == 0) return std.fmt.allocPrint(a, "{s}.md", .{name});
    return std.fmt.allocPrint(a, "{s}/{s}.md", .{ dir, name });
}

/// The date a vault-relative note path names, or null.
pub fn dateOfPath(cfg: *const vault_mod.VaultConfig, path: []const u8) ?Date {
    if (!names.isMdExt(path)) return null;
    const dir = std.mem.trim(u8, cfg.daily_dir, "/");
    var rest = names.withoutMd(path);
    if (dir.len > 0) {
        if (rest.len <= dir.len + 1 or !std.mem.startsWith(u8, rest, dir) or rest[dir.len] != '/') return null;
        rest = rest[dir.len + 1 ..];
    }
    const dt = datefmt.parse(cfg.daily_format, rest) orelse return null;
    return dt.date;
}

fn dateLess(_: void, a: DailyNote, b: DailyNote) bool {
    return datefmt.daysFromCivil(a.date) < datefmt.daysFromCivil(b.date);
}

/// Appends `vault`'s daily notes to `out`, sorted by date.
pub fn listDailyNotes(gpa: Allocator, view: *const note_index.IndexView, vault: *const vault_mod.Vault, out: *std.ArrayList(DailyNote)) !void {
    const start = out.items.len;
    for (view.order) |id| {
        const e = view.entry(id) orelse continue;
        if (e.vault != vault.id) continue;
        const d = dateOfPath(&vault.config, e.path) orelse continue;
        try out.append(gpa, .{ .date = d, .id = id });
    }
    std.mem.sort(DailyNote, out.items[start..], {}, dateLess);
}

pub const Direction = enum { prev, next };

/// The nearest daily note strictly before or after `date`.
pub fn neighbor(list: []const DailyNote, date: Date, dir: Direction) ?DailyNote {
    const key = datefmt.daysFromCivil(date);
    // The first entry not before `date`.
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (datefmt.daysFromCivil(list[mid].date) < key) lo = mid + 1 else hi = mid;
    }
    switch (dir) {
        .prev => return if (lo > 0) list[lo - 1] else null,
        .next => {
            var i = lo;
            while (i < list.len and datefmt.daysFromCivil(list[i].date) == key) i += 1;
            return if (i < list.len) list[i] else null;
        },
    }
}

test "daily: paths and dates round trip" {
    const a = std.testing.allocator;
    const cfg: vault_mod.VaultConfig = .{ .daily_dir = "journal/", .daily_format = "YYYY/MM/YYYY-MM-DD" };
    const p = try dailyPath(a, &cfg, .{ .y = 2026, .m = 3, .d = 9 });
    defer a.free(p);
    try std.testing.expectEqualStrings("journal/2026/03/2026-03-09.md", p);
    try std.testing.expect(dateOfPath(&cfg, p).?.eql(.{ .y = 2026, .m = 3, .d = 9 }));
    try std.testing.expect(dateOfPath(&cfg, "journal/2026/03/notes.md") == null);
    try std.testing.expect(dateOfPath(&cfg, "other/2026/03/2026-03-09.md") == null);
    const root: vault_mod.VaultConfig = .{ .daily_dir = "" };
    try std.testing.expect(dateOfPath(&root, "2026-01-02.md").?.eql(.{ .y = 2026, .m = 1, .d = 2 }));
}
