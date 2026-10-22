//! Debug symbol commands (E17.F01.S01.T02):
//!
//!   zg-release split-debug --in <elf> --out <stripped> --debug <name.debug>
//!   zg-release debug-id --file <elf|exe>
//!   zg-release symcheck --stripped <elf> --debug <name.debug>
//!
//! `split-debug` writes the unstripped binary as the debug file and the
//! stripped one with a `.gnu_debuglink` to it (`elf_debug.zig`).
//! `debug-id` prints the GNU build-id (ELF) or the PDB GUID and age (PE),
//! which `BUILDINFO.zon` records as `debug_ids`. `symcheck` is what
//! `zig build test-build-symbols` runs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const elf_debug = @import("elf_debug.zig");
const pe_debug = @import("pe_debug.zig");

const max_binary = 1 << 30;

/// The debug id of an executable image, formatted into `out` (≥ 128
/// bytes), or null when it has none or is neither ELF nor PE.
pub fn debugId(bytes: []const u8, out: []u8) ?[]const u8 {
    if (elf_debug.Image.parse(bytes)) |img| {
        return elf_debug.buildId(&img, out) catch null;
    } else |_| {}
    const cv = (pe_debug.codeView(bytes, out) catch return null) orelse return null;
    return cv.id;
}

/// `split-debug`.
pub fn splitRun(ctx: *const args.Context) !u8 {
    const gpa = ctx.gpa;
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    const in = try cwd.readFileAlloc(io, try ctx.opts.need("in"), gpa, .limited(max_binary));
    const debug_path = try ctx.opts.need("debug");
    const stripped = try elf_debug.strip(gpa, in, std.fs.path.basename(debug_path), in);
    try cwd.writeFile(io, .{ .sub_path = debug_path, .data = in });
    try cwd.writeFile(io, .{ .sub_path = try ctx.opts.need("out"), .data = stripped, .flags = .{ .permissions = .executable_file } });
    return 0;
}

/// `debug-id`.
pub fn idRun(ctx: *const args.Context) !u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(ctx.io, try ctx.opts.need("file"), ctx.gpa, .limited(max_binary));
    var buf: [128]u8 = undefined;
    const id = debugId(bytes, &buf) orelse {
        std.debug.print("no debug id\n", .{});
        return 1;
    };
    var out_buf: [160]u8 = undefined;
    var w = std.Io.File.stdout().writer(ctx.io, &out_buf);
    try w.interface.print("{s}\n", .{id});
    try w.interface.flush();
    return 0;
}

/// `symcheck`: the stripped binary has no DWARF but a build-id and a
/// debuglink naming the debug file with its CRC; the debug file has
/// DWARF and the same build-id.
pub fn checkRun(ctx: *const args.Context) !u8 {
    const gpa = ctx.gpa;
    const cwd = std.Io.Dir.cwd();
    const debug_path = try ctx.opts.need("debug");
    const s_bytes = try cwd.readFileAlloc(ctx.io, try ctx.opts.need("stripped"), gpa, .limited(max_binary));
    const d_bytes = try cwd.readFileAlloc(ctx.io, debug_path, gpa, .limited(max_binary));
    var problems: std.ArrayList([]const u8) = .empty;
    try check(gpa, s_bytes, d_bytes, std.fs.path.basename(debug_path), &problems);
    for (problems.items) |p| std.debug.print("symcheck: {s}\n", .{p});
    return if (problems.items.len == 0) 0 else 1;
}

fn check(gpa: Allocator, s_bytes: []const u8, d_bytes: []const u8, debug_name: []const u8, problems: *std.ArrayList([]const u8)) !void {
    const s = try elf_debug.Image.parse(s_bytes);
    const d = try elf_debug.Image.parse(d_bytes);
    for (s.shdrs) |h| if (elf_debug.isDebug(s.name(h))) try problems.append(gpa, try std.fmt.allocPrint(gpa, "stripped binary still has {s}", .{s.name(h)}));
    if (d.section(".debug_info") == null) try problems.append(gpa, "debug file has no .debug_info");
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const sid = try elf_debug.buildId(&s, &a);
    const did = try elf_debug.buildId(&d, &b);
    if (sid == null) try problems.append(gpa, "stripped binary has no build-id");
    if (sid != null and (did == null or !std.mem.eql(u8, sid.?, did.?))) try problems.append(gpa, "build-ids differ");
    if (try elf_debug.debugLink(&s)) |link| {
        if (!std.mem.eql(u8, link.name, debug_name)) try problems.append(gpa, try std.fmt.allocPrint(gpa, ".gnu_debuglink names {s}", .{link.name}));
        if (link.crc != elf_debug.linkCrc(d_bytes)) try problems.append(gpa, ".gnu_debuglink CRC does not match the debug file");
    } else try problems.append(gpa, "no .gnu_debuglink");
}

const testing = std.testing;

test "symbols: a split of this test binary passes symcheck" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const self = std.Io.Dir.cwd().readFileAlloc(testing.io, "/proc/self/exe", gpa, .limited(max_binary)) catch return error.SkipZigTest;
    const img = elf_debug.Image.parse(self) catch return error.SkipZigTest;
    if (img.section(".debug_info") == null) return error.SkipZigTest;
    var idbuf: [128]u8 = undefined;
    if ((try elf_debug.buildId(&img, &idbuf)) == null) return error.SkipZigTest;
    const stripped = try elf_debug.strip(gpa, self, "self.debug", self);
    try testing.expect(stripped.len < self.len);
    var problems: std.ArrayList([]const u8) = .empty;
    try check(gpa, stripped, self, "self.debug", &problems);
    try testing.expectEqual(@as(usize, 0), problems.items.len);
    // A debug file that is not the one linked fails the CRC.
    try check(gpa, stripped, stripped, "self.debug", &problems);
    try testing.expect(problems.items.len > 0);
}
