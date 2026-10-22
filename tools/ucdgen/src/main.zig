//! ucdgen: turns the vendored UCD text files into compact lookup tables.
//!
//!   ucdgen --version 18.0.0 --manifest <manifest.zon> <file>... <out-dir>
//!       Files are given in `tables.files` order. Each is checked against its
//!       SHA-256 in the manifest; writes <out-dir>/ucd.bin and ucd_tables.zig.
//!   ucdgen enums <PropertyValueAliases.txt>
//!       Prints the enum block of src/enums.zig.

const std = @import("std");
const tables = @import("tables.zig");
const emit = @import("emit.zig");
const enums_gen = @import("enums_gen.zig");
const lib = @import("lib.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const cwd = std.Io.Dir.cwd();

    if (args.len == 3 and std.mem.eql(u8, args[1], "enums")) {
        const pva = try cwd.readFileAlloc(io, args[2], arena, .limited(1 << 20));
        var buf: [4096]u8 = undefined;
        var fw = std.Io.File.stdout().writer(io, &buf);
        try enums_gen.write(arena, &fw.interface, pva);
        try fw.interface.flush();
        return 0;
    }

    if (args.len != 5 + tables.files.len + 1 or !std.mem.eql(u8, args[1], "--version") or !std.mem.eql(u8, args[3], "--manifest")) {
        std.debug.print("usage: ucdgen --version <v> --manifest <manifest.zon> <{d} UCD files> <out-dir>\n       ucdgen enums <PropertyValueAliases.txt>\n", .{tables.files.len});
        return 2;
    }
    const version = args[2];
    const manifest_src = try cwd.readFileAllocOptions(io, args[4], arena, .limited(1 << 20), .of(u8), 0);
    const manifest = std.zon.parse.fromSliceAlloc([]const lib.ManifestEntry, arena, manifest_src, null, .{}) catch {
        std.debug.print("ucdgen: cannot parse manifest {s}\n", .{args[4]});
        return 1;
    };

    var inputs: tables.Inputs = undefined;
    for (tables.files, 0..) |rel, i| {
        const path = args[5 + i];
        if (!std.mem.endsWith(u8, path, rel)) {
            std.debug.print("ucdgen: argument {d} should be {s}, got {s}\n", .{ i + 1, rel, path });
            return 2;
        }
        inputs[i] = try cwd.readFileAlloc(io, path, arena, .limited(64 << 20));
    }
    var vd: lib.VerifyDiag = .{};
    lib.verifyInputs(manifest, &inputs, &vd) catch |err| {
        switch (err) {
            error.NotInManifest => std.debug.print("ucdgen: {s} is not listed in the manifest\n", .{vd.file}),
            error.ChecksumMismatch => std.debug.print("ucdgen: checksum mismatch for {s}: manifest {s}, file {s}\n", .{ vd.file, &vd.want, &vd.got }),
        }
        return 1;
    };

    var diag: tables.Diag = .{};
    tables.checkAliases(inputs[tables.fileIndex("PropertyValueAliases.txt")], &diag) catch |err| return report(err, diag);
    var ucd = tables.build(gpa, &inputs, &diag) catch |err| return report(err, diag);
    defer ucd.deinit();
    const blob = try emit.buildBlob(arena, &ucd);

    var out = try cwd.createDirPathOpen(io, args[args.len - 1], .{});
    defer out.close(io);
    try out.writeFile(io, .{ .sub_path = "ucd.bin", .data = blob.bytes.items });
    var zig_src: std.Io.Writer.Allocating = .init(arena);
    try emit.writeZig(&zig_src.writer, version, &blob);
    try out.writeFile(io, .{ .sub_path = "ucd_tables.zig", .data = zig_src.written() });
    return 0;
}

fn report(err: anyerror, diag: tables.Diag) u8 {
    if (err == error.UnknownPropertyValue) {
        std.debug.print("ucdgen: {s}:{d}: unknown property value {s} for enum {s}; extend it in tools/ucdgen/src/enums.zig (ucdgen enums)\n", .{ diag.file, diag.line, diag.value, diag.enum_name });
    } else std.debug.print("ucdgen: {t}\n", .{err});
    return 1;
}

test {
    _ = @import("parse.zig");
    _ = @import("tables.zig");
    _ = @import("emit.zig");
    _ = @import("enums_gen.zig");
    _ = @import("lib.zig");
}
