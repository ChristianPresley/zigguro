//! Benchmarks for zg_config; run with `zig build bench` at the repo root.
//! Covers the hot paths of E15: loading a settings file, typed handle reads,
//! when-clause evaluation, command dispatch and key resolution.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_config = @import("zg_config");
const bench = zg_core.bench;
const State = bench.State;

const zon_load = zg_config.zon_load;
const diag = zg_config.diag;
const context = zg_config.context;
const commands = zg_config.commands;
const keymap = zg_config.keymap;
const resolver = zg_config.resolver;
const keys = zg_config.keys;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

fn register(b: *bench.Bench) !void {
    const settings_src = try settingsFile(b.gpa, 200);
    defer b.gpa.free(settings_src);
    try b.run("zon_load: 200-entry settings file", settings_src, zonLoad);
    try b.run("store: typed handle get", {}, handleGet);
    try b.run("when: eval 'editorTextFocus && !editorReadonly && editorLangId == zig'", {}, whenEval);
    try b.run("commands: execute noop", {}, executeNoop);
    try b.run("resolver: single stroke (vscode preset)", {}, resolveStroke);
}

fn settingsFile(gpa: std.mem.Allocator, n: usize) ![:0]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(".{\n");
    for (0..n) |i| try w.print("    .@\"section{d}.setting{d}\" = .{{ .a = {d}, .b = \"value {d}\", .c = .{{ true, false, 1.5 }} }},\n", .{ i % 10, i, i, i });
    try w.writeAll("}\n");
    return aw.toOwnedSliceSentinel(0);
}

fn zonLoad(src: [:0]u8, s: *State) void {
    s.setBytes(src.len);
    for (0..s.iterations()) |_| {
        var d = diag.Diags.init(s.allocator());
        defer d.deinit();
        var doc = zon_load.loadZon(s.allocator(), src, &d) catch unreachable;
        bench.doNotOptimizeAway(doc.root.v.object.len);
        doc.deinit();
    }
}

const Schema = zg_config.store.Settings(zg_config.settings_schema);
const reg_schema = zg_config.schema.SchemaRegistry.comptimeInit(.{zg_config.settings_schema});

fn handleGet(_: void, s: *State) void {
    const io = s.ioHandle();
    const st = zg_config.store.SettingsStore.init(s.allocator(), io, &reg_schema, .{}) catch unreachable;
    defer st.deinit();
    var h = Schema.handle(i64, "keyboard.chordTimeoutMs");
    h.bind(&reg_schema);
    const snap = st.current();
    var sum: i64 = 0;
    for (0..s.iterations()) |_| {
        sum +%= h.get(snap);
        bench.doNotOptimizeAway(sum);
    }
}

fn whenEval(_: void, s: *State) void {
    var svc = context.ContextKeyService.init(s.allocator());
    defer svc.deinit();
    var d = diag.Diags.init(s.allocator());
    defer d.deinit();
    var w = zg_config.when.When.compile(s.allocator(), "editorTextFocus && !editorReadonly && editorLangId == zig", &svc, &d) catch unreachable;
    defer w.deinit();
    svc.setByName("editorTextFocus", .{ .bool = true }) catch unreachable;
    svc.setByName("editorLangId", .{ .str = "zig" }) catch unreachable;
    const env: context.EvalEnv = .{ .global = &svc };
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(w.eval(&env));
}

fn executeNoop(_: void, s: *State) void {
    var svc = context.ContextKeyService.init(s.allocator());
    defer svc.deinit();
    const reg = commands.CommandRegistry.init(s.allocator(), &svc, .{ .io = s.ioHandle() }) catch unreachable;
    defer reg.deinit();
    commands.registerBuiltins(reg) catch unreachable;
    const id = reg.lookup("noop").?;
    for (0..s.iterations()) |_| reg.execute(id, null, .keybinding) catch unreachable;
}

fn resolveStroke(_: void, s: *State) void {
    const gpa = s.allocator();
    var svc = context.ContextKeyService.init(gpa);
    defer svc.deinit();
    context.registerStandard(&svc, .linux) catch unreachable;
    const reg = commands.CommandRegistry.init(gpa, &svc, .{ .io = s.ioHandle() }) catch unreachable;
    defer reg.deinit();
    commands.registerBuiltins(reg) catch unreachable;
    var d = diag.Diags.init(gpa);
    defer d.deinit();
    var doc = zon_load.loadZon(gpa, zg_config.presets.presetSource(.vscode).?, &d) catch unreachable;
    defer doc.deinit();
    // Register every command the preset names so all bindings are live.
    for (doc.root.v.array) |e| {
        const c = e.get("command").?.v.string;
        if (c.len == 0 or c[0] == '-' or reg.lookup(c) != null) continue;
        _ = reg.register(.{ .id = c, .title = c }) catch unreachable;
    }
    const km = keymap.Keymap.build(gpa, &.{.{ .layer = .preset, .doc = &doc }}, reg, &svc, .linux, &d) catch unreachable;
    defer km.deinit();
    const r = resolver.Resolver.init(gpa, &svc, &keys.us_layout, .{ .platform = .linux }) catch unreachable;
    defer r.deinit();
    r.reload(km);
    const stack = [_]context.KeyContext{ .{ .name = "editorFocus" }, .{ .name = "editorTextFocus" } };
    // Ctrl+/ (toggle line comment): a when-guarded binding.
    const ev: keys.KeyInput = .{ .usage = 0x38, .mods = .{ .ctrl = true } };
    for (0..s.iterations()) |_| bench.doNotOptimizeAway(r.resolve(&stack, ev));
}
