//! Task sources and the merged list: `zig build -l` output captured from
//! real builds, `tasks.zon`, VS Code `tasks.json` files as Zig, C, Rust
//! and Node projects write them (testdata/tasks/), then merging, trust
//! and reloading.

const std = @import("std");
const options = @import("zg_options");
const Task = @import("Task.zig");
const TaskList = @import("TaskList.zig");
const zig_build = @import("sources/zig_build.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;

fn fixture(a: Allocator, rel: []const u8) ![:0]u8 {
    const path = try std.fs.path.join(a, &.{ options.package_root, "testdata", "tasks", rel });
    return std.Io.Dir.cwd().readFileAllocOptions(testing.io, path, a, .limited(1 << 20), .of(u8), 0);
}

fn expectArgs(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

fn expectNoWarnings(l: *const TaskList) !void {
    for (l.warnings) |w| std.debug.print("unexpected warning: {s}: {s}\n", .{ w.file, w.message });
    try testing.expectEqual(@as(usize, 0), l.warnings.len);
}

fn named(t: *const Task, i: usize) []const u8 {
    return t.problem_matchers[i].named;
}

test "tasks: zig build -l fixture -> tasks with defaults, watch variant and check tag" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try fixture(arena.allocator(), "zig_init_check_build_l.txt");
    var l = try TaskList.fromSources(gpa, .{ .zig_steps = text, .os = .linux, .trusted = true });
    defer l.deinit();
    try expectNoWarnings(&l);

    // install, uninstall, run, test, check and the watch task.
    try testing.expectEqual(@as(usize, 6), l.all().len);
    const install = l.byLabel("zig build install").?;
    try testing.expectEqual(Task.Source.zig, install.source);
    try testing.expectEqual(Task.Kind.process, install.kind);
    try testing.expectEqualStrings("zig", install.command);
    try expectArgs(&.{ "build", "install" }, install.args);
    try testing.expectEqualStrings("$zig", named(install, 0));
    try testing.expectEqualStrings("Copy build artifacts to prefix path", install.detail.?);
    try testing.expectEqual(install, l.defaultFor(.build).?);
    try testing.expectEqual(l.byLabel("zig build test").?, l.defaultFor(.@"test").?);
    try testing.expectEqual(l.byLabel("zig build check").?, l.tagged("check").?);
    try testing.expect(l.byLabel("zig build run").?.group == null);

    const watch = l.byLabel("zig build --watch").?;
    try testing.expect(watch.is_background);
    try expectArgs(&.{ "build", "--watch" }, watch.args);
    try testing.expectEqualStrings("$zig-watch", named(watch, 0));
    try testing.expectEqual(watch, l.tagged("watch").?);
}

test "tasks: zig build -l of a large build and a custom zig path" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = try fixture(arena.allocator(), "zigguro_build_l.txt");
    const steps = try zig_build.parseSteps(arena.allocator(), text);
    var l = try TaskList.fromSources(gpa, .{ .zig_steps = text, .zig_exe = "/opt/zig/zig", .os = .linux, .trusted = true });
    defer l.deinit();
    try expectNoWarnings(&l);
    try testing.expectEqual(steps.len + 1, l.all().len);
    try testing.expectEqualStrings("/opt/zig/zig", l.defaultFor(.build).?.command);
    // No step is called `check`; `check-gen` and friends are not it.
    try testing.expect(l.tagged("check") == null);
    // A build without `install` takes the `(default)` step.
    var l2 = try TaskList.fromSources(gpa, .{ .zig_steps = "  all (default)   Everything\n  docs   Docs\n", .os = .linux, .trusted = true });
    defer l2.deinit();
    try testing.expectEqualStrings("zig build all", l2.defaultFor(.build).?.label);
}

test "tasks: tasks.zon parse incl. inline matcher" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src = try fixture(arena.allocator(), "tasks.zon");
    var l = try TaskList.fromSources(gpa, .{ .tasks_zon = src, .os = .linux, .trusted = true });
    defer l.deinit();
    try expectNoWarnings(&l);
    try testing.expectEqual(@as(usize, 3), l.all().len);

    const build = l.byLabel("build release").?;
    try testing.expectEqual(Task.Source.zon, build.source);
    try expectArgs(&.{ "build", "-Doptimize=ReleaseFast" }, build.args);
    try testing.expectEqual(build, l.defaultFor(.build).?);
    try testing.expectEqualStrings("$zig", named(build, 0));
    try testing.expectEqual(.silent, build.presentation.reveal);
    try testing.expectEqual(.on_problem, build.presentation.reveal_problems);

    const t = l.byLabel("test all").?;
    try testing.expectEqual(Task.GroupKind.@"test", t.group.?.kind);
    try testing.expect(!t.group.?.is_default);
    try testing.expect(l.defaultFor(.@"test") == null);
    try expectArgs(&.{"build release"}, t.depends_on);
    try testing.expectEqual(Task.DependsOrder.sequence, t.depends_order);
    try testing.expectEqual(t, l.tagged("ci").?);

    const lint = l.byLabel("lint docs").?;
    try testing.expectEqual(Task.Kind.shell, lint.kind);
    // Variables stay as written until the task runs.
    try testing.expectEqualStrings("./tools/lint-docs.sh ${workspaceFolder}/docs", lint.command);
    try testing.expectEqualStrings("${workspaceFolder}", lint.cwd.?);
    try testing.expectEqualStrings("LINT_STRICT", lint.env[0][0]);
    try testing.expectEqualStrings("1", lint.env[0][1]);
    const d = lint.problem_matchers[0].inline_def;
    try testing.expectEqualStrings("lint-docs", d.owner);
    try testing.expectEqual(.warning, d.severity);
    try testing.expectEqualStrings("${workspaceFolder}", d.file_location.relative.?);
    try testing.expectEqualStrings("^(.+):(\\d+): (.*)$", d.patterns[0].regexp);
    try testing.expectEqual(@as(?u8, 3), d.patterns[0].message);
}

test "tasks: a tasks.zon that does not parse is a warning" {
    var l = try TaskList.fromSources(gpa, .{ .tasks_zon = ".{ .tasks = .{ .{ .label = 3 } } }", .os = .linux, .trusted = true });
    defer l.deinit();
    try testing.expectEqual(@as(usize, 0), l.all().len);
    try testing.expectEqual(@as(usize, 1), l.warnings.len);
    try testing.expectEqualStrings(".zigguro/tasks.zon", l.warnings[0].file);
    try testing.expect(std.mem.startsWith(u8, l.warnings[0].message, "1:"));

    var l2 = try TaskList.fromSources(gpa, .{ .tasks_zon = ".{ .version = 2 }", .os = .linux, .trusted = true });
    defer l2.deinit();
    try testing.expectEqualStrings("version 2 is not supported (expected 1)", l2.warnings[0].message);
}

test "tasks: tasks.json import incl. OS overrides and problemMatcher forms" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src = try fixture(arena.allocator(), "vscode/overrides.json");

    var lin = try TaskList.fromSources(gpa, .{ .tasks_json = src, .os = .linux, .trusted = true });
    defer lin.deinit();
    const b = lin.byLabel("build").?;
    try testing.expectEqual(Task.Source.vscode, b.source);
    try testing.expectEqual(Task.Kind.shell, b.kind);
    try testing.expectEqualStrings("./build.sh", b.command);
    // `{ "value": ..., "quoting": ... }` arguments give their value.
    try expectArgs(&.{ "--fast", "a b" }, b.args);
    // Global presentation and the task's merge.
    try testing.expect(!b.presentation.echo);
    try testing.expect(b.presentation.focus);
    try testing.expect(b.shell == null);
    try testing.expectEqual(@as(usize, 2), b.env.len);
    // `$name` and an inline object in one array.
    try testing.expectEqual(@as(usize, 2), b.problem_matchers.len);
    try testing.expectEqualStrings("$gcc", named(b, 0));
    const d = b.problem_matchers[1].inline_def;
    try testing.expectEqualStrings("custom", d.owner);
    try testing.expectEqual(.warning, d.severity);
    try testing.expect(d.file_location == .absolute);
    try testing.expectEqual(@as(?u8, 4), d.patterns[0].message);

    var win = try TaskList.fromSources(gpa, .{ .tasks_json = src, .os = .windows, .trusted = true });
    defer win.deinit();
    const wb = win.byLabel("build").?;
    try testing.expectEqualStrings(".\\build.ps1", wb.command);
    try testing.expectEqualStrings("pwsh.exe", wb.shell.?.executable);
    try expectArgs(&.{ "-NoProfile", "-Command" }, wb.shell.?.args);
    // `env` merges key by key: MODE from the Windows block, COLOR kept.
    var mode: ?[]const u8 = null;
    var color: ?[]const u8 = null;
    for (wb.env) |kv| {
        if (std.mem.eql(u8, kv[0], "MODE")) mode = kv[1];
        if (std.mem.eql(u8, kv[0], "COLOR")) color = kv[1];
    }
    try testing.expectEqualStrings("win", mode.?);
    try testing.expectEqualStrings("1", color.?);

    var mac = try TaskList.fromSources(gpa, .{ .tasks_json = src, .os = .macos, .trusted = true });
    defer mac.deinit();
    try testing.expectEqualStrings("./build-mac.sh", mac.byLabel("build").?.command);

    // A compound task: no command, dependencies in sequence.
    const all = lin.byLabel("all").?;
    try testing.expectEqualStrings("", all.command);
    try expectArgs(&.{ "build", "lint" }, all.depends_on);
    try testing.expectEqual(Task.DependsOrder.sequence, all.depends_order);
    try testing.expectEqual(@as(usize, 0), all.problem_matchers.len);

    // An unknown name stays (the runner reports it again); an incomplete
    // inline matcher is dropped. Both are warnings.
    const broken = lin.byLabel("broken").?;
    try testing.expectEqual(@as(usize, 1), broken.problem_matchers.len);
    try testing.expectEqualStrings("$nope", named(broken, 0));
    try testing.expectEqual(@as(usize, 2), lin.warnings.len);
    try testing.expectEqualStrings("task 'broken': unknown problem matcher '$nope'", lin.warnings[0].message);
    try testing.expectEqualStrings("task 'broken': a problem pattern needs file, message and line (or location) groups", lin.warnings[1].message);
}

test "tasks: sample tasks.json files from Zig, C, Rust and Node projects load" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var zig = try TaskList.fromSources(gpa, .{ .tasks_json = try fixture(a, "vscode/zig.json"), .os = .linux, .trusted = true });
    defer zig.deinit();
    try expectNoWarnings(&zig);
    try testing.expectEqual(@as(usize, 3), zig.all().len);
    try testing.expectEqualStrings("build", zig.defaultFor(.build).?.label);
    const t = zig.byLabel("test").?;
    try testing.expectEqual(Task.GroupKind.@"test", t.group.?.kind);
    try testing.expectEqual(.dedicated, t.presentation.panel);
    try testing.expect(t.presentation.clear);
    try expectArgs(&.{"build"}, zig.byLabel("run").?.depends_on);

    var c = try TaskList.fromSources(gpa, .{ .tasks_json = try fixture(a, "vscode/c_cpp.json"), .os = .linux, .trusted = true });
    defer c.deinit();
    try expectNoWarnings(&c);
    const gcc = c.byLabel("C/C++: gcc build active file").?;
    try testing.expect(gcc.enabled);
    try testing.expectEqual(Task.Kind.process, gcc.kind);
    try testing.expectEqualStrings("${fileDirname}", gcc.cwd.?);
    try testing.expectEqualStrings("Task generated by Debugger.", gcc.detail.?);
    try testing.expectEqual(gcc, c.defaultFor(.build).?);
    // `base` extends a built-in.
    const make = c.byLabel("make").?.problem_matchers[0].inline_def;
    try testing.expectEqualStrings("cpp", make.owner);
    try testing.expectEqualStrings("${workspaceFolder}/build", make.file_location.relative.?);
    try testing.expectEqual(@as(usize, 1), make.patterns.len);
    try testing.expectEqual(.silent, c.byLabel("msbuild").?.presentation.reveal);

    var rust = try TaskList.fromSources(gpa, .{ .tasks_json = try fixture(a, "vscode/rust.json"), .os = .linux, .trusted = true });
    defer rust.deinit();
    try expectNoWarnings(&rust);
    try testing.expectEqualStrings("cargo test", rust.defaultFor(.@"test").?.label);
    try testing.expectEqualStrings("RUST_BACKTRACE", rust.byLabel("cargo test").?.env[0][0]);
    const w = rust.byLabel("cargo watch").?;
    try testing.expect(w.is_background);
    const bg = w.problem_matchers[0].inline_def;
    try testing.expectEqual(@as(usize, 2), bg.patterns.len);
    try testing.expect(bg.background.?.active_on_start);
    try testing.expectEqualStrings("^\\[Running ", bg.background.?.begins);

    var node = try TaskList.fromSources(gpa, .{ .tasks_json = try fixture(a, "vscode/node.json"), .os = .linux, .trusted = true });
    defer node.deinit();
    try expectNoWarnings(&node);
    try testing.expectEqual(@as(usize, 4), node.all().len);
    // A glob `isDefault` still makes the task the default.
    try testing.expectEqualStrings("tsc", node.defaultFor(.build).?.label);
    try testing.expectEqual(Task.RunOn.folder_open, node.byLabel("lint").?.run_on);
}

test "tasks: unsupported types disabled with hint" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var node = try TaskList.fromSources(gpa, .{ .tasks_json = try fixture(a, "vscode/node.json"), .os = .linux, .trusted = true });
    defer node.deinit();
    // npm tasks without a label take VS Code's `npm: <script>`.
    const npm = node.byLabel("npm: build").?;
    try testing.expect(!npm.enabled);
    try testing.expectEqualStrings("'npm' tasks come from a VS Code extension; zigguro runs shell and process tasks (write it as one in .zigguro/tasks.zon)", npm.disabled_reason.?);
    try testing.expectEqualStrings("webpack --mode production", npm.detail.?);
    try testing.expect(!node.byLabel("npm: watch").?.enabled);
    try testing.expect(node.byLabel("tsc").?.enabled);

    var rust = try TaskList.fromSources(gpa, .{ .tasks_json = try fixture(a, "vscode/rust.json"), .os = .linux, .trusted = true });
    defer rust.deinit();
    const cargo = rust.byLabel("rust: cargo build").?;
    try testing.expect(!cargo.enabled);
    try testing.expect(std.mem.startsWith(u8, cargo.disabled_reason.?, "'cargo' tasks"));
}

test "tasks: merge order and label collisions" {
    const zon =
        \\.{ .tasks = .{
        \\    .{ .label = "zig build test", .command = "zig", .args = .{ "build", "test", "-Dslow" } },
        \\    .{ .label = "build", .command = "make" },
        \\} }
    ;
    const json =
        \\{ "version": "2.0.0", "tasks": [
        \\    { "label": "build", "type": "shell", "command": "ninja" },
        \\    { "label": "lint", "type": "shell", "command": "lint" }
        \\] }
    ;
    var l = try TaskList.fromSources(gpa, .{
        .tasks_zon = zon,
        .tasks_json = json,
        .zig_steps = "  install (default)   Install\n  test   Run tests\n",
        .os = .linux,
        .trusted = true,
    });
    defer l.deinit();
    const labels = [_][]const u8{ "zig build test", "build", "lint", "zig build install", "zig build --watch" };
    try testing.expectEqual(labels.len, l.all().len);
    for (labels, l.all()) |want, t| try testing.expectEqualStrings(want, t.label);
    try testing.expectEqualStrings("make", l.byLabel("build").?.command);
    try testing.expectEqual(Task.Source.zon, l.byLabel("zig build test").?.source);
    // The zon task has no group, so the zig `test` step's default is gone
    // with it.
    try testing.expect(l.defaultFor(.@"test") == null);

    try testing.expectEqual(@as(usize, 2), l.warnings.len);
    try testing.expectEqualStrings(".vscode/tasks.json", l.warnings[0].file);
    try testing.expectEqualStrings("task 'build' has the label of a task in .zigguro/tasks.zon, which is the one listed", l.warnings[0].message);
    try testing.expectEqualStrings("build.zig", l.warnings[1].file);
}

test "tasks: untrusted workspace disables workspace tasks" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var l = try TaskList.fromSources(gpa, .{
        .tasks_zon = try fixture(a, "tasks.zon"),
        .tasks_json = try fixture(a, "vscode/node.json"),
        .zig_steps = "  install (default)   Install\n",
        .os = .linux,
        .trusted = false,
    });
    defer l.deinit();
    try testing.expectEqual(@as(usize, 3 + 4 + 2), l.all().len);
    for (l.all()) |t| {
        try testing.expect(!t.enabled);
        try testing.expectEqualStrings(TaskList.untrusted_reason, t.disabled_reason.?);
    }
}

const FakeZig = struct {
    calls: usize = 0,
    text: []const u8 = "  install (default)   Install\n  test   Run tests\n",

    fn run(ctx: ?*anyopaque, a: Allocator, _: std.Io, _: []const u8, _: []const u8, _: ?*const std.process.Environ.Map) ?[]u8 {
        const f: *FakeZig = @ptrCast(@alignCast(ctx.?));
        f.calls += 1;
        return a.dupe(u8, f.text) catch null;
    }
};

test "tasks: reload on file change" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [64]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "pub fn build(_: anytype) void {}\n" });
    try tmp.dir.setTimestamps(io, "build.zig", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 1_000_000_000 } } });

    var fake: FakeZig = .{};
    var cache: TaskList.Cache = .init(gpa, .{ .root = root, .trusted = true }, .linux, .{});
    defer cache.deinit();
    cache.runner = .{ .ctx = &fake, .run = FakeZig.run };

    var l = try cache.get(io);
    try testing.expectEqual(@as(usize, 3), l.all().len);
    try testing.expectEqual(@as(usize, 1), fake.calls);
    // Nothing changed: the same list, no reload.
    try testing.expectEqual(l, try cache.get(io));

    // A new tasks.zon: reloaded, and `zig build -l` not run again.
    try tmp.dir.createDirPath(io, ".zigguro");
    try tmp.dir.writeFile(io, .{ .sub_path = ".zigguro/tasks.zon", .data = ".{ .tasks = .{ .{ .label = \"fmt\", .command = \"zig\", .args = .{\"fmt\"} } } }" });
    try testing.expect(cache.fileChanged(".zigguro/tasks.zon"));
    try testing.expect(cache.stale());
    const before = l;
    l = try cache.get(io);
    // The old list is still readable (a runner may hold it).
    try testing.expect(before != l);
    try testing.expectEqual(@as(usize, 3), before.all().len);
    try testing.expectEqualStrings("fmt", l.all()[0].label);
    try testing.expectEqual(@as(usize, 4), l.all().len);
    try testing.expectEqual(@as(usize, 1), fake.calls);

    // A watcher's absolute (or Windows-style) path works too; other files
    // are not ours.
    var abs_buf: [128]u8 = undefined;
    try testing.expect(cache.fileChanged(try std.fmt.bufPrint(&abs_buf, "{s}/.vscode\\tasks.json", .{root})));
    try testing.expect(!cache.fileChanged("src/main.zig"));
    try testing.expect(!cache.fileChanged("build.zig.zon.bak"));

    // build.zig changed: steps listed again.
    fake.text = "  install (default)   Install\n  test   Run tests\n  check   Check\n";
    try tmp.dir.setTimestamps(io, "build.zig", .{ .modify_timestamp = .{ .new = .{ .nanoseconds = 2_000_000_000 } } });
    try testing.expect(cache.fileChanged("build.zig"));
    l = try cache.get(io);
    try testing.expectEqual(@as(usize, 2), fake.calls);
    try testing.expect(l.tagged("check") != null);

    // Distrusting the workspace: everything disabled, zig not run.
    cache.setTrusted(false);
    l = try cache.get(io);
    try testing.expectEqual(@as(usize, 2), fake.calls);
    try testing.expectEqual(@as(usize, 1), l.all().len);
    try testing.expect(!l.all()[0].enabled);
}
