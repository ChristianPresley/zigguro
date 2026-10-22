//! macOS font discovery tests. The default table and assembly over a
//! fixture tree run everywhere; the live scan runs on macOS only.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const discovery = @import("discovery.zig");
const mac = @import("discovery_macos.zig");
const fallback = @import("fallback.zig");

test "macosDefaults table well-formed" {
    const d = mac.macosDefaults();
    for ([_][]const []const u8{ d.ui, d.mono, d.serif, d.emoji }) |list| {
        try testing.expect(list.len > 0);
        for (list) |f| try testing.expect(f.len > 0 and std.mem.trim(u8, f, " ").len == f.len);
    }
    try testing.expectEqualStrings("Apple Color Emoji", d.emoji[0]);
    try testing.expectEqualStrings("Menlo", d.mono[d.mono.len - 1]);
    for (std.enums.values(fallback.HanVariant)) |v| {
        var n: usize = 0;
        for (d.per_script) |sf| if (sf.script == .Hani and sf.han == v) {
            n += 1;
        };
        try testing.expectEqual(1, n);
    }
    for (d.per_script, 0..) |a, i| {
        try testing.expect(a.families.len > 0);
        try testing.expect((a.script == .Hani) == (a.han != null));
        for (d.per_script[i + 1 ..]) |b| if (a.script != .Hani) try testing.expect(a.script != b.script);
    }
}

test "macos dirs from fake HOME" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "home/Library/Fonts");
    try tmp.dir.createDirPath(io, "root/Library/Fonts");
    try tmp.dir.createDirPath(io, "root/System/Library/Fonts/Supplemental");
    for ([_][]const u8{
        "home/Library/Fonts/user.otf",
        "home/Library/Fonts/old.dfont",
        "root/Library/Fonts/shared.ttf",
        "root/System/Library/Fonts/Menlo.ttc",
        "root/System/Library/Fonts/Supplemental/Arial.ttf",
    }) |p| try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "x" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const home = try std.fs.path.join(a, &.{ base, "home" });
    const root = try std.fs.path.join(a, &.{ base, "root" });

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    var d = try mac.assemble(gpa, io, &env, root, mac.macosDefaults());
    defer d.deinit(gpa);
    // /Network/Library/Fonts is missing, so it is left out.
    const want = [_][]const u8{
        try std.fs.path.join(a, &.{ home, "Library", "Fonts" }),
        try std.mem.concat(a, u8, &.{ root, "/Library/Fonts" }),
        try std.mem.concat(a, u8, &.{ root, "/System/Library/Fonts" }),
        try std.mem.concat(a, u8, &.{ root, "/System/Library/Fonts/Supplemental" }),
    };
    try testing.expectEqual(want.len, d.dirs.len);
    for (want, d.dirs) |w, g| try testing.expectEqualStrings(w, g);
    try testing.expectEqual(0, d.files.len);

    var files: std.ArrayList(discovery.FileEntry) = .empty;
    defer discovery.freeFileEntries(gpa, &files);
    try d.listFiles(gpa, io, &files);
    // The .dfont is skipped; Supplemental is listed once, though it is
    // both a configured directory and a subdirectory of another.
    const names = [_][]const u8{ "user.otf", "shared.ttf", "Menlo.ttc", "Arial.ttf" };
    try testing.expectEqual(names.len, files.items.len);
    for (names, files.items) |n, f| try testing.expectEqualStrings(n, std.fs.path.basename(f.path));

    const sans = try d.preferences(a, "sans-serif");
    try testing.expectEqualStrings("SF Pro", sans[0]);
    const mono = try d.preferences(a, "monospace");
    try testing.expectEqualStrings("Menlo", mono[mono.len - 1]);

    // No HOME: system directories only.
    var bare: std.process.Environ.Map = .init(gpa);
    defer bare.deinit();
    var d2 = try mac.assemble(gpa, io, &bare, root, mac.macosDefaults());
    defer d2.deinit(gpa);
    try testing.expectEqual(3, d2.dirs.len);
}

test "live scan finds Menlo" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = testing.allocator;
    const io = testing.io;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var d = try mac.discoverMacos(gpa, io, &env);
    defer d.deinit(gpa);
    var files: std.ArrayList(discovery.FileEntry) = .empty;
    defer discovery.freeFileEntries(gpa, &files);
    try d.listFiles(gpa, io, &files);
    for (files.items) |f| {
        if (std.mem.eql(u8, std.fs.path.basename(f.path), "Menlo.ttc")) break;
    } else return error.MenloNotFound;
}
