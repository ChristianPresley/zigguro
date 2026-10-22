//! Tests for read.zig (E10.F06.S02.T01): goldens over the fixtures in
//! testdata/tools/read through `DiskFiles`, and the policy, buffer and
//! tracking cases through `FakeFiles`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const golden = @import("zg_core").testkit.golden;
const files = @import("files.zig");
const read = @import("read.zig");
const disk = @import("disk_files.zig");
const fake = @import("fake_files.zig");
const deps = @import("../../loop/deps.zig");
const ReadTracker = @import("../read_tracker.zig").ReadTracker;

const testing = std.testing;
const io = testing.io;
const agent: proto.AgentRef = .{ .session = 7 };

pub fn callTool(ft: *files.FileTools, a: std.mem.Allocator, name: []const u8, input: []const u8) !proto.ToolOutput {
    const spec = for (ft.specs()) |*s| {
        if (std.mem.eql(u8, s.name, name)) break s;
    } else unreachable;
    var c: proto.ToolCall = .{
        .id = "toolu_1",
        .name = name,
        .input_json = input,
        .input = try std.json.parseFromSliceLeaky(std.json.Value, a, input, .{}),
        .arena = a,
        .io = io,
        .agent = agent,
    };
    return spec.handler.call(spec.handler.ctx, &c);
}

/// The output as text: text parts as they are, other parts summarized.
fn render(a: std.mem.Allocator, o: proto.ToolOutput) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    if (o.is_error) try out.writer.writeAll("[is_error]\n");
    for (o.parts) |p| switch (p) {
        .text => |t| try out.writer.print("{s}\n", .{t}),
        .image => |im| try out.writer.print("<image {s}, {d} base64 chars>\n", .{ im.media_type, im.data.base64.len }),
        .document => |d| try out.writer.print("<document {s} {s}, {d} base64 chars>\n", .{ d.media_type, d.title.?, d.data.base64.len }),
        .resource_link => unreachable,
    };
    return out.written();
}

test "read goldens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fs.path.resolve(a, &.{ @import("zg_options").package_root, "testdata/tools/read" });
    var d: disk.DiskFiles = .{ .root = root };
    var tracker: ReadTracker = .init(testing.allocator, io);
    defer tracker.deinit();
    var ft: files.FileTools = .{ .files = d.asFiles(), .tracker = &tracker, .cfg = .{ .max_line_chars = 100 } };
    const cases = [_]struct { name: []const u8, input: []const u8, vision: bool = false }{
        .{ .name = "small", .input = "{\"path\":\"small.zig\"}" },
        .{ .name = "long_lines", .input = "{\"path\":\"long_lines.txt\"}" },
        .{ .name = "crlf", .input = "{\"path\":\"crlf.txt\"}" },
        .{ .name = "utf16le_bom", .input = "{\"path\":\"utf16le_bom.txt\"}" },
        .{ .name = "binary", .input = "{\"path\":\"binary.bin\"}" },
        .{ .name = "image_no_vision", .input = "{\"path\":\"image.png\"}" },
        .{ .name = "image_vision", .input = "{\"path\":\"image.png\"}", .vision = true },
        .{ .name = "empty", .input = "{\"path\":\"empty\"}" },
        .{ .name = "missing", .input = "{\"path\":\"nope.txt\"}" },
        .{ .name = "directory", .input = "{\"path\":\".\"}" },
        .{ .name = "offset_limit", .input = "{\"path\":\"thirty.txt\",\"offset\":10,\"limit\":5}" },
    };
    for (cases) |c| {
        ft.cfg.image_input = c.vision;
        const o = try callTool(&ft, a, "read_file", c.input);
        try golden.expectGoldenOpts(io, @src(), c.name, try render(a, o), .{ .root = @import("zg_options").package_root, .dir = "testdata/golden/tools/read" });
    }
}

test "unsaved buffer wins" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ff: fake.FakeFiles = .init(testing.allocator);
    defer ff.deinit();
    try ff.put("a.zig", "typed but not saved\n", true);
    var tracker: ReadTracker = .init(testing.allocator, io);
    defer tracker.deinit();
    var ft: files.FileTools = .{ .files = ff.asFiles(), .tracker = &tracker };
    const o = try callTool(&ft, arena.allocator(), "read_file", "{\"path\":\"a.zig\"}");
    try testing.expectEqualStrings("[file: a.zig · 1 lines · showing 1-1 · unsaved editor content]\n     1\ttyped but not saved\n", o.parts[0].text);
}

const Policy = struct {
    var last: ?files.Resolved = null;
    fn check(_: *anyopaque, _: std.Io, _: proto.AgentRef, r: files.Resolved, _: files.Access) std.Io.Cancelable!deps.Decision {
        last = r;
        if (std.mem.startsWith(u8, std.fs.path.basename(r.abs), ".env")) return .{ .deny = "policy rule Read(.env*)" };
        if (!r.inside_workspace) return .{ .deny = "the user declined" };
        return .allow;
    }
};

test "outside the workspace goes to the policy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ff: fake.FakeFiles = .init(testing.allocator);
    defer ff.deinit();
    var tracker: ReadTracker = .init(testing.allocator, io);
    defer tracker.deinit();
    var ft: files.FileTools = .{ .files = ff.asFiles(), .tracker = &tracker };
    // Without a policy, outside the workspace is denied.
    const o = try callTool(&ft, a, "read_file", "{\"path\":\"../etc/passwd\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("Access to ../etc/passwd is denied: /etc/passwd is outside the workspace", o.parts[0].text);
    // With one, the policy decides (E16 asks the user).
    var dummy: u8 = 0;
    ft.policy = .{ .ctx = &dummy, .check = Policy.check };
    const p = try callTool(&ft, a, "read_file", "{\"path\":\"/etc/passwd\"}");
    try testing.expect(!Policy.last.?.inside_workspace);
    try testing.expectEqualStrings("Access to /etc/passwd is denied: the user declined", p.parts[0].text);
}

test "denied secret file" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var ff: fake.FakeFiles = .init(testing.allocator);
    defer ff.deinit();
    try ff.put(".env.local", "KEY=1\n", false);
    var tracker: ReadTracker = .init(testing.allocator, io);
    defer tracker.deinit();
    var dummy: u8 = 0;
    var ft: files.FileTools = .{ .files = ff.asFiles(), .tracker = &tracker, .policy = .{ .ctx = &dummy, .check = Policy.check } };
    const o = try callTool(&ft, arena.allocator(), "read_file", "{\"path\":\".env.local\"}");
    try testing.expect(o.is_error);
    try testing.expectEqualStrings("Access to .env.local is denied: policy rule Read(.env*)", o.parts[0].text);
    try testing.expectEqual(@as(?u64, null), tracker.version(agent, "/ws/.env.local"));
}

test "offset and limit bounds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ff: fake.FakeFiles = .init(testing.allocator);
    defer ff.deinit();
    try ff.put("t.txt", "a\nb\nc\nd\ne\n", false);
    var tracker: ReadTracker = .init(testing.allocator, io);
    defer tracker.deinit();
    var ft: files.FileTools = .{ .files = ff.asFiles(), .tracker = &tracker, .cfg = .{ .default_limit = 2 } };
    try testing.expectEqualStrings("[file: t.txt · 5 lines · showing 1-2]\n     1\ta\n     2\tb\n[3 more lines; read on with offset=3]\n", (try callTool(&ft, a, "read_file", "{\"path\":\"t.txt\"}")).parts[0].text);
    try testing.expectEqualStrings("[file: t.txt · 5 lines · showing 4-5]\n     4\td\n     5\te\n", (try callTool(&ft, a, "read_file", "{\"path\":\"t.txt\",\"offset\":4,\"limit\":100}")).parts[0].text);
    const past = try callTool(&ft, a, "read_file", "{\"path\":\"t.txt\",\"offset\":6}");
    try testing.expect(past.is_error);
    try testing.expectEqualStrings("offset 6 is past the end of t.txt (5 lines).", past.parts[0].text);
}

test "read tracker recorded" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ff: fake.FakeFiles = .init(testing.allocator);
    defer ff.deinit();
    try ff.put("t.txt", "a\nb\nc\n", false);
    var tracker: ReadTracker = .init(testing.allocator, io);
    defer tracker.deinit();
    var ft: files.FileTools = .{ .files = ff.asFiles(), .tracker = &tracker };
    _ = try callTool(&ft, a, "read_file", "{\"path\":\"t.txt\",\"limit\":1}");
    _ = try callTool(&ft, a, "read_file", "{\"path\":\"t.txt\",\"offset\":3}");
    try testing.expectEqual(@as(?u64, 1), tracker.version(agent, "/ws/t.txt"));
    const r = try tracker.ranges(a, agent, "/ws/t.txt");
    try testing.expectEqual(@as(usize, 2), r.len);
    try testing.expectEqual(@as(u64, 3), r[1].first);
    // Another agent has not read it.
    try testing.expectEqual(@as(?u64, null), tracker.version(.{ .session = 7, .agent = 1 }, "/ws/t.txt"));
    // A new version forgets the old ranges.
    try ff.put("t.txt", "changed\n", false);
    _ = try callTool(&ft, a, "read_file", "{\"path\":\"t.txt\"}");
    try testing.expectEqual(@as(usize, 1), (try tracker.ranges(a, agent, "/ws/t.txt")).len);
}

test "sniff" {
    try testing.expectEqual(read.Sniff.text, read.sniff("plain\n"));
    try testing.expectEqual(read.Sniff.binary, read.sniff("a\x00b"));
    try testing.expectEqual(read.Sniff.binary, read.sniff("\xff\xff\xff\xffab"));
    try testing.expectEqual(read.Sniff.text, read.sniff("caf\xc3\xa9"));
    try testing.expectEqual(read.Sniff.pdf, read.sniff("%PDF-1.7\n"));
    try testing.expectEqual(read.Sniff.gif, read.sniff("GIF89a...."));
    try testing.expectEqual(read.Sniff.webp, read.sniff("RIFF\x00\x00\x00\x00WEBPVP8 "));
}

test "pdf without and with document input" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ff: fake.FakeFiles = .init(testing.allocator);
    defer ff.deinit();
    try ff.put("doc.pdf", "%PDF-1.4\n1 0 obj << /Type /Pages /Count 2 >>\n2 0 obj << /Type /Page >>\n3 0 obj << /Type /Page >>\n", false);
    var tracker: ReadTracker = .init(testing.allocator, io);
    defer tracker.deinit();
    var ft: files.FileTools = .{ .files = ff.asFiles(), .tracker = &tracker };
    try testing.expectEqualStrings("PDF (2 pages, 97 bytes); use a PDF tool to read it.", (try callTool(&ft, a, "read_file", "{\"path\":\"doc.pdf\"}")).parts[0].text);
    ft.cfg.pdf_input = true;
    const o = try callTool(&ft, a, "read_file", "{\"path\":\"doc.pdf\"}");
    try testing.expectEqualStrings("application/pdf", o.parts[1].document.media_type);
}
