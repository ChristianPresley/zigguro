//! `zig build new-package`: scaffolds a package with the canonical skeleton
//! and registers it in `build/packages.zig`, the root `build.zig.zon` and
//! `tools/pkgtool/layers.zon` (textual inserts before `// pkgtool:insert`).

const std = @import("std");

const tmpl_build = @embedFile("templates/build.zig.tmpl");
const tmpl_zon = @embedFile("templates/build.zig.zon.tmpl");
const tmpl_root = @embedFile("templates/root.zig.tmpl");
const tmpl_bench = @embedFile("templates/bench.zig.tmpl");

/// The insertion marker in registry files.
pub const marker = "// pkgtool:insert";

/// A package fingerprint as Zig 0.16 expects it: the upper 32 bits are
/// `Crc32(name)`, the lower 32 bits a random id that is neither 0 nor
/// 0xffffffff.
pub fn fingerprint(io: std.Io, name: []const u8) u64 {
    while (true) {
        var buf: [4]u8 = undefined;
        io.random(&buf);
        const id = std.mem.readInt(u32, &buf, .little);
        if (id != 0 and id != 0xffffffff) return fingerprintWithId(name, id);
    }
}

/// `fingerprint` with a caller-chosen id (for tests).
pub fn fingerprintWithId(name: []const u8, id: u32) u64 {
    return (@as(u64, std.hash.Crc32.hash(name)) << 32) | id;
}

/// Errors from argument validation.
pub const ValidationError = error{ BadName, BadDir, BadLayer };

/// Validates `zg_<ident>`, a lowercase directory name and a layer in 1..5.
pub fn validate(name: []const u8, dir: []const u8, layer: u8) ValidationError!void {
    if (!std.mem.startsWith(u8, name, "zg_") or name.len <= 3) return error.BadName;
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return error.BadName;
    if (dir.len == 0) return error.BadDir;
    for (dir) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-')) return error.BadDir;
    if (layer < 1 or layer > 5) return error.BadLayer;
}

/// Replaces `{{name}}` and `{{fingerprint}}` in `tmpl`.
pub fn render(gpa: std.mem.Allocator, tmpl: []const u8, name: []const u8, fp: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = tmpl;
    while (std.mem.indexOf(u8, rest, "{{")) |i| {
        try out.appendSlice(gpa, rest[0..i]);
        rest = rest[i..];
        if (std.mem.startsWith(u8, rest, "{{name}}")) {
            try out.appendSlice(gpa, name);
            rest = rest["{{name}}".len..];
        } else if (std.mem.startsWith(u8, rest, "{{fingerprint}}")) {
            try out.print(gpa, "0x{x:0>16}", .{fp});
            rest = rest["{{fingerprint}}".len..];
        } else {
            try out.appendSlice(gpa, "{{");
            rest = rest[2..];
        }
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

/// Inserts `line` before the line containing `marker`, keeping the marker's
/// indentation. Returns error.NoMarker when the marker is absent.
pub fn insertBeforeMarker(gpa: std.mem.Allocator, src: []const u8, line: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, src, marker) orelse return error.NoMarker;
    const line_start = if (std.mem.lastIndexOfScalar(u8, src[0..at], '\n')) |nl| nl + 1 else 0;
    const indent = src[line_start..at];
    return std.mem.concat(gpa, u8, &.{ src[0..line_start], indent, line, "\n", src[line_start..] });
}

/// Creates `packages/<dir>/` from the templates and registers the package.
/// `zig_exe` (from the build step) is used to `zig fmt` the touched files.
pub fn newPackage(
    parent_gpa: std.mem.Allocator,
    io: std.Io,
    repo_root: std.Io.Dir,
    name: []const u8,
    dir: []const u8,
    layer: u8,
    zig_exe: ?[]const u8,
) !void {
    try validate(name, dir, layer);
    var arena: std.heap.ArenaAllocator = .init(parent_gpa);
    defer arena.deinit();
    const gpa = arena.allocator();
    const pkg_dir = try std.fmt.allocPrint(gpa, "packages/{s}", .{dir});
    defer gpa.free(pkg_dir);
    if (repo_root.access(io, pkg_dir, .{})) |_| return error.PathAlreadyExists else |_| {}

    const fp = fingerprint(io, name);
    try repo_root.createDirPath(io, try tmpPath(gpa, pkg_dir, "src"));
    try repo_root.createDirPath(io, try tmpPath(gpa, pkg_dir, "bench"));
    const files = [_]struct { []const u8, []const u8 }{
        .{ "build.zig", tmpl_build },
        .{ "build.zig.zon", tmpl_zon },
        .{ "src/root.zig", tmpl_root },
        .{ "bench/main.zig", tmpl_bench },
    };
    for (files) |f| {
        const data = try render(gpa, f[1], name, fp);
        defer gpa.free(data);
        const p = try std.fs.path.join(gpa, &.{ pkg_dir, f[0] });
        defer gpa.free(p);
        try repo_root.writeFile(io, .{ .sub_path = p, .data = data });
    }

    try patch(gpa, io, repo_root, "build/packages.zig", try std.fmt.allocPrint(gpa, ".{{ .name = \"{s}\", .dir = \"{s}\", .has_bench = true }},", .{ name, pkg_dir }));
    try patch(gpa, io, repo_root, "build.zig.zon", try std.fmt.allocPrint(gpa, ".{s} = .{{ .path = \"{s}\" }},", .{ name, pkg_dir }));
    // layers.zon pre-assigns layers to planned packages; keep an existing entry.
    const layers_src = try repo_root.readFileAlloc(io, "tools/pkgtool/layers.zon", gpa, .limited(4 << 20));
    defer gpa.free(layers_src);
    if (!hasLayerEntry(layers_src, name)) {
        try patch(gpa, io, repo_root, "tools/pkgtool/layers.zon", try std.fmt.allocPrint(gpa, ".{s} = {d},", .{ name, layer }));
    }

    if (zig_exe) |zig| {
        const argv = [_][]const u8{ zig, "fmt", "build/packages.zig", "build.zig.zon", "tools/pkgtool/layers.zon", pkg_dir };
        const r = try std.process.run(gpa, io, .{ .argv = &argv, .cwd = .{ .dir = repo_root } });
        gpa.free(r.stdout);
        gpa.free(r.stderr);
    }
}

/// True when `layers.zon` source already has a `.<name> = ` line.
pub fn hasLayerEntry(src: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimStart(u8, raw, " \t");
        if (line.len > name.len + 1 and line[0] == '.' and std.mem.startsWith(u8, line[1..], name)) {
            const rest = std.mem.trimStart(u8, line[1 + name.len ..], " ");
            if (rest.len > 0 and rest[0] == '=') return true;
        }
    }
    return false;
}

fn tmpPath(gpa: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    return std.fs.path.join(gpa, &.{ a, b });
}

fn patch(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, path: []const u8, line: []const u8) !void {
    defer gpa.free(line);
    const src = try root.readFileAlloc(io, path, gpa, .limited(4 << 20));
    defer gpa.free(src);
    const out = try insertBeforeMarker(gpa, src, line);
    defer gpa.free(out);
    try root.writeFile(io, .{ .sub_path = path, .data = out });
}

test "scaffold: fingerprint upper bits are crc32(name)" {
    try std.testing.expectEqual(@as(u64, 0x300f6db0), fingerprintWithId("zg_core", 1) >> 32);
    try std.testing.expectEqual(@as(u64, 0x78ff8962), fingerprintWithId("zg_jsonrpc", 1) >> 32);
    const fp = fingerprint(std.testing.io, "zg_core");
    try std.testing.expectEqual(@as(u64, 0x300f6db0), fp >> 32);
    try std.testing.expect(@as(u32, @truncate(fp)) != 0);
}

test "scaffold: existing layer entries are detected" {
    const src = ".{\n    .layers = .{\n        .zg_core = 0,\n        .zg_platform = 2,\n        // pkgtool:insert\n    },\n}\n";
    try std.testing.expect(hasLayerEntry(src, "zg_platform"));
    try std.testing.expect(hasLayerEntry(src, "zg_core"));
    try std.testing.expect(!hasLayerEntry(src, "zg_plat"));
    try std.testing.expect(!hasLayerEntry(src, "zg_demo"));
}

test "scaffold: render substitutes placeholders" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, ".name = .{{name}}, .fp = {{fingerprint}}, {{other}}", "zg_demo", 0xab);
    defer gpa.free(out);
    try std.testing.expectEqualStrings(".name = .zg_demo, .fp = 0x00000000000000ab, {{other}}", out);
}

test "scaffold: insertBeforeMarker keeps indentation" {
    const gpa = std.testing.allocator;
    const out = try insertBeforeMarker(gpa, "a\n    // pkgtool:insert\n}", ".x = 1,");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a\n    .x = 1,\n    // pkgtool:insert\n}", out);
}

test "scaffold: validate" {
    try validate("zg_demo", "demo", 4);
    try std.testing.expectError(error.BadName, validate("demo", "demo", 4));
    try std.testing.expectError(error.BadName, validate("zg_Demo", "demo", 4));
    try std.testing.expectError(error.BadDir, validate("zg_demo", "De mo", 4));
    try std.testing.expectError(error.BadLayer, validate("zg_demo", "demo", 0));
}

test "scaffold: templates render to valid zon and zig" {
    const gpa = std.testing.allocator;
    const zon_src = try render(gpa, tmpl_zon, "zg_demo", fingerprintWithId("zg_demo", 7));
    defer gpa.free(zon_src);
    const z = try gpa.dupeZ(u8, zon_src);
    defer gpa.free(z);
    var ast = try std.zig.Ast.parse(gpa, z, .zon);
    defer ast.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    for ([_][]const u8{ tmpl_build, tmpl_root, tmpl_bench }) |t| {
        const s = try render(gpa, t, "zg_demo", 1);
        defer gpa.free(s);
        const sz = try gpa.dupeZ(u8, s);
        defer gpa.free(sz);
        var a = try std.zig.Ast.parse(gpa, sz, .zig);
        defer a.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), a.errors.len);
    }
}
