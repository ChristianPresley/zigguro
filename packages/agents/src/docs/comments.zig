//! Comment threads on a document (E13.F04.S02.T01): margin threads
//! between the person and the agent, anchored to ranges of text.
//!
//! Comments never touch the Markdown. Each document has a JSONL sidecar,
//! `.zigguro/comments/<hash of its path>.jsonl`, of append-only events
//! (a thread opened, a comment, resolved, re-anchored). A thread keeps the
//! text it is about (`quote`, up to 256 bytes) with 32 bytes of context
//! either side, a W3C text-quote selector, so it finds its place again
//! after edits the app did not see: at its last offset, else the exact
//! quote whose context matches best (nearest first), else a fuzzy match
//! within 2 KB of the last offset. A thread whose text is gone is
//! orphaned: still listed, and the person can attach it again.
//!
//! A comment that says `@agent` (or "Ask agent") goes to the document's
//! agent with the quote and its section; the agent answers with
//! `doc_reply` and may link a proposal; accepting the proposal resolves
//! the thread.

const std = @import("std");
const zg_ai = @import("zg_ai");
const runs = @import("../runs/root.zig");
const sections = @import("sections.zig");
const words = @import("words.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Range = sections.Range;
const Clock = zg_ai.ratelimit.Clock;

pub const ThreadId = u32;
pub const CommentId = u32;

pub const quote_max = 256;
pub const context_len = 32;
/// How far from its last offset a fuzzy match may be.
pub const fuzzy_window = 2048;

pub const Author = union(enum) {
    user: []const u8,
    agent: runs.RunId,

    pub fn isAgent(a: Author) bool {
        return a == .agent;
    }
};

pub const Comment = struct {
    id: CommentId,
    thread: ThreadId,
    author: Author,
    text: []const u8,
    created_ms: i64,
    /// A changeset proposed with this comment.
    proposal: ?u64 = null,
};

pub const Thread = struct {
    id: ThreadId,
    /// Null: orphaned (its text is gone).
    anchor: ?Range,
    quote: []const u8,
    prefix: []const u8,
    suffix: []const u8,
    /// The anchored length (the quote may be cut at 256 bytes).
    len: u32,
    /// Where it was last seen (orphans keep it, for the fuzzy window).
    last_offset: u32,
    resolved: bool = false,
    created_ms: i64,
    comments: std.ArrayList(Comment) = .empty,
    /// The anchor moved since it was written to the sidecar.
    dirty: bool = false,
};

/// Sends a comment addressed to the agent as a user message.
pub const AskPort = struct {
    ctx: *anyopaque,
    ask: *const fn (ctx: *anyopaque, thread: ThreadId, prompt: []const u8) anyerror!void,
};

pub const Options = struct {
    clock: Clock = .real,
    ask: ?AskPort = null,
};

/// Whether a comment is addressed to the agent.
pub fn mentionsAgent(text: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(text, "@agent") != null;
}

/// The sidecar's name for a workspace-relative path.
pub fn sidecarName(buf: *[64]u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zigguro/comments/{x:0>16}.jsonl", .{std.hash.XxHash3.hash(0, path)}) catch unreachable;
}

/// One line of the sidecar.
const Event = struct {
    op: []const u8,
    path: ?[]const u8 = null,
    thread: ?ThreadId = null,
    id: ?CommentId = null,
    start: ?u32 = null,
    end: ?u32 = null,
    orphan: ?bool = null,
    quote: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
    len: ?u32 = null,
    author: ?Author = null,
    text: ?[]const u8 = null,
    at: ?i64 = null,
    proposal: ?u64 = null,
    resolved: ?bool = null,
};

pub const CommentStore = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    o: Options,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    file_name: [64]u8 = undefined,
    file_len: usize = 0,
    list: std.ArrayList(Thread) = .empty,
    next_thread: ThreadId = 1,
    next_comment: CommentId = 1,
    /// The document as last seen (for agent prompts).
    doc: std.ArrayList(u8) = .empty,
    /// Bumped on every change (views compare it).
    revision: u64 = 0,

    /// Opens (or starts) the comments of `doc_path`, kept under
    /// `workspace/.zigguro/comments/`.
    pub fn open(gpa: Allocator, io: Io, doc_path: []const u8, workspace: Io.Dir, o: Options) !*CommentStore {
        const s = try gpa.create(CommentStore);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .io = io, .dir = workspace, .o = o, .arena = .init(gpa), .path = undefined };
        errdefer s.arena.deinit();
        s.path = try s.arena.allocator().dupe(u8, doc_path);
        s.setFile(doc_path);
        try s.load();
        return s;
    }

    pub fn close(s: *CommentStore) void {
        for (s.list.items) |*t| t.comments.deinit(s.gpa);
        s.list.deinit(s.gpa);
        s.doc.deinit(s.gpa);
        s.arena.deinit();
        s.gpa.destroy(s);
    }

    fn setFile(s: *CommentStore, path: []const u8) void {
        const n = sidecarName(&s.file_name, path);
        s.file_len = n.len;
    }

    pub fn fileName(s: *const CommentStore) []const u8 {
        return s.file_name[0..s.file_len];
    }

    fn load(s: *CommentStore) !void {
        const bytes = s.dir.readFileAlloc(s.io, s.fileName(), s.gpa, .limited(64 << 20)) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        defer s.gpa.free(bytes);
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
            // A torn last line (a crash mid-write) is skipped.
            const ev = std.json.parseFromSliceLeaky(Event, s.arena.allocator(), line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
            try s.replay(ev);
        }
    }

    fn replay(s: *CommentStore, ev: Event) !void {
        const eq = std.mem.eql;
        if (eq(u8, ev.op, "thread")) {
            const id = ev.thread orelse return;
            const start = ev.start orelse 0;
            try s.list.append(s.gpa, .{
                .id = id,
                .anchor = if (ev.orphan orelse false) null else .{ .start = start, .end = ev.end orelse start },
                .quote = ev.quote orelse "",
                .prefix = ev.prefix orelse "",
                .suffix = ev.suffix orelse "",
                .len = ev.len orelse @intCast(if (ev.quote) |q| q.len else 0),
                .last_offset = start,
                .created_ms = ev.at orelse 0,
            });
            s.next_thread = @max(s.next_thread, id + 1);
        } else if (eq(u8, ev.op, "comment")) {
            const t = s.find(ev.thread orelse return) orelse return;
            const id = ev.id orelse return;
            try t.comments.append(s.gpa, .{ .id = id, .thread = t.id, .author = ev.author orelse .{ .user = "" }, .text = ev.text orelse "", .created_ms = ev.at orelse 0, .proposal = ev.proposal });
            s.next_comment = @max(s.next_comment, id + 1);
        } else if (eq(u8, ev.op, "resolve")) {
            const t = s.find(ev.thread orelse return) orelse return;
            t.resolved = ev.resolved orelse true;
        } else if (eq(u8, ev.op, "anchor")) {
            const t = s.find(ev.thread orelse return) orelse return;
            if (ev.orphan orelse false) {
                t.anchor = null;
            } else {
                const start = ev.start orelse return;
                t.anchor = .{ .start = start, .end = ev.end orelse start };
                t.last_offset = start;
            }
            if (ev.quote) |q| t.quote = q;
            if (ev.prefix) |p| t.prefix = p;
            if (ev.suffix) |x| t.suffix = x;
            if (ev.len) |l| t.len = l;
        } else if (eq(u8, ev.op, "proposal")) {
            for (s.list.items) |*t| for (t.comments.items) |*c| if (c.id == ev.id) {
                c.proposal = ev.proposal;
            };
        } else if (eq(u8, ev.op, "path")) {
            if (ev.path) |p| s.path = p;
        }
    }

    fn append(s: *CommentStore, ev: Event) !void {
        var w: Io.Writer.Allocating = .init(s.gpa);
        defer w.deinit();
        try std.json.Stringify.value(ev, .{ .emit_null_optional_fields = false }, &w.writer);
        try w.writer.writeByte('\n');
        try s.dir.createDirPath(s.io, ".zigguro/comments");
        const f = try s.dir.createFile(s.io, s.fileName(), .{ .truncate = false });
        defer f.close(s.io);
        try f.writePositionalAll(s.io, w.written(), try f.length(s.io));
        s.revision += 1;
    }

    fn find(s: *CommentStore, id: ThreadId) ?*Thread {
        for (s.list.items) |*t| if (t.id == id) return t;
        return null;
    }

    pub fn get(s: *CommentStore, id: ThreadId) ?*const Thread {
        return s.find(id);
    }

    /// Every thread, anchored ones in document order, then orphans.
    pub fn threads(s: *const CommentStore) []const Thread {
        return s.list.items;
    }

    /// Sorts threads by position (orphans last); views call it after changes.
    pub fn sort(s: *CommentStore) void {
        std.mem.sort(Thread, s.list.items, {}, struct {
            fn lt(_: void, x: Thread, y: Thread) bool {
                const xa = if (x.anchor) |r| r.start else std.math.maxInt(u32);
                const ya = if (y.anchor) |r| r.start else std.math.maxInt(u32);
                return if (xa != ya) xa < ya else x.id < y.id;
            }
        }.lt);
    }

    fn now(s: *const CommentStore) i64 {
        return s.o.clock.now(s.io);
    }

    fn rememberDoc(s: *CommentStore, doc: []const u8) !void {
        s.doc.clearRetainingCapacity();
        try s.doc.appendSlice(s.gpa, doc);
    }

    const Selector = struct { quote: []const u8, prefix: []const u8, suffix: []const u8, len: u32 };

    fn selector(s: *CommentStore, doc: []const u8, r: Range) !Selector {
        const a = s.arena.allocator();
        const end = @min(r.end, doc.len);
        const start = @min(r.start, end);
        const q = doc[start..@min(end, start + quote_max)];
        return .{
            .quote = try a.dupe(u8, q),
            .prefix = try a.dupe(u8, doc[start -| context_len..start]),
            .suffix = try a.dupe(u8, doc[end..@min(doc.len, end + context_len)]),
            .len = @intCast(end - start),
        };
    }

    /// A new thread on `anchor` of `doc`, with its first comment.
    pub fn add(s: *CommentStore, doc: []const u8, anchor: Range, text: []const u8, author: Author) !ThreadId {
        const id = blk: {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            try s.rememberDoc(doc);
            const sel = try s.selector(doc, anchor);
            const id = s.next_thread;
            const at = s.now();
            try s.append(.{ .op = "thread", .thread = id, .start = anchor.start, .end = anchor.start + sel.len, .quote = sel.quote, .prefix = sel.prefix, .suffix = sel.suffix, .len = sel.len, .at = at });
            s.next_thread += 1;
            try s.list.append(s.gpa, .{ .id = id, .anchor = .{ .start = anchor.start, .end = anchor.start + sel.len }, .quote = sel.quote, .prefix = sel.prefix, .suffix = sel.suffix, .len = sel.len, .last_offset = anchor.start, .created_ms = at });
            _ = try s.addComment(id, text, author, null);
            break :blk id;
        };
        if (!author.isAgent() and mentionsAgent(text)) try s.askAgent(id);
        return id;
    }

    /// Adds a reply; `proposal` links a changeset proposed with it.
    pub fn reply(s: *CommentStore, t: ThreadId, text: []const u8, author: Author) !CommentId {
        return s.replyWith(t, text, author, null);
    }

    pub fn replyWith(s: *CommentStore, t: ThreadId, text: []const u8, author: Author, proposal: ?u64) !CommentId {
        const id = blk: {
            s.mutex.lockUncancelable(s.io);
            defer s.mutex.unlock(s.io);
            const th = s.find(t) orelse return error.NoSuchThread;
            if (th.resolved) {
                th.resolved = false;
                try s.append(.{ .op = "resolve", .thread = t, .resolved = false });
            }
            break :blk try s.addComment(t, text, author, proposal);
        };
        if (!author.isAgent() and mentionsAgent(text)) try s.askAgent(t);
        return id;
    }

    fn addComment(s: *CommentStore, t: ThreadId, text: []const u8, author: Author, proposal: ?u64) !CommentId {
        const th = s.find(t) orelse return error.NoSuchThread;
        const a = s.arena.allocator();
        const id = s.next_comment;
        const at = s.now();
        const c: Comment = .{ .id = id, .thread = t, .author = switch (author) {
            .user => |u| .{ .user = try a.dupe(u8, u) },
            .agent => author,
        }, .text = try a.dupe(u8, text), .created_ms = at, .proposal = proposal };
        try s.append(.{ .op = "comment", .thread = t, .id = id, .author = c.author, .text = c.text, .at = at, .proposal = proposal });
        s.next_comment += 1;
        try th.comments.append(s.gpa, c);
        return id;
    }

    pub fn resolve(s: *CommentStore, t: ThreadId) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const th = s.find(t) orelse return error.NoSuchThread;
        if (th.resolved) return;
        th.resolved = true;
        try s.append(.{ .op = "resolve", .thread = t, .resolved = true });
    }

    /// A changeset was decided: accepting one a comment proposed resolves
    /// its thread.
    pub fn onDecision(s: *CommentStore, changeset: u64, accepted: bool) !void {
        if (!accepted) return;
        var hit: ?ThreadId = null;
        for (s.list.items) |t| for (t.comments.items) |c| if (c.proposal == changeset) {
            hit = t.id;
        };
        if (hit) |t| try s.resolve(t);
    }

    /// Sends thread `t` to the agent: its quote, section and comments.
    pub fn askAgent(s: *CommentStore, t: ThreadId) !void {
        const port = s.o.ask orelse return;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const prompt = try s.agentPrompt(arena.allocator(), t);
        try port.ask(port.ctx, t, prompt);
    }

    pub fn agentPrompt(s: *CommentStore, a: Allocator, t: ThreadId) ![]const u8 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const th = s.find(t) orelse return error.NoSuchThread;
        var out: Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        try w.print("A comment thread (thread {d}) on {s}", .{ t, s.path });
        const all = try sections.outline(a, s.doc.items);
        const sec = if (th.anchor) |r| sections.sectionAt(all, r.start) else null;
        if (sec) |i| try w.print(", in the section \"{s}\"", .{all[i].title});
        try w.writeAll(", about this text:\n\n");
        var lines = std.mem.splitScalar(u8, th.quote, '\n');
        while (lines.next()) |l| try w.print("> {s}\n", .{l});
        if (sec) |i| {
            const r = all[i].range;
            try w.print("\nThe section:\n\n{s}\n", .{s.doc.items[r.start..@min(r.end, s.doc.items.len)]});
        }
        try w.writeAll("\nThe thread:\n\n");
        for (th.comments.items) |c| switch (c.author) {
            .user => |u| try w.print("- {s}: {s}\n", .{ if (u.len > 0) u else "user", c.text }),
            .agent => try w.print("- agent: {s}\n", .{c.text}),
        };
        try w.print("\nAnswer with doc_reply (thread {d}). To change the text, propose an edit with doc_propose_edit and pass its changeset as the reply's proposal.\n", .{t});
        return out.written();
    }

    // ---- anchors ----

    /// Follows an edit seen in the app: `old_len` bytes at `start` became
    /// `new_len`. A thread whose whole text was replaced is orphaned.
    pub fn applyEdit(s: *CommentStore, start: u32, old_len: u32, new_len: u32) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const end = start + old_len;
        for (s.list.items) |*t| {
            const r = t.anchor orelse continue;
            var n = r;
            if (r.start >= end) {
                n.start = r.start - old_len + new_len;
                n.end = r.end - old_len + new_len;
            } else if (r.end <= start) {
                continue;
            } else if (start <= r.start and end >= r.end and old_len > 0) {
                t.anchor = null;
                t.dirty = true;
                continue;
            } else {
                // Overlapping: the edit's part inside the range changes it.
                n.start = if (start < r.start) start + new_len else r.start;
                n.end = if (end >= r.end) start + new_len else r.end - old_len + new_len;
            }
            if (n.start != r.start or n.end != r.end) {
                t.anchor = n;
                t.last_offset = n.start;
                t.dirty = true;
            }
        }
    }

    /// Writes moved anchors (with fresh quotes) to the sidecar, e.g. on save.
    pub fn sync(s: *CommentStore, doc: []const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        try s.rememberDoc(doc);
        for (s.list.items) |*t| if (t.dirty) try s.writeAnchor(t, doc);
    }

    fn writeAnchor(s: *CommentStore, t: *Thread, doc: []const u8) !void {
        t.dirty = false;
        if (t.anchor) |r| {
            const sel = try s.selector(doc, r);
            t.quote = sel.quote;
            t.prefix = sel.prefix;
            t.suffix = sel.suffix;
            t.len = sel.len;
            try s.append(.{ .op = "anchor", .thread = t.id, .start = r.start, .end = r.end, .quote = sel.quote, .prefix = sel.prefix, .suffix = sel.suffix, .len = sel.len });
        } else try s.append(.{ .op = "anchor", .thread = t.id, .orphan = true });
    }

    /// Finds every thread's text again after the document changed outside
    /// the app (a reload); returns how many threads are orphaned now.
    pub fn reanchor(s: *CommentStore, doc: []const u8) !u32 {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        try s.rememberDoc(doc);
        var scratch: std.heap.ArenaAllocator = .init(s.gpa);
        defer scratch.deinit();
        var orphans: u32 = 0;
        for (s.list.items) |*t| {
            const found = try locate(scratch.allocator(), doc, t);
            const same = if (found) |f| (if (t.anchor) |r| r.start == f.start and r.end == f.end else false) else t.anchor == null;
            if (!same) {
                t.anchor = found;
                if (found) |f| t.last_offset = f.start;
                try s.writeAnchor(t, doc);
            }
            if (t.anchor == null) orphans += 1;
        }
        return orphans;
    }

    /// Attaches thread `t` to `r` (an orphan the person placed again).
    pub fn setAnchor(s: *CommentStore, t: ThreadId, doc: []const u8, r: Range) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const th = s.find(t) orelse return error.NoSuchThread;
        th.anchor = r;
        th.last_offset = r.start;
        try s.writeAnchor(th, doc);
    }

    /// The document was renamed (an E08 rename event): the sidecar follows.
    pub fn rename(s: *CommentStore, new_path: []const u8) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        var old: [64]u8 = undefined;
        const old_name = old[0..s.file_len];
        @memcpy(old_name, s.fileName());
        s.path = try s.arena.allocator().dupe(u8, new_path);
        s.setFile(new_path);
        s.dir.rename(old_name, s.dir, s.fileName(), s.io) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        try s.append(.{ .op = "path", .path = new_path });
    }
};

/// Where thread `t`'s text is in `doc`, or null.
pub fn locate(a: Allocator, doc: []const u8, t: *const Thread) !?Range {
    const q = t.quote;
    if (q.len == 0) return null;
    const cut = t.len > q.len;
    const span = struct {
        fn of(d: []const u8, th: *const Thread, at: usize, matched: usize) Range {
            const l: usize = if (th.len > th.quote.len) th.len else matched;
            return .{ .start = @intCast(at), .end = @intCast(@min(d.len, at + l)) };
        }
    }.of;
    const last: usize = @min(t.last_offset, doc.len);
    if (last + q.len <= doc.len and std.mem.eql(u8, doc[last .. last + q.len], q)) return span(doc, t, last, q.len);
    // Exact occurrences: the best context match, then the nearest.
    var best: ?usize = null;
    var best_score: usize = 0;
    var best_dist: usize = std.math.maxInt(usize);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, doc, from, q)) |at| : (from = at + 1) {
        const score = contextScore(doc, at, at + q.len, t);
        const dist = if (at > last) at - last else last - at;
        if (best == null or score > best_score or (score == best_score and dist < best_dist)) {
            best = at;
            best_score = score;
            best_dist = dist;
        }
    }
    if (best) |at| return span(doc, t, at, q.len);
    // Fuzzy, near where it was.
    if (cut) return null;
    const lo = last -| fuzzy_window;
    const hi = @min(doc.len, last + q.len + fuzzy_window);
    if (try words.findSimilar(a, doc[lo..hi], q, 0.75)) |m| return .{ .start = @intCast(lo + m[0]), .end = @intCast(lo + m[1]) };
    return null;
}

/// How many context bytes around [start, end) match the thread's prefix
/// and suffix.
fn contextScore(doc: []const u8, start: usize, end: usize, t: *const Thread) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < t.prefix.len and i < start and doc[start - 1 - i] == t.prefix[t.prefix.len - 1 - i]) i += 1;
    n += i;
    i = 0;
    while (i < t.suffix.len and end + i < doc.len and doc[end + i] == t.suffix[i]) i += 1;
    return n + i;
}
