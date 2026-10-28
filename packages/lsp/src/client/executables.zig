//! Finding tool executables on PATH and probing their versions, shared by
//! the language server registry (zg_codeintel) and the debug adapter
//! registry (zg_dap). PATHEXT is honoured on Windows; nothing runs except
//! the version probe, which has a deadline.

const std = @import("std");
const zg_core = @import("zg_core");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The executable `name` resolves to: searched on `PATH` (and `PATHEXT` on
/// Windows) from `env`; an absolute or relative name with a separator is
/// used as is when it exists. Null when not found. Allocated in `a`.
pub fn find(io: Io, a: Allocator, os: std.Target.Os.Tag, name: []const u8, env: *const std.process.Environ.Map) Allocator.Error!?[]const u8 {
    if (name.len == 0) return null;
    const windows = os == .windows;
    // Windows runs an extensionless file only by its spelled-out name.
    const exts: []const []const u8 = if (windows) try pathExts(a, env.get("PATHEXT"), std.fs.path.extension(name).len > 0) else &.{""};
    const has_sep = std.mem.indexOfScalar(u8, name, '/') != null or (windows and std.mem.indexOfScalar(u8, name, '\\') != null);
    if (has_sep) return firstExisting(io, a, os, &.{""}, name, exts);
    const path_var = env.get("PATH") orelse env.get("Path") orelse return null;
    var it = std.mem.tokenizeScalar(u8, path_var, if (windows) ';' else ':');
    while (it.next()) |dir| {
        if (try firstExisting(io, a, os, &.{dir}, name, exts)) |p| return p;
    }
    return null;
}

fn firstExisting(io: Io, a: Allocator, os: std.Target.Os.Tag, dirs: []const []const u8, name: []const u8, exts: []const []const u8) Allocator.Error!?[]const u8 {
    const windows = os == .windows;
    for (dirs) |dir| for (exts) |ext| {
        // A name that already ends in one of the extensions is tried as is.
        const full = if (dir.len == 0)
            try std.mem.concat(a, u8, &.{ name, ext })
        else
            try std.mem.concat(a, u8, &.{ dir, if (windows) "\\" else "/", name, ext });
        const ok = if (windows)
            Io.Dir.cwd().access(io, full, .{}) catch null
        else
            Io.Dir.cwd().access(io, full, .{ .execute = true }) catch null;
        if (ok) |_| {
            const st = Io.Dir.cwd().statFile(io, full, .{}) catch continue;
            if (st.kind == .directory) continue;
            return full;
        }
    };
    return null;
}

/// `PATHEXT` as lowercase extensions, the bare name first when it already
/// has an extension.
fn pathExts(a: Allocator, pathext: ?[]const u8, bare: bool) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (bare) try out.append(a, "");
    var it = std.mem.tokenizeScalar(u8, pathext orelse ".COM;.EXE;.BAT;.CMD", ';');
    while (it.next()) |e| try out.append(a, try std.ascii.allocLowerString(a, e));
    return out.items;
}

/// Runs `argv` (argv[0] already resolved) and returns the first non-empty
/// line of its standard output, or null when it cannot start or prints
/// nothing within `timeout` (the process is then killed). The result is
/// `gpa`'s. Worker only.
pub fn probeFirstLine(io: Io, gpa: Allocator, argv: []const []const u8, env: *const std.process.Environ.Map, timeout: Io.Duration) Allocator.Error!?[]u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch return null;
    // The read runs in its own task and the deadline is a plain wait:
    // blocking pipe reads are not cancelable on Windows, so a timeout kills
    // the process, which ends the read.
    var rd: FirstLine = .{};
    var task = io.concurrent(FirstLine.run, .{ &rd, io, child.stdout.? }) catch {
        child.kill(io);
        return null;
    };
    const timed_out = if (rd.done.waitTimeout(io, zg_core.runtime.Deadline.after(io, timeout).timeout())) false else |_| true;
    if (@import("builtin").os.tag == .windows)
        _ = std.os.windows.ntdll.NtTerminateProcess(child.id.?, @enumFromInt(1))
    else
        std.posix.kill(child.id.?, .KILL) catch {};
    task.await(io);
    _ = child.wait(io) catch {};
    if (timed_out) return null;
    var lines = std.mem.tokenizeAny(u8, rd.buf[0..rd.n], "\r\n");
    const line = std.mem.trim(u8, lines.next() orelse return null, " \t");
    if (line.len == 0) return null;
    return try gpa.dupe(u8, line);
}

/// The start of a probed process's output.
const FirstLine = struct {
    buf: [512]u8 = undefined,
    n: usize = 0,
    done: Io.Event = .unset,

    /// Reads until a line ends, end of input, or `buf` is full.
    fn run(f: *FirstLine, io: Io, file: Io.File) void {
        defer f.done.set(io);
        while (f.n < f.buf.len) {
            const got = file.readStreaming(io, &.{f.buf[f.n..]}) catch break;
            if (got == 0) break;
            f.n += got;
            const text = std.mem.trimStart(u8, f.buf[0..f.n], " \t\r\n");
            if (std.mem.indexOfScalar(u8, text, '\n') != null) break;
        }
    }
};

/// The first `major.minor[.patch]` in `text` ("GNU gdb (GDB) 14.2",
/// "lldb version 18.1.8"), with a missing patch as 0.
pub fn parseVersion(text: []const u8) ?std.SemanticVersion {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!std.ascii.isDigit(text[i])) continue;
        if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '.')) {
            // "v1.8" is a version; "x86_64" is not.
            const v_prefix = text[i - 1] == 'v' and (i < 2 or !std.ascii.isAlphanumeric(text[i - 2]));
            if (!v_prefix) continue;
        }
        var nums: [3]usize = .{ 0, 0, 0 };
        var n: usize = 0;
        var j = i;
        while (n < 3) {
            const start = j;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            if (j == start) break;
            nums[n] = std.fmt.parseInt(usize, text[start..j], 10) catch break;
            n += 1;
            if (j < text.len and text[j] == '.' and j + 1 < text.len and std.ascii.isDigit(text[j + 1])) j += 1 else break;
        }
        if (n >= 2) return .{ .major = nums[0], .minor = nums[1], .patch = nums[2] };
        i = j;
    }
    return null;
}

test "executables: version text" {
    const t = std.testing;
    try t.expectEqual(std.SemanticVersion{ .major = 14, .minor = 2, .patch = 0 }, parseVersion("GNU gdb (GDB) 14.2").?);
    try t.expectEqual(std.SemanticVersion{ .major = 18, .minor = 1, .patch = 8 }, parseVersion("lldb version 18.1.8").?);
    try t.expectEqual(std.SemanticVersion{ .major = 12, .minor = 1, .patch = 0 }, parseVersion("GNU gdb (Ubuntu 12.1-0ubuntu1~22.04) 12.1").?);
    try t.expectEqual(std.SemanticVersion{ .major = 1, .minor = 8, .patch = 0 }, parseVersion("debugpy v1.8.0").?);
    try t.expect(parseVersion("x86_64 build 7") == null);
}
