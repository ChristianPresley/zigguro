//! Automatic session titles (E10.F08.S01.T02). After the first user
//! prompt a small request to the `title` role model produces a title of
//! at most 60 characters, off the agent's thread. No title is generated
//! when the user named the session or for `-p` CLI runs; an accepted plan
//! (F09.S02) replaces the title through `SessionIndex.setTitle`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Provider = @import("../provider/Provider.zig");
const request = @import("../provider/request.zig");
const index = @import("index.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// Longest title, in Unicode scalar values.
pub const max_chars = 60;
/// Output limit of the title request.
pub const max_output_tokens = 30;
/// The instruction sent with the prompt.
pub const instruction = "Write a short title (at most eight words) for a coding session that starts with the request below. Reply with the title only, without quotes or punctuation at the end.";

/// Why a session may not get an automatic title.
pub const Policy = struct {
    /// The user named the session (`--name`, rename).
    named: bool = false,
    /// A `-p` (print) CLI run.
    print_mode: bool = false,
    /// A title exists already.
    has_title: bool = false,
};

/// Whether to request a title.
pub fn shouldGenerate(p: Policy) bool {
    return !p.named and !p.print_mode and !p.has_title;
}

/// Asks `provider` for a title of `prompt`; the result is cleaned with
/// `clean`. Null when the model returned nothing usable.
pub fn generate(provider: Provider, model: []const u8, io: Io, arena: Allocator, prompt: []const u8) !?[]const u8 {
    const body = try std.fmt.allocPrint(arena, "{s}\n\n<request>\n{s}\n</request>", .{ instruction, prompt[0..@min(prompt.len, 4000)] });
    const blocks = try arena.alloc(proto.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = body } };
    const msgs = try arena.alloc(proto.Message, 1);
    msgs[0] = .{ .role = .user, .content = blocks };
    const req: request.Request = .{ .model = model, .messages = msgs, .tool_choice = .none, .max_output_tokens = max_output_tokens };
    const resp = try provider.stream(io, arena, &req, .discard);
    const t = clean(try resp.message.text(arena));
    return if (t.len == 0) null else t;
}

/// The first non-empty line of `raw`, without surrounding quotes, a
/// "Title:" prefix or trailing punctuation, cut to `max_chars` at a word
/// boundary when possible. Returns a slice of `raw`.
pub fn clean(raw: []const u8) []const u8 {
    var lines = std.mem.tokenizeAny(u8, raw, "\r\n");
    var t = std.mem.trim(u8, lines.next() orelse return "", " \t");
    for ([_][]const u8{ "Title:", "title:", "TITLE:" }) |p| {
        if (std.mem.startsWith(u8, t, p)) t = std.mem.trim(u8, t[p.len..], " \t");
    }
    t = std.mem.trim(u8, t, " \t\"'`*#");
    t = std.mem.trimEnd(u8, t, " .!:;,");
    // Cut to max_chars scalar values.
    var n: usize = 0;
    var i: usize = 0;
    while (i < t.len and n < max_chars) : (n += 1) {
        i += std.unicode.utf8ByteSequenceLength(t[i]) catch 1;
    }
    if (i >= t.len) return t;
    // Prefer the last space in the kept part.
    if (std.mem.lastIndexOfScalar(u8, t[0..i], ' ')) |sp| if (sp > i / 2) return std.mem.trimEnd(u8, t[0..sp], " ,.;:");
    return t[0..@min(i, t.len)];
}

/// Receives each generated title (to append a `title` record).
pub const OnTitle = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, io: Io, id: proto.SessionId, title: []const u8) void,
};

/// Generates titles in the background and stores them in the index.
pub const Titler = struct {
    gpa: Allocator,
    provider: Provider,
    /// The `title` role model.
    model: []const u8,
    ix: *index.SessionIndex,
    on_title: ?OnTitle = null,
    group: Io.Group = .init,
    /// Titles requested so far.
    started: std.atomic.Value(u32) = .init(0),

    /// Starts a title request for `id` when `policy` allows; returns
    /// whether it did. `prompt` is copied.
    pub fn maybeStart(t: *Titler, io: Io, id: proto.SessionId, prompt: []const u8, policy: Policy) Allocator.Error!bool {
        if (!shouldGenerate(policy)) return false;
        const owned = try t.gpa.dupe(u8, prompt);
        _ = t.started.fetchAdd(1, .monotonic);
        t.group.async(io, run, .{ t, io, id, owned });
        return true;
    }

    /// Waits for running requests.
    pub fn wait(t: *Titler, io: Io) void {
        t.group.await(io) catch {};
    }

    /// Cancels running requests.
    pub fn cancel(t: *Titler, io: Io) void {
        t.group.cancel(io);
    }

    fn run(t: *Titler, io: Io, id: proto.SessionId, prompt: []u8) void {
        defer t.gpa.free(prompt);
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        const title = (generate(t.provider, t.model, io, arena.allocator(), prompt) catch return) orelse return;
        // A name set while the request ran wins.
        const stored = t.ix.setTitle(id, title) catch return;
        if (stored) if (t.on_title) |cb| cb.call(cb.ctx, io, id, title);
    }
};

test "clean titles" {
    const T = std.testing;
    try T.expectEqualStrings("Fix the auth refresh bug", clean("\"Fix the auth refresh bug.\"\nextra"));
    try T.expectEqualStrings("Add tests", clean("Title: Add tests"));
    try T.expectEqualStrings("", clean("\n\n"));
    const long = clean("Refactor the session index so that listing five thousand sessions stays well under ten milliseconds");
    try T.expect(try std.unicode.utf8CountCodepoints(long) <= max_chars);
    try T.expect(!std.mem.endsWith(u8, long, " "));
    try T.expect(shouldGenerate(.{}));
    try T.expect(!shouldGenerate(.{ .named = true }));
    try T.expect(!shouldGenerate(.{ .print_mode = true }));
}
