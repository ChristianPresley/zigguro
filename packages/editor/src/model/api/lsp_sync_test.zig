//! Tests for LSP text sync. A fake server keeps its own copy of each
//! document and applies the notifications the way a language server would
//! (positions resolved against its copy in the negotiated encoding).

const std = @import("std");
const zg_core = @import("zg_core");
const registry = @import("registry.zig");
const lsp = @import("lsp_sync.zig");
const pt = @import("../buffer/piece_tree.zig");
const ChangeSet = @import("../edit/change_set.zig").ChangeSet;

const testing = std.testing;
const Allocator = std.mem.Allocator;
const DocumentRegistry = registry.DocumentRegistry;
const DocHandle = registry.DocHandle;
const LspSync = lsp.LspSync;
const LspChange = lsp.LspChange;
const ChunkIterator = pt.ChunkIterator;
const Encoding = zg_core.utf8.Encoding;

const Server = struct {
    gpa: Allocator,
    enc: Encoding,
    docs: std.StringHashMapUnmanaged(struct { text: std.ArrayList(u8), version: i32 }) = .empty,
    log: std.ArrayList(u8) = .empty,
    did_change: u32 = 0,
    failed: ?anyerror = null,

    fn deinit(s: *Server) void {
        var it = s.docs.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            e.value_ptr.text.deinit(s.gpa);
        }
        s.docs.deinit(s.gpa);
        s.log.deinit(s.gpa);
    }

    fn sink(s: *Server) lsp.LspSink {
        return .{ .ctx = s, .didOpen = didOpen, .didChange = didChange, .didSave = didSave, .didClose = didClose };
    }

    fn text(s: *Server, uri: []const u8) []const u8 {
        return s.docs.get(uri).?.text.items;
    }

    fn collect(gpa: Allocator, it_in: ChunkIterator) !std.ArrayList(u8) {
        var it = it_in;
        var out: std.ArrayList(u8) = .empty;
        while (it.next()) |c| try out.appendSlice(gpa, c);
        return out;
    }

    fn didOpen(ctx: *anyopaque, uri: []const u8, lang: []const u8, version: i32, it: ChunkIterator) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        s.open(uri, lang, version, it) catch |e| {
            s.failed = e;
        };
    }

    fn open(s: *Server, uri: []const u8, lang: []const u8, version: i32, it: ChunkIterator) !void {
        if (s.docs.contains(uri)) return error.OpenTwice;
        try s.docs.put(s.gpa, try s.gpa.dupe(u8, uri), .{ .text = try collect(s.gpa, it), .version = version });
        try s.log.print(s.gpa, "open {s} {s} v{d};", .{ uri, lang, version });
    }

    fn didChange(ctx: *anyopaque, uri: []const u8, version: i32, changes: []const LspChange, full: ?ChunkIterator) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        s.change(uri, version, changes, full) catch |e| {
            s.failed = e;
        };
    }

    fn change(s: *Server, uri: []const u8, version: i32, changes: []const LspChange, full: ?ChunkIterator) !void {
        const d = s.docs.getPtr(uri) orelse return error.NotOpen;
        if (version <= d.version) return error.VersionNotIncreasing;
        d.version = version;
        s.did_change += 1;
        if (full) |it| {
            d.text.deinit(s.gpa);
            d.text = try collect(s.gpa, it);
            try s.log.print(s.gpa, "full v{d};", .{version});
            return;
        }
        for (changes) |c| {
            const a = try offsetOf(d.text.items, c.start.line, c.start.col, s.enc);
            const b = try offsetOf(d.text.items, c.end.line, c.end.col, s.enc);
            if (b < a) return error.BadRange;
            try d.text.replaceRange(s.gpa, a, b - a, c.text);
        }
        try s.log.print(s.gpa, "change v{d} x{d};", .{ version, changes.len });
    }

    fn didSave(ctx: *anyopaque, uri: []const u8, it: ?ChunkIterator) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        var n: usize = 0;
        if (it) |i| {
            var t = collect(s.gpa, i) catch unreachable;
            n = t.items.len;
            t.deinit(s.gpa);
        }
        s.log.print(s.gpa, "save {s} {d};", .{ uri, n }) catch unreachable;
    }

    fn didClose(ctx: *anyopaque, uri: []const u8) void {
        const s: *Server = @ptrCast(@alignCast(ctx));
        const e = s.docs.fetchRemove(uri) orelse {
            s.failed = error.CloseUnopened;
            return;
        };
        s.gpa.free(e.key);
        var t = e.value.text;
        t.deinit(s.gpa);
        s.log.print(s.gpa, "close {s};", .{uri}) catch unreachable;
    }
};

/// The byte offset of an LSP position in `text`, resolved independently
/// of the piece tree: lines end at `\n`, `\r\n` or `\r`; columns count
/// bytes, UTF-16 units or code points.
fn offsetOf(text: []const u8, line: u64, col: u64, enc: Encoding) !usize {
    var i: usize = 0;
    var l: u64 = 0;
    while (l < line) {
        if (i >= text.len) return error.LinePastEnd;
        if (text[i] == '\n') {
            l += 1;
        } else if (text[i] == '\r') {
            l += 1;
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
        }
        i += 1;
    }
    var c: u64 = 0;
    while (c < col) {
        if (i >= text.len or text[i] == '\n' or text[i] == '\r') return error.ColumnPastEnd;
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp = std.unicode.utf8Decode(text[i..][0..n]) catch 0xfffd;
        c += switch (enc) {
            .utf8 => n,
            .utf16 => if (cp > 0xffff) 2 else 1,
            .utf32 => 1,
        };
        i += n;
    }
    if (c != col) return error.SplitCodePoint;
    return i;
}

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

test "lsp_sync: incremental changes reproduce text" {
    const gpa = testing.allocator;
    const pieces = [_][]const u8{ "a", "é", "日", "😀", "\r\n", "\n", "\r", "xyz", "", "👍🏽" };
    for ([_]Encoding{ .utf16, .utf8, .utf32 }) |enc| {
        var reg: DocumentRegistry = .init(gpa, .posix);
        defer reg.deinit();
        var server: Server = .{ .gpa = gpa, .enc = enc };
        defer server.deinit();
        var sync: LspSync = .init(gpa, &reg, enc, .incremental, server.sink());
        defer sync.deinit();
        const h = try reg.openFile("/f.txt", "héllo 😀\r\nworld\n");
        defer reg.release(h);
        try sync.track(h, "plaintext");
        var prng: std.Random.DefaultPrng = .init(0x15b + @as(u64, @intFromEnum(enc)));
        const rand = prng.random();
        for (0..400) |_| {
            // A few edits per frame, at code-point boundaries.
            const n_frame = rand.intRangeAtMost(usize, 1, 4);
            for (0..n_frame) |_| {
                const text = try docText(gpa, &reg, h);
                defer gpa.free(text);
                var edits: [2]pt.Edit = undefined;
                const k = rand.intRangeAtMost(usize, 1, 2);
                var pos: usize = 0;
                var count: usize = 0;
                for (0..k) |_| {
                    if (pos > text.len) break;
                    const a = boundary(text, rand.intRangeAtMost(usize, pos, text.len));
                    const b = boundary(text, @min(text.len, a + rand.uintLessThan(usize, 6)));
                    edits[count] = .{ .range = .{ .start = a, .end = b }, .text = pieces[rand.uintLessThan(usize, pieces.len)] };
                    count += 1;
                    pos = b + 1;
                }
                try edit(&reg, h, edits[0..count]);
            }
            sync.flush();
            if (server.failed) |e| {
                std.debug.print("enc {t}: {t}\n", .{ enc, e });
                return e;
            }
            const want = try docText(gpa, &reg, h);
            defer gpa.free(want);
            try testing.expectEqualStrings(want, server.text("file:///f.txt"));
        }
    }
}

/// `i` moved back to a code-point boundary of `text`.
fn boundary(text: []const u8, i_in: usize) usize {
    var i = i_in;
    while (i < text.len and i > 0 and text[i] & 0xc0 == 0x80) i -= 1;
    return i;
}

test "lsp_sync: coalescing per frame and versions strictly increase" {
    const gpa = testing.allocator;
    var reg: DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    var server: Server = .{ .gpa = gpa, .enc = .utf16 };
    defer server.deinit();
    var sync: LspSync = .init(gpa, &reg, .utf16, .incremental, server.sink());
    defer sync.deinit();
    const h = try reg.openFile("/a.zig", "fn main() {}\n");
    defer reg.release(h);
    try sync.track(h, "zig");
    // Three keystrokes in one frame: one didChange.
    try edit(&reg, h, &.{.{ .range = .{ .start = 11, .end = 11 }, .text = "x" }});
    try edit(&reg, h, &.{.{ .range = .{ .start = 12, .end = 12 }, .text = "y" }});
    try edit(&reg, h, &.{.{ .range = .{ .start = 13, .end = 13 }, .text = "z" }});
    sync.flush();
    try testing.expectEqual(@as(u32, 1), server.did_change);
    try testing.expectEqual(@as(?i32, 2), sync.version(h));
    // A frame without edits sends nothing.
    sync.flush();
    try testing.expectEqual(@as(u32, 1), server.did_change);
    try edit(&reg, h, &.{.{ .range = .{ .start = 0, .end = 2 }, .text = "pub fn" }});
    sync.saved(h);
    try testing.expectEqualStrings("pub fn main() {xyz}\n", server.text("file:///a.zig"));
    try testing.expectEqualStrings("open file:///a.zig zig v1;change v2 x1;change v3 x1;save file:///a.zig 0;", server.log.items);
    try testing.expect(server.failed == null);
}

test "lsp_sync: full sync, save text, overflow reopen, close" {
    const gpa = testing.allocator;
    var reg: DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    var server: Server = .{ .gpa = gpa, .enc = .utf16 };
    defer server.deinit();
    var sync: LspSync = .init(gpa, &reg, .utf16, .full, server.sink());
    defer sync.deinit();
    sync.include_text_on_save = true;
    sync.max_version = 3;
    const h = try reg.openFile("/b.txt", "ab");
    try sync.track(h, "plaintext");
    try testing.expectError(error.AlreadyTracked, sync.track(h, "plaintext"));
    for (0..3) |i| {
        try edit(&reg, h, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "x" }});
        sync.flush();
        _ = i;
    }
    sync.saved(h);
    reg.release(h);
    try testing.expect(!sync.isTracked(h));
    try testing.expectEqualStrings(
        "open file:///b.txt plaintext v1;full v2;full v3;close file:///b.txt;open file:///b.txt plaintext v1;" ++
            "save file:///b.txt 5;close file:///b.txt;",
        server.log.items,
    );
    try testing.expect(server.failed == null);
}

test "lsp_sync: rename reopens under the new uri" {
    const gpa = testing.allocator;
    var reg: DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    var server: Server = .{ .gpa = gpa, .enc = .utf8 };
    defer server.deinit();
    var sync: LspSync = .init(gpa, &reg, .utf8, .incremental, server.sink());
    defer sync.deinit();
    const h = try reg.openFile("/old.c", "int x;");
    defer reg.release(h);
    try sync.track(h, "c");
    try edit(&reg, h, &.{.{ .range = .{ .start = 4, .end = 5 }, .text = "y" }});
    try reg.rename(h, "/new.c");
    try testing.expectEqualStrings("int y;", server.text("file:///new.c"));
    try testing.expectEqualStrings(
        "open file:///old.c c v1;change v2 x1;close file:///old.c;open file:///new.c c v1;",
        server.log.items,
    );
    sync.untrack(h);
    try testing.expectEqual(@as(u32, 0), server.docs.count());
    try testing.expect(server.failed == null);
}

test "lsp_sync: large documents are not synced; evicted log falls back to full" {
    const gpa = testing.allocator;
    var reg: DocumentRegistry = .init(gpa, .posix);
    defer reg.deinit();
    var server: Server = .{ .gpa = gpa, .enc = .utf16 };
    defer server.deinit();
    var sync: LspSync = .init(gpa, &reg, .utf16, .incremental, server.sink());
    defer sync.deinit();
    sync.max_bytes = 4;
    const big = try reg.openFile("/big", "12345");
    defer reg.release(big);
    try testing.expectError(error.TooLarge, sync.track(big, "plaintext"));
    const h = try reg.openFile("/small", "1");
    defer reg.release(h);
    try sync.track(h, "plaintext");
    reg.get(h).?.change_log.capacity_versions = 2;
    for (0..5) |_| try edit(&reg, h, &.{.{ .range = .{ .start = 0, .end = 0 }, .text = "z" }});
    sync.flush();
    try testing.expectEqualStrings("zzzzz1", server.text("file:///small"));
    try testing.expectEqualStrings("open file:///small plaintext v1;full v2;", server.log.items);
}
