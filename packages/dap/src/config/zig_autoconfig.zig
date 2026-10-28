//! Debug configurations for a Zig project with none written
//! (E07.F06.S01.T04), from its `zig build -l` steps and the executables
//! in `zig-out/bin`:
//! - "Debug zig build run": `zig build` first, then the program (one
//!   configuration per executable when there are several, so the picker
//!   asks; the project's name when nothing is built yet);
//! - "Debug tests in current file": a generated task builds the active
//!   file's tests without running them (`zig test ${file}
//!   --test-no-exec -femit-bin=...`), then that binary is debugged.
//! The adapter is the first available of lldb-dap, gdb and CodeLLDB.
//! Nothing is written to disk.

const std = @import("std");
const LaunchConfig = @import("LaunchConfig.zig");
const Registry = @import("../adapters/Registry.zig");
const zig_build = @import("../tasks/sources/zig_build.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The adapters tried, in order.
pub const preference = [_][]const u8{ "lldb-dap", "gdb", "codelldb" };

pub const build_task = "zig build";
pub const test_task = "zig test (build for debugging)";

pub const Options = struct {
    /// Where the test binary goes (the workspace's state folder).
    state_dir: []const u8,
    zig_exe: []const u8 = "zig",
    os: std.Target.Os.Tag = @import("builtin").os.tag,
};

/// The configurations for the project at `build_root` with `adapter`
/// (a type name). `exes` are the file names in `zig-out/bin`. Allocated
/// in `a`.
pub fn configs(a: Allocator, build_root: []const u8, steps: []const zig_build.Step, exes: []const []const u8, adapter: []const u8, o: Options) Allocator.Error![]LaunchConfig {
    var out: std.ArrayList(LaunchConfig) = .empty;
    const has_install = for (steps) |s| {
        if (std.mem.eql(u8, s.name, "install")) break true;
    } else false;
    if (has_install) {
        const programs: []const []const u8 = if (exes.len > 0) exes else &.{try guessName(a, build_root, o.os)};
        for (programs) |exe| {
            var args: std.json.ObjectMap = .empty;
            try args.put(a, "program", .{ .string = try std.mem.concat(a, u8, &.{ "${workspaceFolder}/zig-out/bin/", exe }) });
            try args.put(a, "args", .{ .array = .init(a) });
            try args.put(a, "cwd", .{ .string = "${workspaceFolder}" });
            try out.append(a, .{
                .name = if (programs.len == 1) "Debug zig build run" else try std.fmt.allocPrint(a, "Debug zig build run ({s})", .{exe}),
                .type = adapter,
                .request = .launch,
                .args = args,
                .pre_launch_task = build_task,
                .source = .auto,
            });
        }
    }
    {
        const bin = try std.fs.path.join(a, &.{ o.state_dir, "debug", if (o.os == .windows) "tests.exe" else "tests" });
        var args: std.json.ObjectMap = .empty;
        try args.put(a, "program", .{ .string = bin });
        try args.put(a, "args", .{ .array = .init(a) });
        try args.put(a, "cwd", .{ .string = "${workspaceFolder}" });
        const emit = try std.mem.concat(a, u8, &.{ "-femit-bin=", bin });
        try out.append(a, .{
            .name = "Debug tests in current file",
            .type = adapter,
            .request = .launch,
            .args = args,
            .pre_launch_task = test_task,
            .source = .auto,
            .generated_task = .{
                .label = test_task,
                .command = o.zig_exe,
                .args = try a.dupe([]const u8, &.{ "test", "${file}", "--test-no-exec", emit }),
                .cwd = "${workspaceFolder}",
            },
        });
    }
    return out.items;
}

/// The executable a project of this folder name would install.
fn guessName(a: Allocator, build_root: []const u8, os: std.Target.Os.Tag) Allocator.Error![]const u8 {
    const base = std.fs.path.basename(build_root);
    return if (os == .windows) std.mem.concat(a, u8, &.{ base, ".exe" }) else a.dupe(u8, base);
}

/// The file names in `<build_root>/zig-out/bin` that look runnable
/// (`.exe` on Windows; not `.pdb`, `.dll`, `.so`, `.a`, `.lib`).
/// Sorted. Worker only.
pub fn listExecutables(a: Allocator, io: Io, build_root: []const u8, os: std.Target.Os.Tag) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const path = try std.fs.path.join(a, &.{ build_root, "zig-out", "bin" });
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        const ext = std.fs.path.extension(e.name);
        const runnable = if (os == .windows) std.ascii.eqlIgnoreCase(ext, ".exe") else for ([_][]const u8{ ".pdb", ".dll", ".so", ".a", ".lib", ".dylib", ".o" }) |x| {
            if (std.mem.eql(u8, ext, x)) break false;
        } else true;
        if (runnable) try out.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    return out.items;
}

/// The configurations for the project at `build_root`, with the first
/// available adapter; empty when none is. Worker only (reads
/// `zig-out/bin`, resolves adapters).
pub fn autoConfigsForZig(a: Allocator, io: Io, build_root: []const u8, steps: []const zig_build.Step, reg: *Registry, env: *const std.process.Environ.Map, o: Options) Allocator.Error![]LaunchConfig {
    const def = (try reg.firstAvailable(io, env, &preference)) orelse return &.{};
    const exes = try listExecutables(a, io, build_root, o.os);
    return configs(a, build_root, steps, exes, def.type, o);
}
