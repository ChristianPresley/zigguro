//! Hover (E07.F03.S02.T01): `request` asks every server routed for hover
//! at a byte offset; `tick` merges the answers in routing order into one
//! Markdown text, with the diagnostics at that offset first, and the
//! byte range the hover is about (the server's `range`, else the word).
//! The result is dropped when the document changed after the request, so
//! an edit never shows a stale hover.
//!
//! `hoverToMarkdown` turns any of the protocol's hover forms into
//! Markdown: `MarkupContent` (plain text is escaped), `MarkedString`
//! (`{language, value}` becomes a fenced block) and arrays of them
//! (joined by rules). `sanitize` keeps the Markdown safe to render:
//! links other than http(s), file and allowlisted `command:` URIs become
//! plain text, and raw HTML is dropped except `<br>`, `<code>`, `<b>`
//! and `<i>` (images are never fetched; the renderer shows their text).

const HoverService = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const position = @import("position.zig");
const requester = @import("request.zig");
const Store = @import("../diagnostics/Store.zig");

const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Req = requester.Requester(.@"textDocument/hover", .hover);

/// Where a request came from (the mouse resting, or a key).
pub const Source = enum { mouse, keyboard };

/// A hover to show.
pub const Result = struct {
    h: DocHandle,
    /// The document version it was computed at.
    version: u64,
    offset: u64,
    /// The bytes the hover is about.
    range: zg_editor.model.buffer.piece_tree.Range,
    /// Sanitized Markdown (diagnostics first).
    markdown: []const u8,
    source: Source,
};

gpa: Allocator,
req: Req,
diags: ?*Store,
/// Store key of the document asked about (for its diagnostics).
key: std.ArrayList(u8) = .empty,
pending: ?struct { h: DocHandle, offset: u64, source: Source } = null,
/// Markdown parts per server, until all answered.
parts: [requester.max_servers]?[]u8 = @splat(null),
range: ?zg_editor.model.buffer.piece_tree.Range = null,
result: ?Result = null,
text: std.ArrayList(u8) = .empty,
/// Bumped when `current` changes.
generation: u64 = 0,

/// `diags` (optional) supplies the diagnostics shown first.
pub fn init(mgr: *Manager, diags: ?*Store, waker: zg_core.runtime.Waker) HoverService {
    return .{ .gpa = mgr.gpa, .req = .init(mgr, waker), .diags = diags };
}

/// Call after `Manager.deinit`.
pub fn deinit(s: *HoverService) void {
    s.req.deinit();
    s.clearParts();
    s.key.deinit(s.gpa);
    s.text.deinit(s.gpa);
}

fn clearParts(s: *HoverService) void {
    for (&s.parts) |*p| if (p.*) |x| {
        s.gpa.free(x);
        p.* = null;
    };
}

/// Asks for the hover at byte `offset` of `h`; `key` is its diagnostic
/// store key (null: no diagnostics). A hover already shown for the same
/// spot stays until the answer replaces it.
pub fn request(s: *HoverService, h: DocHandle, offset: u64, key: ?[]const u8, source: Source) !void {
    if (s.pending) |p| if (std.meta.eql(p.h, h) and p.offset == offset) return;
    s.clearParts();
    s.range = null;
    s.pending = .{ .h = h, .offset = offset, .source = source };
    s.key.clearRetainingCapacity();
    if (key) |k| try s.key.appendSlice(s.gpa, k);
    const n = try s.req.ask(h, offset, .{});
    // No server: diagnostics alone may still make a hover.
    if (n == 0) _ = s.finish();
}

/// Stops asking and hides the hover (the mouse left, an edit, Escape).
pub fn cancel(s: *HoverService) void {
    s.req.cancel();
    s.clearParts();
    s.pending = null;
    if (s.result != null) {
        s.result = null;
        s.generation += 1;
    }
}

/// The hover to show, if any.
pub fn current(s: *const HoverService) ?*const Result {
    return if (s.result) |*r| r else null;
}

/// Applies answers; true when `current` changed.
pub fn tick(s: *HoverService) bool {
    const p = s.pending orelse return false;
    var changed = false;
    for (s.req.take()) |a| {
        const doc = s.req.mgr.docs.get(a.h) orelse continue;
        if (doc.version != a.version) {
            // Edited since: drop the request (and any hover shown).
            s.cancel();
            return true;
        }
        const v = switch (a.result) {
            .ok => |o| o.value orelse continue,
            else => continue,
        };
        const md = hoverToMarkdown(s.gpa, v) catch continue;
        s.parts[a.index] = md;
        if (s.range == null) if (v.range) |r| {
            var m: position.Mapper = .{ .gpa = s.gpa, .tree = &doc.tree, .enc = position.encodingOf(a.client.encoding()) };
            defer m.deinit();
            s.range = m.toRange(r) catch null;
        };
    }
    if (s.req.done() and s.pending != null and std.meta.eql(s.pending.?, p)) changed = s.finish() or changed;
    return changed;
}

/// Builds the result from the parts and the diagnostics; true when it
/// changed.
fn finish(s: *HoverService) bool {
    const p = s.pending.?;
    s.pending = null;
    s.text.clearRetainingCapacity();
    const doc = s.req.mgr.docs.get(p.h) orelse return false;
    s.appendDiagnostics(p.h, p.offset) catch {};
    for (s.parts) |part| if (part) |md| {
        if (s.text.items.len > 0) s.text.appendSlice(s.gpa, "\n\n---\n\n") catch {};
        sanitize(s.gpa, md, &s.text) catch {};
    };
    s.clearParts();
    const had = s.result != null;
    if (s.text.items.len == 0) {
        s.result = null;
        if (had) s.generation += 1;
        return had;
    }
    const range = s.range orelse wordAt(doc, p.offset);
    s.result = .{ .h = p.h, .version = doc.version, .offset = p.offset, .range = range, .markdown = s.text.items, .source = p.source };
    s.generation += 1;
    return true;
}

fn appendDiagnostics(s: *HoverService, h: DocHandle, offset: u64) !void {
    const st = s.diags orelse return;
    if (s.key.items.len == 0) return;
    const doc = s.req.mgr.docs.get(h) orelse return;
    const snap = st.acquire();
    defer snap.release();
    const b = snap.bucket(s.key.items) orelse return;
    for (b.sets) |set| {
        const ver = set.version orelse continue;
        for (set.diags) |d| {
            const br = d.bytes orelse continue;
            const r = doc.mapForward(ver, .{ .start = br.start, .end = br.end }, .right) orelse continue;
            if (offset < r.start or offset > @max(r.end, r.start + 1)) continue;
            if (s.text.items.len > 0) try s.text.appendSlice(s.gpa, "\n\n");
            try s.text.print(s.gpa, "**{s}**: ", .{d.severity.label()});
            try escapeInto(s.gpa, d.message, &s.text);
            if (d.source.len > 0) {
                try s.text.appendSlice(s.gpa, " _(");
                try escapeInto(s.gpa, d.source, &s.text);
                if (d.code.len > 0) {
                    try s.text.append(s.gpa, ' ');
                    try escapeInto(s.gpa, d.code, &s.text);
                }
                try s.text.appendSlice(s.gpa, ")_");
            }
        }
    }
}

/// The identifier around `offset` (one character when there is none).
pub fn wordAt(doc: *const zg_editor.model.document.Document, offset: u64) zg_editor.model.buffer.piece_tree.Range {
    const len = doc.len();
    var buf: [256]u8 = undefined;
    const lo = offset -| 128;
    const hi = @min(len, offset + 128);
    var n: usize = 0;
    var it = doc.tree.slice(.{ .start = lo, .end = hi });
    while (it.next()) |c| {
        @memcpy(buf[n..][0..c.len], c);
        n += c.len;
    }
    const text = buf[0..n];
    const at: usize = @intCast(offset - lo);
    var a = at;
    while (a > 0 and isWord(text[a - 1])) a -= 1;
    var b = at;
    while (b < text.len and isWord(text[b])) b += 1;
    if (a == b) return .{ .start = offset, .end = @min(len, offset + 1) };
    return .{ .start = lo + a, .end = lo + b };
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// `h`'s contents as Markdown (caller frees).
pub fn hoverToMarkdown(gpa: Allocator, h: protocol.Hover) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    switch (h.contents) {
        .markup_content => |m| switch (m.kind) {
            .PlainText => try escapeInto(gpa, m.value, &out),
            else => try out.appendSlice(gpa, m.value),
        },
        .marked_string => |ms| try markedInto(gpa, ms, &out),
        .marked_string_array => |arr| for (arr) |ms| {
            const before = out.items.len;
            if (before > 0) try out.appendSlice(gpa, "\n\n---\n\n");
            const body = out.items.len;
            try markedInto(gpa, ms, &out);
            // Empty entries add no rule.
            if (out.items.len == body) out.shrinkRetainingCapacity(before);
        },
    }
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n");
    if (trimmed.len != out.items.len) {
        std.mem.copyForwards(u8, out.items, trimmed);
        out.shrinkRetainingCapacity(trimmed.len);
    }
    return out.toOwnedSlice(gpa);
}

fn markedInto(gpa: Allocator, ms: protocol.MarkedString, out: *std.ArrayList(u8)) Allocator.Error!void {
    switch (ms) {
        .string => |t| try out.appendSlice(gpa, t),
        .marked_string_with_language => |m| {
            if (m.value.len == 0) return;
            try out.print(gpa, "```{s}\n{s}\n```", .{ m.language, std.mem.trimEnd(u8, m.value, "\n") });
        },
    }
}

/// Plain text as Markdown: Markdown's punctuation backslash-escaped,
/// line breaks kept.
pub fn escapeInto(gpa: Allocator, text: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    for (text) |c| {
        if (std.mem.indexOfScalar(u8, "\\`*_{}[]()#+-.!|<>~", c) != null) try out.append(gpa, '\\');
        if (c == '\n') {
            try out.appendSlice(gpa, "  \n");
            continue;
        }
        try out.append(gpa, c);
    }
}

/// `command:` URIs a hover may link to (the client runs them).
pub const allowed_commands = [_][]const u8{
    "editor.showHover",
    "editor.goToDefinition",
    "editor.quickFix",
};

fn linkAllowed(target: []const u8) bool {
    const t = std.mem.trim(u8, target, " <>");
    if (std.ascii.startsWithIgnoreCase(t, "https://") or std.ascii.startsWithIgnoreCase(t, "http://") or std.ascii.startsWithIgnoreCase(t, "file://")) return true;
    if (std.ascii.startsWithIgnoreCase(t, "command:")) {
        const rest = t["command:".len..];
        const name = rest[0 .. std.mem.indexOfAny(u8, rest, "?") orelse rest.len];
        for (allowed_commands) |c| if (std.mem.eql(u8, c, name)) return true;
    }
    return false;
}

const allowed_tags = [_][]const u8{ "br", "code", "b", "i" };

/// Appends `md` with disallowed links reduced to their text and HTML
/// tags other than `allowed_tags` removed. Code spans and fences are
/// copied as they are.
pub fn sanitize(gpa: Allocator, md: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    var i: usize = 0;
    var fence = false;
    var line_start = true;
    while (i < md.len) {
        // Fences: copied verbatim.
        if (line_start) {
            const rest = std.mem.trimStart(u8, md[i..], " ");
            if (std.mem.startsWith(u8, rest, "```") or std.mem.startsWith(u8, rest, "~~~")) fence = !fence;
        }
        if (fence) {
            const e = std.mem.indexOfScalarPos(u8, md, i, '\n') orelse md.len;
            try out.appendSlice(gpa, md[i..@min(e + 1, md.len)]);
            i = e + 1;
            line_start = true;
            continue;
        }
        const c = md[i];
        line_start = c == '\n';
        switch (c) {
            '\\' => {
                try out.appendSlice(gpa, md[i..@min(i + 2, md.len)]);
                i += 2;
            },
            '`' => {
                // A code span: up to the matching run of backticks.
                var n: usize = 0;
                while (i + n < md.len and md[i + n] == '`') n += 1;
                const close = std.mem.indexOfPos(u8, md, i + n, md[i .. i + n]) orelse {
                    try out.appendSlice(gpa, md[i .. i + n]);
                    i += n;
                    continue;
                };
                try out.appendSlice(gpa, md[i .. close + n]);
                i = close + n;
            },
            '<' => {
                const e = std.mem.indexOfScalarPos(u8, md, i, '>') orelse {
                    try out.appendSlice(gpa, "&lt;");
                    i += 1;
                    continue;
                };
                const inner = md[i + 1 .. e];
                // Autolinks: <https://...>.
                if (std.mem.indexOfScalar(u8, inner, ':') != null and std.mem.indexOfAny(u8, inner, " \t\n") == null) {
                    if (linkAllowed(inner)) try out.appendSlice(gpa, md[i .. e + 1]) else try out.appendSlice(gpa, inner);
                    i = e + 1;
                    continue;
                }
                const name_part = std.mem.trimStart(u8, inner, "/");
                const name_end = std.mem.indexOfAny(u8, name_part, " \t/") orelse name_part.len;
                const name = name_part[0..name_end];
                const ok = for (allowed_tags) |t| {
                    if (std.ascii.eqlIgnoreCase(t, name)) break true;
                } else false;
                if (ok) try out.appendSlice(gpa, md[i .. e + 1]);
                i = e + 1;
            },
            '!', '[' => {
                // [text](target) and ![alt](src).
                const img = c == '!';
                const open = if (img) i + 1 else i;
                if (open >= md.len or md[open] != '[') {
                    try out.append(gpa, c);
                    i += 1;
                    continue;
                }
                const close = std.mem.indexOfScalarPos(u8, md, open, ']') orelse {
                    try out.append(gpa, c);
                    i += 1;
                    continue;
                };
                if (close + 1 >= md.len or md[close + 1] != '(') {
                    try out.append(gpa, c);
                    i += 1;
                    continue;
                }
                const end = std.mem.indexOfScalarPos(u8, md, close + 1, ')') orelse {
                    try out.append(gpa, c);
                    i += 1;
                    continue;
                };
                const label = md[open + 1 .. close];
                const target = md[close + 2 .. end];
                if (!img and linkAllowed(target)) try out.appendSlice(gpa, md[i .. end + 1]) else try out.appendSlice(gpa, label);
                i = end + 1;
            },
            else => {
                try out.append(gpa, c);
                i += 1;
            },
        }
    }
}
