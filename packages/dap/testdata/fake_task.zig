//! `fake_task`: a scripted task process for the task runner tests (built
//! only by the test step). Arguments run in order:
//!
//! ```
//! fake_task [--out <line>] [--err <line>] [--sleep-ms <n>] [--child]
//!           [--env <name>] [--cwd] [--args] [--exit <code>] ...
//! ```
//!
//! - `--out`/`--err`: write the line (and a newline) to stdout/stderr at
//!   once (no buffering), so tests see the order lines were written in.
//! - `--child`: start `fake_task --sleep-ms 60000` in the same process
//!   group and print `child <pid>`.
//! - `--env <name>`: print `<name>=<value>` (empty when unset).
//! - `--cwd`: print the working directory.
//! - `--args`: print every remaining argument on its own line, then stop.
//! - `--exit <code>`: exit now with `code`.
//! - `build ...` (as the first argument): a stand-in for `zig build`
//!   that prints its arguments, one per line.

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "build")) {
        for (argv[1..]) |a| try stdout.writeStreamingAll(io, try std.fmt.allocPrint(arena, "{s}\n", .{a}));
        return 0;
    }
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--out") or std.mem.eql(u8, a, "--err")) {
            i += 1;
            const f = if (a[2] == 'o') stdout else stderr;
            try f.writeStreamingAll(io, try std.fmt.allocPrint(arena, "{s}\n", .{argv[i]}));
        } else if (std.mem.eql(u8, a, "--sleep-ms")) {
            i += 1;
            try io.sleep(.fromMilliseconds(try std.fmt.parseInt(i64, argv[i], 10)), .awake);
        } else if (std.mem.eql(u8, a, "--exit")) {
            return try std.fmt.parseInt(u8, argv[i + 1], 10);
        } else if (std.mem.eql(u8, a, "--child")) {
            const child = try std.process.spawn(io, .{
                .argv = &.{ argv[0], "--sleep-ms", "60000" },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
            // The test checks the pid on POSIX only.
            const n: i64 = if (builtin.os.tag == .windows) 0 else child.id.?;
            try stdout.writeStreamingAll(io, try std.fmt.allocPrint(arena, "child {d}\n", .{n}));
        } else if (std.mem.eql(u8, a, "--env")) {
            i += 1;
            const v = init.environ_map.get(argv[i]) orelse "";
            try stdout.writeStreamingAll(io, try std.fmt.allocPrint(arena, "{s}={s}\n", .{ argv[i], v }));
        } else if (std.mem.eql(u8, a, "--cwd")) {
            const cwd = try std.process.currentPathAlloc(io, arena);
            try stdout.writeStreamingAll(io, try std.fmt.allocPrint(arena, "{s}\n", .{cwd}));
        } else if (std.mem.eql(u8, a, "--args")) {
            for (argv[i + 1 ..]) |rest| try stdout.writeStreamingAll(io, try std.fmt.allocPrint(arena, "{s}\n", .{rest}));
            return 0;
        } else {
            std.debug.print("fake_task: unknown argument {s}\n", .{a});
            return 2;
        }
    }
    return 0;
}
