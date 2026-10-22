//! Tests for edit.zig and write.zig (E10.F06.S02.T02) over `FakeFiles`,
//! plus a round trip through `DiskFiles`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const files = @import("files.zig");
const fake = @import("fake_files.zig");
const disk = @import("disk_files.zig");
const ReadTracker = @import("../read_tracker.zig").ReadTracker;
const callTool = @import("read_test.zig").callTool;

const testing = std.testing;
const io = testing.io;

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    ff: fake.FakeFiles,
    tracker: ReadTracker,
    ft: files.FileTools,

    fn init(f: *Fixture) void {
        f.* = .{ .arena = .init(testing.allocator), .ff = .init(testing.allocator), .tracker = .init(testing.allocator, io), .ft = undefined };
        f.ft = .{ .files = f.ff.asFiles(), .tracker = &f.tracker };
    }

    fn deinit(f: *Fixture) void {
        f.tracker.deinit();
        f.ff.deinit();
        f.arena.deinit();
    }

    fn call(f: *Fixture, name: []const u8, input: []const u8) !proto.ToolOutput {
        return callTool(&f.ft, f.arena.allocator(), name, input);
    }
};

test "edit requires a prior read" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.ff.put("a.zig", "const x = 1;\n", false);
    const o = try f.call("edit_file", "{\"path\":\"a.zig\",\"old_string\":\"1\",\"new_string\":\"2\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("Read a.zig with read_file before editing it.", o.parts[0].text);
    try testing.expectEqual(@as(usize, 0), f.ff.proposals.items.len);
    _ = try f.call("read_file", "{\"path\":\"a.zig\"}");
    const ok = try f.call("edit_file", "{\"path\":\"a.zig\",\"old_string\":\"1\",\"new_string\":\"2\"}");
    try testing.expectEqualStrings(
        \\Applied edit to a.zig (+1 −1 lines).
        \\--- a/a.zig
        \\+++ b/a.zig
        \\@@ -1,1 +1,1 @@
        \\-const x = 1;
        \\+const x = 2;
        \\
    , ok.parts[0].text);
    try testing.expectEqual(proto.tool.UiHint.diff, ok.ui_hint);
    try testing.expectEqualStrings("const x = 2;\n", f.ff.text("a.zig").?);
    // The agent's own edit counts as read: a second edit needs no re-read.
    const again = try f.call("edit_file", "{\"path\":\"a.zig\",\"old_string\":\"2\",\"new_string\":\"3\"}");
    try testing.expect(!again.is_error);
}

test "not unique message and replace_all" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.ff.put("a.txt", "x\nx\nx\n", false);
    _ = try f.call("read_file", "{\"path\":\"a.txt\"}");
    const o = try f.call("edit_file", "{\"path\":\"a.txt\",\"old_string\":\"x\",\"new_string\":\"y\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("old_string matches 3 places in a.txt; include more surrounding lines to make it unique, or set replace_all.", o.parts[0].text);
    const all = try f.call("edit_file", "{\"path\":\"a.txt\",\"old_string\":\"x\",\"new_string\":\"y\",\"replace_all\":true}");
    try testing.expect(std.mem.startsWith(u8, all.parts[0].text, "Applied edit to a.txt (+3 −3 lines)."));
    try testing.expectEqualStrings("y\ny\ny\n", f.ff.text("a.txt").?);
    const nf = try f.call("edit_file", "{\"path\":\"a.txt\",\"old_string\":\"zzz\",\"new_string\":\"y\"}");
    try testing.expectEqualStrings("old_string was not found in a.txt; re-read the file (it may have changed).", nf.parts[0].text);
    const same = try f.call("edit_file", "{\"path\":\"a.txt\",\"old_string\":\"y\",\"new_string\":\"y\"}");
    try testing.expect(same.is_error);
    const empty = try f.call("edit_file", "{\"path\":\"a.txt\",\"old_string\":\"\",\"new_string\":\"y\"}");
    try testing.expectEqualStrings("old_string is empty; use write_file to create or overwrite a file.", empty.parts[0].text);
}

test "multi_edit is atomic" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.ff.put("m.zig", "a\nb\nc\n", false);
    _ = try f.call("read_file", "{\"path\":\"m.zig\"}");
    const bad = try f.call("multi_edit",
        \\{"path":"m.zig","edits":[{"old_string":"a","new_string":"A"},{"old_string":"q","new_string":"Q"}]}
    );
    try testing.expect(bad.is_error);
    try testing.expectEqualStrings("Edit 1: old_string was not found in m.zig; re-read the file (it may have changed). No edits were made.", bad.parts[0].text);
    try testing.expectEqualStrings("a\nb\nc\n", f.ff.text("m.zig").?);
    try testing.expectEqual(@as(usize, 0), f.ff.proposals.items.len);
    // Each edit sees the ones before it.
    const ok = try f.call("multi_edit",
        \\{"path":"m.zig","edits":[{"old_string":"a","new_string":"A"},{"old_string":"A\nb","new_string":"AB"}]}
    );
    try testing.expect(std.mem.startsWith(u8, ok.parts[0].text, "Applied 2 edits to m.zig (+1 −2 lines)."));
    try testing.expectEqualStrings("AB\nc\n", f.ff.text("m.zig").?);
    try testing.expect(f.ff.proposals.items[0].p == .whole_file);
}

test "write a new file as a create entry, pending review" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    f.ff.mode = .pending;
    const o = try f.call("write_file", "{\"path\":\"src/new.zig\",\"content\":\"pub fn f() void {}\\n\"}");
    try testing.expectEqualStrings("Proposed new file src/new.zig (1 lines) in changeset #1 — pending review.", o.parts[0].text);
    const p = f.ff.proposals.items[0];
    try testing.expect(p.p == .create);
    try testing.expectEqualStrings("/ws/src/new.zig", p.abs);
    try testing.expectEqualStrings("write_file", p.origin.tool);
    try testing.expectEqualStrings("toolu_1", p.origin.tool_call_id);
    // Pending: nothing changed yet.
    try testing.expectEqual(@as(?[]const u8, null), f.ff.text("src/new.zig"));
    f.ff.mode = .apply;
    const c = try f.call("write_file", "{\"path\":\"src/new.zig\",\"content\":\"x\"}");
    try testing.expectEqualStrings("Created src/new.zig (1 lines).", c.parts[0].text);
}

test "write over an existing file requires a read" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.ff.put("w.txt", "old\n", false);
    const o = try f.call("write_file", "{\"path\":\"w.txt\",\"content\":\"new\\n\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("w.txt already exists; read it with read_file before overwriting it.", o.parts[0].text);
    _ = try f.call("read_file", "{\"path\":\"w.txt\"}");
    // A change after the read makes the write stale.
    try f.ff.put("w.txt", "someone else\n", false);
    const stale = try f.call("write_file", "{\"path\":\"w.txt\",\"content\":\"new\\n\"}");
    try testing.expectEqualStrings("w.txt changed since you read it; read it again before writing it.", stale.parts[0].text);
    _ = try f.call("read_file", "{\"path\":\"w.txt\"}");
    const ok = try f.call("write_file", "{\"path\":\"w.txt\",\"content\":\"new\\n\"}");
    try testing.expect(std.mem.startsWith(u8, ok.parts[0].text, "Applied write to w.txt (+1 −1 lines)."));
}

test "conflict reports ranges, pending reports the changeset" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.ff.put("c.zig", "a\nb\n", true);
    _ = try f.call("read_file", "{\"path\":\"c.zig\"}");
    f.ff.mode = .{ .reject = .{ .conflict = &.{ .{ .first = 2, .last = 2 }, .{ .first = 5, .last = 7 } } } };
    const o = try f.call("edit_file", "{\"path\":\"c.zig\",\"old_string\":\"b\",\"new_string\":\"B\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("The edit conflicts with changes made to c.zig since you read it (lines 2, 5-7); re-read it and try again.", o.parts[0].text);
    f.ff.mode = .pending;
    const p = try f.call("edit_file", "{\"path\":\"c.zig\",\"old_string\":\"b\",\"new_string\":\"B\"}");
    try testing.expect(std.mem.startsWith(u8, p.parts[0].text, "Proposed edit to c.zig (+1 −1 lines) in changeset #1 — pending review.\n"));
    f.ff.mode = .{ .reject = .read_only };
    const ro = try f.call("edit_file", "{\"path\":\"c.zig\",\"old_string\":\"b\",\"new_string\":\"B\"}");
    try testing.expectEqualStrings("c.zig is read-only.", ro.parts[0].text);
}

test "crlf files take LF old_string" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try files.strReplace(arena.allocator(), "one\r\ntwo\r\n", "one\ntwo", "1\n2", .unique);
    try testing.expectEqualStrings("1\r\n2\r\n", r.ok.text);
    try testing.expect(r.ok.crlf_adjusted);
}

test "diff is bounded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    const st = try files.writeDiff(&out.writer, a, "f", "1\n2\n3\n4\n5\n6\n7\n8\n", "1\n2\n3\n4\nX\nY\nZ\n6\n7\n8\n", 5);
    try testing.expectEqual(@as(usize, 3), st.added);
    try testing.expectEqual(@as(usize, 1), st.removed);
    try testing.expectEqualStrings("--- a/f\n+++ b/f\n@@ -2,7 +2,9 @@\n 2\n 3\n 4\n-5\n+X\n… 5 more diff lines\n", out.written());
}

test "no direct writes in the edit tools" {
    for ([_][]const u8{ @embedFile("edit.zig"), @embedFile("write.zig") }) |src| {
        for ([_][]const u8{ "createFile", "writeFile", "createFileAtomic" }) |needle|
            try testing.expect(std.mem.indexOf(u8, src, needle) == null);
    }
}

test "disk round trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try a.dupe(u8, buf[0..try tmp.dir.realPath(io, &buf)]);
    var d: disk.DiskFiles = .{ .root = root };
    var tracker: ReadTracker = .init(testing.allocator, io);
    defer tracker.deinit();
    var ft: files.FileTools = .{ .files = d.asFiles(), .tracker = &tracker };
    try testing.expectEqualStrings("Created sub/dir/a.txt (2 lines).", (try callTool(&ft, a, "write_file", "{\"path\":\"sub/dir/a.txt\",\"content\":\"hello\\nworld\\n\"}")).parts[0].text);
    const e = try callTool(&ft, a, "edit_file", "{\"path\":\"sub/dir/a.txt\",\"old_string\":\"world\",\"new_string\":\"there\"}");
    try testing.expect(!e.is_error);
    const got = try tmp.dir.readFileAlloc(io, "sub/dir/a.txt", a, .limited(100));
    try testing.expectEqualStrings("hello\nthere\n", got);
    // Someone else changes the file: a whole-file write is stale.
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/dir/a.txt", .data = "changed\n" });
    const w = try callTool(&ft, a, "write_file", "{\"path\":\"sub/dir/a.txt\",\"content\":\"mine\\n\"}");
    try testing.expect(w.is_error);
    try testing.expectEqualStrings("sub/dir/a.txt changed since you read it; read it again before writing it.", w.parts[0].text);
    // Paths may not leave the workspace.
    const out = try callTool(&ft, a, "write_file", "{\"path\":\"../escape.txt\",\"content\":\"x\"}");
    try testing.expect(out.is_error);
}
