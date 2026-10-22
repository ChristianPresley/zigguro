//! zg-transcript: turns LSP client traces (`lsp.trace = "verbose"`, the
//! NDJSON lines `Trace.dump` writes) into regression tests for
//! `fake_lsp_server`.
//!
//!   zg-transcript normalize <trace> [--workspace <path>] [-o <out>]
//!   zg-transcript to-script <trace> [--workspace <path>] [-o <script>]
//!   zg-transcript diff <a> <b> [--workspace <path>]
//!
//! `normalize` renumbers ids from 1, drops timestamps and replaces the
//! workspace root (by default the `initialize` rootUri) with
//! `${workspace}`. `to-script` writes a script the fake server replays.
//! `diff` compares two normalized traces and exits 1 when they differ.
//! Exit status 2 means bad usage or an unreadable trace.

const std = @import("std");
const transcript = @import("zg_transcript");

const usage =
    \\usage: zg-transcript normalize <trace> [--workspace <path>] [-o <out>]
    \\       zg-transcript to-script <trace> [--workspace <path>] [-o <script>]
    \\       zg-transcript diff <a> <b> [--workspace <path>]
    \\
;

const Command = enum { normalize, @"to-script", diff };

const Args = struct {
    cmd: Command,
    inputs: [2]?[]const u8 = .{ null, null },
    workspace: ?[]const u8 = null,
    out: ?[]const u8 = null,
};

/// Parses the command line (without the program name).
pub fn parseArgs(args: []const []const u8) ?Args {
    if (args.len == 0) return null;
    var a: Args = .{ .cmd = std.meta.stringToEnum(Command, args[0]) orelse return null };
    var n: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--workspace") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i == args.len) return null;
            if (arg[1] == 'o') a.out = args[i] else a.workspace = args[i];
        } else if (n < a.inputs.len and !std.mem.startsWith(u8, arg, "-")) {
            a.inputs[n] = arg;
            n += 1;
        } else return null;
    }
    const want: usize = if (a.cmd == .diff) 2 else 1;
    if (n != want or (a.cmd == .diff and a.out != null)) return null;
    return a;
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    var ebuf: [1024]u8 = undefined;
    var ew: std.Io.File.Writer = .init(.stderr(), io, &ebuf);
    const err = &ew.interface;
    defer err.flush() catch {};

    const args = parseArgs(argv[1..]) orelse {
        try err.writeAll(usage);
        return 2;
    };
    var traces: [2][]const transcript.Line = undefined;
    for (args.inputs, 0..) |maybe, i| {
        const path = maybe orelse break;
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |e| {
            try err.print("zg-transcript: {s}: {t}\n", .{ path, e });
            return 2;
        };
        var bad: usize = 0;
        const lines = transcript.parse(arena, text, &bad) catch |e| {
            try err.print("zg-transcript: {s}:{d}: {t}\n", .{ path, bad, e });
            return 2;
        };
        traces[i] = try transcript.normalize(arena, lines, args.workspace);
    }

    var obuf: [64 << 10]u8 = undefined;
    var file: ?std.Io.File = null;
    defer if (file) |f| f.close(io);
    if (args.out) |p| file = std.Io.Dir.cwd().createFile(io, p, .{}) catch |e| {
        try err.print("zg-transcript: {s}: {t}\n", .{ p, e });
        return 2;
    };
    var ow: std.Io.File.Writer = .init(file orelse .stdout(), io, &obuf);
    const out = &ow.interface;
    defer out.flush() catch {};

    switch (args.cmd) {
        .normalize => for (traces[0]) |l| try transcript.writeLine(out, l),
        .@"to-script" => try transcript.toScript(arena, traces[0], out),
        .diff => return if (try transcript.diff(arena, traces[0], traces[1], out)) 0 else 1,
    }
    return 0;
}

test "zg-transcript: arguments" {
    const t = std.testing;
    const a = parseArgs(&.{ "to-script", "x.ndjson", "-o", "x.script", "--workspace", "/w" }).?;
    try t.expectEqual(Command.@"to-script", a.cmd);
    try t.expectEqualStrings("x.ndjson", a.inputs[0].?);
    try t.expectEqualStrings("x.script", a.out.?);
    try t.expectEqualStrings("/w", a.workspace.?);
    const d = parseArgs(&.{ "diff", "a", "b" }).?;
    try t.expectEqualStrings("b", d.inputs[1].?);
    for ([_][]const []const u8{
        &.{},
        &.{"record"},
        &.{"normalize"},
        &.{ "normalize", "a", "b" },
        &.{ "diff", "a" },
        &.{ "diff", "a", "b", "-o", "c" },
        &.{ "to-script", "a", "-o" },
        &.{ "to-script", "a", "--bogus" },
    }) |bad| try t.expect(parseArgs(bad) == null);
}

test {
    _ = transcript;
}
