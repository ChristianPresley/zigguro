//! `zg-release repro-compare <dirA> <dirB>`: byte-compares two release
//! trees. PE images are compared with their Authenticode signature and
//! CheckSum removed (pe_strip_sig.zig). Exit 0 when identical, 1 with the
//! first difference printed, 2 on usage errors.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pe = @import("pe_strip_sig.zig");

/// The first difference between two trees.
pub const Difference = union(enum) {
    only_in_a: []const u8,
    only_in_b: []const u8,
    content: struct { path: []const u8, offset: u64 },
};

/// Sorted relative paths of every regular file and symlink under `dir`.
fn listTree(gpa: Allocator, io: std.Io, dir: std.Io.Dir) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var w = try dir.walk(gpa);
    defer w.deinit();
    while (try w.next(io)) |e| {
        if (e.kind == .directory) continue;
        try out.append(gpa, try gpa.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out.items;
}

fn normalized(bytes: []u8) []u8 {
    if (pe.isPe(bytes)) return pe.strip(bytes) catch bytes;
    return bytes;
}

/// Compares the trees and returns the first difference, or null.
pub fn compare(gpa: Allocator, io: std.Io, a: std.Io.Dir, b: std.Io.Dir) !?Difference {
    const la = try listTree(gpa, io, a);
    const lb = try listTree(gpa, io, b);
    var i: usize = 0;
    var j: usize = 0;
    while (i < la.len or j < lb.len) {
        if (j == lb.len or (i < la.len and std.mem.order(u8, la[i], lb[j]) == .lt)) return .{ .only_in_a = la[i] };
        if (i == la.len or std.mem.order(u8, la[i], lb[j]) == .gt) return .{ .only_in_b = lb[j] };
        const ba = normalized(try a.readFileAlloc(io, la[i], gpa, .unlimited));
        const bb = normalized(try b.readFileAlloc(io, lb[j], gpa, .unlimited));
        if (std.mem.indexOfDiff(u8, ba, bb)) |off| return .{ .content = .{ .path = la[i], .offset = off } };
        i += 1;
        j += 1;
    }
    return null;
}

/// Entry point for `zg-release repro-compare`.
pub fn main(gpa: Allocator, io: std.Io, argv: []const []const u8) !u8 {
    if (argv.len != 2) return 2;
    var a = try std.Io.Dir.cwd().openDir(io, argv[0], .{ .iterate = true });
    defer a.close(io);
    var b = try std.Io.Dir.cwd().openDir(io, argv[1], .{ .iterate = true });
    defer b.close(io);
    const diff = try compare(gpa, io, a, b) orelse {
        std.debug.print("identical\n", .{});
        return 0;
    };
    switch (diff) {
        .only_in_a => |p| std.debug.print("only in {s}: {s}\n", .{ argv[0], p }),
        .only_in_b => |p| std.debug.print("only in {s}: {s}\n", .{ argv[1], p }),
        .content => |c| std.debug.print("{s} differs at byte {d}\n", .{ c.path, c.offset }),
    }
    return 1;
}

test "repro-compare: identical, different file, PE signature ignored" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var a = try tmp.dir.createDirPathOpen(io, "a", .{ .open_options = .{ .iterate = true } });
    defer a.close(io);
    var b = try tmp.dir.createDirPathOpen(io, "b", .{ .open_options = .{ .iterate = true } });
    defer b.close(io);
    var ia: [0x400]u8 = undefined;
    var ib: [0x400]u8 = undefined;
    try a.writeFile(io, .{ .sub_path = "zg.exe", .data = pe.testImage(&ia, true, 77) });
    try b.writeFile(io, .{ .sub_path = "zg.exe", .data = pe.testImage(&ib, false, 0) });
    try a.writeFile(io, .{ .sub_path = "SHA256SUMS", .data = "x\n" });
    try b.writeFile(io, .{ .sub_path = "SHA256SUMS", .data = "x\n" });
    try std.testing.expect(try compare(gpa, io, a, b) == null);

    try b.writeFile(io, .{ .sub_path = "SHA256SUMS", .data = "y\n" });
    const d = (try compare(gpa, io, a, b)).?;
    try std.testing.expectEqualStrings("SHA256SUMS", d.content.path);
    try std.testing.expectEqual(@as(u64, 0), d.content.offset);

    try a.writeFile(io, .{ .sub_path = "extra", .data = "" });
    try std.testing.expectEqualStrings("SHA256SUMS", (try compare(gpa, io, a, b)).?.content.path);
    try b.writeFile(io, .{ .sub_path = "SHA256SUMS", .data = "x\n" });
    try std.testing.expectEqualStrings("extra", (try compare(gpa, io, a, b)).?.only_in_a);
}
