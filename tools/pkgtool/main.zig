//! pkgtool: repository package tool.
//!
//!   pkgtool check-layers --root <repo>
//!   pkgtool new --root <repo> [--zig <zig exe>] --name zg_demo --dir demo --layer 4
//!
//! Exit codes: 0 clean, 1 violations or failure, 2 usage error.

const std = @import("std");
const layers = @import("layers.zig");
const scaffold = @import("scaffold.zig");

const usage =
    \\usage: pkgtool check-layers --root <repo>
    \\       pkgtool new --root <repo> [--zig <exe>] --name <zg_name> --dir <dir> --layer <1-5>
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw: std.Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;
    defer stderr.flush() catch {};

    if (args.len < 2) {
        try stderr.writeAll(usage);
        return 2;
    }
    var root_path: ?[]const u8 = null;
    var zig_exe: ?[]const u8 = null;
    var name: []const u8 = "";
    var dir: []const u8 = "";
    var layer: u8 = 255;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (i + 1 >= args.len) {
            try stderr.print("missing value for {s}\n{s}", .{ a, usage });
            return 2;
        }
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--root")) {
            root_path = v;
        } else if (std.mem.eql(u8, a, "--zig")) {
            zig_exe = v;
        } else if (std.mem.eql(u8, a, "--name")) {
            name = v;
        } else if (std.mem.eql(u8, a, "--dir")) {
            dir = v;
        } else if (std.mem.eql(u8, a, "--layer")) {
            layer = std.fmt.parseInt(u8, v, 10) catch 255;
        } else {
            try stderr.print("unknown argument {s}\n{s}", .{ a, usage });
            return 2;
        }
    }
    var root = std.Io.Dir.cwd().openDir(io, root_path orelse ".", .{}) catch |err| {
        try stderr.print("cannot open repo root: {t}\n", .{err});
        return 1;
    };
    defer root.close(io);

    if (std.mem.eql(u8, args[1], "check-layers")) {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const violations = layers.check(arena.allocator(), io, root) catch |err| {
            try stderr.print("check-layers failed: {t}\n", .{err});
            return 1;
        };
        const src = try root.readFileAllocOptions(io, "tools/pkgtool/layers.zon", arena.allocator(), .limited(1 << 20), .of(u8), 0);
        var table = try layers.Layers.parse(arena.allocator(), src);
        for (violations) |v| try layers.format(v, &table, stderr);
        return if (violations.len == 0) 0 else 1;
    } else if (std.mem.eql(u8, args[1], "new")) {
        scaffold.newPackage(gpa, io, root, name, dir, layer, zig_exe) catch |err| {
            try stderr.print("new-package failed: {t}\n{s}", .{ err, usage });
            return if (err == error.BadName or err == error.BadDir or err == error.BadLayer) 2 else 1;
        };
        try stderr.print("created packages/{s} ({s}, layer {d})\n", .{ dir, name, layer });
        return 0;
    }
    try stderr.writeAll(usage);
    return 2;
}

test {
    _ = @import("zon.zig");
    _ = layers;
    _ = scaffold;
}
