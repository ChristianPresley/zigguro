//! lspgen: generates the Zig LSP protocol types from the official meta
//! model.
//!
//!   lspgen <metaModel.json> <out.zig> [--since-max 3.18.0] [--include-proposed] [--check]
//!
//! With `--check`, nothing is written: the exit code is 1 when `<out.zig>`
//! differs from what would be generated (`zig build test` runs this so the
//! checked-in file never goes stale). See `emit.zig` for the mapping rules.

const std = @import("std");
const model = @import("model.zig");
const emit = @import("emit.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var positional: std.ArrayList([]const u8) = .empty;
    var opts: emit.Options = .{};
    var check = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--since-max")) {
            i += 1;
            if (i == args.len) return usage();
            opts.since_max = args[i];
        } else if (std.mem.eql(u8, a, "--include-proposed")) {
            opts.include_proposed = true;
        } else if (std.mem.eql(u8, a, "--check")) {
            check = true;
        } else try positional.append(arena, a);
    }
    if (positional.items.len != 2) return usage();
    const in_path = positional.items[0];
    const out_path = positional.items[1];
    opts.source_name = std.fs.path.basename(in_path);

    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, in_path, arena, .limited(64 << 20));
    const m = try model.parse(arena, bytes);
    const out = try emit.emit(arena, &m, opts);

    if (check) {
        const current = cwd.readFileAlloc(io, out_path, arena, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        if (!std.mem.eql(u8, current, out)) {
            std.log.err("{s} is out of date; run `zig build lspgen`", .{out_path});
            return 1;
        }
        return 0;
    }
    if (std.fs.path.dirname(out_path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out });
    return 0;
}

fn usage() u8 {
    std.log.err("usage: lspgen <metaModel.json> <out.zig> [--since-max X.Y.Z] [--include-proposed] [--check]", .{});
    return 2;
}

test {
    _ = model;
    _ = emit;
}

test "lspgen: generation is deterministic" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try model.parse(a, @embedFile("data/metaModel-3.18.json"));
    const one = try emit.emit(a, &m, .{ .source_name = "metaModel-3.18.json" });
    const two = try emit.emit(a, &m, .{ .source_name = "metaModel-3.18.json" });
    try std.testing.expectEqualStrings(one, two);
    // Every structure, enumeration and alias is emitted.
    for (m.structures) |s| try expectDecl(one, s.name);
    for (m.enumerations) |x| try expectDecl(one, x.name);
    for (m.type_aliases) |x| try expectDecl(one, x.name);
    // The 3.17 model generates too.
    const m17 = try model.parse(a, @embedFile("data/metaModel-3.17.json"));
    _ = try emit.emit(a, &m17, .{});
}

fn expectDecl(src: []const u8, name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const needle = try std.fmt.bufPrint(&buf, "pub const {s} =", .{name});
    if (std.mem.indexOf(u8, src, needle) == null) {
        std.debug.print("missing declaration {s}\n", .{name});
        return error.TestUnexpectedResult;
    }
}
