//! Session export (E10.F08.S01.T02). Markdown for reading and sharing:
//! role headings, tool calls as fenced blocks with their JSON input and a
//! bounded output, thinking omitted unless asked for. JSON is the
//! canonical message array (`zg_ai_proto` codecs). Both export the active
//! conversation: messages undone by a rewind are left out.

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const loader = @import("loader.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const ExportOptions = struct {
    include_thinking: bool = false,
    /// Bytes of each tool output kept; the rest is replaced by a note.
    max_output_bytes: u32 = 2000,
    /// Heading of the document; defaults to the session id.
    title: ?[]const u8 = null,
};

/// Writes `l` (loaded in `.full` mode) as Markdown.
pub fn exportMarkdown(gpa: Allocator, l: *const loader.LoadedSession, w: *Writer, opts: ExportOptions) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try records.activeMessages(a, l.tail);
    var title: ?[]const u8 = opts.title;
    if (title == null) for (l.tail) |x| if (x.record == .title) {
        title = x.record.title;
    };
    if (title) |t| try w.print("# {s}\n", .{t}) else try w.print("# Session {s}\n", .{&proto.agent_ref.format(l.header.session)});
    try w.print("\nStarted in `{s}`", .{l.header.cwd});
    if (l.header.model.len > 0) try w.print(" with `{s}`", .{l.header.model});
    try w.writeAll(".\n");

    // Tool names by call id, for result headings.
    var names: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (lines) |x| {
        const m = x.record.message().?;
        if (x.record == .tool_results) {
            try w.writeAll("\n## Tool results\n");
        } else {
            try w.print("\n## {s}\n", .{if (m.role == .assistant) "Assistant" else "User"});
        }
        for (m.content) |b| switch (b) {
            .text => |t| try w.print("\n{s}\n", .{std.mem.trimEnd(u8, t.text, "\n")}),
            .thinking => |t| if (opts.include_thinking and !t.redacted) {
                try w.writeAll("\n<details><summary>Thinking</summary>\n\n");
                try w.print("{s}\n\n</details>\n", .{std.mem.trimEnd(u8, t.text, "\n")});
            },
            .tool_use => |t| {
                try names.put(a, t.id, t.name);
                try w.print("\n**Tool call:** `{s}`\n\n", .{t.name});
                try fenced(w, "json", t.input_json, std.math.maxInt(u32));
            },
            .tool_result => |t| {
                const name = names.get(t.tool_use_id) orelse t.tool_use_id;
                try w.print("\n**{s}:** `{s}`\n\n", .{ if (t.is_error) "Error from" else "Output of", name });
                var text: std.ArrayList(u8) = .empty;
                for (t.parts) |p| switch (p) {
                    .text => |s| try text.appendSlice(a, s),
                    .image => |img| try text.print(a, "[image {s}]\n", .{img.media_type}),
                    .document => |d| try text.print(a, "[document {s}]\n", .{d.media_type}),
                    .resource_link => |r| try text.print(a, "[resource {s}]\n", .{r.uri}),
                };
                try fenced(w, "", text.items, opts.max_output_bytes);
            },
            .image => |img| try w.print("\n[image {s}]\n", .{img.media_type}),
            .document => |d| try w.print("\n[document {s}]\n", .{d.title orelse d.media_type}),
            .provider_opaque => {},
        };
    }
}

/// A fenced block, cut to `max` bytes (at a UTF-8 boundary). The fence is
/// longer than any backtick run inside.
fn fenced(w: *Writer, lang: []const u8, body: []const u8, max: u32) !void {
    var cut = @min(body.len, max);
    while (cut > 0 and cut < body.len and body[cut] & 0xC0 == 0x80) cut -= 1;
    const shown = std.mem.trimEnd(u8, body[0..cut], "\n");
    var run: usize = 0;
    var longest: usize = 0;
    for (shown) |c| {
        run = if (c == '`') run + 1 else 0;
        longest = @max(longest, run);
    }
    const ticks = @max(3, longest + 1);
    try w.splatByteAll('`', ticks);
    try w.print("{s}\n{s}\n", .{ lang, shown });
    try w.splatByteAll('`', ticks);
    try w.writeByte('\n');
    if (cut < body.len) try w.print("\n_({d} more bytes not shown)_\n", .{body.len - cut});
}

/// Writes the active messages of `l` as a JSON array.
pub fn exportJson(gpa: Allocator, l: *const loader.LoadedSession, w: *Writer) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const lines = try records.activeMessages(arena.allocator(), l.tail);
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginArray();
    for (lines) |x| try proto.json.writeMessage(&s, x.record.message().?);
    try s.endArray();
    try w.writeByte('\n');
}
