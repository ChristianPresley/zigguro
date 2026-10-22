//! vkgen: generates `packages/vulkan/src/vk/vk.zig` from the vendored
//! Vulkan registry (E02.F01.S01).
//!
//!   vkgen <vk.xml> <out.zig> [--check] [--max-version 1.4]
//!         [--extensions VK_KHR_a,VK_EXT_b] [--no-helpers]
//!
//! Without `--extensions` the allowlist in `extensions.zon` is used.
//! `--check` exits 1 when `out.zig` differs from what would be written.
//! `zig build vkgen` regenerates the checked-in file and `zig build test`
//! fails when it is stale.

const std = @import("std");
const registry = @import("registry.zig");
const resolve = @import("resolve.zig");
const emit = @import("emit.zig");

/// The default extension allowlist.
pub const allowlist: []const []const u8 = @import("extensions.zon");

pub const GenOptions = struct {
    max_version: u32 = 104,
    extensions: []const []const u8 = allowlist,
    emit: emit.Options = .{},
};

/// Parses, resolves and emits; returns the file contents. On error
/// `culprit` names the offending item.
pub fn generate(a: std.mem.Allocator, src: []const u8, opts: GenOptions, culprit: *[]const u8) ![]u8 {
    var reg = registry.Registry.parse(a, src) catch |err| {
        culprit.* = "vk.xml";
        return err;
    };
    defer reg.deinit();
    var sel = try resolve.resolve(a, &reg, .{ .max_version = opts.max_version, .extensions = opts.extensions }, culprit);
    defer sel.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try emit.emit(a, &reg, &sel, &out.writer, opts.emit, culprit);
    // Canonical `zig fmt` layout, and a syntax check of the emitter.
    const src_z = try a.dupeZ(u8, out.written());
    defer a.free(src_z);
    var tree = try std.zig.Ast.parse(a, src_z, .zig);
    defer tree.deinit(a);
    if (tree.errors.len > 0) {
        const loc = tree.tokenLocation(0, tree.errors[0].token);
        culprit.* = try std.fmt.allocPrint(a, "generated line {d}", .{loc.line + 1});
        return error.GeneratedSyntax;
    }
    return tree.renderAlloc(a);
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var positional: std.ArrayList([]const u8) = .empty;
    var opts: GenOptions = .{};
    var check = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, a, "--no-helpers")) {
            opts.emit.helpers = false;
        } else if (std.mem.eql(u8, a, "--max-version")) {
            i += 1;
            if (i == args.len) return usage();
            const v = args[i];
            const dot = std.mem.indexOfScalar(u8, v, '.') orelse return usage();
            const major = std.fmt.parseInt(u32, v[0..dot], 10) catch return usage();
            const minor = std.fmt.parseInt(u32, v[dot + 1 ..], 10) catch return usage();
            opts.max_version = major * 100 + minor;
        } else if (std.mem.eql(u8, a, "--extensions")) {
            i += 1;
            if (i == args.len) return usage();
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.tokenizeScalar(u8, args[i], ',');
            while (it.next()) |x| try list.append(arena, x);
            opts.extensions = list.items;
        } else try positional.append(arena, a);
    }
    if (positional.items.len != 2) return usage();
    const in_path = positional.items[0];
    const out_path = positional.items[1];
    opts.emit.source = std.fs.path.basename(in_path);

    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, in_path, arena, .limited(64 << 20));
    var culprit: []const u8 = "";
    const out = generate(arena, bytes, opts, &culprit) catch |err| {
        std.log.err("{s}: {t} ({s})", .{ in_path, err, culprit });
        return 1;
    };

    if (check) {
        const current = cwd.readFileAlloc(io, out_path, arena, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        if (!std.mem.eql(u8, current, out)) {
            std.log.err("{s} is out of date; run `zig build vkgen`", .{out_path});
            return 1;
        }
        return 0;
    }
    if (std.fs.path.dirname(out_path)) |dir| try cwd.createDirPath(io, dir);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out });
    return 0;
}

fn usage() u8 {
    std.log.err("usage: vkgen <vk.xml> <out.zig> [--check] [--max-version X.Y] [--extensions A,B] [--no-helpers]", .{});
    return 2;
}

test {
    _ = @import("xml.zig");
    _ = @import("cdecl.zig");
    _ = @import("registry.zig");
    _ = @import("resolve.zig");
    _ = @import("names.zig");
    _ = @import("layout.zig");
    _ = @import("emit.zig");
}

fn expectParses(a: std.mem.Allocator, src: []const u8) !void {
    const z = try a.dupeZ(u8, src);
    var tree = try std.zig.Ast.parse(a, z, .zig);
    defer tree.deinit(a);
    if (tree.errors.len > 0) {
        const e = tree.errors[0];
        const loc = tree.tokenLocation(0, e.token);
        std.debug.print("generated file does not parse at {d}:{d}\n", .{ loc.line + 1, loc.column + 1 });
        return error.TestUnexpectedResult;
    }
}

test "emit: vendored vk.xml generates parseable, deterministic output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var culprit: []const u8 = "";
    const one = generate(a, @embedFile("data/vk.xml"), .{}, &culprit) catch |err| {
        std.debug.print("vkgen: {t} ({s})\n", .{ err, culprit });
        return err;
    };
    const two = try generate(a, @embedFile("data/vk.xml"), .{}, &culprit);
    try std.testing.expectEqualStrings(one, two);
    try expectParses(a, one);
    try std.testing.expect(std.mem.count(u8, one, "\n") < 60_000);
    for ([_][]const u8{
        "pub const ImageCreateInfo = extern struct {",
        "pub const ImageUsageFlags = packed struct(u32) {",
        "pub const PipelineStageFlags2 = packed struct(u64) {",
        "    cmd_begin_rendering,",
        "    error_out_of_date_khr = -1000001004,",
        "    OutOfDateKHR,",
        "    swapchain_create_info_khr = 1000001000,",
    }) |needle| {
        if (std.mem.indexOf(u8, one, needle) == null) {
            std.debug.print("missing: {s}\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
}

test "emit: mini registry golden" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var culprit: []const u8 = "";
    const out = generate(a, @embedFile("testdata/mini.xml"), .{
        .max_version = 101,
        .extensions = &.{"VK_KHR_mini"},
        .emit = .{ .source = "mini.xml", .helpers = false },
    }, &culprit) catch |err| {
        std.debug.print("vkgen: {t} ({s})\n", .{ err, culprit });
        return err;
    };
    try expectParses(a, out);
    // Regenerate with:
    //   zig build vkgen-mini
    try std.testing.expectEqualStrings(@embedFile("testdata/golden/mini_vk.zig"), out);
}
