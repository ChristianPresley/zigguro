const std = @import("std");
const builtin = @import("builtin");
const options = @import("zg_options");
const zls = @import("zls.zig");
const testing = std.testing;

fn fixture(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(a, &.{ options.package_root, "testdata", "zls", name });
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, a, .limited(1 << 20));
}

fn v(text: []const u8) std.SemanticVersion {
    return std.SemanticVersion.parse(text) catch unreachable;
}

test "zls: parse zig version strings" {
    const tagged = try zls.parseVersion("0.16.0\n");
    try testing.expectEqual(@as(usize, 16), tagged.minor);
    try testing.expect(tagged.pre == null);
    const dev = try zls.parseVersion("0.17.0-dev.123+abcdef0");
    try testing.expectEqualStrings("dev.123", dev.pre.?);
    try testing.expectEqualStrings("abcdef0", dev.build.?);
    try testing.expectEqual(@as(usize, 1), (try zls.parseVersion("zls 0.16.1")).patch);
    try testing.expectError(error.InvalidVersion, zls.parseVersion("zig: command not found"));
    try testing.expectError(error.InvalidVersion, zls.parseVersion(""));
}

test "zls: pairing matrix" {
    const P = zls.Pairing;
    try testing.expectEqual(P.ok, zls.checkPairing(v("0.16.0"), v("0.16.0")));
    try testing.expectEqual(P.patch_mismatch_ok, zls.checkPairing(v("0.16.0"), v("0.16.2")));
    try testing.expectEqual(P.minor_mismatch, zls.checkPairing(v("0.16.0"), v("0.15.1")));
    try testing.expectEqual(P.minor_mismatch, zls.checkPairing(v("1.0.0"), v("0.16.0")));
    try testing.expectEqual(P.dev_mismatch, zls.checkPairing(v("0.17.0-dev.12+abc"), v("0.16.0")));
    try testing.expectEqual(P.dev_mismatch, zls.checkPairing(v("0.16.0"), v("0.17.0-dev.3+def")));
    try testing.expectEqual(P.ok, zls.checkPairing(v("0.17.0-dev.12+abc"), v("0.17.0-dev.9+def")));
    try testing.expectEqual(P.dev_mismatch, zls.checkPairing(v("0.17.0-dev.12+abc"), v("0.18.0-dev.1+def")));
    var buf: [256]u8 = undefined;
    try testing.expect(zls.pairingWarning(&buf, v("0.16.0"), v("0.16.3")) == null);
    const w = zls.pairingWarning(&buf, v("0.16.0"), v("0.15.1")).?;
    try testing.expect(std.mem.startsWith(u8, w, "ZLS 0.15.1 does not match Zig 0.16.0"));
}

test "zls: config section mapping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tc: zls.ZigToolchain = .{ .exe_path = "/opt/zig/zig", .version = v("0.16.0") };
    var args = std.json.Array.init(a);
    try args.append(.{ .string = "-fincremental" });
    const s: zls.Settings = .{ .zls = &.{
        .{ .name = "build_on_save_args", .value = .{ .array = args } },
        .{ .name = "semantic_tokens", .value = .{ .string = "partial" } },
        .{ .name = "warn_style", .value = .{ .bool = true } },
    } };
    const got = try std.json.Stringify.valueAlloc(a, try zls.configSection(a, &s, &tc), .{});
    try testing.expectEqualStrings(
        \\{"zig_exe_path":"/opt/zig/zig","build_on_save_args":["-fincremental"],"semantic_tokens":"partial","warn_style":true}
    , got);
    // `zig.path` wins over the detected toolchain; nothing else is invented.
    const only: zls.Settings = .{ .zig_path = "/custom/zig" };
    try testing.expectEqualStrings(
        \\{"zig_exe_path":"/custom/zig"}
    , try std.json.Stringify.valueAlloc(a, try zls.configSection(a, &only, &tc), .{}));
    try testing.expectEqualStrings("{}", try std.json.Stringify.valueAlloc(a, try zls.configSection(a, &.{}, null), .{}));
}

test "zls: parse 'zig build -l' fixture" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const steps = try zls.parseBuildSteps(a, try fixture(a, "zig_build_list.txt"));
    try testing.expectEqual(@as(usize, 4), steps.len);
    try testing.expectEqualStrings("install", steps[0].name);
    try testing.expect(steps[0].default);
    try testing.expectEqualStrings("Copy build artifacts to prefix path", steps[0].description);
    try testing.expectEqualStrings("run", steps[2].name);
    try testing.expectEqualStrings("Run the app", steps[2].description);
    try testing.expect(!zls.hasStep(steps, "check"));
    const more = try zls.parseBuildSteps(a, "  check                        Check that the code compiles\r\n  fmt\n");
    try testing.expect(zls.hasStep(more, "check"));
    try testing.expectEqualStrings("", more[1].description);
}

test "zls: zig env fixture parsing (0.16 ZON format, plus a legacy JSON fixture)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zon = try zls.parseZigEnv(a, try fixture(a, "zig_env_0.16.zon"));
    try testing.expectEqualStrings("/opt/zig/zig", zon.zig_exe.?);
    try testing.expectEqualStrings("/opt/zig/lib", zon.lib_dir.?);
    try testing.expectEqualStrings("0.16.0", zon.version.?);
    const json = try zls.parseZigEnv(a, try fixture(a, "zig_env_legacy.json"));
    try testing.expectEqualStrings("/opt/zig-0.13/lib", json.lib_dir.?);
    try testing.expectEqualStrings("0.13.0", json.version.?);
    try testing.expectError(error.InvalidEnv, zls.parseZigEnv(a, "error: no"));
}

test "zls: check step goes before the end of the build function" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try a.dupeZ(u8, try fixture(a, "init_build.zig.txt"));
    const at = (try zls.checkStepInsertion(testing.allocator, src)).?;
    try testing.expectEqualStrings("}\n", src[at..]);
    try testing.expect(try zls.checkStepInsertion(testing.allocator, "const x = 1;\n") == null);
}

test "zls: check step snippet compiles" {
    // Needs `zig` on PATH.
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zig = zls.detectZig(a, io, "zig", null) orelse return error.SkipZigTest;
    if (zig.version.minor != 16 or zig.version.major != 0) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPathFile(io, ".", &root_buf)];
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "pub fn main() void {}\n" });
    const base =
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    _ = b;
        \\}
        \\
    ;
    const at = (try zls.checkStepInsertion(a, base)).?;
    const snippet = try zls.checkStepSnippet(a, "src/main.zig");
    // The template's `_ = b;` would be a pointless discard now.
    const head = try std.mem.replaceOwned(u8, a, base[0..at], "    _ = b;\n", "");
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = try std.mem.concat(a, u8, &.{ head, snippet, base[at..] }) });
    const steps = zls.listBuildSteps(a, io, zig.exe_path, root, null) orelse return error.TestUnexpectedResult;
    try testing.expect(zls.hasStep(steps, "check"));
    const r = try std.process.run(a, io, .{ .argv = &.{ zig.exe_path, "build", "check" }, .cwd = .{ .path = root } });
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("{s}\n", .{r.stderr});
        return error.TestUnexpectedResult;
    }
}
