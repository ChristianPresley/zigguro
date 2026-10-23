//! A document session (E13.F04.S01.T01): an agent writing alongside a
//! person in one Markdown document. The session mirrors the document (the
//! app feeds it the editor's edits), keeps its section outline and sticky
//! anchors, and turns the agent's proposals into E12 changesets of word
//! hunks. It never writes the document: the person accepts changes in
//! review, and the accepted edit comes back like any other.
//!
//! A proposal names a scope (a section, or the whole document) and the
//! text it replaces. The text is found exactly, then with whitespace
//! normalized, then by word similarity (at least 0.9), so edits the person
//! made meanwhile do not break it; otherwise the proposal is stale and the
//! agent gets the current text to try again. While the person is typing
//! in the section (a keystroke in the last 2 s) the proposal waits until
//! they pause, so tracked changes do not flicker under the cursor.

const std = @import("std");
const zg_ai = @import("zg_ai");
const runs = @import("../runs/root.zig");
const sections_mod = @import("sections.zig");
const anchors_mod = @import("anchors.zig");
const words = @import("words.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Section = sections_mod.Section;
pub const Range = sections_mod.Range;
pub const AnchorId = anchors_mod.AnchorId;
pub const Hunk = words.Hunk;
pub const Clock = zg_ai.ratelimit.Clock;

/// Who proposed a change.
pub const Provenance = struct {
    run: ?runs.RunId = null,
    session: ?u128 = null,
    tool: []const u8 = "",
};

/// An agent's change to the document, for review.
pub const DocChange = struct {
    /// Workspace-relative path.
    path: []const u8,
    /// The document the hunks apply to, and its version.
    base: []const u8,
    base_version: u64,
    /// Word hunks, in order, offsets into `base`.
    hunks: []const Hunk,
    summary: []const u8,
    rationale: ?[]const u8,
    prov: Provenance,
};

/// E12: queues a change for review; returns the changeset id.
pub const ChangePort = struct {
    ctx: *anyopaque,
    propose: *const fn (ctx: *anyopaque, c: DocChange) anyerror!u64,
};

pub const Scope = union(enum) {
    document,
    /// A section id (`2.1`), slug or title.
    section: []const u8,
};

pub const Proposal = struct {
    scope: Scope = .document,
    old_text: []const u8,
    new_text: []const u8,
    rationale: ?[]const u8 = null,
};

pub const ProposeResult = union(enum) {
    /// The changeset.
    ok: u64,
    /// `old_text` is no longer in the scope: its current text.
    stale: []const u8,
    /// A message for the agent (no such section, ambiguous text, ...).
    not_found: []const u8,
};

pub const InsertAt = union(enum) {
    /// After the section and its children.
    after_section: []const u8,
    at_anchor: AnchorId,
    end,
};

pub const Options = struct {
    clock: Clock = .real,
    /// A proposal waits while the person typed in its section this recently.
    idle_ms: u32 = 2000,
    /// ...but no longer than this.
    max_hold_ms: u32 = 30_000,
    /// The least word similarity a fuzzy match needs.
    min_similarity: f32 = 0.9,
};

pub const DocSession = struct {
    gpa: Allocator,
    io: Io,
    path: []const u8,
    changes: ChangePort,
    o: Options,
    mutex: Io.Mutex = .init,
    text: std.ArrayList(u8) = .empty,
    version: u64,
    anchors: anchors_mod.Anchors = .{},
    /// The outline of `text` at `outline_version`.
    outline_arena: std.heap.ArenaAllocator,
    outline_cache: []const Section = &.{},
    outline_version: ?u64 = null,
    /// The person's last keystroke.
    typing: ?struct { offset: u32, at_ms: i64 } = null,
    /// Proposals made (tests and the UI's badge).
    proposals: u32 = 0,

    pub fn open(gpa: Allocator, io: Io, path: []const u8, text: []const u8, version: u64, changes: ChangePort, o: Options) !*DocSession {
        const s = try gpa.create(DocSession);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .io = io, .path = try gpa.dupe(u8, path), .changes = changes, .o = o, .version = version, .outline_arena = .init(gpa) };
        try s.text.appendSlice(gpa, text);
        return s;
    }

    pub fn close(s: *DocSession) void {
        const gpa = s.gpa;
        s.text.deinit(gpa);
        s.anchors.deinit(gpa);
        s.outline_arena.deinit();
        gpa.free(s.path);
        gpa.destroy(s);
    }

    // ---- fed by the editor ----

    /// The document was replaced (opened, reloaded).
    pub fn replaceAll(s: *DocSession, text: []const u8, version: u64) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const old_len: u32 = @intCast(s.text.items.len);
        s.text.clearRetainingCapacity();
        try s.text.appendSlice(s.gpa, text);
        s.anchors.applyEdit(0, old_len, @intCast(text.len));
        s.version = version;
    }

    /// The document changed: `old_len` bytes at `start` became `new_text`.
    pub fn applyEdit(s: *DocSession, start: u32, old_len: u32, new_text: []const u8, version: u64) !void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const st = @min(start, s.text.items.len);
        const ol = @min(old_len, s.text.items.len - st);
        try s.text.replaceRange(s.gpa, st, ol, new_text);
        s.anchors.applyEdit(@intCast(st), @intCast(ol), @intCast(new_text.len));
        s.version = version;
    }

    /// The person typed at `offset`.
    pub fn noteTyping(s: *DocSession, offset: u32) void {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        s.typing = .{ .offset = offset, .at_ms = s.o.clock.now(s.io) };
    }

    // ---- reading ----

    /// The current text and outline, copied into `a`.
    pub fn snapshot(s: *DocSession, a: Allocator) !Snapshot {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const out = try s.outlineLocked();
        return .{ .text = try a.dupe(u8, s.text.items), .version = s.version, .outline = try cloneOutline(a, out) };
    }

    /// A sticky anchor at `offset`.
    pub fn anchor(s: *DocSession, offset: u32, bias: anchors_mod.Bias) !AnchorId {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.anchors.create(s.gpa, s.text.items, offset, bias);
    }

    pub fn resolveAnchor(s: *DocSession, id: AnchorId) ?anchors_mod.Resolved {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.anchors.resolve(id, s.text.items);
    }

    fn outlineLocked(s: *DocSession) ![]const Section {
        if (s.outline_version != s.version) {
            _ = s.outline_arena.reset(.retain_capacity);
            s.outline_cache = try sections_mod.outline(s.outline_arena.allocator(), s.text.items);
            s.outline_version = s.version;
        }
        return s.outline_cache;
    }

    // ---- proposing ----

    /// Proposes replacing `p.old_text` within `p.scope` by `p.new_text`.
    pub fn propose(s: *DocSession, a: Allocator, p: Proposal, prov: Provenance) !ProposeResult {
        if (p.old_text.len == 0) return .{ .not_found = "old_text is empty: to add text, use doc_insert" };
        const started = s.o.clock.now(s.io);
        while (true) {
            s.mutex.lockUncancelable(s.io);
            var locked = true;
            defer if (locked) s.mutex.unlock(s.io);
            const text = s.text.items;
            const out = try s.outlineLocked();
            const scope: Range = switch (p.scope) {
                .document => .{ .start = 0, .end = @intCast(text.len) },
                .section => |ref| blk: {
                    const i = sections_mod.find(out, ref) orelse return .{ .not_found = try std.fmt.allocPrint(a, "no section {s}; doc_outline lists them", .{ref}) };
                    break :blk out[i].range;
                },
            };
            const hay = text[scope.start..scope.end];
            const span: [2]u32 = blk: {
                const n = std.mem.count(u8, hay, p.old_text);
                if (n > 1) return .{ .not_found = try std.fmt.allocPrint(a, "old_text occurs {d} times in the scope; include more of the surrounding text", .{n}) };
                if (n == 1) {
                    const at = std.mem.indexOf(u8, hay, p.old_text).?;
                    break :blk .{ @intCast(at), @intCast(at + p.old_text.len) };
                }
                var count: u32 = 0;
                if (try words.findLoose(a, hay, p.old_text, &count)) |r| {
                    if (count > 1) return .{ .not_found = try std.fmt.allocPrint(a, "old_text occurs {d} times in the scope; include more of the surrounding text", .{count}) };
                    break :blk r;
                }
                if (try words.findSimilar(a, hay, p.old_text, s.o.min_similarity)) |r| break :blk r;
                return .{ .stale = try a.dupe(u8, hay) };
            };
            const start = scope.start + span[0];
            const end = scope.start + span[1];
            if (s.holdFor(out, start, end, started)) |wait_ms| {
                locked = false;
                s.mutex.unlock(s.io);
                try s.o.clock.sleep(s.io, wait_ms);
                continue;
            }
            const hs = try words.hunks(a, text[start..end], p.new_text, start);
            if (hs.len == 0) return .{ .not_found = "new_text is the same as the current text" };
            return .{ .ok = try s.submit(a, hs, p.rationale, prov, "Edit") };
        }
    }

    /// Proposes inserting `new_text` at `where`.
    pub fn insert(s: *DocSession, a: Allocator, where: InsertAt, new_text: []const u8, rationale: ?[]const u8, prov: Provenance) !ProposeResult {
        if (new_text.len == 0) return .{ .not_found = "text is empty" };
        const started = s.o.clock.now(s.io);
        while (true) {
            s.mutex.lockUncancelable(s.io);
            var locked = true;
            defer if (locked) s.mutex.unlock(s.io);
            const text = s.text.items;
            const out = try s.outlineLocked();
            const at: u32 = switch (where) {
                .end => @intCast(text.len),
                .at_anchor => |id| (s.anchors.resolve(id, text) orelse return .{ .not_found = "no such anchor" }).offset,
                .after_section => |ref| blk: {
                    const i = sections_mod.find(out, ref) orelse return .{ .not_found = try std.fmt.allocPrint(a, "no section {s}; doc_outline lists them", .{ref}) };
                    break :blk out[i].range.end;
                },
            };
            if (s.holdFor(out, at, at, started)) |wait_ms| {
                locked = false;
                s.mutex.unlock(s.io);
                try s.o.clock.sleep(s.io, wait_ms);
                continue;
            }
            // Keep blocks apart: a blank line before and a newline after.
            const before: []const u8 = if (at == 0 or (at >= 2 and text[at - 1] == '\n' and text[at - 2] == '\n')) "" else if (text[at - 1] == '\n') "\n" else "\n\n";
            const body = std.mem.trim(u8, new_text, "\n");
            const after: []const u8 = if (at < text.len) "\n\n" else "\n";
            const hs = try a.dupe(Hunk, &.{.{ .start = at, .end = at, .new = try std.mem.concat(a, u8, &.{ before, body, after }) }});
            return .{ .ok = try s.submit(a, hs, rationale, prov, "Insert") };
        }
    }

    /// How long a proposal touching `start..end` must still wait for the
    /// person to pause typing in that section, or null.
    fn holdFor(s: *DocSession, out: []const Section, start: u32, end: u32, started: i64) ?u64 {
        const t = s.typing orelse return null;
        const now = s.o.clock.now(s.io);
        if (now - started >= s.o.max_hold_ms) return null;
        const idle_at = t.at_ms + s.o.idle_ms;
        if (now >= idle_at) return null;
        const same = if (sections_mod.sectionAt(out, start)) |i| out[i].range.contains(t.offset) or out[i].range.end == t.offset else t.offset >= start and t.offset <= end;
        if (!same) return null;
        return @intCast(idle_at - now);
    }

    /// Hands hunks to review; the session's lock is held.
    fn submit(s: *DocSession, a: Allocator, hs: []const Hunk, rationale: ?[]const u8, prov: Provenance, verb: []const u8) !u64 {
        const out = try s.outlineLocked();
        const where = if (sections_mod.sectionAt(out, hs[0].start)) |i| out[i].title else std.fs.path.basename(s.path);
        const summary = try std.fmt.allocPrint(a, "{s} {s}", .{ verb, where });
        const id = try s.changes.propose(s.changes.ctx, .{
            .path = s.path,
            .base = try a.dupe(u8, s.text.items),
            .base_version = s.version,
            .hunks = hs,
            .summary = summary,
            .rationale = rationale,
            .prov = prov,
        });
        s.proposals += 1;
        return id;
    }
};

pub const Snapshot = struct {
    text: []const u8,
    version: u64,
    outline: []const Section,

    /// Section `ref`'s text: with its children, or up to its first child.
    pub fn sectionText(snap: *const Snapshot, ref: []const u8, children: bool) ?[]const u8 {
        const i = sections_mod.find(snap.outline, ref) orelse return null;
        const sec = &snap.outline[i];
        return snap.text[sec.range.start..if (children) sec.range.end else sec.ownEnd(snap.outline)];
    }

    pub fn find(snap: *const Snapshot, ref: []const u8) ?*const Section {
        const i = sections_mod.find(snap.outline, ref) orelse return null;
        return &snap.outline[i];
    }
};

fn cloneOutline(a: Allocator, out: []const Section) ![]const Section {
    const c = try a.dupe(Section, out);
    for (c) |*x| {
        x.path = try a.dupe(u16, x.path);
        x.id = try a.dupe(u8, x.id);
        x.slug = try a.dupe(u8, x.slug);
        x.title = try a.dupe(u8, x.title);
        x.children = try a.dupe(u32, x.children);
    }
    return c;
}
