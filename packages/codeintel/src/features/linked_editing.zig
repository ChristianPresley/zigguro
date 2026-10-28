//! Linked editing (E07.F03.S02.T04): with `editor.linkedEditing` on, the
//! caret resting `debounce_ms` asks `textDocument/linkedEditingRange`;
//! when the caret is inside one of the ranges answered (an HTML or JSX
//! open and close tag), a session starts. The editor mirrors the ranges
//! the way snippet mirrors work: a caret in every range at the same
//! column, so typing edits all of them in one undo step.
//!
//! The ranges grow with text typed at their edges. The session ends when
//! an edit lands outside them, when the ranges' texts stop matching the
//! server's `wordPattern` (anchored), when the caret leaves them, or on
//! `end` (Escape).

const LinkedEditingService = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const zg_regex = @import("zg_regex");
const Manager = @import("../Manager.zig");
const requester = @import("request.zig");
const position = @import("position.zig");

const Allocator = std.mem.Allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Document = zg_editor.model.document.Document;
const ByteRange = position.ByteRange;
const Req = requester.Requester(.@"textDocument/linkedEditingRange", .linked_editing_range);

const log = std.log.scoped(.linked_editing);

pub const Options = struct {
    debounce_ms: u64 = 100,
    /// `editor.linkedEditing` (off by default, as in VS Code).
    enabled: bool = false,
};

const Session = struct {
    h: DocHandle,
    /// The version `ranges` are for.
    version: u64,
    ranges: std.ArrayList(ByteRange) = .empty,
    /// The range holding the caret.
    primary: usize = 0,
    regex: ?zg_regex.Regex = null,
    cache: ?zg_regex.Cache = null,

    fn deinit(s: *Session, gpa: Allocator) void {
        s.ranges.deinit(gpa);
        if (s.cache) |*c| c.deinit();
        if (s.regex) |*r| r.deinit(gpa);
    }
};

gpa: Allocator,
mgr: *Manager,
req: Req,
opts: Options,
session: ?Session = null,
/// Where the caret rests, and when to ask.
want: ?struct { h: DocHandle, pos: u64, version: u64, due_ms: u64 } = null,
/// The caret the request in flight is for.
asked: ?struct { h: DocHandle, pos: u64 } = null,
/// Bumped when a session starts or ends.
generation: u64 = 0,

pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker, opts: Options) LinkedEditingService {
    return .{ .gpa = mgr.gpa, .mgr = mgr, .req = .init(mgr, waker), .opts = opts };
}

/// Call after `Manager.deinit`.
pub fn deinit(s: *LinkedEditingService) void {
    s.req.deinit();
    if (s.session) |*x| x.deinit(s.gpa);
}

pub fn setEnabled(s: *LinkedEditingService, on: bool) void {
    s.opts.enabled = on;
    if (!on) {
        s.end();
        s.want = null;
    }
}

/// The caret of `h` is at `pos` (call on every move; cheap while it
/// stays inside the session).
pub fn onCursor(s: *LinkedEditingService, h: DocHandle, pos: u64, now_ms: u64) void {
    if (!s.opts.enabled) return;
    if (s.active(h)) |rs| {
        for (rs, 0..) |r, i| if (pos >= r.start and pos <= r.end) {
            s.session.?.primary = i;
            return;
        };
        s.end();
    }
    const doc = s.mgr.docs.get(h) orelse return;
    if (s.want) |w| if (std.meta.eql(w.h, h) and w.pos == pos and w.version == doc.version) return;
    s.want = .{ .h = h, .pos = pos, .version = doc.version, .due_ms = now_ms + s.opts.debounce_ms };
}

/// Ends the session (Escape).
pub fn end(s: *LinkedEditingService) void {
    var x = s.session orelse return;
    x.deinit(s.gpa);
    s.session = null;
    s.generation += 1;
}

pub fn nextDue(s: *const LinkedEditingService) ?u64 {
    return if (s.want) |w| w.due_ms else null;
}

/// The session's ranges in `h`'s current version, the primary first
/// among equals (`primary`); null without a session (or when an edit
/// just ended it).
pub fn active(s: *LinkedEditingService, h: DocHandle) ?[]const ByteRange {
    if (s.session == null) return null;
    const ses = &s.session.?;
    if (!std.meta.eql(ses.h, h)) return null;
    const doc = s.mgr.docs.get(h) orelse {
        s.end();
        return null;
    };
    if (!s.sync(ses, doc)) {
        s.end();
        return null;
    }
    return ses.ranges.items;
}

/// The index of the range holding the caret.
pub fn primary(s: *const LinkedEditingService) usize {
    return if (s.session) |x| x.primary else 0;
}

/// Brings the ranges to the document's version; false when the session
/// must end (an edit outside them, unequal texts, a pattern mismatch).
fn sync(s: *LinkedEditingService, ses: *Session, doc: *const Document) bool {
    if (ses.version == doc.version) return true;
    const entries = doc.change_log.since(ses.version) orelse return false;
    for (entries) |*e| {
        const cs = &e.changes;
        for (cs.replaces) |rep| {
            const inside = for (ses.ranges.items) |r| {
                if (rep.range.start >= r.start and rep.range.end <= r.end) break true;
            } else false;
            if (!inside) return false;
        }
        // Text typed at an edge belongs to the range.
        for (ses.ranges.items) |*r| r.* = .{ .start = cs.mapPos(r.start, .left), .end = cs.mapPos(r.end, .right) };
    }
    ses.version = doc.version;
    return s.check(ses, doc);
}

/// Whether every range holds the same text, matching the word pattern.
fn check(s: *LinkedEditingService, ses: *Session, doc: *const Document) bool {
    const p = ses.ranges.items[ses.primary];
    const first = doc.tree.copyRange(s.gpa, .{ .start = p.start, .end = p.end }) catch return false;
    defer s.gpa.free(first);
    for (ses.ranges.items) |r| {
        if (r.end - r.start != p.end - p.start) return false;
        const t = doc.tree.copyRange(s.gpa, .{ .start = r.start, .end = r.end }) catch return false;
        defer s.gpa.free(t);
        if (!std.mem.eql(u8, t, first)) return false;
    }
    if (first.len == 0) return true;
    const re = &(ses.regex orelse return true);
    var in: zg_regex.Input = .fromSlice(first);
    in.anchored = true;
    const m = re.find(&ses.cache.?, in) orelse return false;
    return m.start == 0 and m.end == first.len;
}

/// Sends a due request and takes its answer; true when a session started
/// or ended.
pub fn tick(s: *LinkedEditingService, now_ms: u64) bool {
    const g = s.generation;
    if (s.asked) |a| for (s.req.take()) |ans| {
        if (ans.index != 0) continue;
        s.asked = null;
        s.onAnswer(a.h, a.pos, ans);
        break;
    };
    if (s.want) |w| if (now_ms >= w.due_ms and s.opts.enabled) {
        s.want = null;
        if (s.req.available(w.h)) {
            if ((s.req.ask(w.h, w.pos, .{}) catch 0) > 0) s.asked = .{ .h = w.h, .pos = w.pos };
        }
    };
    return s.generation != g;
}

fn onAnswer(s: *LinkedEditingService, h: DocHandle, pos: u64, a: *const Req.Answer) void {
    const doc = s.mgr.docs.get(h) orelse return;
    if (a.version != doc.version) return;
    const v = switch (a.result) {
        .ok => |o| o.value orelse return,
        else => return,
    };
    if (v.ranges.len < 2) return;
    var ses: Session = .{ .h = h, .version = doc.version };
    var m: position.Mapper = .{ .gpa = s.gpa, .tree = &doc.tree, .enc = position.encodingOf(a.client.encoding()) };
    defer m.deinit();
    var holds: ?usize = null;
    for (v.ranges) |r| {
        const br = m.toRange(r) catch return ses.deinit(s.gpa);
        if (pos >= br.start and pos <= br.end and holds == null) holds = ses.ranges.items.len;
        ses.ranges.append(s.gpa, br) catch return ses.deinit(s.gpa);
    }
    // The caret moved away meanwhile: nothing to mirror.
    ses.primary = holds orelse return ses.deinit(s.gpa);
    if (v.wordPattern) |pat| if (zg_regex.Regex.compile(s.gpa, pat, .{})) |re| {
        ses.regex = re;
        ses.cache = re.newCache(s.gpa) catch {
            ses.deinit(s.gpa);
            return;
        };
    } else |e| log.debug("wordPattern /{s}/ not supported ({t}); not checked", .{ pat, e });
    if (!s.check(&ses, doc)) return ses.deinit(s.gpa);
    s.end();
    s.session = ses;
    s.generation += 1;
}
