//! spirv-dis: prints our disassembly of a SPIR-V file (E02.F05.S01.T04).
//!
//!   spirv-dis [--dir <dir>] <file.spv | shader name>...
//!
//! A bare shader name such as `prim_frag` is looked up as
//! `<dir>/<name>.spv` (`zig build spirv-dis -- <name>` passes the
//! generated shader directory).

const std = @import("std");
const disasm = @import("disasm.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var dir: []const u8 = ".";
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    var i: usize = 1;
    var any = false;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir") and i + 1 < args.len) {
            i += 1;
            dir = args[i];
            continue;
        }
        any = true;
        const path = if (std.mem.endsWith(u8, args[i], ".spv")) args[i] else try std.fmt.allocPrint(arena, "{s}/{s}.spv", .{ dir, args[i] });
        const bytes = try std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(16 << 20), .of(u32), null);
        if (bytes.len % 4 != 0) {
            std.log.err("{s}: size is not a multiple of 4", .{path});
            return 1;
        }
        disasm.disassemble(arena, w, std.mem.bytesAsSlice(u32, bytes)) catch |err| {
            try w.flush();
            std.log.err("{s}: {t}", .{ path, err });
            return 1;
        };
    }
    try w.flush();
    if (!any) {
        std.log.err("usage: spirv-dis [--dir <dir>] <file.spv | name>...", .{});
        return 2;
    }
    return 0;
}

test {
    _ = disasm;
}
