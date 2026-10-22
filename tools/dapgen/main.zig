//! dapgen: generates the Zig Debug Adapter Protocol types from the
//! official JSON schema.
//!
//!   dapgen <debugAdapterProtocol.json> <out.zig> [--check]
//!
//! With `--check`, nothing is written: the exit code is 1 when `<out.zig>`
//! differs from what would be generated (`zig build test` runs this). See
//! `emit.zig` for the mapping rules.

const std = @import("std");
const schema = @import("schema.zig");
const emit = @import("emit.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var positional: std.ArrayList([]const u8) = .empty;
    var check = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--check")) check = true else try positional.append(arena, a);
    }
    if (positional.items.len != 2) {
        std.log.err("usage: dapgen <debugAdapterProtocol.json> <out.zig> [--check]", .{});
        return 2;
    }
    const in_path = positional.items[0];
    const out_path = positional.items[1];
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, in_path, arena, .limited(64 << 20));
    const doc = try schema.parse(arena, bytes);
    const out = try emit.emit(arena, &doc, bytes, .{ .source_name = std.fs.path.basename(in_path) });
    if (check) {
        const current = cwd.readFileAlloc(io, out_path, arena, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        if (!std.mem.eql(u8, current, out)) {
            std.log.err("{s} is out of date; run `zig build dapgen`", .{out_path});
            return 1;
        }
        return 0;
    }
    if (std.fs.path.dirname(out_path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out });
    return 0;
}

test {
    _ = schema;
    _ = emit;
}

test "dapgen: generation is deterministic and complete" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = @embedFile("data/debugAdapterProtocol.json");
    const doc = try schema.parse(a, bytes);
    const one = try emit.emit(a, &doc, bytes, .{});
    const two = try emit.emit(a, &doc, bytes, .{});
    try std.testing.expectEqualStrings(one, two);
    var buf: [256]u8 = undefined;
    for (doc.definitions) |d| {
        const needle = try std.fmt.bufPrint(&buf, "pub const {s} =", .{d.name});
        if (std.mem.indexOf(u8, one, needle) == null) {
            std.debug.print("missing declaration {s}\n", .{d.name});
            return error.TestUnexpectedResult;
        }
    }
}
