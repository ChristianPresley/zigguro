//! The headless toolchain and `zg lsp` against the fake server: the
//! host's answers to server UI requests, nothing started before first
//! use, diagnostics output (the agents' text) and exit codes, a
//! definition, and the check task for a workspace with no paths given.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_dap = @import("zg_dap");
const options = @import("zg_options");
const test_exes = @import("zg_test_exes");
const Toolchain = @import("Toolchain.zig");
const HeadlessHost = @import("HeadlessHost.zig");
const cli = @import("cli.zig");
const tools = @import("../agent/tools.zig");
const Registry = @import("../registry/Registry.zig");

const testing = std.testing;
const gpa = testing.allocator;

const lib_zig =
    \\const Pool = struct {
    \\    pub fn init() Pool {
    \\        return .{};
    \\    }
    \\};
    \\test { _ = Pool.init(); }
    \\
;

const Fx = struct {
    rt: zg_core.Runtime,
    tmp: testing.TmpDir,
    ws_buf: [std.fs.max_path_bytes]u8,
    ws: []const u8,
    script: []u8,
    host_log: std.Io.Writer.Allocating,
    host: HeadlessHost,
    env: std.process.Environ.Map,
    tasks: ?zg_dap.headless.HeadlessTasks = null,
    tc: Toolchain,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn init(f: *Fx, script: ?[]const u8, tasks_zon: ?[]const u8) !void {
        f.rt.initTesting();
        const io = f.rt.io;
        f.tmp = testing.tmpDir(.{});
        f.ws = f.ws_buf[0..try f.tmp.dir.realPathFile(io, ".", &f.ws_buf)];
        try f.tmp.dir.writeFile(io, .{ .sub_path = "lib.zig", .data = lib_zig });
        f.script = try std.fs.path.join(gpa, &.{ options.package_root, "testdata", "transcripts", script orelse "headless.script" });
        f.host_log = .init(gpa);
        f.host = .init(io, &f.host_log.writer, .{});
        f.env = .init(gpa);
        f.tasks = null;
        if (tasks_zon) |zon| {
            try f.tmp.dir.createDirPath(io, ".zigguro");
            try f.tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/tasks.zon", .data = zon });
            f.tasks = @as(zg_dap.headless.HeadlessTasks, undefined);
            try f.tasks.?.init(&f.rt, .{ .root = f.ws, .env = &f.env, .trusted = true });
        }
        const overrides = [_]Registry.Override{
            .{ .id = "zls", .enabled = false },
            .{
                .id = "fake",
                .command = &.{ test_exes.fake_lsp_server, "--script", f.script, "--workspace", f.ws },
                .languages = &.{"zig"},
                .enabled = script != null,
            },
        };
        try f.tc.init(&f.rt, .{
            .roots = (&f.ws)[0..1],
            .env = &f.env,
            .host = &f.host,
            .tasks = if (f.tasks) |*t| t else null,
            .overrides = &overrides,
            .init_timeout = .fromSeconds(10),
        });
        f.out = .init(gpa);
        f.err = .init(gpa);
    }

    fn deinit(f: *Fx) void {
        f.out.deinit();
        f.err.deinit();
        f.tc.deinit();
        if (f.tasks) |*t| t.deinit();
        f.env.deinit();
        f.host_log.deinit();
        gpa.free(f.script);
        f.tmp.cleanup();
        _ = f.rt.deinit();
    }

    fn run(f: *Fx, args: []const []const u8) !u8 {
        f.out.clearRetainingCapacity();
        f.err.clearRetainingCapacity();
        return cli.cliMain(&f.tc, args, &f.out.writer, &f.err.writer);
    }
};

test "headless: host defaults for server-initiated UI requests" {
    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    var h: HeadlessHost = .init(testing.io, &log.writer, .{});
    const c = h.clientHost();
    const Got = struct {
        var choice: ?usize = 7;
        var shown: bool = true;
        fn onChoice(_: ?*anyopaque, x: ?usize) void {
            choice = x;
        }
        fn onShown(_: ?*anyopaque, ok: bool) void {
            shown = ok;
        }
    };
    c.showMessageRequest(c.ctx, 1, .Warning, "Restart?", &.{ "Yes", "No" }, .{ .ctx = null, .func = Got.onChoice });
    try testing.expectEqual(@as(?usize, null), Got.choice);
    c.showDocument(c.ctx, "file:///a.zig", false, true, null, .{ .ctx = null, .func = Got.onShown });
    try testing.expect(!Got.shown);
    c.showMessage(c.ctx, 1, .Error, "zig not found\n");
    // Info and log lines only when verbose.
    c.showMessage(c.ctx, 1, .Info, "indexing");
    c.logMessage(c.ctx, 1, .Error, "a log line");
    try testing.expectEqualStrings("language server: warning: Restart?\nlanguage server: error: zig not found\n", log.written());
    try testing.expectEqual(@as(u32, 2), h.refused);
    try testing.expectEqual(std.json.Value.null, c.getConfiguration(c.ctx, "zls", null, gpa));
}

test "headless: compose starts nothing until first use; zg lsp diagnostics output and exit codes" {
    var f: Fx = undefined;
    try f.init("headless.script", null);
    defer f.deinit();
    try testing.expectEqual(@as(usize, 0), f.tc.serverCount());

    // Errors and warnings by default; the info is not counted.
    const rc0 = try f.run(&.{ "diagnostics", "lib.zig", "--wait" });
    try testing.expectEqual(@as(u8, 1), rc0);
    try testing.expectEqual(@as(usize, 1), f.tc.serverCount());
    // The agents' text for the same state.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var o: tools.Output = .init(arena.allocator());
    try testing.expect(try f.tc.tool(arena.allocator(), "lsp_wait_for_diagnostics", "{\"paths\": [\"lib.zig\"], \"timeout_ms\": 10000}", &o));
    try testing.expectEqualStrings(o.text.written(), std.mem.trimEnd(u8, f.out.written(), "\n"));
    try testing.expectEqualStrings("1 error, 0 warnings:\nlib.zig:2:5: error: expected ';' [fake]", o.text.written());

    try testing.expectEqual(@as(u8, 1), try f.run(&.{ "diagnostics", "lib.zig", "--min-severity=hint" }));
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "lib.zig:6:1: info: a test [fake]") != null);

    try testing.expectEqual(@as(u8, 1), try f.run(&.{ "diagnostics", "lib.zig", "--json" }));
    const J = struct { status: struct { settled: bool }, diagnostics: []const struct { path: []const u8, line: u32, column: u32, severity: []const u8 } };
    const j = try std.json.parseFromSlice(J, gpa, f.out.written(), .{ .ignore_unknown_fields = true });
    defer j.deinit();
    try testing.expect(j.value.status.settled);
    try testing.expectEqual(@as(usize, 1), j.value.diagnostics.len);
    try testing.expectEqualStrings("lib.zig", j.value.diagnostics[0].path);
    try testing.expectEqual(@as(u32, 2), j.value.diagnostics[0].line);

    // Only errors: still one.
    try testing.expectEqual(@as(u8, 1), try f.run(&.{ "diagnostics", "lib.zig", "--min-severity", "error" }));

    try testing.expectEqual(@as(u8, 0), try f.run(&.{ "definition", "lib.zig:6:17" }));
    try testing.expect(std.mem.startsWith(u8, f.out.written(), "1 definition in 1 file:\nlib.zig:2:12\n"));

    // Usage errors.
    try testing.expectEqual(@as(u8, 2), try f.run(&.{}));
    try testing.expectEqual(@as(u8, 2), try f.run(&.{"frob"}));
    try testing.expectEqual(@as(u8, 2), try f.run(&.{ "definition", "lib.zig" }));
    try testing.expectEqual(@as(u8, 2), try f.run(&.{ "diagnostics", "--limit" }));
    try testing.expectEqual(@as(u8, 2), try f.run(&.{ "diagnostics", "--min-severity=loud", "lib.zig" }));
    try testing.expectEqual(@as(u8, 2), try f.run(&.{ "diagnostics", "/elsewhere/x.zig" }));
    // No paths and no check task.
    try testing.expectEqual(@as(u8, 2), try f.run(&.{"diagnostics"}));
    try testing.expectEqual(@as(u8, 0), try f.run(&.{"--help"}));
}

test "headless: diagnostics with no paths run the check task" {
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(testing.io, test_exes.fake_task, gpa);
    defer gpa.free(exe);
    var esc: std.Io.Writer.Allocating = .init(gpa);
    defer esc.deinit();
    try std.zon.stringify.serialize(exe, .{}, &esc.writer);
    const zon = try std.mem.replaceOwned(u8, gpa,
        \\.{ .tasks = .{
        \\    .{ .label = "check", .command = FAKE, .tags = .{"check"}, .problem_matcher = "$zig",
        \\       .args = .{ "--err", "lib.zig:2:5: error: expected ';'", "--exit", "1" } },
        \\} }
    , "FAKE", esc.written());
    defer gpa.free(zon);
    var f: Fx = undefined;
    try f.init(null, zon);
    defer f.deinit();
    try testing.expectEqual(@as(u8, 1), try f.run(&.{"diagnostics"}));
    try testing.expectEqual(@as(usize, 0), f.tc.serverCount());
    try testing.expect(std.mem.indexOf(u8, f.out.written(), "lib.zig:2:5: error: expected ';'") != null);
    // No server for a query: the agents' answer, as a failure.
    try testing.expectEqual(@as(u8, 2), try f.run(&.{ "definition", "lib.zig:2:12" }));
    try testing.expect(std.mem.startsWith(u8, f.err.written(), "No language server for .zig files: "));
}

test "headless: locations split from the right" {
    const l = cli.parseLoc("C:\\w\\a.zig:12:5").?;
    try testing.expectEqualStrings("C:\\w\\a.zig", l.path);
    try testing.expectEqual(@as(u32, 12), l.line);
    try testing.expectEqual(@as(?u32, 5), l.column);
    const m = cli.parseLoc("src/a.zig:7").?;
    try testing.expectEqualStrings("src/a.zig", m.path);
    try testing.expectEqual(@as(?u32, null), m.column);
    try testing.expectEqual(@as(?cli.Loc, null), cli.parseLoc("a.zig"));
    try testing.expectEqual(@as(?cli.Loc, null), cli.parseLoc("a.zig:0"));
}
