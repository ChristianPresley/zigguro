//! The chat fallback: completions from a chat model with no FIM support
//! (Claude, GPT and the like through E10). The prompt marks the cursor with
//! `<CURSOR>` and asks for only the code that goes there, at temperature 0.
//! zg_review does not import zg_ai, so the model is reached through a
//! `ChatPort` the app binds to `zg_ai.Provider.stream`, passing text deltas
//! only. Latency is higher than a FIM model's; mid-line requests are fine
//! (`server_side_template`). A reply wrapped in a Markdown fence is
//! unwrapped.

const std = @import("std");
const context = @import("context.zig");
const providers = @import("providers.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const CompletionRequest = context.CompletionRequest;

pub const cursor = "<CURSOR>";

pub const system_prompt =
    "You are a code completion engine. Output only the code that replaces " ++ cursor ++
    " in the user's file: no explanations, no Markdown fences, and none of the " ++
    "code before or after the cursor. Output nothing if nothing fits.";

pub const ChatRequest = struct {
    model: []const u8,
    system: []const u8,
    user: []const u8,
    max_tokens: u32,
    stop: []const []const u8,
    temperature: f32 = 0,
};

/// A chat model, bound by the app (E10 `Provider.stream`, text deltas only).
pub const ChatPort = struct {
    ctx: *anyopaque,
    stream: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, req: *const ChatRequest, sink: providers.Sink) anyerror!void,
};

pub const ChatFallbackOptions = struct {
    port: ChatPort,
    model: []const u8,
};

/// The user message: the snippets, then the file with the cursor marked.
pub fn userMessage(arena: Allocator, req: *const CompletionRequest) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (req.extras) |s| {
        try out.print(arena, "Related file {s}:\n{s}", .{ s.path, s.text });
        if (!std.mem.endsWith(u8, s.text, "\n")) try out.append(arena, '\n');
        try out.append(arena, '\n');
    }
    try out.print(arena, "File {s} ({s}). {s}\n\n{s}{s}{s}", .{
        req.path,
        req.language,
        if (req.multiline) "Complete the block at the cursor." else "Complete the line at the cursor.",
        req.prefix,
        cursor,
        req.suffix,
    });
    return out.items;
}

pub const ChatFim = struct {
    opts: ChatFallbackOptions,

    pub fn provider(c: *ChatFim) providers.FimProvider {
        return .{ .ctx = c, .vtable = &vtable, .caps = .{ .server_side_template = true } };
    }

    const vtable: providers.FimProvider.VTable = .{ .complete = completeFn };

    fn completeFn(ctx: *anyopaque, io: Io, arena: Allocator, req: *const CompletionRequest, sink: providers.Sink) anyerror!void {
        const c: *ChatFim = @ptrCast(@alignCast(ctx));
        const chat: ChatRequest = .{
            .model = c.opts.model,
            .system = system_prompt,
            .user = try userMessage(arena, req),
            .max_tokens = req.max_tokens,
            .stop = req.stop,
        };
        var fence: FenceFilter = .{ .out = sink };
        try c.opts.port.stream(c.opts.port.ctx, io, arena, &chat, fence.sink());
        try fence.finish();
    }
};

/// Drops a leading Markdown fence line (```zig) and the closing fence.
pub const FenceFilter = struct {
    out: providers.Sink,
    state: enum { start, fenced, plain } = .start,
    head: [32]u8 = undefined,
    head_len: u8 = 0,
    filter: providers.TokenFilter = .{ .tokens = &.{"\n```"} },

    pub fn sink(f: *FenceFilter) providers.Sink {
        return .{ .ctx = f, .text = textFn };
    }

    fn textFn(ctx: ?*anyopaque, bytes: []const u8) anyerror!void {
        const f: *FenceFilter = @ptrCast(@alignCast(ctx.?));
        var rest = bytes;
        while (f.state == .start and rest.len > 0) {
            const c = rest[0];
            const n = f.head_len;
            if (n < 3 and c != '`') {
                // Not a fence: show what was held.
                f.state = .plain;
                try f.out.text(f.out.ctx, f.head[0..n]);
                break;
            }
            rest = rest[1..];
            if (c == '\n') {
                f.state = .fenced;
                break;
            }
            if (n == f.head.len) {
                f.state = .plain;
                try f.out.text(f.out.ctx, f.head[0..n]);
                try f.out.text(f.out.ctx, &.{c});
                break;
            }
            f.head[n] = c;
            f.head_len += 1;
        }
        switch (f.state) {
            .start => {},
            .plain => if (rest.len > 0) try f.out.text(f.out.ctx, rest),
            .fenced => try f.filter.feed(rest, f.out),
        }
    }

    pub fn finish(f: *FenceFilter) !void {
        switch (f.state) {
            .start => if (f.head_len > 0 and f.head_len < 3) try f.out.text(f.out.ctx, f.head[0..f.head_len]),
            .plain => {},
            .fenced => try f.filter.finish(f.out),
        }
    }
};
