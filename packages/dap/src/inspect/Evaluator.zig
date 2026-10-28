//! Expression evaluation (E07.F06.S04.T02) for every DAP context, and
//! REPL completions.
//!
//! Contexts follow the adapter's capabilities: `hover` needs
//! `supportsEvaluateForHovers` and falls back to `watch` (never to
//! `repl`, which can have side effects, unless `Options.hover_with_repl`,
//! the `debug.hoverEvaluateWithRepl` setting); `clipboard` needs
//! `supportsClipboardContext` and falls back to `variables`.
//!
//! A result with a `variablesReference` becomes an expandable root in the
//! variables model. Per the DAP overview such references live until the
//! next resume, and so do the roots: after it they answer `.stale`.
//!
//! `completions` sends the `completions` request (columns are 1-based, as
//! the client declares) and ranks the targets locally with the shared
//! fuzzy scorer against the word before the cursor. Callbacks run on the
//! UI thread from `Inspector.pump`. Part of an `Inspector`.

const Evaluator = @This();
const std = @import("std");
const zg_lsp = @import("zg_lsp");
const Inspector = @import("Inspector.zig");
const VariablesModel = @import("VariablesModel.zig");

const Allocator = std.mem.Allocator;
const fuzzy = zg_lsp.fuzzy;

pub const EvalContext = enum { watch, repl, hover, clipboard, variables };

pub const EvalResult = struct {
    value: []const u8,
    type: ?[]const u8 = null,
    /// The expandable tree root, when the result has children.
    node: ?VariablesModel.NodeId = null,
    memory_ref: ?[]const u8 = null,
    err: bool = false,
};

pub const EvalCb = struct {
    ctx: ?*anyopaque,
    /// Passed back to `func`.
    user: u64 = 0,
    /// `r` and its strings are valid during the call.
    func: *const fn (ctx: ?*anyopaque, user: u64, r: *const EvalResult) void,
};

pub const ComplItem = struct {
    label: []const u8,
    /// What to insert (the label when the adapter gives no text).
    text: []const u8,
    /// The 0-based offset in the input where the text replaces `length`
    /// characters; null: the word before the cursor.
    start: ?u32,
    length: u32,
    type: ?[]const u8,
    score: i32,
};

pub const ComplCb = struct {
    ctx: ?*anyopaque,
    /// Ranked best first; valid during the call. Empty when unsupported
    /// or failed.
    func: *const fn (ctx: ?*anyopaque, items: []const ComplItem) void,
};

const Pending = union(enum) {
    eval: struct { cb: EvalCb, expr: []u8, frame: ?i64 },
    compl: struct { cb: ComplCb, word: []u8 },

    fn deinit(p: Pending, gpa: Allocator) void {
        switch (p) {
            .eval => |e| gpa.free(e.expr),
            .compl => |c| gpa.free(c.word),
        }
    }
};

gpa: Allocator,
pending: std.AutoHashMapUnmanaged(u64, Pending) = .empty,
next_token: u64 = 1,
triggers: [32]u8 = undefined,
triggers_len: usize = 0,

pub fn init(gpa: Allocator) Evaluator {
    return .{ .gpa = gpa };
}

pub fn deinit(e: *Evaluator) void {
    e.failAll("the debug session ended");
    e.pending.deinit(e.gpa);
    e.* = undefined;
}

fn inspector(e: *Evaluator) *Inspector {
    return @alignCast(@fieldParentPtr("eval", e));
}

/// The context sent for `ctx` with this adapter.
pub fn contextName(e: *Evaluator, ctx: EvalContext) []const u8 {
    const insp = e.inspector();
    const caps = insp.ch.caps();
    return switch (ctx) {
        .watch => "watch",
        .repl => "repl",
        .variables => "variables",
        .hover => if (caps.supportsEvaluateForHovers orelse false) "hover" else if (insp.opts.hover_with_repl) "repl" else "watch",
        .clipboard => if (caps.supportsClipboardContext orelse false) "clipboard" else "variables",
    };
}

/// Evaluates `expr` in `frame` (null: the global scope). `cb` runs from
/// `pump`, or at once when the request cannot be sent.
pub fn evaluate(e: *Evaluator, expr: []const u8, ctx: EvalContext, frame: ?i64, cb: EvalCb) void {
    const insp = e.inspector();
    var aw: std.Io.Writer.Allocating = .init(e.gpa);
    defer aw.deinit();
    const Format = struct { hex: bool };
    std.json.Stringify.value(.{
        .expression = expr,
        .frameId = frame,
        .context = e.contextName(ctx),
        .format = if (insp.vars.hex) Format{ .hex = true } else null,
    }, .{ .emit_null_optional_fields = false }, &aw.writer) catch return fail(cb, "out of memory");
    const copy = e.gpa.dupe(u8, expr) catch return fail(cb, "out of memory");
    const token = e.next_token;
    e.next_token += 1;
    e.pending.put(e.gpa, token, .{ .eval = .{ .cb = cb, .expr = copy, .frame = frame } }) catch {
        e.gpa.free(copy);
        return fail(cb, "out of memory");
    };
    if (!insp.send("evaluate", aw.written(), .{ .kind = .evaluate, .a = token })) {
        if (e.pending.fetchRemove(token)) |kv| kv.value.deinit(e.gpa);
        fail(cb, "the debug session ended");
    }
}

fn fail(cb: EvalCb, message: []const u8) void {
    const r: EvalResult = .{ .value = message, .err = true };
    cb.func(cb.ctx, cb.user, &r);
}

/// Completions for `text` with the cursor at byte `cursor` (0-based).
pub fn completions(e: *Evaluator, text: []const u8, cursor: u32, frame: ?i64, cb: ComplCb) void {
    const insp = e.inspector();
    if (!(insp.ch.caps().supportsCompletionsRequest orelse false)) return cb.func(cb.ctx, &.{});
    const at = @min(cursor, text.len);
    var aw: std.Io.Writer.Allocating = .init(e.gpa);
    defer aw.deinit();
    std.json.Stringify.value(.{ .text = text, .column = at + 1, .frameId = frame }, .{ .emit_null_optional_fields = false }, &aw.writer) catch return cb.func(cb.ctx, &.{});
    const word = e.gpa.dupe(u8, wordBefore(text, at)) catch return cb.func(cb.ctx, &.{});
    const token = e.next_token;
    e.next_token += 1;
    e.pending.put(e.gpa, token, .{ .compl = .{ .cb = cb, .word = word } }) catch {
        e.gpa.free(word);
        return cb.func(cb.ctx, &.{});
    };
    if (!insp.send("completions", aw.written(), .{ .kind = .completions, .a = token })) {
        if (e.pending.fetchRemove(token)) |kv| kv.value.deinit(e.gpa);
        cb.func(cb.ctx, &.{});
    }
}

/// The identifier characters right before `at`.
fn wordBefore(text: []const u8, at: usize) []const u8 {
    var i = at;
    while (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_' or text[i - 1] == '$')) i -= 1;
    return text[i..at];
}

/// `completionTriggerCharacters`, one byte each (longer triggers are
/// left out).
pub fn triggerCharacters(e: *Evaluator) []const u8 {
    const caps = e.inspector().ch.caps();
    e.triggers_len = 0;
    for (caps.completionTriggerCharacters orelse &.{}) |t| {
        if (t.len != 1 or e.triggers_len == e.triggers.len) continue;
        e.triggers[e.triggers_len] = t[0];
        e.triggers_len += 1;
    }
    return e.triggers[0..e.triggers_len];
}

/// Answers every pending request with `message` (the session ended).
pub fn failAll(e: *Evaluator, message: []const u8) void {
    var it = e.pending.iterator();
    while (it.next()) |kv| {
        switch (kv.value_ptr.*) {
            .eval => |p| fail(p.cb, message),
            .compl => |p| p.cb.func(p.cb.ctx, &.{}),
        }
        kv.value_ptr.deinit(e.gpa);
    }
    e.pending.clearRetainingCapacity();
}

/// An `evaluate` or `completions` result. `live`: it belongs to the
/// current stop (its references may become tree roots).
pub fn apply(e: *Evaluator, token: u64, gen: u64, live: bool, ok: bool, body: []const u8) Allocator.Error!void {
    const kv = e.pending.fetchRemove(token) orelse return;
    defer kv.value.deinit(e.gpa);
    switch (kv.value) {
        .eval => |p| try e.applyEval(p.cb, p.expr, gen, live, ok, body),
        .compl => |p| try e.applyCompletions(p.cb, p.word, ok, body),
    }
}

fn applyEval(e: *Evaluator, cb: EvalCb, expr: []const u8, gen: u64, live: bool, ok: bool, body: []const u8) Allocator.Error!void {
    if (!ok) return fail(cb, body);
    const B = struct {
        result: []const u8 = "",
        type: ?[]const u8 = null,
        variablesReference: i64 = 0,
        namedVariables: ?i64 = null,
        indexedVariables: ?i64 = null,
        memoryReference: ?[]const u8 = null,
    };
    var arena: std.heap.ArenaAllocator = .init(e.gpa);
    defer arena.deinit();
    const b = std.json.parseFromSliceLeaky(B, arena.allocator(), body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(cb, "the debug adapter sent an invalid result"),
    };
    var r: EvalResult = .{ .value = b.result, .type = b.type, .memory_ref = b.memoryReference };
    if (live and b.variablesReference > 0) r.node = try e.inspector().vars.addEvalRoot(gen, .{
        .expr = expr,
        .value = b.result,
        .type = b.type,
        .ref = b.variablesReference,
        .named = b.namedVariables,
        .indexed = b.indexedVariables,
        .memory_ref = b.memoryReference,
    });
    cb.func(cb.ctx, cb.user, &r);
}

fn applyCompletions(e: *Evaluator, cb: ComplCb, word: []const u8, ok: bool, body: []const u8) Allocator.Error!void {
    if (!ok) return cb.func(cb.ctx, &.{});
    const B = struct {
        targets: []const struct {
            label: []const u8 = "",
            text: ?[]const u8 = null,
            sortText: ?[]const u8 = null,
            type: ?[]const u8 = null,
            start: ?i64 = null,
            length: ?i64 = null,
        } = &.{},
    };
    var arena: std.heap.ArenaAllocator = .init(e.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const b = std.json.parseFromSliceLeaky(B, a, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return cb.func(cb.ctx, &.{}),
    };
    const Ranked = struct { item: ComplItem, sort: []const u8 };
    var out: std.ArrayList(Ranked) = try .initCapacity(a, b.targets.len);
    const f: fuzzy.Fuzzy = .init(word);
    var scratch: fuzzy.Scratch = undefined;
    for (b.targets) |t| {
        const score = f.score(t.label, &scratch, null) orelse continue;
        out.appendAssumeCapacity(.{
            .item = .{
                .label = t.label,
                .text = t.text orelse t.label,
                // `start` is 0-based in the text (it is not a column).
                .start = if (t.start) |s| std.math.cast(u32, s) else null,
                .length = if (t.length) |l| std.math.cast(u32, l) orelse 0 else 0,
                .type = t.type,
                .score = score,
            },
            .sort = t.sortText orelse t.label,
        });
    }
    std.mem.sort(Ranked, out.items, {}, struct {
        fn lt(_: void, x: Ranked, y: Ranked) bool {
            if (x.item.score != y.item.score) return x.item.score > y.item.score;
            return std.mem.order(u8, x.sort, y.sort) == .lt;
        }
    }.lt);
    const items = try a.alloc(ComplItem, out.items.len);
    for (items, out.items) |*i, r| i.* = r.item;
    cb.func(cb.ctx, items);
}

test "word before the cursor" {
    try std.testing.expectEqualStrings("ba", wordBefore("foo.ba", 6));
    try std.testing.expectEqualStrings("", wordBefore("foo.", 4));
    try std.testing.expectEqualStrings("foo", wordBefore("foo.ba", 3));
}
