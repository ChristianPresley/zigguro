//! Rewrites `testdata/golden/minimal_frag.{words,spvasm}`:
//! `zig run tools/spirv/regen_goldens.zig` from the repository root.

const std = @import("std");
const builder = @import("builder.zig");
const disasm = @import("disasm.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const words = try builder.minimalFrag(gpa);
    defer gpa.free(words);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try builder.hexDump(&out.writer, words);
    const dir = std.Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = "tools/spirv/testdata/golden/minimal_frag.words", .data = out.written() });
    out.clearRetainingCapacity();
    try disasm.disassemble(gpa, &out.writer, words);
    try dir.writeFile(io, .{ .sub_path = "tools/spirv/testdata/golden/minimal_frag.spvasm", .data = out.written() });
}
