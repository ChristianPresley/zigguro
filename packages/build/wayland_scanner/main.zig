//! wayland_scanner: generates typed Zig encoders and decoders from Wayland
//! protocol XML.
//!
//!   wayland_scanner --out <file.zig> <proto.xml>...
//!
//! All protocols go into one file so that interfaces can refer to each
//! other. Output depends only on the inputs, so the build cache keys on
//! their contents. Lives in zg_build (build-time only) so that package
//! build scripts can run it; `zig build test-tools` runs its tests.

const std = @import("std");
const model = @import("model.zig");
const emit = @import("emit.zig");

/// Parses `sources` (path and contents pairs) and returns the generated
/// source, allocated in `arena`.
pub fn generate(arena: std.mem.Allocator, paths: []const []const u8, contents: []const []const u8) ![]u8 {
    const protos = try arena.alloc(model.Protocol, contents.len);
    for (contents, paths, protos) |c, p, *out| {
        var d: model.Diagnostic = .{};
        out.* = model.parse(arena, c, &d) catch |err| {
            std.debug.print("{s}:{d}:{d}: {s} ({s})\n", .{ p, d.line, d.col, d.message, @errorName(err) });
            return err;
        };
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    try emit.emit(arena, &out.writer, protos, paths);
    return out.written();
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var out_path: ?[]const u8 = null;
    var inputs: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            i += 1;
            out_path = args[i];
        } else try inputs.append(arena, args[i]);
    }
    const out = out_path orelse {
        std.debug.print("usage: wayland_scanner --out <file.zig> <proto.xml>...\n", .{});
        return 2;
    };
    const cwd = std.Io.Dir.cwd();
    const contents = try arena.alloc([]const u8, inputs.items.len);
    for (inputs.items, contents) |p, *c| c.* = try cwd.readFileAlloc(io, p, arena, .limited(8 << 20));
    const text = try generate(arena, inputs.items, contents);
    try cwd.writeFile(io, .{ .sub_path = out, .data = text });
    return 0;
}

const testing = std.testing;

test "emit is deterministic and matches the golden file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xml = @embedFile("testdata/mini.xml");
    const one = try generate(a, &.{"mini.xml"}, &.{xml});
    const two = try generate(a, &.{"mini.xml"}, &.{xml});
    try testing.expectEqualStrings(one, two);
    try testing.expectEqualStrings(@embedFile("testdata/mini.zig"), one);
}

test "the generated golden code compiles" {
    _ = @import("testdata/mini.zig");
}

test {
    _ = @import("xml.zig");
    _ = @import("model.zig");
}
