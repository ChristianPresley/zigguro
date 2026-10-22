//! Split debug symbols for release builds (E17.F01.S01.T02).
//!
//! - ELF: `zg-release split-debug` strips the DWARF sections and links the
//!   unstripped binary as `<name>.debug` through `.gnu_debuglink`, because
//!   `zig objcopy` cannot strip ELF in Zig 0.16. The SHA-1 build-id
//!   (`addApp`) matches the two.
//! - PE: the binary already carries no DWARF; its PDB is the symbol file,
//!   matched through the CodeView GUID and age.

const std = @import("std");

/// A binary ready to ship and its symbol file.
pub const Split = struct {
    /// The binary to ship, named like the executable.
    stripped: std.Build.LazyPath,
    /// The symbol file, or null when the format has none.
    symbols: ?std.Build.LazyPath,
    /// File names of the two, e.g. `zigguro` and `zigguro.debug`.
    name: []const u8,
    symbols_name: []const u8,
};

/// Splits the debug info of `exe` with `tool` (zg-release).
pub fn splitDebug(b: *std.Build, tool: *std.Build.Step.Compile, exe: *std.Build.Step.Compile) Split {
    const t = exe.rootModuleTarget();
    const name = exe.out_filename;
    switch (t.ofmt) {
        .elf => {
            const run = b.addRunArtifact(tool);
            run.addArg("split-debug");
            run.addArg("--in");
            run.addArtifactArg(exe);
            run.addArg("--out");
            const stripped = run.addOutputFileArg(name);
            run.addArg("--debug");
            const symbols_name = b.fmt("{s}.debug", .{name});
            const debug = run.addOutputFileArg(symbols_name);
            return .{ .stripped = stripped, .symbols = debug, .name = name, .symbols_name = symbols_name };
        },
        // A stripped PE has no PDB (the setup exe is ReleaseSmall, stripped).
        .coff => if (exe.root_module.strip == true) {
            return .{ .stripped = exe.getEmittedBin(), .symbols = null, .name = name, .symbols_name = "" };
        } else return .{ .stripped = exe.getEmittedBin(), .symbols = exe.getEmittedPdb(), .name = name, .symbols_name = b.fmt("{s}.pdb", .{exe.name}) },
        else => return .{ .stripped = exe.getEmittedBin(), .symbols = null, .name = name, .symbols_name = "" },
    }
}

/// Installs the shipped binary into `dist_dir` and its symbols into
/// `symbols_dir` (both under the install prefix), as dependencies of `step`.
pub fn install(b: *std.Build, s: Split, dist_dir: []const u8, symbols_dir: []const u8, step: *std.Build.Step) void {
    step.dependOn(&b.addInstallFileWithDir(s.stripped, .{ .custom = dist_dir }, s.name).step);
    if (s.symbols) |sym| step.dependOn(&b.addInstallFileWithDir(sym, .{ .custom = symbols_dir }, s.symbols_name).step);
}
