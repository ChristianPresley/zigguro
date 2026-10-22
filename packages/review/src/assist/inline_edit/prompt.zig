//! The inline edit prompt (E12.F06.S01.T01): a file excerpt with the
//! selection marked, the instruction, and in edit and insert modes the
//! `<rewrite>` output protocol. The system part (instructions and project
//! rules) is stable across edits, so providers can cache it.
//!
//! A follow-up shows the previous output as the selection and lists the
//! earlier instructions; its diff is still against the original region
//! (`StreamDiff`).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Mode = enum {
    /// Rewrite the selection.
    edit,
    /// Write text at an empty selection.
    insert,
    /// Answer a question about the selection in Markdown.
    question,
};

/// One earlier round of a follow-up chain.
pub const Turn = struct { instruction: []const u8, output: []const u8 };

pub const PromptInput = struct {
    path: []const u8,
    language: []const u8 = "",
    /// The excerpt before and after the selection (already cut to the
    /// context budget, secrets excluded).
    before: []const u8,
    selection: []const u8,
    after: []const u8,
    /// Diagnostics intersecting the selection, one line each.
    diagnostics: []const []const u8 = &.{},
    /// Project rules (the "inline" context profile).
    rules: []const u8 = "",
    history: []const Turn = &.{},
    instruction: []const u8,
    mode: Mode = .edit,
};

pub const PromptParts = struct {
    /// Instructions and rules: the cacheable part.
    system: []const u8,
    user: []const u8,
    /// The current selection, for providers with predicted outputs (edit
    /// mode only; the caller drops it when the provider lacks them).
    prediction: ?[]const u8,
};

const edit_system =
    \\Rewrite ONLY the code between <selection> markers according to the instruction. Output the complete rewritten selection inside <rewrite></rewrite>. Preserve indentation style. Output nothing else.
;
const insert_system =
    \\Write the code to insert at the <insert-here/> marker according to the instruction. Output only the inserted code inside <rewrite></rewrite>. Match the surrounding indentation style. Output nothing else.
;
const question_system =
    \\Answer the question about the code between <selection> markers. Answer in Markdown. Do not rewrite the code.
;

/// Builds the prompt for `in` (in `arena`).
pub fn buildPrompt(arena: Allocator, in: PromptInput) Allocator.Error!PromptParts {
    const head = switch (in.mode) {
        .edit => edit_system,
        .insert => insert_system,
        .question => question_system,
    };
    const system = if (in.rules.len > 0)
        try std.fmt.allocPrint(arena, "{s}\n\nProject rules:\n{s}", .{ head, std.mem.trimEnd(u8, in.rules, "\n") })
    else
        head;

    // A follow-up rewrites the last output.
    const current = if (in.history.len > 0) in.history[in.history.len - 1].output else in.selection;
    var w: std.Io.Writer.Allocating = .init(arena);
    const o = &w.writer;
    o.print("File: {s}", .{in.path}) catch return error.OutOfMemory;
    if (in.language.len > 0) o.print(" ({s})", .{in.language}) catch return error.OutOfMemory;
    o.writeAll("\n\n```\n") catch return error.OutOfMemory;
    o.writeAll(in.before) catch return error.OutOfMemory;
    switch (in.mode) {
        .insert => o.writeAll("<insert-here/>") catch return error.OutOfMemory,
        .edit, .question => o.print("<selection>{s}</selection>", .{current}) catch return error.OutOfMemory,
    }
    o.writeAll(in.after) catch return error.OutOfMemory;
    if (!std.mem.endsWith(u8, in.after, "\n")) o.writeByte('\n') catch return error.OutOfMemory;
    o.writeAll("```\n") catch return error.OutOfMemory;
    if (in.diagnostics.len > 0) {
        o.writeAll("\nDiagnostics in the selection:\n") catch return error.OutOfMemory;
        for (in.diagnostics) |d| o.print("- {s}\n", .{d}) catch return error.OutOfMemory;
    }
    if (in.history.len > 0) {
        o.writeAll("\nEarlier instructions (the selection shows the result of the last one):\n") catch return error.OutOfMemory;
        for (in.history, 1..) |t, i| o.print("{d}. {s}\n", .{ i, t.instruction }) catch return error.OutOfMemory;
    }
    o.print("\n{s}: {s}\n", .{ if (in.mode == .question) "Question" else "Instruction", in.instruction }) catch return error.OutOfMemory;
    return .{
        .system = system,
        .user = w.written(),
        .prediction = if (in.mode == .edit) current else null,
    };
}

const testing = std.testing;

test "inline: prompt golden for edit/insert/question modes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base: PromptInput = .{
        .path = "src/main.zig",
        .language = "zig",
        .before = "fn main() void {\n",
        .selection = "    var x = 1;\n",
        .after = "}\n",
        .instruction = "make x const",
    };
    const edit = try buildPrompt(a, base);
    try testing.expectEqualStrings(edit_system, edit.system);
    try testing.expectEqualStrings(
        \\File: src/main.zig (zig)
        \\
        \\```
        \\fn main() void {
        \\<selection>    var x = 1;
        \\</selection>}
        \\```
        \\
        \\Instruction: make x const
        \\
    , edit.user);
    try testing.expectEqualStrings("    var x = 1;\n", edit.prediction.?);

    var ins = base;
    ins.mode = .insert;
    ins.selection = "";
    ins.rules = "Use 4 spaces.\n";
    ins.instruction = "log x";
    const ip = try buildPrompt(a, ins);
    try testing.expectEqualStrings(insert_system ++ "\n\nProject rules:\nUse 4 spaces.", ip.system);
    try testing.expect(std.mem.indexOf(u8, ip.user, "fn main() void {\n<insert-here/>}\n") != null);
    try testing.expect(ip.prediction == null);

    var q = base;
    q.mode = .question;
    q.instruction = "why var?";
    q.diagnostics = &.{"3:9 local variable is never mutated"};
    const qp = try buildPrompt(a, q);
    try testing.expectEqualStrings(question_system, qp.system);
    try testing.expect(std.mem.indexOf(u8, qp.user, "Diagnostics in the selection:\n- 3:9 local variable is never mutated\n") != null);
    try testing.expect(std.mem.endsWith(u8, qp.user, "\nQuestion: why var?\n"));
    try testing.expect(qp.prediction == null);
}

test "inline: follow-up rewrites the last output and lists earlier instructions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const p = try buildPrompt(arena_state.allocator(), .{
        .path = "a.py",
        .before = "",
        .selection = "x = 1\n",
        .after = "",
        .history = &.{.{ .instruction = "rename x to count", .output = "count = 1\n" }},
        .instruction = "add a type hint",
    });
    try testing.expect(std.mem.indexOf(u8, p.user, "<selection>count = 1\n</selection>") != null);
    try testing.expect(std.mem.indexOf(u8, p.user, "1. rename x to count\n") != null);
    try testing.expectEqualStrings("count = 1\n", p.prediction.?);
}
