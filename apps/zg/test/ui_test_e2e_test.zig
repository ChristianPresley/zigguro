//! End-to-end test of `zg ui-test` (E04.F01.S03.T01): runs the built `zg`
//! on zg_gui's example scripts, checks the snapshots it writes against
//! the package's goldens, then fails a script on purpose.

const std = @import("std");
const fixtures = @import("zg_e2e");

const testing = std.testing;
const io = testing.io;

fn uiTest(args: []const []const u8) !struct { out: []u8, code: u8 } {
    const gpa = testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ fixtures.zg, "ui-test" });
    try argv.appendSlice(gpa, args);
    var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .pipe, .stderr = .inherit, .create_no_window = true });
    var buf: [4096]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &buf);
    const out = try r.interface.allocRemaining(gpa, .limited(1 << 20));
    const term = try child.wait(io);
    return .{ .out = out, .code = switch (term) {
        .exited => |c| c,
        else => 255,
    } };
}

test "zg ui-test: example scripts pass and snapshots match the goldens" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const snaps = buf[0..try tmp.dir.realPath(io, &buf)];

    var scripts: std.ArrayList([]const u8) = .empty;
    defer {
        for (scripts.items) |p| gpa.free(p);
        scripts.deinit(gpa);
    }
    var dir = try std.Io.Dir.cwd().openDir(io, fixtures.scripts, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| if (std.mem.endsWith(u8, e.name, ".zgui"))
        try scripts.append(gpa, try std.fs.path.join(gpa, &.{ fixtures.scripts, e.name }));
    try testing.expect(scripts.items.len > 0);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.appendSlice(gpa, &.{ "--snapshots", snaps });
    try args.appendSlice(gpa, scripts.items);
    const r = try uiTest(args.items);
    defer gpa.free(r.out);
    try testing.expectEqual(@as(u8, 0), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "scripts passed") != null);

    var snap_dir = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer snap_dir.close(io);
    var written = snap_dir.iterate();
    var n: usize = 0;
    while (try written.next(io)) |e| {
        n += 1;
        const got = try tmp.dir.readFileAlloc(io, e.name, gpa, .limited(1 << 20));
        defer gpa.free(got);
        const golden = try std.fmt.allocPrint(gpa, "{s}/{s}.golden", .{ fixtures.goldens, e.name });
        defer gpa.free(golden);
        const want = try std.Io.Dir.cwd().readFileAlloc(io, golden, gpa, .limited(1 << 20));
        defer gpa.free(want);
        try testing.expectEqualStrings(want, got);
    }
    try testing.expect(n > 0);

    // A second run compares with what the first wrote.
    const again = try uiTest(args.items);
    defer gpa.free(again.out);
    try testing.expectEqual(@as(u8, 0), again.code);
}

test "zg ui-test: a failing query exits 1 with the closest names" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.zgui", .data = "open Counter\nclick role=button name=\"Incremnet\"\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(testing.allocator, &.{ root, "bad.zgui" });
    defer testing.allocator.free(path);
    const r = try uiTest(&.{path});
    defer testing.allocator.free(r.out);
    try testing.expectEqual(@as(u8, 1), r.code);
    try testing.expect(std.mem.indexOf(u8, r.out, "2:1: nothing matches") != null);
    try testing.expect(std.mem.indexOf(u8, r.out, "button \"Increment\"") != null);

    const usage = try uiTest(&.{});
    defer testing.allocator.free(usage.out);
    try testing.expectEqual(@as(u8, 2), usage.code);
}
