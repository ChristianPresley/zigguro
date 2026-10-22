//! Syntax colours for Markdown code blocks: implements zg_gui.markdown's
//! `Highlighter` seam with zg_syntax. A fence's info word is looked up by
//! language name or alias, its code is lexed line by line (injections
//! included), and each highlight maps to the view's coarser `SyntaxClass`.

const std = @import("std");
const zg_syntax = @import("zg_syntax");
const zg_gui = @import("zg_gui");

const Allocator = std.mem.Allocator;
const HighlightId = zg_syntax.HighlightId;
const code_view = zg_gui.markdown.code_view;
const Span = code_view.Span;
const SyntaxClass = code_view.SyntaxClass;

/// Highlights code blocks for a Markdown view. Not thread-safe: one per
/// UI thread.
pub const MarkdownHighlighter = struct {
    reg: zg_syntax.Registry,
    sink: zg_syntax.TokenSink = .{},

    /// With every built-in language.
    pub fn init(gpa: Allocator) Allocator.Error!MarkdownHighlighter {
        return .{ .reg = try zg_syntax.defaultRegistry(gpa) };
    }

    /// Frees the registry and token buffer.
    pub fn deinit(m: *MarkdownHighlighter, gpa: Allocator) void {
        m.sink.deinit(gpa);
        m.reg.deinit(gpa);
    }

    /// The seam value for `MdViewProps.highlighter`.
    pub fn highlighter(m: *MarkdownHighlighter) code_view.Highlighter {
        return .{ .ptr = m, .highlight = highlightFn };
    }

    fn highlightFn(ptr: *anyopaque, gpa: Allocator, lang: []const u8, code: []const u8, out: *std.ArrayList(Span)) Allocator.Error!void {
        const m: *MarkdownHighlighter = @ptrCast(@alignCast(ptr));
        return m.highlight(gpa, lang, code, out);
    }

    /// Appends sorted, non-overlapping spans for `code` in `lang` to
    /// `out`; nothing when the language is unknown. Adjacent spans of
    /// one class are merged and plain text gets no span.
    pub fn highlight(m: *MarkdownHighlighter, gpa: Allocator, lang: []const u8, code: []const u8, out: *std.ArrayList(Span)) Allocator.Error!void {
        const id = m.reg.byName(lang) orelse return;
        var st: zg_syntax.LexState = .init(id);
        var off: u32 = 0;
        var it = std.mem.splitScalar(u8, code, '\n');
        while (it.next()) |raw| {
            const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
            try m.sink.begin(gpa, line.len);
            zg_syntax.lex.lexer.lexLine(&m.reg, &st, line, &m.sink);
            const toks = m.sink.tokens();
            for (toks, 0..) |t, k| {
                const end: u32 = if (k + 1 < toks.len) toks[k + 1].start else @intCast(line.len);
                const class = classOf(t.hl);
                if (class == .plain or end <= t.start) continue;
                const s = off + t.start;
                const e = off + end;
                if (out.items.len > 0) {
                    const last = &out.items[out.items.len - 1];
                    if (last.class == class and last.end == s) {
                        last.end = e;
                        continue;
                    }
                }
                try out.append(gpa, .{ .start = s, .end = e, .class = class });
            }
            off += @intCast(raw.len + 1);
        }
    }
};

/// The view class of a highlight: by the highlight itself, then by its
/// dotted ancestors (`keyword.control` -> `keyword`).
pub fn classOf(hl: HighlightId) SyntaxClass {
    var id = hl;
    while (true) {
        if (direct(id)) |c| return c;
        id = id.parent() orelse return .plain;
    }
}

fn direct(id: HighlightId) ?SyntaxClass {
    return switch (id) {
        .comment => .comment,
        .string, .character, .markup_code => .string,
        .number => .number,
        .constant, .variable_builtin, .label => .constant,
        .keyword, .tag, .markup_heading_1, .markup_heading_2, .markup_heading_3, .markup_heading_4, .markup_heading_5, .markup_heading_6 => .keyword,
        .type, .attribute => .type,
        .function, .markup_link => .function,
        .operator => .operator,
        .punctuation => .punctuation,
        .none, .variable, .property, .markup_bold, .markup_italic, .invalid => .plain,
        else => null,
    };
}
