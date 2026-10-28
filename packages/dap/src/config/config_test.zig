//! Launch configurations: `launch.zon` (dynamic adapter args, errors,
//! OS overrides, saving), `.vscode/launch.json` files as Zig, C, Rust,
//! Python and Node projects write them (testdata/launch/), type mapping,
//! compounds, trust and reloading.

const std = @import("std");
const options = @import("zg_options");
const ConfigSet = @import("ConfigSet.zig");
const zon_dynamic = @import("zon_dynamic.zig");
const type_map = @import("type_map.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;

fn fixture(a: Allocator, rel: []const u8) ![:0]u8 {
    const path = try std.fs.path.join(a, &.{ options.package_root, "testdata", "launch", rel });
    return std.Io.Dir.cwd().readFileAllocOptions(testing.io, path, a, .limited(1 << 20), .of(u8), 0);
}

fn expectNoErrors(s: *const ConfigSet) !void {
    for (s.errors) |e| std.debug.print("unexpected error: {s}: {s}\n", .{ e.file, e.message });
    try testing.expectEqual(@as(usize, 0), s.errors.len);
}

fn hasError(s: *const ConfigSet, needle: []const u8) bool {
    for (s.errors) |e| if (std.mem.indexOf(u8, e.message, needle) != null) return true;
    return false;
}

fn jsonSet(src: []const u8, os: std.Target.Os.Tag) !ConfigSet {
    return ConfigSet.fromSources(gpa, .{ .launch_json = src, .os = os, .trusted = true });
}

test "launch.zon: nested adapter args are read as written" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var s = try ConfigSet.fromSources(gpa, .{ .launch_zon = try fixture(arena.allocator(), "zon/launch.zon"), .os = .linux, .trusted = true });
    defer s.deinit();
    try expectNoErrors(&s);
    try testing.expectEqual(@as(usize, 2), s.configs.len);
    const c = s.find("Debug app").?;
    try testing.expect(c.enabled);
    try testing.expectEqualStrings("lldb-dap", c.type);
    try testing.expectEqual(.launch, c.request);
    try testing.expectEqualStrings("${workspaceFolder}/zig-out/bin/app", c.argString("program").?);
    try testing.expectEqualStrings("zig build", c.pre_launch_task.?);
    try testing.expectEqualStrings("app", c.presentation.?.group.?);
    const argv = c.args.get("args").?.array.items;
    try testing.expectEqual(@as(usize, 2), argv.len);
    try testing.expectEqualStrings("8080", argv[1].string);
    const env = c.args.get("env").?.object;
    try testing.expectEqualStrings("1", env.get("MY-VAR").?.string);
    try testing.expectEqual(false, c.args.get("stopOnEntry").?.bool);
    const nested = c.args.get("nested").?.object;
    try testing.expectEqual(@as(i64, 3), nested.get("depth").?.object.get("level").?.integer);
    try testing.expectEqual(@as(f64, 0.5), nested.get("ratio").?.float);
    try testing.expect(nested.get("none").? == .null);

    try testing.expectEqual(.attach, s.find("Attach").?.request);
    try testing.expectEqual(@as(usize, 1), s.compounds.len);
    try testing.expect(s.compounds[0].stop_all);
    try testing.expectEqual(.promptString, s.findInput("pid").?.type);
}

test "launch.zon: a syntax error has a line and column" {
    var s = try ConfigSet.fromSources(gpa, .{ .launch_zon = ".{\n    .version = 1,\n    .configurations = .{ .{ .name = \"x\" .type = \"gdb\" } },\n}\n", .os = .linux, .trusted = true });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 0), s.configs.len);
    try testing.expectEqual(@as(usize, 1), s.errors.len);
    const e = s.errors[0];
    try testing.expectEqualStrings(".zigguro/launch.zon", e.file);
    try testing.expectEqual(@as(?u32, 3), e.line);
    try testing.expect(e.column.? > 20);

    // A ZON (not syntax) error: a non-literal value.
    var e2: zon_dynamic.ZonError = undefined;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqual(null, try zon_dynamic.parse(arena.allocator(), ".{ .a = 1 + 2 }", &e2));
    try testing.expectEqual(@as(u32, 1), e2.line);
    try testing.expectError(error.InvalidZon, zon_dynamic.zonToJson(arena.allocator(), ".{ .a = }"));
}

test "launch.zon: missing fields are reported, the rest still load" {
    var s = try ConfigSet.fromSources(gpa, .{
        .launch_zon =
        \\.{ .configurations = .{
        \\    .{ .type = "gdb", .request = .launch },
        \\    .{ .name = "no type", .request = .launch },
        \\    .{ .name = "bad request", .type = "gdb", .request = .run },
        \\    .{ .name = "ok", .type = "gdb", .request = .launch, .args = .{} },
        \\    .{ .name = "linux type", .type = "gdb", .request = .launch, .linux = .{ .type = "lldb-dap" } },
        \\} }
        ,
        .os = .linux,
        .trusted = true,
    });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 2), s.configs.len);
    try testing.expect(hasError(&s, "configuration 1 has no .name"));
    try testing.expect(hasError(&s, "\"no type\" has no .type"));
    try testing.expect(hasError(&s, ".request must be"));
    try testing.expect(hasError(&s, "type cannot be changed per OS"));
    try testing.expectEqualStrings("gdb", s.find("linux type").?.type);
}

test "launch.json: comments and trailing commas" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var s = try jsonSet(try fixture(arena.allocator(), "vscode/zig.json"), .linux);
    defer s.deinit();
    try expectNoErrors(&s);
    try testing.expectEqual(@as(usize, 2), s.configs.len);
    const c = s.find("Debug app").?;
    try testing.expectEqual(.vscode, c.source);
    try testing.expectEqualStrings("codelldb", c.type);
    try testing.expectEqualStrings("zig build", c.pre_launch_task.?);
    // Adapter keys go to args; VS Code's own keys do not.
    try testing.expectEqualStrings("${workspaceFolder}", c.argString("cwd").?);
    try testing.expect(c.args.get("preLaunchTask") == null);
    try testing.expect(c.args.get("windows") == null);
    try testing.expect(c.args.get("name") == null);
    try testing.expectEqualStrings("lldb-dap", s.find("Debug tests").?.type);

    // A JSON error has a position.
    var bad = try jsonSet("{\n  \"configurations\": [\n    { \"name\": }\n  ]\n}", .linux);
    defer bad.deinit();
    try testing.expectEqual(@as(?u32, 3), bad.errors[0].line);
    var unterminated = try jsonSet("{ /* never closed", .linux);
    defer unterminated.deinit();
    try testing.expect(hasError(&unterminated, "unterminated"));
}

test "launch.json and launch.zon: per-OS overrides merge" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // VS Code: `windows.program` replaces the program on Windows only.
    const zig_json = try fixture(a, "vscode/zig.json");
    var win = try jsonSet(zig_json, .windows);
    defer win.deinit();
    try testing.expectEqualStrings("${workspaceFolder}/zig-out/bin/app.exe", win.find("Debug app").?.argString("program").?);
    var lin = try jsonSet(zig_json, .linux);
    defer lin.deinit();
    try testing.expectEqualStrings("${workspaceFolder}/zig-out/bin/app", lin.find("Debug app").?.argString("program").?);

    // `env` merges key by key.
    var c = try jsonSet(try fixture(a, "vscode/c.json"), .linux);
    defer c.deinit();
    const env = c.find("GDB direct").?.args.get("env").?.object;
    try testing.expectEqualStrings("1", env.get("LOG").?.string);
    try testing.expectEqualStrings("linux", env.get("MODE").?.string);

    // launch.zon: `.windows.args` merges into `.args`, and env into env.
    var z = try ConfigSet.fromSources(gpa, .{ .launch_zon = try fixture(a, "zon/launch.zon"), .os = .windows, .trusted = true });
    defer z.deinit();
    const app = z.find("Debug app").?;
    try testing.expectEqualStrings("${workspaceFolder}/zig-out/bin/app.exe", app.argString("program").?);
    try testing.expectEqual(@as(usize, 2), app.args.get("args").?.array.items.len);
    const zenv = app.args.get("env").?.object;
    try testing.expectEqualStrings("win", zenv.get("LOG").?.string);
    try testing.expectEqualStrings("1", zenv.get("MY-VAR").?.string);
}

test "launch.json: type mapping table" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, ?[]const u8 }{
        .{ "lldb-dap", "lldb-dap" }, .{ "lldb-vscode", "lldb-dap" }, .{ "gdb", "gdb" },
        .{ "lldb", "codelldb" },     .{ "codelldb", "codelldb" },    .{ "debugpy", "debugpy" },
        .{ "python", "debugpy" },    .{ "node", "js-debug" },        .{ "pwa-node", "js-debug" },
        .{ "chrome", "js-debug" },   .{ "pwa-chrome", "js-debug" },  .{ "cppdbg", null },
        .{ "cppvsdbg", null },       .{ "extensionHost", null },
    };
    for (cases) |c| {
        const m = try type_map.map(a, c[0], null);
        if (c[1]) |want| {
            try testing.expectEqualStrings(want, m.adapter.?);
        } else {
            try testing.expect(m.adapter == null);
            try testing.expect(m.reason != null);
        }
    }
    var mi: std.json.ObjectMap = .empty;
    try mi.put(a, "MIMode", .{ .string = "gdb" });
    try testing.expect(std.mem.indexOf(u8, (try type_map.map(a, "cppdbg", mi)).reason.?, "\"gdb\" configuration") != null);
    try testing.expectEqualStrings("No adapter for type \"extensionHost\"", (try type_map.map(a, "extensionHost", null)).reason.?);
}

test "launch.json: real-world files" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var c = try jsonSet(try fixture(a, "vscode/c.json"), .linux);
    defer c.deinit();
    try expectNoErrors(&c);
    const gdb_launch = c.find("(gdb) Launch").?;
    try testing.expect(!gdb_launch.enabled);
    try testing.expect(std.mem.indexOf(u8, gdb_launch.disabled_reason.?, "MIMode gdb") != null);
    try testing.expectEqual(@as(usize, 1), gdb_launch.args.get("setupCommands").?.array.items.len);
    try testing.expect(!c.find("(Windows) Launch").?.enabled);
    try testing.expect(c.find("GDB direct").?.enabled);

    var rust = try jsonSet(try fixture(a, "vscode/rust.json"), .linux);
    defer rust.deinit();
    try expectNoErrors(&rust);
    const exe = rust.find("Debug executable 'hello'").?;
    try testing.expectEqualStrings("codelldb", exe.type);
    try testing.expectEqualStrings("hello", exe.args.get("cargo").?.object.get("filter").?.object.get("name").?.string);
    try testing.expectEqual(.attach, rust.find("Attach").?.request);
    try testing.expectEqualStrings("${command:pickMyProcess}", rust.find("Attach").?.argString("pid").?);

    var py = try jsonSet(try fixture(a, "vscode/python.json"), .linux);
    defer py.deinit();
    try expectNoErrors(&py);
    try testing.expectEqual(@as(usize, 3), py.configs.len);
    for (py.configs) |cfg| try testing.expectEqualStrings("debugpy", cfg.type);
    try testing.expectEqual(@as(i64, 5678), py.find("Python: Remote Attach").?.args.get("connect").?.object.get("port").?.integer);
    try testing.expectEqualStrings("app", py.findInput("module").?.default.?);

    var node = try jsonSet(try fixture(a, "vscode/node.json"), .linux);
    defer node.deinit();
    try expectNoErrors(&node);
    try testing.expectEqualStrings("js-debug", node.find("Server").?.type);
    try testing.expectEqualStrings("js-debug", node.find("Client").?.type);
    try testing.expectEqual(@as(?i64, 2), node.find("Client").?.presentation.?.order);
    const ext = node.find("Run Extension").?;
    try testing.expect(!ext.enabled);
    try testing.expectEqualStrings("No adapter for type \"extensionHost\"", ext.disabled_reason.?);
    const both = node.findCompound("Server + Client").?;
    try testing.expectEqual(@as(usize, 2), both.configurations.len);
    try testing.expectEqualStrings("Client", both.configurations[1]);
    try testing.expect(both.stop_all);
    try testing.expectEqualStrings("npm: build", both.pre_launch_task.?);
    const env_in = node.findInput("env").?;
    try testing.expectEqual(.pickString, env_in.type);
    try testing.expectEqualStrings("prod", env_in.options[1]);
}

test "compounds: references and empty lists are checked" {
    var s = try ConfigSet.fromSources(gpa, .{
        .launch_zon =
        \\.{
        \\    .configurations = .{ .{ .name = "a", .type = "gdb", .request = .launch } },
        \\    .compounds = .{
        \\        .{ .name = "good", .configurations = .{"a"} },
        \\        .{ .name = "dangling", .configurations = .{ "a", "zz" } },
        \\        .{ .name = "empty", .configurations = .{} },
        \\    },
        \\}
        ,
        .os = .linux,
        .trusted = true,
    });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.compounds.len);
    try testing.expectEqual(@as(usize, 2), s.errors.len);
    try testing.expect(hasError(&s, "compound \"dangling\": no configuration named \"zz\""));
    try testing.expect(hasError(&s, "compound \"empty\" lists no configurations"));
}

test "launch configurations: launch.zon wins a name, untrusted disables all" {
    const zon = ".{ .configurations = .{ .{ .name = \"App\", .type = \"gdb\", .request = .launch } } }";
    const json = "{ \"configurations\": [ { \"name\": \"App\", \"type\": \"lldb\", \"request\": \"launch\" }, { \"name\": \"Other\", \"type\": \"gdb\", \"request\": \"launch\" } ] }";
    var s = try ConfigSet.fromSources(gpa, .{ .launch_zon = zon, .launch_json = json, .os = .linux, .trusted = true });
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.configs.len);
    try testing.expectEqual(.zon, s.find("App").?.source);
    try testing.expect(s.find("App").?.enabled);
    try testing.expect(!s.configs[1].enabled);
    try testing.expectEqual(@as(usize, 1), s.errors.len);
    try testing.expectEqualStrings(".vscode/launch.json", s.errors[0].file);

    var u = try ConfigSet.fromSources(gpa, .{ .launch_zon = zon, .launch_json = json, .os = .linux, .trusted = false });
    defer u.deinit();
    for (u.configs) |c| {
        try testing.expect(!c.enabled);
        try testing.expectEqualStrings(ConfigSet.untrusted_reason, c.disabled_reason.?);
    }
}

test "launch.zon: save and read back" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // From launch.zon, and from an imported launch.json ("Convert").
    for ([_]ConfigSet.Inputs{
        .{ .launch_zon = try fixture(a, "zon/launch.zon"), .os = .linux, .trusted = true },
        .{ .launch_json = try fixture(a, "vscode/node.json"), .os = .linux, .trusted = true },
    }) |in| {
        var s = try ConfigSet.fromSources(gpa, in);
        defer s.deinit();
        const text = try s.saveZon(gpa);
        defer gpa.free(text);
        const z = try a.dupeZ(u8, text);
        var back = try ConfigSet.fromSources(gpa, .{ .launch_zon = z, .os = .linux, .trusted = true });
        defer back.deinit();
        try testing.expectEqual(s.configs.len, back.configs.len);
        for (s.configs, back.configs) |x, y| {
            try testing.expectEqualStrings(x.name, y.name);
            try testing.expectEqualStrings(x.type, y.type);
            try testing.expectEqual(x.request, y.request);
            try testing.expectEqual(x.args.count(), y.args.count());
            try testing.expectEqual(x.enabled, y.enabled);
        }
        try testing.expectEqual(s.compounds.len, back.compounds.len);
        try testing.expectEqual(s.inputs.len, back.inputs.len);
        // Saving again gives the same text.
        const again = try back.saveZon(gpa);
        defer gpa.free(again);
        try testing.expectEqualStrings(text, again);
    }
    // Enum-valued keys are written as enum literals.
    var s = try ConfigSet.fromSources(gpa, .{ .launch_zon = try fixture(a, "zon/launch.zon"), .os = .linux, .trusted = true });
    defer s.deinit();
    const text = try s.saveZon(gpa);
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".request = .launch,") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".@\"MY-VAR\" = \"1\",") != null);
}

test "launch configurations: reload on file change" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var cache: ConfigSet.Cache = .init(gpa, .{ .root = root, .trusted = true }, .linux);
    defer cache.deinit();
    var s = try cache.get(io);
    try testing.expectEqual(@as(usize, 0), s.configs.len);
    try testing.expectEqual(s, try cache.get(io));

    try tmp.dir.createDirPath(io, ".zigguro");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/launch.zon", .data = ".{ .configurations = .{ .{ .name = \"a\", .type = \"gdb\", .request = .launch } } }" });
    try testing.expect(cache.fileChanged(".zigguro/launch.zon"));
    const before = s;
    s = try cache.get(io);
    try testing.expect(before != s);
    try testing.expectEqual(@as(usize, 0), before.configs.len);
    try testing.expectEqualStrings("a", s.configs[0].name);

    var abs_buf: [128]u8 = undefined;
    try tmp.dir.createDirPath(io, ".vscode");
    try tmp.dir.writeFile(io, .{ .sub_path = ".vscode/launch.json", .data = "{ \"configurations\": [ { \"name\": \"b\", \"type\": \"node\", \"request\": \"launch\" } ] }" });
    try testing.expect(cache.fileChanged(try std.fmt.bufPrint(&abs_buf, "{s}/.vscode\\launch.json", .{root})));
    try testing.expect(!cache.fileChanged(".vscode/tasks.json"));
    s = try cache.get(io);
    try testing.expectEqual(@as(usize, 2), s.configs.len);

    cache.setTrusted(false);
    s = try cache.get(io);
    try testing.expect(!s.configs[0].enabled);
}
