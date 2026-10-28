//! Benchmarks for zg_dap; run with `zig build bench` at the repo root.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_dap = @import("zg_dap");
const bench = zg_core.bench;
const State = bench.State;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    try b.run("dap.variables: substitute a launch configuration", {}, substitute);
    try b.run("dap.protocol: decode a 200-frame stackTrace body", {}, decodeStack);
    try b.run("dap.events_10k: decode 10k event envelopes", {}, decodeEvents);
    try b.run("tasks.matcher.200mb: $zig over build output (MB/s)", {}, matchOutput);
    try b.run("tasks.load: 50 zig build steps, 20 tasks.zon and 20 tasks.json tasks", {}, loadTasks);
}

/// The task list from texts already read (the `zig build -l` process is
/// not part of the budget).
fn loadTasks(_: void, s: *State) void {
    const gpa = s.allocator();
    var steps: std.ArrayList(u8) = .empty;
    defer steps.deinit(gpa);
    var zon: std.ArrayList(u8) = .empty;
    defer zon.deinit(gpa);
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    steps.appendSlice(gpa, "  install (default)            Copy build artifacts to prefix path\n") catch unreachable;
    for (1..50) |i| steps.print(gpa, "  step-{d:0>2}                      Run step number {d} of the build\n", .{ i, i }) catch unreachable;
    zon.appendSlice(gpa, ".{ .version = 1, .tasks = .{\n") catch unreachable;
    json.appendSlice(gpa, "{ \"version\": \"2.0.0\", // tasks\n \"options\": { \"env\": { \"MODE\": \"dev\" } },\n \"tasks\": [\n") catch unreachable;
    for (0..20) |i| {
        zon.print(gpa,
            \\    .{{ .label = "zon {d}", .command = "zig", .args = .{{ "build", "step-{d:0>2}", "-Doptimize=ReleaseSafe" }}, .depends_on = .{{"zon 0"}}, .problem_matcher = "$zig", .presentation = .{{ .reveal = .silent }} }},
            \\
        , .{ i, i }) catch unreachable;
        json.print(gpa,
            \\  {{ "label": "json {d}", "type": "shell", "command": "make -j8 target{d}", "args": ["--keep-going"], "group": {{ "kind": "build" }},
            \\    "options": {{ "cwd": "${{workspaceFolder}}/build" }}, "linux": {{ "args": ["-k"] }},
            \\    "problemMatcher": ["$gcc", {{ "owner": "x", "pattern": {{ "regexp": "^(.*):(\\d+): (.*)$", "file": 1, "line": 2, "message": 3 }} }}] }},
            \\
        , .{ i, i }) catch unreachable;
    }
    zon.appendSlice(gpa, "} }\n") catch unreachable;
    json.appendSlice(gpa, "] }\n") catch unreachable;
    const zon_z = gpa.dupeZ(u8, zon.items) catch unreachable;
    defer gpa.free(zon_z);
    s.setBytes(steps.items.len + zon.items.len + json.items.len);
    for (0..s.iterations()) |_| {
        var l = zg_dap.tasks.TaskList.fromSources(gpa, .{
            .tasks_zon = zon_z,
            .tasks_json = json.items,
            .zig_steps = steps.items,
            .os = .linux,
            .trusted = true,
        }) catch unreachable;
        defer l.deinit();
        std.debug.assert(l.all().len == 91 and l.warnings.len == 0);
        bench.doNotOptimizeAway(l.all().len);
    }
}

/// Build output: mostly lines that match nothing (progress, excerpts,
/// carets, references), one error with a note in every 16 lines.
fn matchOutput(_: void, s: *State) void {
    const gpa = s.allocator();
    const block =
        \\   +- compile exe demo Debug native 2 errors
        \\src/main.zig:9:27: error: expected type 'u32', found '[]const u8'
        \\    const n: u32 = add(1, s);
        \\                          ^
        \\src/main.zig:3:19: note: parameter type declared here
        \\fn add(a: u32, b: u32) u32 {
        \\                  ^~~
        \\referenced by:
        \\    callMain [inlined]: /opt/zig/lib/std/start.zig:698:59
        \\    posixCallMainAndExit: /opt/zig/lib/std/start.zig:590:38
        \\    2 reference(s) hidden; use '-freference-trace=5' to see all references
        \\failed command: /opt/zig/zig build-exe -Mroot=/home/dev/proj/src/main.zig --cache-dir .zig-cache --listen=-
        \\
        \\Build Summary: 0/3 steps succeeded (1 failed)
        \\install transitive failure
        \\+- install demo transitive failure
        \\
    ;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    // Distinct lines per block so deduplication does not skip the work.
    var i: usize = 0;
    while (text.items.len < 8 << 20) : (i += 1) {
        text.print(gpa, "src/f{d}.zig:{d}:1: warning: unused\n", .{ i, i }) catch unreachable;
        text.appendSlice(gpa, block) catch unreachable;
    }
    s.setBytes(text.items.len);
    const Null = struct {
        fn problem(_: *anyopaque, p: *const zg_dap.tasks.matcher.Problem) void {
            bench.doNotOptimizeAway(p.line);
        }
        fn cycle(_: *anyopaque, _: zg_dap.tasks.matcher.Cycle) void {}
    };
    var dummy: u8 = 0;
    const sink: zg_dap.tasks.matcher.ProblemSink = .{ .ctx = &dummy, .problem = Null.problem, .cycle = Null.cycle };
    for (0..s.iterations()) |_| {
        var m = zg_dap.tasks.matcher.Matcher.init(gpa, zg_dap.tasks.matcher.builtinNamed("zig").?, "/home/dev/proj", .{}) catch unreachable;
        defer m.deinit();
        m.feedBytes(text.items, sink);
        m.finish(sink);
        bench.doNotOptimizeAway(m.emitted);
    }
}

fn decodeEvents(_: void, s: *State) void {
    const gpa = s.allocator();
    const frame =
        \\{"seq":123456,"type":"event","event":"output","body":{"category":"stdout","output":"line 42 of the program output\n","source":{"path":"/home/dev/proj/src/main.zig"},"line":42}}
    ;
    s.setBytes(frame.len * 10_000);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (0..s.iterations()) |_| {
        for (0..10_000) |_| {
            _ = arena.reset(.retain_capacity);
            const env = zg_dap.conn.message.decode(arena.allocator(), frame) catch unreachable;
            bench.doNotOptimizeAway(env.body.?.bytes.len);
        }
    }
}

const Ctx = struct {
    fn config(_: *anyopaque, _: []const u8, _: std.mem.Allocator) ?[]const u8 {
        return null;
    }
    fn command(_: *anyopaque, _: []const u8, _: std.mem.Allocator) anyerror!?[]const u8 {
        return error.CommandNotAllowed;
    }
    fn input(_: *anyopaque, _: *const zg_dap.variables.InputDef, _: std.mem.Allocator) anyerror!?[]const u8 {
        return null;
    }
};

fn substitute(_: void, s: *State) void {
    const gpa = s.allocator();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    env.put("HOME", "/home/dev") catch unreachable;
    var dummy: u8 = 0;
    const ctx: zg_dap.variables.VarContext = .{
        .workspace_folder = "/home/dev/proj",
        .file = "/home/dev/proj/src/main.zig",
        .line = 10,
        .column = 1,
        .selected_text = null,
        .cwd = "/home/dev/proj",
        .exec_path = "/usr/bin/zigguro",
        .user_home = "/home/dev",
        .default_build_task = null,
        .os = .linux,
        .env = &env,
        .config = Ctx.config,
        .command = Ctx.command,
        .input = Ctx.input,
        .ctx = &dummy,
    };
    const launch =
        \\{"name":"Debug","type":"lldb-dap","request":"launch","program":"${workspaceFolder}/zig-out/bin/app",
        \\ "args":["${relativeFile}","--line","${lineNumber}"],"cwd":"${fileDirname}","env":{"HOME":"${env:HOME}"}}
    ;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (0..s.iterations()) |_| {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        var v = std.json.parseFromSliceLeaky(std.json.Value, a, launch, .{}) catch unreachable;
        zg_dap.variables.substituteValue(a, &v, &ctx, &.{}) catch unreachable;
        bench.doNotOptimizeAway(&v);
    }
}

fn decodeStack(_: void, s: *State) void {
    const gpa = s.allocator();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    body.appendSlice(gpa, "{\"stackFrames\":[") catch unreachable;
    for (0..200) |i| {
        if (i > 0) body.append(gpa, ',') catch unreachable;
        body.print(gpa, "{{\"id\":{d},\"name\":\"frame{d}\",\"source\":{{\"path\":\"/home/dev/proj/src/f{d}.zig\"}},\"line\":{d},\"column\":1,\"instructionPointerReference\":\"0x{x}\"}}", .{ i, i, i, i + 1, 0x1000 + i }) catch unreachable;
    }
    body.appendSlice(gpa, "],\"totalFrames\":200}") catch unreachable;
    s.setBytes(body.items.len);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const Body = zg_dap.protocol.RequestInfo(.stackTrace).ResponseBody;
    for (0..s.iterations()) |_| {
        _ = arena.reset(.retain_capacity);
        const r = zg_dap.json.parse(Body, arena.allocator(), body.items) catch unreachable;
        bench.doNotOptimizeAway(r.stackFrames.len);
    }
}
