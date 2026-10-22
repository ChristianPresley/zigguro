//! Tests for the text-sync sink: the JSON it produces is parsed back the
//! way a server would and applied to a reference copy of each document.

const std = @import("std");
const zg_editor = @import("zg_editor");
const sink_mod = @import("sink.zig");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const api = zg_editor.model.api;
const DocumentRegistry = api.registry.DocumentRegistry;
const DocHandle = api.registry.DocHandle;
const LspSync = api.lsp_sync.LspSync;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const pt = zg_editor.model.buffer.piece_tree;

/// A server's view: every message, and each document's text as it would
/// apply the notifications (UTF-16 positions).
const Peer = struct {
    gpa: Allocator,
    methods: std.ArrayList([]const u8) = .empty,
    bodies: std.ArrayList([]u8) = .empty,
    docs: std.StringHashMapUnmanaged(std.ArrayList(u8)) = .empty,
    fail_sends: bool = false,

    fn deinit(p: *Peer) void {
        for (p.bodies.items) |b| p.gpa.free(b);
        p.bodies.deinit(p.gpa);
        p.methods.deinit(p.gpa);
        var it = p.docs.iterator();
        while (it.next()) |e| {
            p.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(p.gpa);
        }
        p.docs.deinit(p.gpa);
    }

    fn out(p: *Peer) sink_mod.Out {
        return .{ .ctx = p, .send = send };
    }

    fn send(ctx: *anyopaque, method: []const u8, params: []const u8) anyerror!void {
        const p: *Peer = @ptrCast(@alignCast(ctx));
        if (p.fail_sends) return error.NotRunning;
        try p.methods.append(p.gpa, method);
        try p.bodies.append(p.gpa, try p.gpa.dupe(u8, params));
        try p.apply(method, params);
    }

    fn last(p: *const Peer) []const u8 {
        return p.bodies.items[p.bodies.items.len - 1];
    }

    fn apply(p: *Peer, method: []const u8, params: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, p.gpa, params, .{});
        defer parsed.deinit();
        const td = parsed.value.object.get("textDocument").?.object;
        const uri = td.get("uri").?.string;
        if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(p.gpa, td.get("text").?.string);
            try p.docs.put(p.gpa, try p.gpa.dupe(u8, uri), text);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            const doc = p.docs.getPtr(uri).?;
            for (parsed.value.object.get("contentChanges").?.array.items) |c| {
                const new = c.object.get("text").?.string;
                const range = c.object.get("range") orelse {
                    doc.clearRetainingCapacity();
                    try doc.appendSlice(p.gpa, new);
                    continue;
                };
                const a = offset16(doc.items, range.object.get("start").?.object);
                const b = offset16(doc.items, range.object.get("end").?.object);
                try doc.replaceRange(p.gpa, a, b - a, new);
            }
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            var kv = p.docs.fetchRemove(uri).?;
            p.gpa.free(kv.key);
            kv.value.deinit(p.gpa);
        }
    }

    /// The byte offset of an LSP position (UTF-16 columns).
    fn offset16(text: []const u8, pos: std.json.ObjectMap) usize {
        const line: u64 = @intCast(pos.get("line").?.integer);
        const col: u64 = @intCast(pos.get("character").?.integer);
        var i: usize = 0;
        var l: u64 = 0;
        while (l < line) : (i += 1) {
            if (text[i] == '\n') l += 1 else if (text[i] == '\r') {
                l += 1;
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
            }
        }
        var c: u64 = 0;
        while (c < col) {
            const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
            c += if (n == 4) 2 else 1;
            i += n;
        }
        return i;
    }
};

fn docText(gpa: Allocator, reg: *DocumentRegistry, h: DocHandle) ![]u8 {
    const t = reg.get(h).?.tree;
    return t.copyRange(gpa, .{ .start = 0, .end = t.len() });
}

fn edit(reg: *DocumentRegistry, h: DocHandle, edits: []const pt.Edit) !void {
    const doc = reg.get(h).?;
    var cs = try ChangeSet.fromEdits(testing.allocator, doc.len(), edits);
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
}

test "sink: didOpen, didSave and didClose bodies" {
    const gpa = testing.allocator;
    var reg: DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    var peer: Peer = .{ .gpa = gpa };
    defer peer.deinit();
    var sink: sink_mod.Sink = .init(gpa, peer.out());
    defer sink.deinit();
    var sync: LspSync = .init(gpa, &reg, .utf16, .incremental, sink.lspSink());
    defer sync.deinit();
    const h = try reg.openFile("/src/a b.zig", "const s = \"q\\\\\";\n\ttab\x01\n");
    defer reg.release(h);
    try sync.track(h, "zig");
    try testing.expectEqualStrings("textDocument/didOpen", peer.methods.items[0]);
    try testing.expectEqualStrings(
        \\{"textDocument":{"uri":"file:///src/a%20b.zig","languageId":"zig","version":1,"text":"const s = \"q\\\\\";\n\ttab\u0001\n"}}
    , peer.last());
    try testing.expectEqual(@as(?i32, 1), sink.sentVersion("file:///src/a%20b.zig"));
    sync.saved(h);
    try testing.expectEqualStrings(
        \\{"textDocument":{"uri":"file:///src/a%20b.zig"}}
    , peer.last());
    sync.include_text_on_save = true;
    sync.saved(h);
    try testing.expect(std.mem.endsWith(u8, peer.last(), "},\"text\":\"const s = \\\"q\\\\\\\\\\\";\\n\\ttab\\u0001\\n\"}"));
    sync.untrack(h);
    try testing.expectEqualStrings(
        \\{"textDocument":{"uri":"file:///src/a%20b.zig"}}
    , peer.last());
    try testing.expectEqualStrings("textDocument/didClose", peer.methods.items[peer.methods.items.len - 1]);
    try testing.expectEqual(@as(?i32, null), sink.sentVersion("file:///src/a%20b.zig"));
}

test "sink: incremental and full didChange reproduce the document" {
    const gpa = testing.allocator;
    const pieces = [_][]const u8{ "a", "é", "日", "😀", "\r\n", "\n", "\"", "\\", "\t", "" };
    for ([_]api.lsp_sync.SyncKind{ .incremental, .full }) |kind| {
        var reg: DocumentRegistry = .init(gpa, .posix);
        defer reg.deinit();
        var peer: Peer = .{ .gpa = gpa };
        defer peer.deinit();
        var sink: sink_mod.Sink = .init(gpa, peer.out());
        defer sink.deinit();
        var sync: LspSync = .init(gpa, &reg, .utf16, kind, sink.lspSink());
        defer sync.deinit();
        const h = try reg.openFile("/f.txt", "héllo 😀\r\nworld\n");
        defer reg.release(h);
        try sync.track(h, "plaintext");
        var prng: std.Random.DefaultPrng = .init(0x5171 + @as(u64, @intFromEnum(kind)));
        const rand = prng.random();
        var version: i32 = 1;
        for (0..300) |_| {
            const text = try docText(gpa, &reg, h);
            defer gpa.free(text);
            var a = rand.intRangeAtMost(usize, 0, text.len);
            while (a > 0 and a < text.len and text[a] & 0xc0 == 0x80) a -= 1;
            var b = @min(text.len, a + rand.uintLessThan(usize, 5));
            while (b < text.len and text[b] & 0xc0 == 0x80) b += 1;
            try edit(&reg, h, &.{.{ .range = .{ .start = a, .end = b }, .text = pieces[rand.uintLessThan(usize, pieces.len)] }});
            sync.flush();
            version += 1;
            try testing.expectEqual(@as(?i32, version), sink.sentVersion("file:///f.txt"));
            const want = try docText(gpa, &reg, h);
            defer gpa.free(want);
            try testing.expectEqualStrings(want, peer.docs.get("file:///f.txt").?.items);
        }
    }
}

test "sink: a send that fails is counted, not fatal" {
    const gpa = testing.allocator;
    var reg: DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    var peer: Peer = .{ .gpa = gpa, .fail_sends = true };
    defer peer.deinit();
    var sink: sink_mod.Sink = .init(gpa, peer.out());
    defer sink.deinit();
    var sync: LspSync = .init(gpa, &reg, .utf16, .incremental, sink.lspSink());
    defer sync.deinit();
    const h = try reg.openFile("/f.txt", "x");
    defer reg.release(h);
    try sync.track(h, "plaintext");
    sync.untrack(h);
    try testing.expectEqual(@as(u32, 2), sink.dropped);
}
