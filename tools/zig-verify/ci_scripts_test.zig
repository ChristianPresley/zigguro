//! `zig build test-ci-scripts`: runs `.github/scripts/setup-zig.sh` against a
//! loopback fixture mirror with a fake toolchain archive (Linux only; needs
//! bash, curl, tar with xz, sha256sum and shuf, as on GitHub runners).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const opts = @import("ci_test_options");
const FixtureServer = @import("fixture_server.zig").FixtureServer;
const Route = @import("fixture_server.zig").Route;

const testing = std.testing;

fn sh(a: std.mem.Allocator, argv: []const []const u8, env: ?*const std.process.Environ.Map) !struct { code: u8, stderr: []const u8 } {
    const r = try std.process.run(a, testing.io, .{ .argv = argv, .environ_map = env });
    const code: u8 = switch (r.term) {
        .exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stderr = r.stderr };
}

fn exists(path: []const u8) bool {
    Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

test "setup-zig.sh: mirror fallback, cache hit, hash mismatch, all sources failing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.SkipZigTest,
    };
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cwd = Io.Dir.cwd();

    var rnd: [6]u8 = undefined;
    io.random(&rnd);
    const work = try std.fmt.allocPrint(a, "{s}/.zig-cache/ci-scripts-test/{x}", .{ opts.repo_root, rnd });
    try cwd.createDirPath(io, work);
    defer cwd.deleteTree(io, work) catch {};

    const dir_name = try std.fmt.allocPrint(a, "zig-{s}-linux-0.16.0", .{arch});
    const file = try std.fmt.allocPrint(a, "{s}.tar.xz", .{dir_name});
    const src = try std.fmt.allocPrint(a, "{s}/src/{s}", .{ work, dir_name });
    try cwd.createDirPath(io, src);
    const fake_zig = try std.fmt.allocPrint(a, "{s}/zig", .{src});
    try cwd.writeFile(io, .{ .sub_path = fake_zig, .data = "#!/bin/sh\necho 0.16.0\n" });
    try testing.expectEqual(@as(u8, 0), (try sh(a, &.{ "chmod", "+x", fake_zig }, null)).code);
    const archive = try std.fmt.allocPrint(a, "{s}/{s}", .{ work, file });
    const tar = try sh(a, &.{ "tar", "-cJf", archive, "-C", try std.fmt.allocPrint(a, "{s}/src", .{work}), dir_name }, null);
    try testing.expectEqual(@as(u8, 0), tar.code);
    const data = try cwd.readFileAlloc(io, archive, a, .limited(1 << 20));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const sha = std.fmt.bytesToHex(digest, .lower);

    var routes = [_]Route{
        .{ .path = "/mirrors.txt" },
        .{ .path = try std.fmt.allocPrint(a, "/bad/{s}", .{file}), .status = .service_unavailable, .body = "busy" },
        .{ .path = try std.fmt.allocPrint(a, "/fallback/0.16.0/{s}", .{file}), .body = data },
    };
    var srv: FixtureServer = .{ .server = undefined, .port = 0, .routes = &routes };
    try srv.start(io);
    defer srv.stop(io);
    var ub: [128]u8 = undefined;
    routes[0].body = try std.fmt.allocPrint(a, "# test mirrors\n{s}\n", .{srv.url(&ub, "/bad")});

    const triple = try std.fmt.allocPrint(a, "{s}-linux", .{arch});
    const pin_good = try std.fmt.allocPrint(a, "{s}/pin-good.txt", .{work});
    try cwd.writeFile(io, .{ .sub_path = pin_good, .data = try std.fmt.allocPrint(a, "version 0.16.0\npubkey X\n{s} {s} {s}\n", .{ triple, file, sha }) });
    const pin_bad = try std.fmt.allocPrint(a, "{s}/pin-bad.txt", .{work});
    try cwd.writeFile(io, .{ .sub_path = pin_bad, .data = try std.fmt.allocPrint(a, "version 0.16.0\npubkey X\n{s} {s} {s}\n", .{ triple, file, "0" ** 64 }) });

    var env = try testing.environ.createMap(a);
    try env.put("ZIGGURO_MIRRORS_URL", srv.url(&ub, "/mirrors.txt"));
    try env.put("ZIGGURO_FALLBACK_URL", try a.dupe(u8, srv.url(&ub, "/fallback")));
    try env.put("ZIGGURO_ALLOW_HTTP", "1");
    const gh_path = try std.fmt.allocPrint(a, "{s}/github_path", .{work});
    try env.put("GITHUB_PATH", gh_path);
    try env.put("GITHUB_ENV", try std.fmt.allocPrint(a, "{s}/github_env", .{work}));
    _ = env.swapRemove("http_proxy");
    _ = env.swapRemove("HTTP_PROXY");
    _ = env.swapRemove("https_proxy");
    _ = env.swapRemove("HTTPS_PROXY");
    _ = env.swapRemove("all_proxy");
    _ = env.swapRemove("ALL_PROXY");
    const script = try std.fmt.allocPrint(a, "{s}/.github/scripts/setup-zig.sh", .{opts.repo_root});

    // 503 from the only mirror, then the ziglang.org fallback.
    const dest1 = try std.fmt.allocPrint(a, "{s}/dest1", .{work});
    const r1 = try sh(a, &.{ "bash", script, "--pin", pin_good, "--dest", dest1 }, &env);
    if (r1.code != 0) std.debug.print("{s}\n", .{r1.stderr});
    try testing.expectEqual(@as(u8, 0), r1.code);
    // curl --retry 2 retries the 503 twice before moving on.
    try testing.expectEqual(@as(u32, 3), srv.hits(routes[1].path));
    try testing.expectEqual(@as(u32, 1), srv.hits(routes[2].path));
    try testing.expect(exists(try std.fmt.allocPrint(a, "{s}/{s}/zig", .{ dest1, dir_name })));
    const published = try cwd.readFileAlloc(io, gh_path, a, .limited(4096));
    try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/{s}\n", .{ dest1, dir_name }), published);

    // Cache hit: nothing is downloaded.
    const r2 = try sh(a, &.{ "bash", script, "--pin", pin_good, "--dest", dest1 }, &env);
    try testing.expectEqual(@as(u8, 0), r2.code);
    try testing.expectEqual(@as(u32, 1), srv.hits(routes[2].path));

    // Hash mismatch: exit 10, nothing extracted.
    const dest2 = try std.fmt.allocPrint(a, "{s}/dest2", .{work});
    const r3 = try sh(a, &.{ "bash", script, "--pin", pin_bad, "--dest", dest2 }, &env);
    try testing.expectEqual(@as(u8, 10), r3.code);
    try testing.expect(std.mem.indexOf(u8, r3.stderr, "zig toolchain hash mismatch") != null);
    try testing.expect(!exists(try std.fmt.allocPrint(a, "{s}/{s}", .{ dest2, dir_name })));

    // Every source fails: exit 11.
    try env.put("ZIGGURO_MIRRORS_URL", try a.dupe(u8, srv.url(&ub, "/missing.txt")));
    try env.put("ZIGGURO_FALLBACK_URL", try a.dupe(u8, srv.url(&ub, "/nowhere")));
    const dest3 = try std.fmt.allocPrint(a, "{s}/dest3", .{work});
    const r4 = try sh(a, &.{ "bash", script, "--pin", pin_good, "--dest", dest3 }, &env);
    try testing.expectEqual(@as(u8, 11), r4.code);
}
