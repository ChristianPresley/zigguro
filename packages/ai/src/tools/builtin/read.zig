//! `read_file` (E10.F06.S02.T01): numbered lines for text, images and PDFs
//! as content parts when the model takes them, and a description for
//! other binary files.
//!
//! Text comes back as `<line number right-aligned to 6>\t<line>` under a
//! header `[file: <path> · <n> lines · showing <a>-<b>]`. The default is
//! 2,000 lines; longer lines are cut with `…[N chars]`. CRLF files are
//! shown with LF and say so; UTF-16 files (with a BOM) are decoded. Every
//! read is recorded in the `ReadTracker`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;
const FileTools = files.FileTools;

pub const schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1,"maximum":5000}},"required":["path"],"additionalProperties":false}
;

pub const description = "Read a file from the workspace. Returns numbered lines (cat -n style). Use offset/limit for large files. Reads unsaved editor content when the file is open.";

pub fn spec(ft: *FileTools) proto.ToolSpec {
    return .{
        .name = "read_file",
        .description = description,
        .input_schema_json = schema,
        .read_only = true,
        .effects = .{ .read_only = true, .idempotent = true },
        .handler = .{ .ctx = ft, .call = call },
    };
}

/// What the first bytes say a file is.
pub const Sniff = enum { text, png, jpeg, gif, webp, pdf, binary };

pub fn sniff(bytes: []const u8) Sniff {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return .gif;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    if (std.mem.startsWith(u8, bytes, "%PDF-")) return .pdf;
    if (utf16Bom(bytes) != null) return .text;
    const head = bytes[0..@min(bytes.len, 8192)];
    if (std.mem.indexOfScalar(u8, head, 0) != null) return .binary;
    // More than 30% invalid UTF-8 is binary.
    var bad: usize = 0;
    var i: usize = 0;
    while (i < head.len) {
        const n = std.unicode.utf8ByteSequenceLength(head[i]) catch {
            bad += 1;
            i += 1;
            continue;
        };
        if (i + n > head.len) break;
        if (!std.unicode.utf8ValidateSlice(head[i .. i + n])) bad += n;
        i += n;
    }
    return if (head.len > 0 and bad * 10 > head.len * 3) .binary else .text;
}

fn mediaType(s: Sniff) []const u8 {
    return switch (s) {
        .png => "image/png",
        .jpeg => "image/jpeg",
        .gif => "image/gif",
        .webp => "image/webp",
        .pdf => "application/pdf",
        .text => "text/plain",
        .binary => "application/octet-stream",
    };
}

fn utf16Bom(bytes: []const u8) ?enum { le, be } {
    if (std.mem.startsWith(u8, bytes, "\xff\xfe")) return .le;
    if (std.mem.startsWith(u8, bytes, "\xfe\xff")) return .be;
    return null;
}

/// UTF-8 text of `bytes` and a note on its encoding, if not UTF-8.
fn decode(a: Allocator, bytes: []const u8) !struct { text: []const u8, note: ?[]const u8 } {
    const bom = utf16Bom(bytes) orelse return .{ .text = if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes, .note = null };
    const body = bytes[2 .. bytes.len - (bytes.len % 2)];
    const units = try a.alloc(u16, body.len / 2);
    for (units, 0..) |*u, i| u.* = switch (bom) {
        .le => std.mem.readInt(u16, body[i * 2 ..][0..2], .little),
        .be => std.mem.readInt(u16, body[i * 2 ..][0..2], .big),
    };
    const text = std.unicode.utf16LeToUtf8Alloc(a, units) catch return .{ .text = bytes, .note = null };
    return .{ .text = text, .note = if (bom == .le) "UTF-16LE" else "UTF-16BE" };
}

fn pdfPages(bytes: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "/Type")) |at| {
        i = at + 5;
        var j = i;
        while (j < bytes.len and (bytes[j] == ' ' or bytes[j] == '\n' or bytes[j] == '\r')) j += 1;
        if (std.mem.startsWith(u8, bytes[j..], "/Page") and !std.mem.startsWith(u8, bytes[j..], "/Pages")) n += 1;
    }
    return n;
}

fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
    const ft: *FileTools = @ptrCast(@alignCast(ctx));
    const a = c.arena;
    const path = files.str(c.input, "path") orelse return files.errOut(a, "read_file needs a \"path\" string.");
    const r = switch (try ft.open(c, path, .read)) {
        .ok => |r| r,
        .denied => |why| return files.errOut(a, try std.fmt.allocPrint(a, "Access to {s} is denied: {s}", .{ path, why })),
    };
    switch (ft.files.kindAs(c.io, r.abs, c.agent)) {
        .missing => return files.errOut(a, try std.fmt.allocPrint(a, "File not found: {s}. Use a search tool to locate it.", .{r.rel})),
        .directory => return files.errOut(a, try std.fmt.allocPrint(a, "{s} is a directory; use list_dir.", .{r.rel})),
        .file => {},
    }
    const offset = files.int(c.input, "offset");
    const limit = files.int(c.input, "limit");
    const max: usize = if (offset != null and limit != null) std.math.maxInt(usize) else @intCast(ft.cfg.large_file_bytes + 1);
    const read = ft.files.readAs(c.io, a, r.abs, max, c.agent) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        else => return files.errOut(a, try std.fmt.allocPrint(a, "Could not read {s}: {s}", .{ r.rel, @errorName(e) })),
    };
    if (read.size > ft.cfg.large_file_bytes and (offset == null or limit == null))
        return files.errOut(a, try std.fmt.allocPrint(a, "{s} is {d} MB; pass offset and limit to read part of it.", .{ r.rel, read.size >> 20 }));
    if (read.size == 0) {
        try ft.tracker.record(c.agent, r.abs, read.version, .{ .first = 1, .last = 1 });
        return files.textOut(a, try std.fmt.allocPrint(a, "[file: {s} · file is empty]", .{r.rel}));
    }

    const kind = sniff(read.bytes);
    switch (kind) {
        .png, .jpeg, .gif, .webp => {
            if (ft.cfg.image_input and read.size <= ft.cfg.max_image_bytes) return encoded(c, ft, r, read, kind, .image);
            return files.textOut(a, try std.fmt.allocPrint(a, "Image file ({s}, {d} bytes); this model cannot view it here.", .{ @tagName(kind), read.size }));
        },
        .pdf => {
            if (ft.cfg.pdf_input) return encoded(c, ft, r, read, kind, .document);
            return files.textOut(a, try std.fmt.allocPrint(a, "PDF ({d} pages, {d} bytes); use a PDF tool to read it.", .{ pdfPages(read.bytes), read.size }));
        },
        .binary => return files.textOut(a, try std.fmt.allocPrint(a, "Binary file ({d} bytes, {s}); not shown.", .{ read.size, mediaType(kind) })),
        .text => {},
    }

    const dec = decode(a, read.bytes) catch return error.OutOfMemory;
    const crlf = std.mem.indexOf(u8, dec.text, "\r\n") != null;
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, dec.text, '\n');
    while (it.next()) |l| try lines.append(a, std.mem.trimEnd(u8, l, "\r"));
    if (dec.text.len > 0 and dec.text[dec.text.len - 1] == '\n') lines.items.len -= 1;
    const total = lines.items.len;

    const first: usize = if (offset) |o| @intCast(@max(o, 1)) else 1;
    if (first > total) return files.errOut(a, try std.fmt.allocPrint(a, "offset {d} is past the end of {s} ({d} lines).", .{ first, r.rel, total }));
    const n: usize = if (limit) |l| @intCast(std.math.clamp(l, 1, 5000)) else ft.cfg.default_limit;
    const last = @min(total, first + n - 1);

    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    write: {
        w.print("[file: {s} · {d} lines · showing {d}-{d}", .{ r.rel, total, first, last }) catch break :write;
        if (crlf) w.writeAll(" · CRLF line endings, shown as LF") catch break :write;
        if (dec.note) |note| w.print(" · decoded from {s}", .{note}) catch break :write;
        if (read.from_buffer) w.writeAll(" · unsaved editor content") catch break :write;
        w.writeAll("]\n") catch break :write;
        for (lines.items[first - 1 .. last], first..) |l, no| {
            if (l.len > ft.cfg.max_line_chars) {
                var cut = ft.cfg.max_line_chars;
                while (cut > 0 and (l[cut] & 0xc0) == 0x80) cut -= 1;
                w.print("{d:>6}\t{s}…[{d} chars]\n", .{ no, l[0..cut], l.len - cut }) catch break :write;
            } else w.print("{d:>6}\t{s}\n", .{ no, l }) catch break :write;
        }
        if (last < total) w.print("[{d} more lines; read on with offset={d}]\n", .{ total - last, last + 1 }) catch break :write;
    }
    try ft.tracker.record(c.agent, r.abs, read.version, .{ .first = first, .last = last });
    return FileTools.withNotes(c, read.notes, try files.textOut(a, out.written()));
}

fn encoded(c: *proto.ToolCall, ft: *FileTools, r: files.Resolved, read: files.Read, kind: Sniff, as: enum { image, document }) proto.ToolError!proto.ToolOutput {
    const a = c.arena;
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(read.bytes.len));
    _ = enc.encode(b64, read.bytes);
    const parts = try a.alloc(proto.ResultPart, 2);
    parts[0] = .{ .text = try std.fmt.allocPrint(a, "[file: {s} · {s} · {d} bytes]", .{ r.rel, mediaType(kind), read.size }) };
    parts[1] = switch (as) {
        .image => .{ .image = .{ .media_type = mediaType(kind), .data = .{ .base64 = b64 } } },
        .document => .{ .document = .{ .media_type = mediaType(kind), .data = .{ .base64 = b64 }, .title = r.rel } },
    };
    try ft.tracker.record(c.agent, r.abs, read.version, .{ .first = 1, .last = 1 });
    return .{ .parts = parts };
}
