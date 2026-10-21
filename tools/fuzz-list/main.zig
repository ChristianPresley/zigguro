//! fuzz-list: prints every `test "fuzz: ..."` target in the repository as
//! JSON, for nightly CI (`zig build fuzz-list`):
//!
//!   {"targets":[{"package":"zg_net","name":"fuzz: sse parser","file":"packages/net/src/sse.zig"}, ...]}
//!
//! Plain text matching over `packages/*/src/**/*.zig`; the package name is
//! the `.name` of the directory's `build.zig.zon`.

const std = @import("std");

/// One discovered fuzz test.
pub const Target = struct { package: []const u8, name: []const u8, file: []const u8 };

/// Appends the fuzz test names declared in Zig `source` (strings point into it).
pub fn scanSource(gpa: std.mem.Allocator, source: []const u8, out: *std.ArrayList([]const u8)) !void {
    const needle = "test \"fuzz: ";
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, needle)) |i| {
        pos = i + needle.len;
        // Only count declarations at the start of a line.
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..i], '\n')) |nl| nl + 1 else 0;
        if (std.mem.trim(u8, source[line_start..i], " \t").len != 0) continue;
        const name_start = i + "test \"".len;
        const end = std.mem.indexOfScalarPos(u8, source, name_start, '"') orelse continue;
        try out.append(gpa, source[name_start..end]);
    }
}

/// Extracts `.name = .<ident>` from a build.zig.zon source.
pub fn zonName(source: []const u8) ?[]const u8 {
    const key = ".name = .";
    const i = std.mem.indexOf(u8, source, key) orelse return null;
    var j = i + key.len;
    while (j < source.len and (std.ascii.isAlphanumeric(source[j]) or source[j] == '_')) j += 1;
    return source[i + key.len .. j];
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var root_path: []const u8 = ".";
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--root")) root_path = args[2];
    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);

    var targets: std.ArrayList(Target) = .empty;
    var pkgs = try root.openDir(io, "packages", .{ .iterate = true });
    defer pkgs.close(io);
    var dirs: std.ArrayList([]const u8) = .empty;
    var it = pkgs.iterate();
    while (try it.next(io)) |e| if (e.kind == .directory) try dirs.append(gpa, try gpa.dupe(u8, e.name));
    std.mem.sort([]const u8, dirs.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (dirs.items) |dir| {
        const zon = pkgs.readFileAlloc(io, try std.fs.path.join(gpa, &.{ dir, "build.zig.zon" }), gpa, .limited(1 << 20)) catch continue;
        const pkg = zonName(zon) orelse continue;
        var src = pkgs.openDir(io, try std.fs.path.join(gpa, &.{ dir, "src" }), .{ .iterate = true }) catch continue;
        defer src.close(io);
        var walker = try src.walk(gpa);
        defer walker.deinit();
        var files: std.ArrayList([]const u8) = .empty;
        while (try walker.next(io)) |e| {
            if (e.kind == .file and std.mem.endsWith(u8, e.basename, ".zig")) try files.append(gpa, try gpa.dupe(u8, e.path));
        }
        std.mem.sort([]const u8, files.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        for (files.items) |f| {
            const text = try src.readFileAlloc(io, f, gpa, .limited(16 << 20));
            var names: std.ArrayList([]const u8) = .empty;
            try scanSource(gpa, text, &names);
            for (names.items) |n| try targets.append(gpa, .{
                .package = pkg,
                .name = n,
                .file = try std.mem.replaceOwned(u8, gpa, try std.fs.path.join(gpa, &.{ "packages", dir, "src", f }), "\\", "/"),
            });
        }
    }

    var buf: [4096]u8 = undefined;
    var fw: std.Io.File.Writer = .init(.stdout(), io, &buf);
    var s: std.json.Stringify = .{ .writer = &fw.interface };
    try s.write(.{ .targets = targets.items });
    try fw.interface.writeAll("\n");
    try fw.interface.flush();
    return 0;
}

test "fuzz-list: scans fuzz test declarations" {
    const gpa = std.testing.allocator;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    try scanSource(gpa,
        \\test "fuzz: sse parser" {
        \\}
        \\test "not fuzz" {}
        \\    test "fuzz: indented" {}
        \\const s = "x test \"fuzz: inside string";
    , &names);
    try std.testing.expectEqual(@as(usize, 2), names.items.len);
    try std.testing.expectEqualStrings("fuzz: sse parser", names.items[0]);
    try std.testing.expectEqualStrings("fuzz: indented", names.items[1]);
}

test "fuzz-list: zon name" {
    try std.testing.expectEqualStrings("zg_net", zonName(".{\n    .name = .zg_net,\n}").?);
    try std.testing.expect(zonName(".{}") == null);
}
