//! Tests for the debug adapter registry, argument normalization and the
//! Zig auto-configurations.

const std = @import("std");
const builtin = @import("builtin");
const Registry = @import("Registry.zig");
const builtins = @import("builtin_adapters.zig");
const normalize = @import("normalize.zig");
const autoconfig = @import("../config/zig_autoconfig.zig");
const zig_build = @import("../tasks/sources/zig_build.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const posix_only = builtin.os.tag == .windows;

/// A temporary folder on PATH holding fake tools.
const Bin = struct {
    tmp: testing.TmpDir,
    root: []const u8,
    env: std.process.Environ.Map,

    fn init(b: *Bin) !void {
        b.tmp = testing.tmpDir(.{});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        b.root = try gpa.dupe(u8, buf[0..try b.tmp.dir.realPath(io, &buf)]);
        b.env = .init(gpa);
        try b.env.put("PATH", b.root);
    }

    fn deinit(b: *Bin) void {
        b.env.deinit();
        gpa.free(b.root);
        b.tmp.cleanup();
    }

    /// A shell script that prints `out`.
    fn tool(b: *Bin, name: []const u8, out: []const u8) !void {
        var buf: [256]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "#!/bin/sh\necho '{s}'\n", .{out});
        try b.tmp.dir.writeFile(io, .{ .sub_path = name, .data = data, .flags = .{ .permissions = .executable_file } });
    }
};

test "adapters: builtin table loads; aliases resolve" {
    var r = try Registry.init(gpa, .{});
    defer r.deinit();
    for (builtins.defs) |d| {
        try testing.expect(d.install_hint.len > 0);
        try testing.expect(d.install_url.len > 0);
        try testing.expect(r.get(d.type) != null);
    }
    try testing.expectEqualStrings("lldb-dap", r.get("lldb-vscode").?.type);
    try testing.expectEqualStrings("debugpy", r.get("python").?.type);
    try testing.expectEqualStrings("js-debug", r.get("pwa-node").?.type);
    try testing.expectEqualStrings("codelldb", r.get("lldb").?.type);
    try testing.expect(r.get("cppdbg") == null);
    try testing.expectEqual(builtins.TransportKind.tcp_listen_child, r.get("js-debug").?.transport);
}

test "adapters: found on PATH; missing ones say how to install" {
    if (posix_only) return error.SkipZigTest;
    var b: Bin = undefined;
    try b.init();
    defer b.deinit();
    try b.tool("lldb-dap", "lldb-dap version 19.1.0");
    var r = try Registry.init(gpa, .{ .os = .linux });
    defer r.deinit();
    const st = try r.resolve(io, r.get("lldb-dap").?, &b.env);
    try testing.expect(st == .ok);
    try testing.expect(std.mem.endsWith(u8, st.ok.argv[0], "/lldb-dap"));
    const missing = try r.resolve(io, r.get("debugpy").?, &b.env);
    try testing.expectEqualStrings("python", missing.missing);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const msg = try missing.message(arena.allocator(), r.get("debugpy").?);
    try testing.expect(std.mem.indexOf(u8, msg, "pip install debugpy") != null);
    // Cached until a rescan.
    try b.tool("python", "1.8.0");
    try testing.expect((try r.resolve(io, r.get("debugpy").?, &b.env)) == .missing);
    r.rescan();
    try testing.expect((try r.resolve(io, r.get("debugpy").?, &b.env)) == .ok);
}

test "adapters: gdb < 14 disabled with warning" {
    if (posix_only) return error.SkipZigTest;
    var b: Bin = undefined;
    try b.init();
    defer b.deinit();
    try b.tool("gdb", "GNU gdb (Ubuntu 12.1-0ubuntu1~22.04.2) 12.1");
    var r = try Registry.init(gpa, .{ .os = .linux });
    defer r.deinit();
    const gdb = r.get("gdb").?;
    const st = try r.resolve(io, gdb, &b.env);
    try testing.expect(st == .too_old);
    try testing.expectEqual(@as(usize, 12), st.too_old.found.major);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expect(std.mem.indexOf(u8, try st.message(arena.allocator(), gdb), "14.0 or later") != null);

    try b.tool("gdb", "GNU gdb (GDB) 14.2");
    // The version is kept across a rescan; an upgrade in place needs
    // forgetVersions.
    r.rescan();
    try testing.expect((try r.resolve(io, gdb, &b.env)) == .too_old);
    r.forgetVersions();
    const ok = try r.resolve(io, gdb, &b.env);
    try testing.expect(ok == .ok);
    try testing.expectEqual(@as(usize, 14), ok.ok.version.?.major);
    try testing.expectEqualStrings("--interpreter=dap", ok.ok.argv[2]);
}

test "adapters: js-debug requires path setting; argv with {port}" {
    if (posix_only) return error.SkipZigTest;
    var b: Bin = undefined;
    try b.init();
    defer b.deinit();
    try b.tool("node", "v20.11.0");
    var r0 = try Registry.init(gpa, .{ .os = .linux });
    defer r0.deinit();
    const st0 = try r0.resolve(io, r0.get("js-debug").?, &b.env);
    try testing.expectEqualStrings("debug.adapters.jsDebug.path", st0.needs_setting);

    try b.tmp.dir.createDirPath(io, "js-debug/src");
    try b.tmp.dir.writeFile(io, .{ .sub_path = "js-debug/src/dapDebugServer.js", .data = "" });
    const jd = try std.fs.path.join(gpa, &.{ b.root, "js-debug" });
    defer gpa.free(jd);
    var r = try Registry.init(gpa, .{ .os = .linux, .js_debug_path = jd });
    defer r.deinit();
    const st = try r.resolve(io, r.get("node").?, &b.env);
    try testing.expect(st == .ok);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const argv = try Registry.withPort(arena.allocator(), st.ok.argv, 48123);
    try testing.expect(std.mem.endsWith(u8, argv[1], "js-debug/src/dapDebugServer.js"));
    try testing.expectEqualStrings("48123", argv[2]);
    try testing.expectEqualStrings("127.0.0.1", argv[3]);
}

test "adapters: codelldb not auto-discovered" {
    if (posix_only) return error.SkipZigTest;
    var b: Bin = undefined;
    try b.init();
    defer b.deinit();
    try b.tool("codelldb", "codelldb 1.10");
    var r = try Registry.init(gpa, .{ .os = .linux });
    defer r.deinit();
    try testing.expect((try r.resolve(io, r.get("codelldb").?, &b.env)) == .needs_setting);
    try testing.expect((try r.firstAvailable(io, &b.env, &autoconfig.preference)) == null);
    var r2 = try Registry.init(gpa, .{ .os = .linux, .codelldb_command = &.{ "codelldb", "--port", "{port}" } });
    defer r2.deinit();
    const st = try r2.resolve(io, r2.get("codelldb").?, &b.env);
    try testing.expect(st == .ok);
    try testing.expectEqualStrings("{port}", st.ok.argv[2]);
}

test "adapters: untrusted workspace ignores overridden command" {
    if (posix_only) return error.SkipZigTest;
    var b: Bin = undefined;
    try b.init();
    defer b.deinit();
    try b.tool("evil-dap", "1.0.0");
    try b.tool("my-lldb-dap", "1.0.0");
    const overrides: []const Registry.Override = &.{
        .{ .type = "lldb-dap", .command = &.{"my-lldb-dap"} },
        .{ .type = "lldb-dap", .command = &.{"evil-dap"}, .from_workspace = true },
    };
    var untrusted = try Registry.init(gpa, .{ .os = .linux, .overrides = overrides, .trusted = false });
    defer untrusted.deinit();
    const st = try untrusted.resolve(io, untrusted.get("lldb-dap").?, &b.env);
    try testing.expect(std.mem.endsWith(u8, st.ok.argv[0], "/my-lldb-dap"));
    var trusted = try Registry.init(gpa, .{ .os = .linux, .overrides = overrides });
    defer trusted.deinit();
    const st2 = try trusted.resolve(io, trusted.get("lldb-dap").?, &b.env);
    try testing.expect(std.mem.endsWith(u8, st2.ok.argv[0], "/evil-dap"));
}

fn parseObject(a: std.mem.Allocator, json: []const u8) !std.json.ObjectMap {
    return (try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{})).object;
}

fn render(a: std.mem.Allocator, m: std.json.ObjectMap) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = m }, .{});
}

test "adapters: normalize env object vs array" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try Registry.init(gpa, .{});
    defer r.deinit();

    var to_array = try parseObject(a, "{\"env\":{\"A\":\"1\",\"B\":null,\"N\":3},\"args\":\"--x 'a b' \\\"c\\\\\\\"d\\\" e\\\\ f\"}");
    try Registry.normalizeArgs(r.get("lldb-dap").?, a, .launch, &to_array);
    try testing.expectEqualStrings("{\"env\":[\"A=1\",\"N=3\"],\"args\":[\"--x\",\"a b\",\"c\\\"d\",\"e f\"]}", try render(a, to_array));

    var to_object = try parseObject(a, "{\"env\":[\"A=1\",\"B=x=y\",\"C\"],\"args\":[\"kept\"]}");
    try Registry.normalizeArgs(r.get("gdb").?, a, .launch, &to_object);
    try testing.expectEqualStrings("{\"env\":{\"A\":\"1\",\"B\":\"x=y\",\"C\":\"\"},\"args\":[\"kept\"]}", try render(a, to_object));

    // The right shape already: unchanged.
    var same = try parseObject(a, "{\"env\":{\"A\":\"1\"}}");
    try Registry.normalizeArgs(r.get("debugpy").?, a, .attach, &same);
    try testing.expectEqualStrings("{\"env\":{\"A\":\"1\"}}", try render(a, same));
}

const steps_text =
    \\  install (default)            Copy build artifacts to prefix path
    \\  uninstall                    Remove build artifacts from prefix path
    \\  run                          Run the app
    \\  test                         Run unit tests
;

test "autoconfig: zig build -l fixture produces run config; multiple executables prompt" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const steps = try zig_build.parseSteps(a, steps_text);
    const o: autoconfig.Options = .{ .state_dir = "/state", .os = .linux };

    const one = try autoconfig.configs(a, "/p/hello", steps, &.{}, "lldb-dap", o);
    try testing.expectEqual(@as(usize, 2), one.len);
    try testing.expectEqualStrings("Debug zig build run", one[0].name);
    try testing.expectEqualStrings("${workspaceFolder}/zig-out/bin/hello", one[0].argString("program").?);
    try testing.expectEqualStrings("zig build", one[0].pre_launch_task.?);
    try testing.expectEqualStrings("lldb-dap", one[0].type);
    try testing.expectEqual(.auto, one[0].source);

    const several = try autoconfig.configs(a, "/p/hello", steps, &.{ "client", "server" }, "gdb", o);
    try testing.expectEqual(@as(usize, 3), several.len);
    try testing.expectEqualStrings("Debug zig build run (client)", several[0].name);
    try testing.expectEqualStrings("${workspaceFolder}/zig-out/bin/server", several[1].argString("program").?);

    const win = try autoconfig.configs(a, "C:\\p\\hello", steps, &.{}, "lldb-dap", .{ .state_dir = "C:\\state", .os = .windows });
    try testing.expect(std.mem.endsWith(u8, win[0].argString("program").?, "hello.exe"));
    // No install step (not a zig build project): only the tests.
    const none = try autoconfig.configs(a, "/p", &.{}, &.{}, "lldb-dap", o);
    try testing.expectEqual(@as(usize, 1), none.len);
}

test "autoconfig: test config uses --test-no-exec" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try autoconfig.configs(a, "/p", &.{}, &.{}, "lldb-dap", .{ .state_dir = "/state", .os = .linux });
    const c = cs[0];
    try testing.expectEqualStrings("Debug tests in current file", c.name);
    const t = c.generated_task.?;
    try testing.expectEqualStrings(c.pre_launch_task.?, t.label);
    try testing.expectEqualStrings("zig", t.command);
    try testing.expectEqualStrings("test", t.args[0]);
    try testing.expectEqualStrings("${file}", t.args[1]);
    try testing.expectEqualStrings("--test-no-exec", t.args[2]);
    try testing.expectEqualStrings("-femit-bin=/state/debug/tests", t.args[3]);
    try testing.expectEqualStrings("/state/debug/tests", c.argString("program").?);
}

test "autoconfig: executables in zig-out/bin and the first available adapter" {
    if (posix_only) return error.SkipZigTest;
    var b: Bin = undefined;
    try b.init();
    defer b.deinit();
    try b.tmp.dir.createDirPath(io, "proj/zig-out/bin");
    for ([_][]const u8{ "zeta", "alpha", "libx.so", "alpha.pdb" }) |n| {
        var buf: [64]u8 = undefined;
        try b.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&buf, "proj/zig-out/bin/{s}", .{n}), .data = "" });
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const proj = try std.fs.path.join(a, &.{ b.root, "proj" });
    const exes = try autoconfig.listExecutables(a, io, proj, .linux);
    try testing.expectEqual(@as(usize, 2), exes.len);
    try testing.expectEqualStrings("alpha", exes[0]);
    try testing.expectEqualStrings("zeta", exes[1]);

    const steps = try zig_build.parseSteps(a, steps_text);
    var r = try Registry.init(gpa, .{ .os = .linux });
    defer r.deinit();
    // No adapter: nothing offered.
    try testing.expectEqual(@as(usize, 0), (try autoconfig.autoConfigsForZig(a, io, proj, steps, &r, &b.env, .{ .state_dir = "/s", .os = .linux })).len);
    // gdb 14 is there: it is used.
    try b.tool("gdb", "GNU gdb (GDB) 15.1");
    r.rescan();
    const cs = try autoconfig.autoConfigsForZig(a, io, proj, steps, &r, &b.env, .{ .state_dir = "/s", .os = .linux });
    try testing.expectEqual(@as(usize, 3), cs.len);
    try testing.expectEqualStrings("gdb", cs[0].type);
}
