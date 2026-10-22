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
