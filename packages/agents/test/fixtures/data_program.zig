//! A stand-in analysis program for data_run_program's process tests
//! (E13.F06.S02.T02). The first argument picks what it does:
//!
//! - `write`: writes `out.csv` and `notes.md` into `$ZIGGURO_OUTPUT_DIR`,
//!   prints to stdout and stderr, exits 0.
//! - `args …`: prints each later argument on its own line, exits 7.
//! - `spawn-sleep <pidfile>`: starts a grandchild (this program with
//!   `sleep`), writes the grandchild's pid to `<pidfile>`, then sleeps.
//! - `sleep`: sleeps forever.
//! - `spam <n>`: prints n numbered lines.

const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    const self_path = args.next() orelse return 2;
    const mode = args.next() orelse return 2;
    const out = Io.File.stdout();
    if (std.mem.eql(u8, mode, "write")) {
        const dir_path = init.environ_map.get("ZIGGURO_OUTPUT_DIR") orelse return 3;
        var dir = try Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        try dir.writeFile(io, .{ .sub_path = "out.csv", .data = "city,total\nOslo,3\nLima,5\n" });
        try dir.writeFile(io, .{ .sub_path = "notes.md", .data = "# Notes\n" });
        try out.writeStreamingAll(io, "wrote 2 files\n");
        try Io.File.stderr().writeStreamingAll(io, "a warning\n");
        return 0;
    }
    if (std.mem.eql(u8, mode, "args")) {
        while (args.next()) |a| {
            try out.writeStreamingAll(io, a);
            try out.writeStreamingAll(io, "\n");
        }
        return 7;
    }
    if (std.mem.eql(u8, mode, "spawn-sleep")) {
        const pidfile = args.next() orelse return 2;
        const child = try std.process.spawn(io, .{ .argv = &.{ self_path, "sleep" }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{child.id.?});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = pidfile, .data = text });
        while (true) try io.sleep(.fromSeconds(3600), .awake);
    }
    if (std.mem.eql(u8, mode, "sleep")) {
        while (true) try io.sleep(.fromSeconds(3600), .awake);
    }
    if (std.mem.eql(u8, mode, "spam")) {
        const n = try std.fmt.parseInt(usize, args.next() orelse "0", 10);
        var buf: [64]u8 = undefined;
        for (0..n) |i| try out.writeStreamingAll(io, try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
        return 0;
    }
    return 2;
}
