//! External analysis programs (E13.F06.S02.T02) with fake file system,
//! approval and exec ports. The real process path is tested in
//! test/program_test.zig with a fixture program.

const std = @import("std");
const zg_ai = @import("zg_ai");
const external = @import("external.zig");
const artifacts = @import("../artifacts/root.zig");
const runs = @import("../runs/root.zig");

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;

const FakeFs = struct {
    files: []const []const u8,
    asked: std.ArrayList([]const u8) = .empty,
    a: std.mem.Allocator,

    fn lookup(f: *FakeFs) external.Lookup {
        return .{ .ctx = f, .isProgram = isProgram };
    }

    fn isProgram(ctx: *anyopaque, path: []const u8) bool {
        const f: *FakeFs = @ptrCast(@alignCast(ctx));
        f.asked.append(f.a, path) catch {};
        for (f.files) |x| if (std.mem.eql(u8, x, path)) return true;
        return false;
    }
};

fn found(r: external.Resolved) []const u8 {
    return switch (r) {
        .found => |p| p,
        else => "<none>",
    };
}

test "path_resolution_linux_windows" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // POSIX: the first PATH entry that has it.
    var fs: FakeFs = .{ .a = a, .files = &.{ "/usr/bin/python3", "/opt/py/bin/python3", "/usr/local/bin/duckdb" } };
    try testing.expectEqualStrings("/opt/py/bin/python3", found(try external.resolveWith(a, fs.lookup(), "python3", "/opt/py/bin:/usr/bin", .{ .os = .posix })));
    try testing.expectEqualStrings("/usr/local/bin/duckdb", found(try external.resolveWith(a, fs.lookup(), "duckdb", "/usr/bin/:/usr/local/bin", .{ .os = .posix })));
    // A path is used as is.
    try testing.expectEqualStrings("/usr/bin/python3", found(try external.resolveWith(a, fs.lookup(), "/usr/bin/python3", "", .{ .os = .posix })));

    // Windows: .COM/.EXE before the rest of PATHEXT, whatever its order;
    // batch files never, unless allowed.
    var wfs: FakeFs = .{ .a = a, .files = &.{
        "C:\\tools\\jq.cmd",
        "C:\\tools\\jq.exe",
        "C:\\py\\python.bat",
        "C:\\py\\python.ps1",
        "C:\\r\\Rscript.exe",
    } };
    const pathext = ".BAT;.CMD;.PS1;.EXE;.COM";
    try testing.expectEqualStrings("C:\\tools\\jq.exe", found(try external.resolveWith(a, wfs.lookup(), "jq", "C:\\tools;C:\\r", .{ .os = .windows, .pathext = pathext })));
    try testing.expectEqualStrings("C:\\r\\Rscript.exe", found(try external.resolveWith(a, wfs.lookup(), "Rscript", "\"C:\\tools\";C:\\r\\", .{ .os = .windows, .pathext = pathext })));
    // python.bat is skipped (and python.ps1 found through PATHEXT).
    try testing.expectEqualStrings("C:\\py\\python.ps1", found(try external.resolveWith(a, wfs.lookup(), "python", "C:\\py", .{ .os = .windows, .pathext = pathext })));
    // Named explicitly: refused.
    try testing.expect(try external.resolveWith(a, wfs.lookup(), "python.bat", "C:\\py", .{ .os = .windows, .pathext = pathext }) == .batch);
    try testing.expect(try external.resolveWith(a, wfs.lookup(), "JQ.CMD", "C:\\tools", .{ .os = .windows, .pathext = pathext }) == .batch);
    // Allowed by policy.
    try testing.expectEqualStrings("C:\\py\\python.bat", found(try external.resolveWith(a, wfs.lookup(), "python.bat", "C:\\py", .{ .os = .windows, .pathext = pathext, .allow_batch = true })));
    // The lookup order checks .com and .exe first.
    wfs.asked.clearRetainingCapacity();
    _ = try external.resolveWith(a, wfs.lookup(), "nothing", "C:\\x", .{ .os = .windows, .pathext = pathext });
    try testing.expectEqualStrings("C:\\x\\nothing.com", wfs.asked.items[0]);
    try testing.expectEqualStrings("C:\\x\\nothing.exe", wfs.asked.items[1]);
    try testing.expectEqualStrings("C:\\x\\nothing.ps1", wfs.asked.items[2]);
    try testing.expectEqual(@as(usize, 3), wfs.asked.items.len);

    const nf = try external.resolveWith(a, fs.lookup(), "Rscript", "/usr/bin:/opt/py/bin", .{ .os = .posix });
    try testing.expectEqual(@as(usize, 2), nf.not_found.len);
}

const Fakes = struct {
    decision: external.Decision = .{ .allow = 42 },
    payload: []const u8 = "",
    asked: usize = 0,
    execs: std.ArrayList(external.ExecRequest) = .empty,
    a: std.mem.Allocator,
    ws: std.Io.Dir,
    /// Files the fake program writes into the output dir.
    writes: []const [2][]const u8 = &.{},

    fn decide(ctx: *anyopaque, r: *const external.ProgramRun, payload: []const u8) external.Decision {
        const f: *Fakes = @ptrCast(@alignCast(ctx));
        _ = r;
        f.asked += 1;
        f.payload = f.a.dupe(u8, payload) catch "";
        return f.decision;
    }

    fn exec(ctx: *anyopaque, io_: std.Io, arena: std.mem.Allocator, req: *const external.ExecRequest) anyerror!external.ExecResult {
        const f: *Fakes = @ptrCast(@alignCast(ctx));
        try f.execs.append(f.a, req.*);
        const out = for (req.env) |e| {
            if (std.mem.eql(u8, e.name, "ZIGGURO_OUTPUT_DIR")) break e.value;
        } else unreachable;
        for (f.writes) |w| {
            const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ out, w[0] });
            if (std.fs.path.dirname(p)) |dir| try f.ws.createDirPath(io_, dir);
            try f.ws.writeFile(io_, .{ .sub_path = p, .data = w[1] });
        }
        return .{ .exit = 0, .timed_out = false, .stdout = "done\n", .stderr = "" };
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    clock: zg_ai.ratelimit.FakeClock,
    store_dir: std.Io.Dir,
    store: *artifacts.ArtifactStore,
    fakes: Fakes,
    fs: FakeFs,
    deps: external.Deps,
    ws_path: []const u8,

    fn init(f: *Fx) !void {
        f.tmp = testing.tmpDir(.{ .iterate = true });
        f.arena = .init(gpa);
        const a = f.arena.allocator();
        f.clock = .init(1_760_000_000_000);
        try f.tmp.dir.createDirPath(io, ".zigguro/artifacts");
        f.store_dir = try f.tmp.dir.openDir(io, ".zigguro/artifacts", .{ .iterate = true });
        f.store = try artifacts.ArtifactStore.open(gpa, io, f.store_dir, .{ .clock = f.clock.clock() });
        f.fakes = .{ .a = a, .ws = f.tmp.dir };
        f.fs = .{ .a = a, .files = &.{ "/usr/bin/python3", "/usr/bin/duckdb", "/usr/bin/gnuplot" } };
        f.ws_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{f.tmp.sub_path});
        f.deps = .{
            .gpa = gpa,
            .io = io,
            .workspace = f.tmp.dir,
            .workspace_path = f.ws_path,
            .approval = .{ .ctx = &f.fakes, .decide = Fakes.decide },
            .exec = .{ .ctx = &f.fakes, .exec = Fakes.exec },
            .store = f.store,
            .run = runs.RunId.fromInt(0x0193_0000_0000_0000_0000_0000_0000_0001),
            .lookup = f.fs.lookup(),
            .env_path = "/usr/bin",
            .resolve = .{ .os = .posix },
            .clock = f.clock.clock(),
        };
    }

    fn deinit(f: *Fx) void {
        f.store.close();
        f.store_dir.close(io);
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn call(f: *Fx, input: []const u8) !external.Output {
        return external.run(&f.deps, f.arena.allocator(), input);
    }
};

test "approval_card_payload_golden" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(io, .{ .sub_path = "sales.csv", .data = "a\n1\n" });
    const out = try f.call(
        \\{"program":"python3","args":["--rows","10"],"script":{"content":"import os\nprint(1)\n"},"inputs":["sales.csv"],"timeout_s":60}
    );
    try testing.expect(!out.is_error);
    const want =
        \\{
        \\  "kind": "RunProgram",
        \\  "program": "python3",
        \\  "argv": [
        \\    "/usr/bin/python3",
        \\    ".zigguro/runs/01JC0000000000000000000001/scripts/script.py",
        \\    "--rows",
        \\    "10"
        \\  ],
        \\  "cwd": "WS",
        \\  "inputs": [
        \\    "sales.csv"
        \\  ],
        \\  "output_dir": ".zigguro/artifacts/runs/01JC0000000000000000000001",
        \\  "timeout_s": 60,
        \\  "script": {
        \\    "path": ".zigguro/runs/01JC0000000000000000000001/scripts/script.py",
        \\    "content": "import os\nprint(1)\n",
        \\    "language": "python"
        \\  },
        \\  "listed": true,
        \\  "rule": "RunProgram(python3:*)",
        \\  "fallback_rule": "run_command(/usr/bin/python3 *)"
        \\}
    ;
    const golden = try std.mem.replaceOwned(u8, f.arena.allocator(), want, "WS", f.ws_path);
    try testing.expectEqualStrings(golden, f.fakes.payload);

    // The exec port got the same argv, no shell, and the output dir.
    const req = f.fakes.execs.items[0];
    try testing.expectEqual(@as(u64, 42), req.ticket);
    try testing.expectEqual(@as(u64, 60_000), req.timeout_ms);
    try testing.expectEqualStrings("\u{2699} python3", req.title);
    try testing.expect(!req.network);
    try testing.expectEqual(@as(usize, 4), req.argv.len);
    for (req.argv) |arg| {
        try testing.expect(!std.mem.endsWith(u8, arg, "/sh"));
        try testing.expect(!std.mem.eql(u8, arg, "-c"));
    }
}

test "denied_returns_tool_error" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.fakes.decision = .{ .deny = "not now" };
    const out = try f.call("{\"program\":\"duckdb\",\"args\":[\"-c\",\"select 1\"]}");
    try testing.expect(out.is_error);
    try testing.expectEqualStrings("running duckdb was denied: not now", out.text);
    try testing.expectEqual(@as(usize, 1), f.fakes.asked);
    try testing.expectEqual(@as(usize, 0), f.fakes.execs.items.len);

    // A program outside agents.data.programs is still asked about (the
    // card says it isn't listed).
    f.fakes.decision = .{ .allow = 1 };
    const g = try f.call("{\"program\":\"gnuplot\"}");
    try testing.expect(!g.is_error);
    try testing.expect(std.mem.indexOf(u8, f.fakes.payload, "\"listed\": false") != null);

    // Bad paths fail before anything is asked.
    const asked = f.fakes.asked;
    for ([_][]const u8{
        "{\"program\":\"duckdb\",\"inputs\":[\"../secret.csv\"]}",
        "{\"program\":\"duckdb\",\"output_dir\":\"/tmp/out\"}",
        "{\"program\":\"duckdb\",\"script\":{\"path\":\"/etc/x.sql\"}}",
        "{\"program\":\"duckdb\",\"timeout_s\":4000}",
    }) |input| {
        const r = try f.call(input);
        try testing.expect(r.is_error);
    }
    try testing.expectEqual(asked, f.fakes.asked);
}

test "script_written_to_run_scratch" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const out = try f.call("{\"program\":\"duckdb\",\"script\":{\"path\":\"queries/top.sql\",\"content\":\"select 42;\"}}");
    try testing.expect(!out.is_error);
    const rel = ".zigguro/runs/01JC0000000000000000000001/scripts/top.sql";
    const text = try f.tmp.dir.readFileAlloc(io, rel, f.arena.allocator(), .limited(100));
    try testing.expectEqualStrings("select 42;", text);
    // Not in the user's tree.
    try testing.expectError(error.FileNotFound, f.tmp.dir.statFile(io, "queries/top.sql", .{}));
    try testing.expectEqualStrings(rel, f.fakes.execs.items[0].argv[1]);
    try testing.expect(std.mem.indexOf(u8, f.fakes.payload, "\"language\": \"sql\"") != null);

    // A workspace script is passed by path.
    try f.tmp.dir.writeFile(io, .{ .sub_path = "an.py", .data = "print(1)" });
    _ = try f.call("{\"program\":\"python3\",\"script\":{\"path\":\"an.py\"},\"args\":[\"x\"]}");
    const argv = f.fakes.execs.items[1].argv;
    try testing.expectEqualStrings("an.py", argv[1]);
    try testing.expectEqualStrings("x", argv[2]);
}

test "outputs_captured_as_artifacts" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.tmp.dir.createDirPath(io, "out");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "out/old.txt", .data = "unchanged" });
    var csv: std.ArrayList(u8) = .empty;
    try csv.appendSlice(a, "n,sq\n");
    for (0..50) |i| try csv.print(a, "{d},{d}\n", .{ i, i * i });
    f.fakes.writes = &.{
        .{ "result.csv", csv.items },
        .{ "plots/chart.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>" },
        .{ "summary.md", "# Summary\n" },
    };
    const out = try f.call("{\"program\":\"python3\",\"output_dir\":\"out\"}");
    try testing.expect(!out.is_error);
    const r = try std.json.parseFromSliceLeaky(std.json.Value, a, out.text, .{});
    const outs = r.object.get("outputs").?.array.items;
    try testing.expectEqual(@as(usize, 3), outs.len);
    try testing.expectEqualStrings("image", outs[0].object.get("kind").?.string);
    try testing.expectEqualStrings("plots/chart.svg", outs[0].object.get("title").?.string);
    try testing.expectEqualStrings("table", outs[1].object.get("kind").?.string);
    const preview = outs[1].object.get("preview").?.string;
    try testing.expectEqual(@as(usize, 21), std.mem.count(u8, preview, "\n"));
    try testing.expectEqualStrings("markdown", outs[2].object.get("kind").?.string);
    try testing.expectEqual(@as(i64, 0), r.object.get("exit").?.integer);
    try testing.expectEqualStrings("done\n", r.object.get("stdout_tail").?.string);

    // In the run's artifacts.
    var listed: std.ArrayList(artifacts.Artifact) = .empty;
    try f.store.list(.{ .run = f.deps.run }, &listed, a);
    try testing.expectEqual(@as(usize, 3), listed.items.len);

    // A second run that rewrites one file captures only that file.
    f.fakes.writes = &.{.{ "summary.md", "# Summary v2\n" }};
    const out2 = try f.call("{\"program\":\"python3\",\"output_dir\":\"out\"}");
    const r2 = try std.json.parseFromSliceLeaky(std.json.Value, a, out2.text, .{});
    try testing.expectEqual(@as(usize, 1), r2.object.get("outputs").?.array.items.len);
}

test "not_found_fallback_message" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.deps.env_path = "/usr/bin:/opt/bin";
    const out = try f.call("{\"program\":\"Rscript\"}");
    try testing.expect(out.is_error);
    try testing.expectEqualStrings(
        "`Rscript` not found on PATH (checked: /usr/bin, /opt/bin). Programs usually available for data work: python3, python, duckdb, Rscript, sqlite3, jq.",
        out.text,
    );
    try testing.expectEqual(@as(usize, 0), f.fakes.asked);
}

test "tail_bounds" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (0..500) |i| try buf.print(gpa, "line {d}\n", .{i});
    const t = external.tail(buf.items);
    try testing.expectEqual(@as(usize, 200), std.mem.count(u8, t, "\n"));
    try testing.expect(std.mem.startsWith(u8, t, "line 300\n"));
    buf.clearRetainingCapacity();
    try buf.appendNTimes(gpa, 'x', 100_000);
    try testing.expectEqual(external.tail_bytes, external.tail(buf.items).len);
    try testing.expectEqualStrings("", external.tail(""));
}
