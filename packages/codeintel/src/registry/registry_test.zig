const std = @import("std");
const builtin = @import("builtin");
const Registry = @import("Registry.zig");
const routing = @import("routing.zig");

const testing = std.testing;
const Io = std.Io;

fn ids(r: *const Registry, lang: []const u8, path: ?[]const u8, buf: []u8) ![]const u8 {
    var defs: std.ArrayList(*const Registry.ServerDef) = .empty;
    defer defs.deinit(testing.allocator);
    try r.defsForDoc(lang, path, &defs, testing.allocator);
    var w: std.Io.Writer = .fixed(buf);
    for (defs.items, 0..) |d, i| try w.print("{s}{s}", .{ if (i > 0) "," else "", d.id });
    return w.buffered();
}

test "registry: builtin defs load" {
    var r: Registry = try .init(testing.allocator, .{});
    defer r.deinit();
    try testing.expectEqual(@as(usize, 6), r.defs.len);
    const zls = r.get("zls").?;
    try testing.expectEqualStrings("zls", zls.command[0]);
    try testing.expectEqualStrings("build.zig", zls.root_markers[0]);
    try testing.expectEqualStrings("zls", zls.settings_section.?);
    try testing.expectEqualStrings("--stdio", r.get("pyright").?.command[1]);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("zls", try ids(&r, "zon", null, &buf));
    try testing.expectEqualStrings("clangd", try ids(&r, "cpp", "/x/a.cc", &buf));
    try testing.expectEqualStrings("", try ids(&r, "markdown", "/x/a.md", &buf));
}

test "registry: settings override, disable and add servers" {
    const overrides = [_]Registry.Override{
        .{ .id = "clangd", .enabled = false },
        .{ .id = "zls", .command = &.{ "/opt/zls/zls", "--enable-debug-log" }, .features_except = &.{.formatting} },
        .{ .id = "templ", .command = &.{ "templ", "lsp" }, .languages = &.{"templ"}, .file_patterns = &.{"*.templ"} },
        // A new server without a command is ignored.
        .{ .id = "half", .languages = &.{"x"} },
    };
    var r: Registry = try .init(testing.allocator, .{ .overrides = &overrides });
    defer r.deinit();
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("", try ids(&r, "c", null, &buf));
    const zls = r.get("zls").?;
    try testing.expectEqualStrings("/opt/zls/zls", zls.command[0]);
    try testing.expect(!zls.allows(.formatting) and zls.allows(.hover));
    try testing.expectEqualStrings("templ", try ids(&r, "plaintext", "/w/views/page.templ", &buf));
    try testing.expect(r.get("half") == null);
}

test "registry: untrusted workspace command ignored" {
    const overrides = [_]Registry.Override{
        .{ .id = "zls", .scope = .workspace, .command = &.{"./evil"}, .root_markers = &.{"x.zig"} },
        .{ .id = "new", .scope = .folder, .command = &.{"./evil"}, .languages = &.{"zig"} },
    };
    {
        var r: Registry = try .init(testing.allocator, .{ .overrides = &overrides, .trusted = false });
        defer r.deinit();
        try testing.expectEqualStrings("zls", r.get("zls").?.command[0]);
        // Other fields still apply.
        try testing.expectEqualStrings("x.zig", r.get("zls").?.root_markers[0]);
        try testing.expect(r.get("new") == null);
        try testing.expectEqual(@as(usize, 2), r.ignored_commands.len);
    }
    var r: Registry = try .init(testing.allocator, .{ .overrides = &overrides, .trusted = true });
    defer r.deinit();
    try testing.expectEqualStrings("./evil", r.get("zls").?.command[0]);
    try testing.expect(r.get("new") != null);
}

test "registry: PATH resolution (symlink on linux, PATHEXT on windows)" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPathFile(io, ".", &root_buf)];
    try tmp.dir.createDirPath(io, "a");
    try tmp.dir.createDirPath(io, "b");
    const exe_name = if (builtin.os.tag == .windows) "b/zls.EXE" else "b/zls-real";
    try tmp.dir.writeFile(io, .{ .sub_path = exe_name, .data = "#!/bin/sh\n", .flags = .{ .permissions = .executable_file } });
    if (builtin.os.tag != .windows) try tmp.dir.symLink(io, "zls-real", "b/zls", .{});
    // Not executable: skipped.
    try tmp.dir.writeFile(io, .{ .sub_path = "a/zls", .data = "", .flags = .{ .permissions = .default_file } });

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const path_var = try std.fmt.allocPrint(testing.allocator, "{s}{c}a{c}{s}{c}b", .{ root, std.fs.path.sep, sep, root, std.fs.path.sep });
    defer testing.allocator.free(path_var);
    try env.put("PATH", path_var);
    if (builtin.os.tag == .windows) try env.put("PATHEXT", ".COM;.EXE");

    var r: Registry = try .init(testing.allocator, .{});
    defer r.deinit();
    const found = (try r.resolveExecutable(io, r.get("zls").?, &env)) orelse return error.NotFound;
    try testing.expect(std.mem.indexOf(u8, found, "b") != null);
    // Windows names are case-insensitive; PATHEXT spells the extension.
    try testing.expect(std.ascii.endsWithIgnoreCase(found, if (builtin.os.tag == .windows) "zls.exe" else "zls"));
    // Cached, and a missing server is null.
    try testing.expectEqualStrings(found, (try r.resolveExecutable(io, r.get("zls").?, &env)).?);
    try testing.expect(try r.resolveExecutable(io, r.get("gopls").?, &env) == null);
    r.rescan();
    try testing.expect(try r.resolveExecutable(io, r.get("zls").?, &env) != null);
}

test "registry: findRoot picks the nearest marker inside the workspace" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ws = root_buf[0..try tmp.dir.realPathFile(io, ".", &root_buf)];
    try tmp.dir.createDirPath(io, "pkg/src/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/build.zig", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    const a = testing.allocator;
    const file = try std.fs.path.join(a, &.{ ws, "pkg", "src", "deep", "main.zig" });
    defer a.free(file);
    const pkg = try std.fs.path.join(a, &.{ ws, "pkg" });
    defer a.free(pkg);
    var r: Registry = try .init(a, .{});
    defer r.deinit();
    try testing.expectEqualStrings(pkg, Registry.findRoot(io, r.get("zls").?, file, &.{ws}));
    // No marker for this server: the workspace folder.
    try testing.expectEqualStrings(ws, Registry.findRoot(io, r.get("gopls").?, file, &.{ws}));
}

test "routing: feature allow/deny and merge policy table" {
    const a: Registry.ServerDef = .{ .id = "a", .command = &.{"a"}, .languages = &.{"x"} };
    const b: Registry.ServerDef = .{ .id = "b", .command = &.{"b"}, .languages = &.{"x"}, .features_except = &.{.hover} };
    const c: Registry.ServerDef = .{ .id = "c", .command = &.{"c"}, .languages = &.{"x"}, .features_only = &.{.completion} };
    const C = routing.Candidate(u8);
    var out: [3]u8 = undefined;
    // Completion merges from all that support it.
    const all = [_]C{ .{ .def = &a, .ctx = 'a', .supports = true }, .{ .def = &b, .ctx = 'b', .supports = true }, .{ .def = &c, .ctx = 'c', .supports = true } };
    try testing.expectEqualStrings("abc", out[0..routing.select(u8, .completion, &all, &out)]);
    // Hover goes to the first allowed: a; without a, b is denied and c is not allowed.
    try testing.expectEqualStrings("a", out[0..routing.select(u8, .hover, &all, &out)]);
    try testing.expectEqualStrings("", out[0..routing.select(u8, .hover, all[1..], &out)]);
    // Capabilities decide too.
    const no_a = [_]C{ .{ .def = &a, .ctx = 'a', .supports = false }, .{ .def = &b, .ctx = 'b', .supports = true } };
    try testing.expectEqualStrings("b", out[0..routing.select(u8, .semantic_tokens_full, &no_a, &out)]);
    try testing.expectEqual(routing.Policy.first, routing.policy(.rename));
    try testing.expectEqual(routing.Policy.merge_all, routing.policy(.references));
}

test "registry: version probe reads the first line" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const def: Registry.ServerDef = .{
        .id = "sh",
        .command = &.{"/bin/sh"},
        .languages = &.{"x"},
        .version_args = &.{ "-c", "echo; echo '  zls 0.16.0 '; echo more" },
    };
    var r: Registry = try .init(testing.allocator, .{});
    defer r.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const v = (try r.probeVersion(testing.io, testing.allocator, &def, &env, .fromSeconds(2))).?;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("zls 0.16.0", v);
}

test "registry: version probe timeout" {
    const io = testing.io;
    // Sleeps until killed and prints nothing.
    const def: Registry.ServerDef = .{
        .id = "sleeper",
        .command = &.{@import("zg_test_exes").fake_lsp_server},
        .languages = &.{"x"},
        .version_args = &.{"--sleep"},
    };
    var r: Registry = try .init(testing.allocator, .{});
    defer r.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    const t0 = Io.Clock.Timestamp.now(io, .awake);
    try testing.expect(try r.probeVersion(io, testing.allocator, &def, &env, .fromSeconds(2)) == null);
    const took = t0.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds();
    try testing.expect(took >= 1900 and took < 2200);
    // A missing server is null at once.
    try testing.expect(try r.probeVersion(io, testing.allocator, r.get("gopls").?, &env, .fromSeconds(2)) == null);
}
