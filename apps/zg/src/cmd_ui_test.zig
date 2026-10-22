//! `zg ui-test` (E04.F01.S03.T01): runs `.zgui` interaction scripts
//! headlessly against zg_gui's example views and checks their snapshots.
//!
//! A snapshot `snapshot layout "name"` is compared with
//! `<snapshots>/<name>.layout` (default `snapshots/` next to the script).
//! A missing file is written; a different one fails the script unless
//! `--update` is given. Exit 0 when every script passes, 1 when one fails,
//! 2 on a usage error.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");

const script = zg_gui.testing.script;
const Io = std.Io;

pub const usage =
    \\Usage: zg ui-test [--update] [--snapshots DIR] FILE.zgui...
    \\
    \\Runs .zgui scripts against the example views (Counter, Form, Dock)
    \\without a display. Snapshots are compared with DIR/<name>.<kind>
    \\(default: snapshots/ next to each script); missing ones are written.
    \\
    \\  --update          rewrite snapshots that differ
    \\  --snapshots DIR   where snapshots live
    \\
;

const Sink = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    update: bool,
    out: *Io.Writer,
    failed: u32 = 0,

    fn check(ctx: ?*anyopaque, kind: script.SnapshotKind, name: []const u8, text: []const u8) anyerror!void {
        const s: *Sink = @ptrCast(@alignCast(ctx.?));
        const file = try std.fmt.allocPrint(s.gpa, "{s}.{t}", .{ name, kind });
        defer s.gpa.free(file);
        const path = try std.fs.path.join(s.gpa, &.{ s.dir, file });
        defer s.gpa.free(path);
        const old = Io.Dir.cwd().readFileAlloc(s.io, path, s.gpa, .limited(16 << 20)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        };
        defer if (old) |o| s.gpa.free(o);
        if (old) |o| if (std.mem.eql(u8, o, text)) return;
        if (old != null and !s.update) {
            s.failed += 1;
            try s.out.print("  snapshot {s} differs", .{path});
            try firstDiff(s.out, old.?, text);
            return;
        }
        try Io.Dir.cwd().createDirPath(s.io, s.dir);
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = text });
        try s.out.print("  {s} {s}\n", .{ if (old == null) "wrote" else "updated", path });
    }
};

fn firstDiff(w: *Io.Writer, want: []const u8, got: []const u8) !void {
    var a = std.mem.splitScalar(u8, want, '\n');
    var b = std.mem.splitScalar(u8, got, '\n');
    var line: usize = 1;
    while (true) : (line += 1) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) break;
        if (x != null and y != null and std.mem.eql(u8, x.?, y.?)) continue;
        try w.print(" at line {d}:\n    want: {s}\n    got:  {s}\n", .{ line, x orelse "(end)", y orelse "(end)" });
        return;
    }
    try w.writeAll("\n");
}

/// Runs `zg ui-test <argv>`; returns the process exit code.
pub fn run(rt: *zg_core.Runtime, argv: []const [:0]const u8) !u8 {
    const gpa = rt.gpa;
    const io = rt.io;
    var out_buf: [4096]u8 = undefined;
    var out_w: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    var update = false;
    var snapshots: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(gpa);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            try out.writeAll(usage);
            return 0;
        } else if (std.mem.eql(u8, a, "--update")) {
            update = true;
        } else if (std.mem.eql(u8, a, "--snapshots")) {
            i += 1;
            if (i == argv.len) return usageError(out, "--snapshots needs a directory");
            snapshots = argv[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return usageError(out, a);
        } else try files.append(gpa, a);
    }
    if (files.items.len == 0) return usageError(out, "no script given");

    var failed: u32 = 0;
    for (files.items) |path| {
        const dir = snapshots orelse try std.fs.path.join(gpa, &.{ std.fs.path.dirname(path) orelse ".", "snapshots" });
        defer if (snapshots == null) gpa.free(dir);
        var sink: Sink = .{ .io = io, .gpa = gpa, .dir = dir, .update = update, .out = out };
        var diag: script.Diag = .{};
        try out.print("{s}\n", .{path});
        script.runFile(gpa, io, path, .{ .views = &zg_gui.testing.examples.views, .snapshot = .{ .ctx = &sink, .f = Sink.check } }, &diag) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                try out.print("  {s}:{s}\n", .{ path, diag.message() });
                failed += 1;
                continue;
            },
        };
        if (sink.failed > 0) failed += 1;
    }
    try out.print("{d} of {d} scripts passed\n", .{ files.items.len - failed, files.items.len });
    return if (failed > 0) 1 else 0;
}

fn usageError(out: *Io.Writer, what: []const u8) !u8 {
    try out.print("zg ui-test: {s}\n\n{s}", .{ what, usage });
    return 2;
}
