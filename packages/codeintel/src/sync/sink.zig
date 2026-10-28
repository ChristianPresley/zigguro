//! The LSP text-sync sink for one language server (E07.F02.S01.T02):
//! implements `zg_editor.model.api.lsp_sync.LspSink`, serializing
//! `didOpen`, `didChange`, `didSave` and `didClose` and handing the
//! params to the client. Document text is escaped chunk by chunk from the
//! piece tree, so it is never copied into a buffer of its own before the
//! JSON body. The last version sent per document is tracked for request
//! versioning and diagnostics.
//!
//! The sink runs where `LspSync.flush` runs (once per frame); it does no
//! I/O beyond queueing the message on the client's endpoint.

const std = @import("std");
const zg_editor = @import("zg_editor");
const zg_lsp = @import("zg_lsp");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const lsp_sync = zg_editor.model.api.lsp_sync;
const LspChange = lsp_sync.LspChange;
const ChunkIterator = zg_editor.model.buffer.piece_tree.ChunkIterator;
const escape: std.json.Stringify.Options = .{};

const log = std.log.scoped(.codeintel);

/// Where serialized notifications go: a running `zg_lsp` client, or a
/// test's capture.
pub const Out = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, method: []const u8, params: []const u8) anyerror!void,

    /// Sends through `c.notifyRaw`.
    pub fn client(c: *zg_lsp.client.Client) Out {
        return .{ .ctx = c, .send = struct {
            fn send(ctx: *anyopaque, method: []const u8, params: []const u8) anyerror!void {
                const cl: *zg_lsp.client.Client = @ptrCast(@alignCast(ctx));
                return cl.notifyRaw(method, params);
            }
        }.send };
    }
};

/// Text sync to one server.
pub const Sink = struct {
    gpa: Allocator,
    out: Out,
    /// URI -> the last version sent (owned keys).
    sent: std.StringHashMapUnmanaged(i32) = .empty,
    body: std.Io.Writer.Allocating,
    /// Messages that could not be sent (the server is not running); the
    /// supervisor re-syncs from the documents after a restart.
    dropped: u32 = 0,
    /// Told after each `didOpen`/`didChange` (diagnostics map reported
    /// versions to the text that was sent).
    observer: ?Observer = null,

    pub const Observer = struct {
        ctx: *anyopaque,
        sent: *const fn (ctx: *anyopaque, uri: []const u8, version: i32) void,
    };

    pub fn init(gpa: Allocator, out: Out) Sink {
        return .{ .gpa = gpa, .out = out, .body = .init(gpa) };
    }

    pub fn deinit(s: *Sink) void {
        var it = s.sent.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        s.sent.deinit(s.gpa);
        s.body.deinit();
    }

    /// The vtable `LspSync` calls. `s` must not move afterwards.
    pub fn lspSink(s: *Sink) lsp_sync.LspSink {
        return .{ .ctx = s, .didOpen = didOpen, .didChange = didChange, .didSave = didSave, .didClose = didClose };
    }

    /// The last version sent for `uri`, or null when it is not open.
    pub fn sentVersion(s: *const Sink, uri: []const u8) ?i32 {
        return s.sent.get(uri);
    }

    fn fromCtx(ctx: *anyopaque) *Sink {
        return @ptrCast(@alignCast(ctx));
    }

    fn didOpen(ctx: *anyopaque, uri: []const u8, lang: []const u8, version: i32, text: ChunkIterator) void {
        const s = fromCtx(ctx);
        s.emit("textDocument/didOpen", textHint(text), struct {
            fn write(w: *Writer, a: anytype) Writer.Error!void {
                try w.writeAll("{\"textDocument\":{\"uri\":");
                try std.json.Stringify.encodeJsonString(a.uri, escape, w);
                try w.writeAll(",\"languageId\":");
                try std.json.Stringify.encodeJsonString(a.lang, escape, w);
                try w.print(",\"version\":{d},\"text\":", .{a.version});
                try writeText(w, a.text);
                try w.writeAll("}}");
            }
        }.write, .{ .uri = uri, .lang = lang, .version = version, .text = text });
        s.setSent(uri, version);
    }

    fn didChange(ctx: *anyopaque, uri: []const u8, version: i32, changes: []const LspChange, full: ?ChunkIterator) void {
        const s = fromCtx(ctx);
        s.emit("textDocument/didChange", if (full) |it| textHint(it) else 0, struct {
            fn write(w: *Writer, a: anytype) Writer.Error!void {
                try w.writeAll("{\"textDocument\":{\"uri\":");
                try std.json.Stringify.encodeJsonString(a.uri, escape, w);
                try w.print(",\"version\":{d}}},\"contentChanges\":[", .{a.version});
                if (a.full) |it| {
                    try w.writeAll("{\"text\":");
                    try writeText(w, it);
                    try w.writeAll("}");
                } else for (a.changes, 0..) |c, i| {
                    if (i > 0) try w.writeByte(',');
                    try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"text\":", .{ c.start.line, c.start.col, c.end.line, c.end.col });
                    try std.json.Stringify.encodeJsonString(c.text, escape, w);
                    try w.writeByte('}');
                }
                try w.writeAll("]}");
            }
        }.write, .{ .uri = uri, .version = version, .changes = changes, .full = full });
        s.setSent(uri, version);
    }

    fn didSave(ctx: *anyopaque, uri: []const u8, text: ?ChunkIterator) void {
        const s = fromCtx(ctx);
        s.emit("textDocument/didSave", if (text) |it| textHint(it) else 0, struct {
            fn write(w: *Writer, a: anytype) Writer.Error!void {
                try w.writeAll("{\"textDocument\":{\"uri\":");
                try std.json.Stringify.encodeJsonString(a.uri, escape, w);
                try w.writeByte('}');
                if (a.text) |it| {
                    try w.writeAll(",\"text\":");
                    try writeText(w, it);
                }
                try w.writeByte('}');
            }
        }.write, .{ .uri = uri, .text = text });
    }

    fn didClose(ctx: *anyopaque, uri: []const u8) void {
        const s = fromCtx(ctx);
        s.emit("textDocument/didClose", 0, struct {
            fn write(w: *Writer, a: anytype) Writer.Error!void {
                try w.writeAll("{\"textDocument\":{\"uri\":");
                try std.json.Stringify.encodeJsonString(a.uri, escape, w);
                try w.writeAll("}}");
            }
        }.write, .{ .uri = uri });
        if (s.sent.fetchRemove(uri)) |kv| s.gpa.free(kv.key);
    }

    /// Builds the params with `write` and sends them. A failure is logged
    /// and counted: `LspSink` has no error channel, and a server that is
    /// not running is re-synced when it restarts.
    /// `hint`: the bytes of text the body carries, so a large document's
    /// body is sized once rather than grown by doubling.
    fn emit(s: *Sink, method: []const u8, hint: u64, comptime write: anytype, args: anytype) void {
        s.body.clearRetainingCapacity();
        if (hint > 0) s.body.ensureTotalCapacityPrecise(@intCast(hint + hint / 32 + 512)) catch {};
        write(&s.body.writer, args) catch {
            s.dropped += 1;
            log.warn("{s}: out of memory building the message", .{method});
            return;
        };
        s.out.send(s.out.ctx, method, s.body.written()) catch |err| {
            s.dropped += 1;
            log.debug("{s} not sent: {t}", .{ method, err });
        };
        // Large documents should not pin a large buffer between frames.
        if (s.body.writer.buffer.len > 1 << 20) {
            s.body.deinit();
            s.body = .init(s.gpa);
        }
    }

    fn setSent(s: *Sink, uri: []const u8, version: i32) void {
        const gop = s.sent.getOrPut(s.gpa, uri) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = s.gpa.dupe(u8, uri) catch {
                s.sent.removeByPtr(gop.key_ptr);
                return;
            };
        }
        gop.value_ptr.* = version;
        if (s.observer) |o| o.sent(o.ctx, uri, version);
    }
};

fn textHint(it: ChunkIterator) u64 {
    return it.end - it.pos;
}

/// The text as one JSON string, escaped chunk by chunk.
fn writeText(w: *Writer, it_in: ChunkIterator) Writer.Error!void {
    var it = it_in;
    try w.writeByte('"');
    while (it.next()) |chunk| try std.json.Stringify.encodeJsonStringChars(chunk, escape, w);
    try w.writeByte('"');
}
