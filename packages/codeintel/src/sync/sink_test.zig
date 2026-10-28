//! Tests for the text-sync sink: the JSON it produces is parsed back the
//! way a server would and applied to a reference copy of each document.

const std = @import("std");
const zg_core = @import("zg_core");
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
/// apply the notifications (positions in `enc`).
const Peer = struct {
    gpa: Allocator,
    enc: zg_core.utf8.Encoding = .utf16,
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
                const a = offsetOf(doc.items, range.object.get("start").?.object, p.enc);
                const b = offsetOf(doc.items, range.object.get("end").?.object, p.enc);
                try doc.replaceRange(p.gpa, a, b - a, new);
            }
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            var kv = p.docs.fetchRemove(uri).?;
            p.gpa.free(kv.key);
            kv.value.deinit(p.gpa);
        }
    }

    /// The byte offset of an LSP position (columns in `enc`).
    fn offsetOf(text: []const u8, pos: std.json.ObjectMap, enc: zg_core.utf8.Encoding) usize {
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
            c += switch (enc) {
                .utf8 => n,
                .utf16 => if (n == 4) 2 else 1,
                .utf32 => 1,
            };
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

/// Random edits, several per frame, in `enc`: one `didChange` per flush,
/// versions one up each time, and the server's copy equals the document.
fn syncRound(gpa: Allocator, smith: *std.testing.Smith) !void {
    const encs = [_]zg_core.utf8.Encoding{ .utf8, .utf16, .utf32 };
    const enc = encs[smith.valueRangeAtMost(u8, 0, 2)];
    const kind: api.lsp_sync.SyncKind = if (smith.valueRangeAtMost(u8, 0, 3) == 0) .full else .incremental;
    var reg: DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    var peer: Peer = .{ .gpa = gpa, .enc = enc };
    defer peer.deinit();
    var sink: sink_mod.Sink = .init(gpa, peer.out());
    defer sink.deinit();
    var sync: LspSync = .init(gpa, &reg, enc, kind, sink.lspSink());
    defer sync.deinit();
    const h = try reg.openFile("/f.txt", "a\u{e9}\r\n\u{1F600}b\n");
    defer reg.release(h);
    try sync.track(h, "plaintext");
    const pieces = [_][]const u8{ "a", "\u{e9}", "\u{65e5}", "\u{1F600}", "\r\n", "\n", "\r", "\"", "" };
    var version: i32 = 1;
    for (0..smith.valueRangeAtMost(u8, 1, 12)) |_| {
        const before = peer.bodies.items.len;
        const n_edits = smith.valueRangeAtMost(u8, 0, 4);
        for (0..n_edits) |_| {
            const text = try docText(gpa, &reg, h);
            defer gpa.free(text);
            var a: usize = smith.valueRangeAtMost(u16, 0, @intCast(@min(text.len, 0xffff)));
            while (a > 0 and a < text.len and text[a] & 0xc0 == 0x80) a -= 1;
            var b = @min(text.len, a + smith.valueRangeAtMost(u8, 0, 4));
            while (b < text.len and text[b] & 0xc0 == 0x80) b += 1;
            try edit(&reg, h, &.{.{ .range = .{ .start = a, .end = b }, .text = pieces[smith.valueRangeAtMost(u8, 0, pieces.len - 1)] }});
        }
        sync.flush();
        const sent = peer.bodies.items.len - before;
        try testing.expect(sent <= 1);
        if (sent == 1) {
            try testing.expectEqualStrings("textDocument/didChange", peer.methods.items[before]);
            version += 1;
        }
        try testing.expectEqual(@as(?i32, version), sink.sentVersion("file:///f.txt"));
        const want = try docText(gpa, &reg, h);
        defer gpa.free(want);
        try testing.expectEqualStrings(want, peer.docs.get("file:///f.txt").?.items);
    }
}

test "fuzz-lsp-sync: incremental reproduces text in every encoding" {
    try std.testing.fuzz({}, struct {
        fn f(_: void, smith: *std.testing.Smith) anyerror!void {
            try syncRound(testing.allocator, smith);
        }
    }.f, .{});
}

test "sink: one didChange per frame, versions strictly increasing" {
    const gpa = testing.allocator;
    var reg: DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    var peer: Peer = .{ .gpa = gpa };
    defer peer.deinit();
    var sink: sink_mod.Sink = .init(gpa, peer.out());
    defer sink.deinit();
    var sync: LspSync = .init(gpa, &reg, .utf16, .incremental, sink.lspSink());
    defer sync.deinit();
    const h = try reg.openFile("/f.txt", "abc\n");
    defer reg.release(h);
    try sync.track(h, "plaintext");
    for (0..3) |frame| {
        // Three keystrokes in one frame.
        for (0..3) |k| try edit(&reg, h, &.{.{ .range = .{ .start = k, .end = k }, .text = "x" }});
        sync.flush();
        try testing.expectEqual(@as(usize, 2 + frame), peer.bodies.items.len);
        try testing.expectEqual(@as(?i32, @intCast(2 + frame)), sink.sentVersion("file:///f.txt"));
    }
    // A frame without edits sends nothing.
    sync.flush();
    try testing.expectEqual(@as(usize, 4), peer.bodies.items.len);
    try testing.expectEqualStrings("xxxxxxxxxabc\n", peer.docs.get("file:///f.txt").?.items);
}

/// Counts the bytes a test allocator holds at most.
const PeakAllocator = struct {
    child: Allocator,
    now: usize = 0,
    peak: usize = 0,

    fn allocator(p: *PeakAllocator) Allocator {
        return .{ .ptr = p, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn of(ctx: *anyopaque) *PeakAllocator {
        return @ptrCast(@alignCast(ctx));
    }

    fn grow(p: *PeakAllocator, old: usize, new: usize) void {
        p.now = p.now - old + new;
        p.peak = @max(p.peak, p.now);
    }

    fn alloc(ctx: *anyopaque, len: usize, al: std.mem.Alignment, ra: usize) ?[*]u8 {
        const p = of(ctx);
        const r = p.child.rawAlloc(len, al, ra) orelse return null;
        p.grow(0, len);
        return r;
    }

    fn resize(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const p = of(ctx);
        if (!p.child.rawResize(mem, al, new_len, ra)) return false;
        p.grow(mem.len, new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const p = of(ctx);
        const r = p.child.rawRemap(mem, al, new_len, ra) orelse return null;
        p.grow(mem.len, new_len);
        return r;
    }

    fn free(ctx: *anyopaque, mem: []u8, al: std.mem.Alignment, ra: usize) void {
        const p = of(ctx);
        p.child.rawFree(mem, al, ra);
        p.grow(mem.len, 0);
    }
};

test "sink: full sync streaming without concatenation" {
    const gpa = testing.allocator;
    const size = 50 << 20;
    const text = try gpa.alloc(u8, size);
    defer gpa.free(text);
    for (text, 0..) |*c, i| c.* = if (i % 64 == 63) '\n' else 'a' + @as(u8, @intCast(i % 26));
    var reg: DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    const h = try reg.openFile("/big.txt", text);
    defer reg.release(h);

    const Count = struct {
        bytes: usize = 0,
        fn send(ctx: *anyopaque, _: []const u8, params: []const u8) anyerror!void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.bytes += params.len;
        }
    };
    var count: Count = .{};
    var peak: PeakAllocator = .{ .child = gpa };
    var sink: sink_mod.Sink = .init(peak.allocator(), .{ .ctx = &count, .send = Count.send });
    defer sink.deinit();
    var sync: LspSync = .init(gpa, &reg, .utf16, .full, sink.lspSink());
    defer sync.deinit();
    try sync.track(h, "plaintext");
    try edit(&reg, h, &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "b" }});
    sync.flush();
    try testing.expect(count.bytes > 2 * size);
    // The body is the only copy the sink makes: never twice the text.
    try testing.expect(peak.peak < size + size / 4);
    // And it is not kept between frames.
    try testing.expect(peak.now < 1 << 20);
}
