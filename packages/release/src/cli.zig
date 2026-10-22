//! `--version` handling shared by every zigguro binary. It runs before any
//! runtime init: no heap allocator (a stack buffer on Windows, where argv
//! needs decoding) and the process-global single-threaded `Io`.

const std = @import("std");
const BuildInfo = @import("build_info.zig").BuildInfo;

/// True when `arg` asks for the version (`--version` or `-V`).
pub fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V");
}

/// When `argv[1]` is a version flag, prints `bi.writeLine(name)` to stdout
/// and returns true; the caller then exits 0. Returns false otherwise, or
/// when the arguments cannot be decoded into the stack buffer.
pub fn handleVersionFlag(min: std.process.Init.Minimal, bi: *const BuildInfo, name: []const u8) bool {
    var arg_buf: [8192]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&arg_buf);
    var it = min.args.iterateAllocator(fba.allocator()) catch return false;
    defer it.deinit();
    _ = it.skip();
    const first = it.next() orelse return false;
    if (!isVersionFlag(first)) return false;

    const io = std.Io.Threaded.global_single_threaded.io();
    var buf: [256]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), io, &buf);
    bi.writeLine(&out.interface, name) catch {};
    out.interface.flush() catch {};
    return true;
}

test "cli: version flags" {
    try std.testing.expect(isVersionFlag("--version"));
    try std.testing.expect(isVersionFlag("-V"));
    try std.testing.expect(!isVersionFlag("--versions"));
    try std.testing.expect(!isVersionFlag("-v"));
}
