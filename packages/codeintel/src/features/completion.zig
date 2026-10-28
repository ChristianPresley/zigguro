//! The completion engine (E07.F03.S01.T02), headless: when to trigger,
//! asking every server routed for completion, merging their lists,
//! filtering and ranking as the user types, resolving the selected item
//! and accepting one.
//!
//! - `shouldTrigger`: a server's trigger character triggers at once; an
//!   identifier character triggers when quick suggestions are on for the
//!   token class (code on, comments and strings off by default);
//!   Ctrl+Space is `invoked`.
//! - `start` asks with the trigger as `context` and keeps a snapshot of
//!   the document: the servers' positions are converted against the
//!   version they were computed for and mapped forward when accepted, so
//!   an edit never lands at stale offsets.
//! - `update`, after every edit or caret move: the pattern is the text
//!   from the word start to the caret. A caret before the start, or a
//!   non-word character in between, closes; an incomplete list asks
//!   again (`TriggerForIncompleteCompletions`) and keeps showing the old
//!   one until the new answer comes; otherwise the list is refiltered.
//! - `select` starts the resolve timer (50 ms); `tick` sends
//!   `completionItem/resolve` for the selected item (canceling the one
//!   before) and merges only `documentation`, `detail`,
//!   `additionalTextEdits` and `command`.
//! - `accept` writes the main edit (insert or replace range) at every
//!   caret whose prefix matches and the additional edits once, as one
//!   undo step; snippets start a snippet session; the item's command
//!   runs with `workspace/executeCommand`; a commit character is typed
//!   after.

const CompletionService = @This();
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const position = @import("position.zig");
const requester = @import("request.zig");
const rank = @import("completion_rank.zig");
const Snippet = @import("../snippet/Snippet.zig");
const SnippetSession = @import("../snippet/Session.zig");

const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Document = zg_editor.model.document.Document;
const Snapshot = zg_editor.model.snapshot.Snapshot;
const EditorView = zg_editor.view.EditorView;
const ByteRange = zg_editor.model.buffer.piece_tree.Range;
const Replace = zg_editor.model.edit.change_set.Replace;
const Selection = zg_editor.model.edit.selection.Selection;
const Req = requester.Requester(.@"textDocument/completion", .completion);
const Resolve = Client.Result(.@"completionItem/resolve");

const log = std.log.scoped(.completion);

pub const Item = rank.Item;
/// A `textDocument/completion` result.
pub const Result = protocol.TextDocumentCompletionResult;
pub const Ranked = rank.Ranked;

pub const Trigger = union(enum) { invoked, character: u21, incomplete_requery };

/// The kind of text the caret is in (from the syntax highlighter).
pub const TokenClass = enum { code, comment, string };

pub const Options = struct {
    /// Quick suggestions (identifier characters) per token class.
    quick_code: bool = true,
    quick_comments: bool = false,
    quick_strings: bool = false,
    resolve_delay: Io.Duration = .fromMilliseconds(50),
};

/// What `update` did.
pub const Action = enum { none, refilter, requery, close };

pub const AcceptMode = enum { insert, replace };

/// Longest word prefix filtered on.
const max_prefix = 256;

const Server = struct {
    client: *Client,
    enc: position.Encoding,
    resolve: bool,
};

pub const Session = struct {
    h: DocHandle,
    trigger: Trigger,
    /// The document as asked about; item positions refer to it.
    snap: Snapshot,
    /// Caret and word start at the request, in `snap`.
    at: u64,
    req_start: u64,
    /// Word start and caret now.
    start: u64,
    start_version: u64,
    cursor: u64,
    pattern: std.ArrayList(u8) = .empty,
    servers: [requester.max_servers]?Server = @splat(null),
    answers: std.ArrayList(*Req.Answer) = .empty,
    items: std.ArrayList(Item) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    ranker: rank.Ranker,
    incomplete: bool = false,
    /// A re-query in flight: its first answer replaces the items.
    next: ?struct { snap: Snapshot, at: u64, req_start: u64 } = null,
    /// Bumped when `items` are replaced (resolve answers to older items
    /// are dropped).
    items_gen: u64 = 0,
    /// Index into `items()` of the selected item.
    selected: ?u32 = null,
    resolve_due_ns: ?i96 = null,
    resolve_inflight: ?struct { client: *Client, handle: Client.ReqHandle } = null,
    resolved: std.ArrayList(Resolve) = .empty,

    /// The filtered items, best first.
    pub fn list(s: *const Session) []const Ranked {
        return s.ranker.ranked.items;
    }

    pub fn item(s: *const Session, pos: u32) *const Item {
        return &s.items.items[s.ranker.ranked.items[pos].item];
    }
};

const ResolveReq = struct {
    svc: *CompletionService,
    items_gen: u64,
    item: u32,
    result: Resolve = undefined,
};

gpa: Allocator,
io: Io,
mgr: *Manager,
req: Req,
waker: zg_core.runtime.Waker,
opts: Options,
recency: rank.Recency = .{},
session: ?*Session = null,
inbox_mutex: Io.Mutex = .init,
inbox: std.ArrayList(*ResolveReq) = .empty,
inbox_taken: std.ArrayList(*ResolveReq) = .empty,
outstanding: std.atomic.Value(usize) = .init(0),
/// Bumped when the list, the selection or a resolved item changes.
generation: u64 = 0,
/// Resolve requests sent (tests).
resolves_sent: u32 = 0,

pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker, opts: Options) CompletionService {
    return .{ .gpa = mgr.gpa, .io = mgr.rt.io, .mgr = mgr, .req = .init(mgr, waker), .waker = waker, .opts = opts };
}

/// Call after `Manager.deinit`.
pub fn deinit(s: *CompletionService) void {
    s.close();
    s.req.deinit();
    for (s.takeResolved()) |r| s.dropResolve(r);
    s.inbox.deinit(s.gpa);
    s.inbox_taken.deinit(s.gpa);
    std.debug.assert(s.outstanding.load(.acquire) == 0);
    s.recency.deinit(s.gpa);
}

/// Whether typing `typed` at `offset` of `h` (in text of class `class`)
/// should start completion.
pub fn shouldTrigger(s: *CompletionService, h: DocHandle, typed: u21, class: TokenClass) ?Trigger {
    var cs: [requester.max_servers]*Client = undefined;
    const n = s.mgr.clientsFor(h, .completion, &cs);
    if (n == 0) return null;
    for (cs[0..n]) |c| {
        const caps = c.caps() orelse continue;
        if (std.mem.indexOfScalar(u21, caps.completion_triggers, typed) != null) return .{ .character = typed };
    }
    if (!rank.isWordChar(typed)) return null;
    const on = switch (class) {
        .code => s.opts.quick_code,
        .comment => s.opts.quick_comments,
        .string => s.opts.quick_strings,
    };
    return if (on) .invoked else null;
}

/// The start of the word that ends at `offset`.
pub fn wordStart(doc: *const Document, offset: u64) u64 {
    var buf: [max_prefix]u8 = undefined;
    const lo = offset -| max_prefix;
    const n = copyInto(doc, .{ .start = lo, .end = offset }, &buf);
    var i = n;
    while (i > 0 and rank.isWordByte(buf[i - 1])) i -= 1;
    return lo + i;
}

fn copyInto(doc: *const Document, r: ByteRange, buf: []u8) usize {
    var n: usize = 0;
    var it = doc.tree.slice(r);
    while (it.next()) |chunk| {
        const k = @min(chunk.len, buf.len - n);
        @memcpy(buf[n..][0..k], chunk[0..k]);
        n += k;
        if (n == buf.len) break;
    }
    return n;
}

/// Asks for completions at `cursor` of `h`; false when no server
/// provides them. Ends any session.
pub fn start(s: *CompletionService, h: DocHandle, cursor: u64, trig: Trigger) !bool {
    s.close();
    const doc = s.mgr.docs.get(h) orelse return false;
    const at = @min(cursor, doc.len());
    const ws = wordStart(doc, at);
    var tc: [4]u8 = undefined;
    const n = try s.ask(h, at, trig, &tc);
    if (n == 0) return false;
    const ses = try s.gpa.create(Session);
    errdefer s.gpa.destroy(ses);
    ses.* = .{
        .h = h,
        .trigger = trig,
        .snap = doc.snapshot(),
        .at = at,
        .req_start = ws,
        .start = ws,
        .start_version = doc.version,
        .cursor = at,
        .ranker = try .init(s.gpa),
    };
    s.session = ses;
    try s.readPattern(ses, doc);
    s.generation += 1;
    return true;
}

fn ask(s: *CompletionService, h: DocHandle, at: u64, trig: Trigger, tc: *[4]u8) !u8 {
    const ctx: protocol.CompletionContext = switch (trig) {
        .invoked => .{ .triggerKind = .Invoked },
        .incomplete_requery => .{ .triggerKind = .TriggerForIncompleteCompletions },
        .character => |c| .{ .triggerKind = .TriggerCharacter, .triggerCharacter = tc[0..(std.unicode.utf8Encode(c, tc) catch 0)] },
    };
    return s.req.ask(h, at, .{ .context = ctx });
}

/// The current session, if any.
pub fn active(s: *const CompletionService) ?*const Session {
    return s.session;
}

/// Ends the session (Escape, focus lost, accepted).
pub fn close(s: *CompletionService) void {
    const ses = s.session orelse return;
    s.req.cancel();
    if (ses.resolve_inflight) |r| r.client.cancel(r.handle);
    s.freeItems(ses);
    if (ses.next) |*n| n.snap.release();
    ses.snap.release();
    ses.answers.deinit(s.gpa);
    ses.items.deinit(s.gpa);
    ses.seen.deinit(s.gpa);
    ses.resolved.deinit(s.gpa);
    ses.pattern.deinit(s.gpa);
    ses.ranker.deinit();
    s.gpa.destroy(ses);
    s.session = null;
    s.generation += 1;
}

fn freeItems(s: *CompletionService, ses: *Session) void {
    for (ses.answers.items) |a| s.req.free(a);
    ses.answers.clearRetainingCapacity();
    for (ses.resolved.items) |r| r.deinit();
    ses.resolved.clearRetainingCapacity();
    ses.items.clearRetainingCapacity();
    ses.seen.clearRetainingCapacity();
    ses.ranker.reset();
    ses.selected = null;
    ses.resolve_due_ns = null;
    ses.items_gen += 1;
}

fn readPattern(s: *CompletionService, ses: *Session, doc: *const Document) !void {
    var buf: [max_prefix]u8 = undefined;
    const n = copyInto(doc, .{ .start = ses.start, .end = ses.cursor }, &buf);
    ses.pattern.clearRetainingCapacity();
    try ses.pattern.appendSlice(s.gpa, buf[0..n]);
}

/// After an edit or a caret move in `h` (caret at `cursor`): follows
/// the session.
pub fn update(s: *CompletionService, h: DocHandle, cursor: u64) !Action {
    const ses = s.session orelse return .none;
    if (!std.meta.eql(ses.h, h)) return s.closed();
    const doc = s.mgr.docs.get(h) orelse return s.closed();
    const st = doc.mapForward(ses.start_version, .{ .start = ses.start, .end = ses.start }, .left) orelse return s.closed();
    ses.start = st.start;
    ses.start_version = doc.version;
    if (cursor < ses.start or cursor - ses.start > max_prefix or cursor > doc.len()) return s.closed();
    var buf: [max_prefix]u8 = undefined;
    const n = copyInto(doc, .{ .start = ses.start, .end = cursor }, &buf);
    for (buf[0..n]) |c| if (!rank.isWordByte(c)) return s.closed();
    ses.cursor = cursor;
    if (ses.ranker.valid and std.mem.eql(u8, buf[0..n], ses.pattern.items)) return .none;
    ses.pattern.clearRetainingCapacity();
    try ses.pattern.appendSlice(s.gpa, buf[0..n]);
    var action: Action = .refilter;
    if (ses.incomplete) {
        var tc: [4]u8 = undefined;
        if (try s.ask(h, cursor, .incomplete_requery, &tc) > 0) {
            if (ses.next) |*nx| nx.snap.release();
            ses.next = .{ .snap = doc.snapshot(), .at = cursor, .req_start = ses.start };
            action = .requery;
        }
    }
    try s.refilter(ses);
    return action;
}

fn closed(s: *CompletionService) Action {
    s.close();
    return .close;
}

fn refilter(s: *CompletionService, ses: *Session) !void {
    const lang = if (s.mgr.docMatch(ses.h)) |m| m.language_id else "";
    const prev = if (ses.selected) |p| if (p < ses.ranker.ranked.items.len) ses.ranker.ranked.items[p].item else null else null;
    try ses.ranker.refilter(ses.items.items, ses.pattern.items, s.recency.view(lang));
    // The selection stays on its item while it is listed, else the top.
    ses.selected = null;
    if (prev) |it| for (ses.ranker.ranked.items, 0..) |r, i| {
        if (r.item == it) ses.selected = @intCast(i);
    };
    if (ses.selected == null and ses.ranker.ranked.items.len > 0) s.selectIn(ses, 0);
    s.generation += 1;
}

/// Selects item `pos` of the list; it is resolved once it rests there.
pub fn select(s: *CompletionService, pos: u32) void {
    const ses = s.session orelse return;
    if (pos >= ses.ranker.ranked.items.len) return;
    if (ses.selected == pos) return;
    s.selectIn(ses, pos);
    s.generation += 1;
}

fn selectIn(s: *CompletionService, ses: *Session, pos: u32) void {
    ses.selected = pos;
    const it = ses.item(pos);
    const srv = ses.servers[it.server];
    ses.resolve_due_ns = if (!it.resolved and srv != null and srv.?.resolve) now(s.io) + s.opts.resolve_delay.nanoseconds else null;
}

fn now(io: Io) i96 {
    return Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

/// When the next resolve is due (`.awake` ns), if one waits.
pub fn nextDue(s: *const CompletionService) ?i96 {
    const ses = s.session orelse return null;
    return ses.resolve_due_ns;
}

/// Applies answers and sends a due resolve; true when the list or an
/// item changed.
pub fn tick(s: *CompletionService) bool {
    const g = s.generation;
    const ses = s.session orelse {
        for (s.req.take()) |_| {}
        for (s.takeResolved()) |r| s.dropResolve(r);
        return false;
    };
    if (ses.resolve_due_ns) |due| if (now(s.io) >= due) {
        ses.resolve_due_ns = null;
        s.sendResolve(ses) catch |e| log.debug("completion resolve not sent: {t}", .{e});
    };
    var added = false;
    for (s.req.take()) |a| {
        const value = switch (a.result) {
            .ok => |o| o.value,
            else => continue,
        };
        if (ses.next) |nx| {
            // The re-query's first answer replaces the old list.
            s.freeItems(ses);
            ses.snap.release();
            ses.snap = nx.snap;
            ses.at = nx.at;
            ses.req_start = nx.req_start;
            ses.incomplete = false;
            ses.next = null;
        }
        s.req.retain(a);
        ses.answers.append(s.gpa, a) catch {
            a.kept = false;
            continue;
        };
        const c = a.client;
        const caps = c.caps();
        const all_commit: []const []const u8 = if (caps) |cp| (if (cp.raw.completionProvider) |p| p.allCommitCharacters orelse &.{} else &.{}) else &.{};
        ses.servers[a.index] = .{
            .client = c,
            .enc = position.encodingOf(c.encoding()),
            .resolve = if (caps) |cp| cp.supports(.completion_resolve, s.mgr.docMatch(ses.h)) else false,
        };
        const before = ses.items.items.len;
        const inc = rank.decode(s.gpa, value, a.index, all_commit, &ses.items) catch continue;
        ses.incomplete = ses.incomplete or inc;
        s.dedup(ses, before);
        added = true;
    }
    if (added) {
        ses.ranker.reset();
        s.refilter(ses) catch {};
    }
    for (s.takeResolved()) |r| {
        defer s.gpa.destroy(r);
        defer _ = s.outstanding.fetchSub(1, .acq_rel);
        if (r.items_gen != ses.items_gen or r.item >= ses.items.items.len) {
            r.result.deinit();
            continue;
        }
        const v = switch (r.result) {
            .ok => |o| o.value,
            else => {
                r.result.deinit();
                continue;
            },
        };
        ses.resolved.append(s.gpa, r.result) catch {
            r.result.deinit();
            continue;
        };
        const it = &ses.items.items[r.item];
        if (v.documentation) |d| it.doc = rank.docOf(d);
        if (v.detail) |d| it.detail = d;
        if (v.additionalTextEdits) |e| it.additional = e;
        if (v.command) |cmd| it.command = cmd;
        it.resolved = true;
        s.generation += 1;
    }
    return s.generation != g;
}

/// Drops the items from `before` on that an earlier one already lists.
fn dedup(s: *CompletionService, ses: *Session, before: usize) void {
    var keep = before;
    for (ses.items.items[before..]) |it| {
        const gop = ses.seen.getOrPut(s.gpa, rank.dedupKey(&it)) catch {
            ses.items.items[keep] = it;
            keep += 1;
            continue;
        };
        if (gop.found_existing) continue;
        ses.items.items[keep] = it;
        keep += 1;
    }
    ses.items.shrinkRetainingCapacity(keep);
}

fn sendResolve(s: *CompletionService, ses: *Session) !void {
    const pos = ses.selected orelse return;
    const idx = ses.ranker.ranked.items[pos].item;
    const it = &ses.items.items[idx];
    const raw = it.raw orelse return;
    const srv = ses.servers[it.server] orelse return;
    if (ses.resolve_inflight) |r| r.client.cancel(r.handle);
    ses.resolve_inflight = null;
    var params = raw.*;
    params.data = it.data;
    const rr = try s.gpa.create(ResolveReq);
    errdefer s.gpa.destroy(rr);
    rr.* = .{ .svc = s, .items_gen = ses.items_gen, .item = idx };
    _ = s.outstanding.fetchAdd(1, .acq_rel);
    const hd = srv.client.request(.@"completionItem/resolve", params, .{ .doc = s.mgr.docMatch(ses.h) }, .{ .ctx = rr, .func = onResolved }) catch |e| {
        _ = s.outstanding.fetchSub(1, .acq_rel);
        return e;
    };
    ses.resolve_inflight = .{ .client = srv.client, .handle = hd };
    s.resolves_sent += 1;
}

fn onResolved(ctx: ?*anyopaque, res: Resolve) void {
    const rr: *ResolveReq = @ptrCast(@alignCast(ctx.?));
    rr.result = res;
    const s = rr.svc;
    {
        s.inbox_mutex.lockUncancelable(s.io);
        defer s.inbox_mutex.unlock(s.io);
        s.inbox.append(s.gpa, rr) catch {
            s.dropResolve(rr);
            return;
        };
    }
    s.waker.wake();
}

fn dropResolve(s: *CompletionService, rr: *ResolveReq) void {
    rr.result.deinit();
    s.gpa.destroy(rr);
    _ = s.outstanding.fetchSub(1, .acq_rel);
}

/// The resolve answers that arrived; valid until the next call.
fn takeResolved(s: *CompletionService) []*ResolveReq {
    s.inbox_taken.clearRetainingCapacity();
    s.inbox_mutex.lockUncancelable(s.io);
    defer s.inbox_mutex.unlock(s.io);
    std.mem.swap(std.ArrayList(*ResolveReq), &s.inbox, &s.inbox_taken);
    return s.inbox_taken.items;
}

/// Whether typing `c` (one character) commits item `pos`.
pub fn isCommit(s: *const CompletionService, pos: u32, c: []const u8) bool {
    const ses = s.session orelse return false;
    if (pos >= ses.ranker.ranked.items.len) return false;
    return ses.item(pos).commits(c);
}

pub const Accepted = struct {
    /// Carets the item was written at.
    carets: u32,
    snippet: bool,
    command_sent: bool,
};

/// Accepts item `pos` in `view` (showing the session's document):
/// writes it, starts its snippet session in `snippets` (null: the
/// snippet's text without stops), runs its command and types
/// `commit_char` (when it committed). Ends the session.
pub fn accept(s: *CompletionService, view: *EditorView, pos: u32, mode: AcceptMode, commit_char: ?[]const u8, snippets: ?*SnippetSession.Stack, vars: Snippet.VariableResolver) !Accepted {
    const ses = s.session orelse return error.NoSession;
    defer s.close();
    if (pos >= ses.ranker.ranked.items.len) return error.NoItem;
    const doc = s.mgr.docs.get(ses.h) orelse return error.NoSession;
    if (doc != view.doc) return error.WrongView;
    const it = ses.item(pos);
    const srv = ses.servers[it.server] orelse return error.NoItem;
    var m: position.Mapper = .{ .gpa = s.gpa, .tree = &ses.snap.tree, .enc = srv.enc };
    defer m.deinit();

    // The main range at the request, then now.
    const cursor = @min(view.primarySel().head, doc.len());
    const req_range: ByteRange = switch (it.edit) {
        .insert_text => .{ .start = ses.req_start, .end = ses.at },
        .text_edit => |t| try m.toRange(t.range),
        .insert_replace => |t| try m.toRange(if (mode == .insert) t.insert else t.replace),
    };
    const main = mainRange(doc, ses.snap.version, req_range, ses.at, cursor) orelse return error.Stale;

    const lang = if (s.mgr.docMatch(ses.h)) |dm| dm.language_id else "";
    s.recency.note(s.gpa, lang, it.label) catch {};

    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Additional edits, once, where they still apply.
    var extra: std.ArrayList(Replace) = .empty;
    for (it.additional) |te| {
        const r = try m.toRange(te.range);
        const now_r = position.mapResultRange(doc, ses.snap.version, r, .drop) orelse {
            log.debug("completion additional edit dropped: its text changed", .{});
            continue;
        };
        if (now_r.start < main.end and now_r.end > main.start) continue;
        try extra.append(a, .{ .range = now_r, .text = te.newText });
    }

    // Every caret whose prefix matches the primary's gets the item.
    var ranges: std.ArrayList(ByteRange) = .empty;
    try ranges.append(a, main);
    if (view.selections().len > 1) {
        const before = cursor -| main.start;
        const after = main.end -| cursor;
        const prefix = try doc.tree.copyRange(a, .{ .start = cursor - before, .end = cursor });
        for (view.selections()) |sel| {
            const c = sel.head;
            if (c == cursor or c < before or c + after > doc.len()) continue;
            const r: ByteRange = .{ .start = c - before, .end = c + after };
            const got = try doc.tree.copyRange(a, .{ .start = r.start, .end = c });
            if (!std.mem.eql(u8, got, prefix)) continue;
            if (overlapsAny(r, ranges.items) or overlapsAny(r, extraRanges(a, extra.items))) continue;
            try ranges.append(a, r);
        }
    }
    std.mem.sort(ByteRange, ranges.items, {}, struct {
        fn lt(_: void, x: ByteRange, y: ByteRange) bool {
            return x.start < y.start;
        }
    }.lt);

    const indent = try lineIndent(a, doc, main.start);
    const text = it.edit.newText();
    var snippet_started = false;
    if (it.insert_format == .snippet) {
        var sn = try Snippet.parse(s.gpa, text);
        defer sn.deinit();
        var exp: Snippet.Expansion = .{};
        defer exp.deinit(s.gpa);
        const unit: []const u8 = if (indent.len > 0 and indent[0] == ' ') "    " else "\t";
        try sn.expand(s.gpa, vars, .{ .line_indent = if (it.insert_mode == .adjust_indentation) indent else "", .indent_unit = unit }, &exp);
        if (snippets) |stack| {
            try stack.beginWith(view, ranges.items, &exp, extra.items);
            snippet_started = true;
        } else {
            try writePlain(a, view, ranges.items, main.start, extra.items, exp.text.items);
        }
    } else {
        const body = if (it.insert_mode == .adjust_indentation) try reindent(a, text, indent) else text;
        try writePlain(a, view, ranges.items, main.start, extra.items, body);
    }

    var sent = false;
    if (it.command) |cmd| {
        _ = srv.client.request(.@"workspace/executeCommand", .{ .command = cmd.command, .arguments = cmd.arguments }, .{}, .{ .ctx = null, .func = ignoreResult(.@"workspace/executeCommand") }) catch |e| {
            log.debug("completion command not sent: {t}", .{e});
        };
        sent = true;
    }
    if (commit_char) |cc| try view.typeText(cc);
    return .{ .carets = @intCast(ranges.items.len), .snippet = snippet_started, .command_sent = sent };
}

fn ignoreResult(comptime M: protocol.Method) *const fn (?*anyopaque, Client.Result(M)) void {
    return struct {
        fn f(_: ?*anyopaque, r: Client.Result(M)) void {
            r.deinit();
        }
    }.f;
}

fn extraRanges(a: Allocator, extra: []const Replace) []const ByteRange {
    const out = a.alloc(ByteRange, extra.len) catch return &.{};
    for (extra, out) |e, *o| o.* = e.range;
    return out;
}

fn overlapsAny(r: ByteRange, rs: []const ByteRange) bool {
    for (rs) |x| if (r.start < x.end and x.start < r.end or r.start == x.start) return true;
    return false;
}

/// Writes `text` over every range and `extra`, as one undo step, with a
/// caret after each insertion (the primary's for the range at
/// `primary_start`).
fn writePlain(a: Allocator, view: *EditorView, ranges: []const ByteRange, primary_start: u64, extra: []const Replace, text: []const u8) !void {
    const Ins = struct { e: Replace, main: bool };
    const all = try a.alloc(Ins, ranges.len + extra.len);
    for (ranges, 0..) |r, i| all[i] = .{ .e = .{ .range = r, .text = text }, .main = true };
    for (extra, ranges.len..) |e, i| all[i] = .{ .e = e, .main = false };
    std.mem.sort(Ins, all, {}, struct {
        fn lt(_: void, x: Ins, y: Ins) bool {
            return x.e.range.start < y.e.range.start;
        }
    }.lt);
    const edits = try a.alloc(Replace, all.len);
    for (all, edits) |x, *e| e.* = x.e;
    try view.applyEdits(edits);
    var carets: std.ArrayList(Selection) = .empty;
    var primary: usize = 0;
    var delta: i128 = 0;
    for (all) |x| {
        const r = x.e.range;
        const end: u64 = @intCast(@as(i128, r.start) + delta + @as(i128, @intCast(x.e.text.len)));
        delta += @as(i128, @intCast(x.e.text.len)) - @as(i128, @intCast(r.end - r.start));
        if (!x.main) continue;
        if (r.start == primary_start) primary = carets.items.len;
        try carets.append(a, .caret(end));
    }
    try view.setSelections(carets.items, primary);
}

/// The main edit's range now: the start follows edits before it, the
/// end follows text typed at the request caret (so typed characters are
/// replaced too). Null when the range's text was edited away.
pub fn mainRange(doc: *const Document, version: u64, r: ByteRange, at: u64, cursor: u64) ?ByteRange {
    const st = mapAt(doc, version, r.start, .left) orelse return null;
    if (st.deleted and r.start < r.end) return null;
    const en = mapAt(doc, version, r.end, if (r.end >= at) .right else .left) orelse return null;
    var end = en.pos;
    if (r.end == at and end < cursor) end = cursor;
    if (end < st.pos or end > doc.len()) return null;
    return .{ .start = st.pos, .end = end };
}

const Mapped = struct { pos: u64, deleted: bool };

fn mapAt(doc: *const Document, version: u64, pos: u64, bias: zg_editor.model.edit.change_set.Bias) ?Mapped {
    if (version == doc.version) return .{ .pos = pos, .deleted = false };
    const m = doc.change_log.mapPos(version, pos, bias) orelse return null;
    return .{ .pos = m.pos, .deleted = m.deleted };
}

/// The leading whitespace of the line holding `offset`.
fn lineIndent(a: Allocator, doc: *const Document, offset: u64) ![]const u8 {
    var lc: position.LineCursor = .{};
    const ls = lc.seekOffset(&doc.tree, offset);
    const head = try doc.tree.copyRange(a, .{ .start = ls, .end = @min(offset, ls + 256) });
    var i: usize = 0;
    while (i < head.len and (head[i] == ' ' or head[i] == '\t')) i += 1;
    return head[0..i];
}

/// `text` with `indent` after each newline (`adjustIndentation`).
fn reindent(a: Allocator, text: []const u8, indent: []const u8) ![]const u8 {
    if (indent.len == 0 or std.mem.indexOfScalar(u8, text, '\n') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        try out.append(a, c);
        if (c == '\n') try out.appendSlice(a, indent);
    }
    return out.items;
}
