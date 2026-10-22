//! Tests for auto_memory.zig on temp dirs.

const std = @import("std");
const am_mod = @import("auto_memory.zig");

const testing = std.testing;
const AutoMemory = am_mod.AutoMemory;

fn tmpRoot(tmp: *testing.TmpDir, arena: std.mem.Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    return arena.dupe(u8, buf[0..n]);
}

fn writeIndex(arena: std.mem.Allocator, am: *const AutoMemory, data: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(testing.io, am.dir);
    const p = try std.fs.path.join(arena, &.{ am.dir, "MEMORY.md" });
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = p, .data = data });
}

test "index limit: 200 lines or 25 KiB, whichever first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data_dir = try tmpRoot(&tmp, a);
    const am = try AutoMemory.init(a, data_dir, "/work/repo", .{}, .gui);

    var lines: std.ArrayList(u8) = .empty;
    for (0..250) |i| try lines.print(a, "- [m{d}](m{d}.md): hook\n", .{ i, i });
    try writeIndex(a, &am, lines.items);
    const ix = try am.loadIndex(testing.io, a);
    try testing.expect(ix.truncated);
    try testing.expectEqual(@as(u32, 200), ix.lines);
    try testing.expect(std.mem.endsWith(u8, ix.text, "m199.md): hook\n"));

    // 100 long lines exceed 25 KiB before 200 lines.
    var long: std.ArrayList(u8) = .empty;
    for (0..100) |_| {
        try long.appendNTimes(a, 'x', 299);
        try long.append(a, '\n');
    }
    try writeIndex(a, &am, long.items);
    const ix2 = try am.loadIndex(testing.io, a);
    try testing.expect(ix2.truncated);
    try testing.expect(ix2.bytes <= am_mod.max_index_bytes);
    try testing.expectEqual(@as(u32, 85), ix2.lines);

    try writeIndex(a, &am, "- [a](a.md): small\n");
    const ix3 = try am.loadIndex(testing.io, a);
    try testing.expect(!ix3.truncated);
    try testing.expectEqualStrings("- [a](a.md): small\n", ix3.text);
}

test "topic files are not loaded; kinds parse from frontmatter" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const am = try AutoMemory.init(a, try tmpRoot(&tmp, a), "/work/repo", .{}, .gui);
    try writeIndex(a, &am, "- [Test cmd](test-cmd.md): use zig build test-ai\n");
    const topic = "---\nname: test-cmd\ntype: feedback\n---\nUse zig build test-ai, not zig test.\n";
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(a, &.{ am.dir, "test-cmd.md" }), .data = topic });
    const ix = try am.loadIndex(testing.io, a);
    try testing.expect(std.mem.indexOf(u8, ix.text, "Use zig build test-ai, not") == null);
    try testing.expectEqual(am_mod.MemoryKind.feedback, AutoMemory.kindOf(a, topic).?);
    try testing.expectEqual(@as(?am_mod.MemoryKind, null), AutoMemory.kindOf(a, "no frontmatter"));
}

test "lanes of one repository share the directory" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const x = try AutoMemory.dirFor(a, "/data", "/work/repo");
    try testing.expectEqualStrings(x, try AutoMemory.dirFor(a, "/data", "/work/repo/"));
    try testing.expect(!std.mem.eql(u8, x, try AutoMemory.dirFor(a, "/data", "/work/other")));
    try testing.expect(std.mem.indexOf(u8, x, "memory") != null);
}

test "direct writes bypass changesets only inside the memory dir" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const am = try AutoMemory.init(a, "/data", "/work/repo", .{}, .gui);
    const inside = try std.fs.path.join(a, &.{ am.dir, "MEMORY.md" });
    const up = try std.fs.path.join(a, &.{ am.dir, "..", "MEMORY.md" });
    const sneaky = try std.mem.concat(a, u8, &.{ am.dir, "-evil/x.md" });
    try testing.expect(try am.allowsDirectWrite(testing.allocator, "edit_file", inside));
    try testing.expect(try am.allowsDirectWrite(testing.allocator, "write_file", inside));
    try testing.expect(!try am.allowsDirectWrite(testing.allocator, "edit_file", up));
    try testing.expect(!try am.allowsDirectWrite(testing.allocator, "edit_file", sneaky));
    try testing.expect(!try am.allowsDirectWrite(testing.allocator, "run_command", inside));
    try testing.expect(!try am.allowsDirectWrite(testing.allocator, "edit_file", "/work/repo/MEMORY.md"));
    const off = try AutoMemory.init(a, "/data", "/work/repo", .{ .enabled = false }, .gui);
    try testing.expect(!try off.allowsDirectWrite(testing.allocator, "edit_file", inside));
}

test "near-limit reminder and over-limit error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const am = try AutoMemory.init(a, try tmpRoot(&tmp, a), "/work/repo", .{}, .gui);
    const index = try std.fs.path.join(a, &.{ am.dir, "MEMORY.md" });
    var buf: std.ArrayList(u8) = .empty;
    for (0..50) |_| try buf.appendSlice(a, "- [a](a.md): x\n");
    try writeIndex(a, &am, buf.items);
    try testing.expectEqual(@as(?am_mod.WriteCheck, null), try am.afterWrite(testing.io, a, index));
    for (0..135) |_| try buf.appendSlice(a, "- [a](a.md): x\n");
    try writeIndex(a, &am, buf.items);
    try testing.expect((try am.afterWrite(testing.io, a, index)).? == .reminder);
    for (0..30) |_| try buf.appendSlice(a, "- [a](a.md): x\n");
    try writeIndex(a, &am, buf.items);
    try testing.expect((try am.afterWrite(testing.io, a, index)).? == .over_limit);
    // Other files in the directory are not checked.
    try testing.expectEqual(@as(?am_mod.WriteCheck, null), try am.afterWrite(testing.io, a, try std.fs.path.join(a, &.{ am.dir, "topic.md" })));
}

test "disabled in print mode by default; nothing is read when disabled" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmpRoot(&tmp, a);
    try testing.expect(!(try AutoMemory.init(a, root, "/r", .{}, .print)).enabled());
    try testing.expect(!(try AutoMemory.init(a, root, "/r", .{}, .background)).enabled());
    try testing.expect((try AutoMemory.init(a, root, "/r", .{ .force_flag = true }, .print)).enabled());
    try testing.expect((try AutoMemory.init(a, root, "/r", .{}, .gui)).enabled());
    const on = try AutoMemory.init(a, root, "/r", .{}, .gui);
    try writeIndex(a, &on, "- secret\n");
    const off = try AutoMemory.init(a, root, "/r", .{ .enabled = false }, .gui);
    try testing.expectEqualStrings("", (try off.loadIndex(testing.io, a)).text);
    try testing.expectEqual(@as(?am_mod.WriteCheck, null), try off.afterWrite(testing.io, a, try std.fs.path.join(a, &.{ off.dir, "MEMORY.md" })));
}

test "an untrusted project's directory setting is ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const untrusted = try AutoMemory.init(a, "/data", "/r", .{ .directory = "/elsewhere", .directory_from_project = true, .workspace_trusted = false }, .gui);
    try testing.expectEqualStrings(try AutoMemory.dirFor(a, "/data", "/r"), untrusted.dir);
    const trusted = try AutoMemory.init(a, "/data", "/r", .{ .directory = "/elsewhere", .directory_from_project = true }, .gui);
    try testing.expectEqualStrings("/elsewhere", trusted.dir);
    const user_level = try AutoMemory.init(a, "/data", "/r", .{ .directory = "/mine", .workspace_trusted = false }, .gui);
    try testing.expectEqualStrings("/mine", user_level.dir);
}
