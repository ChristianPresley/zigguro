//! `text-fontscan-report`: prints what font discovery finds on this
//! machine (directories, generic-family preferences, font files) so a
//! maintainer can compare it by hand with `fc-list --format '%{file}\n'`,
//! and how long a font database scan of those files takes.
//! This is a manual check, never a CI step.
//!
//!   zig build text-fontscan-report [-- --no-files]

const std = @import("std");
const builtin = @import("builtin");
const zg_text = @import("zg_text");
const fonts = zg_text.fonts;

const generics = [_][]const u8{ "monospace", "sans-serif", "serif", "emoji", "system-ui" };

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};
    const files = !(args.len > 1 and std.mem.eql(u8, args[1], "--no-files"));

    if (builtin.os.tag != .linux) {
        try out.print("font discovery for {t} is not implemented yet\n", .{builtin.os.tag});
        return 2;
    }
    const t0 = std.Io.Clock.awake.now(io);
    var d = try fonts.discoverLinux(gpa, io, init.environ_map);
    const t1 = std.Io.Clock.awake.now(io);
    try out.print("# directories ({d}, {d} µs)\n", .{ d.dirs.len, @divTrunc(t0.durationTo(t1).nanoseconds, 1000) });
    for (d.dirs) |dir| try out.print("{s}\n", .{dir});
    try out.print("\n# generic families\n", .{});
    for (generics) |g| {
        const prefs = try d.preferences(gpa, g);
        try out.print("{s}:", .{g});
        for (prefs) |p| try out.print(" \"{s}\"", .{p});
        try out.print("\n", .{});
    }
    var list: std.ArrayList(fonts.FileEntry) = .empty;
    try fonts.listFontFiles(gpa, io, d.dirs, &list);
    const t2 = std.Io.Clock.awake.now(io);
    try out.print("\n# font files ({d}, {d} µs)\n", .{ list.items.len, @divTrunc(t1.durationTo(t2).nanoseconds, 1000) });
    if (files) for (list.items) |e| try out.print("{s}\n", .{e.path});

    var stats: fonts.ScanStats = .{};
    var db = try fonts.FontDb.empty.rescan(gpa, io, list.items, &stats);
    try out.print("\n# database: {d} faces from {d} files in {d} ms ({d} unreadable)\n", .{ db.faces().len, stats.added, stats.ms, stats.failed });
    var again: fonts.ScanStats = .{};
    var db2 = try db.rescan(gpa, io, list.items, &again);
    try out.print("# rescan with nothing changed: {d} ms\n", .{again.ms});
    db2.deinit(gpa);
    db.deinit(gpa);
    return 0;
}
