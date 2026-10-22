//! AgentEditSession: the agent-facing edit API for one agent session.
//!
//! Agents read version-stamped text and propose edits in four forms: a
//! ChangeSet at a version, line edits, `str_replace`, or a whole new file.
//! A proposal is validated, rebased onto the current version (rejecting it
//! with the conflicting ranges when the user changed the same text since),
//! and then applied, turned into a `PendingChange`, or denied, as the
//! session's `ApplyPolicy` (E12/E16) decides. Every rejection says what to
//! do next (re-read, which ranges conflict, how many matches).

const std = @import("std");
const zg_regex = @import("zg_regex");
const pt = @import("../buffer/piece_tree.zig");
const cs_mod = @import("../edit/change_set.zig");
const document = @import("../document.zig");
const Snapshot = @import("../snapshot.zig").Snapshot;
const diff = @import("../diff.zig");
const find = @import("../search/find.zig");
const store_mod = @import("../decorations/store.zig");
const pending_mod = @import("../decorations/pending.zig");
const registry = @import("registry.zig");
const text_query = @import("text_query.zig");

const Allocator = std.mem.Allocator;
const Range = pt.Range;
const PieceTree = pt.PieceTree;
const ChangeSet = cs_mod.ChangeSet;
const Document = document.Document;
const DocHandle = registry.DocHandle;
const DocumentRegistry = registry.DocumentRegistry;
const PendingChange = pending_mod.PendingChange;

pub const LineRange = text_query.LineRange;
pub const ReadOptions = text_query.ReadOptions;
pub const ReadResult = text_query.ReadResult;

/// Replace lines `[start_line, end_line)` (0-based) with `new_text`.
pub const LineEdit = struct { start_line: u64, end_line: u64, new_text: []const u8 };

/// Which matches `str_replace` replaces.
pub const Occurrence = union(enum) {
    /// Exactly one match, else `not_found` or `not_unique`.
    unique,
    all,
    /// The n-th match, 0-based.
    nth: u32,
};

pub const Proposal = union(enum) {
    change_set: struct { cs: *const ChangeSet, base_version: u64 },
    line_edits: struct { edits: []const LineEdit, base_version: u64 },
    /// Exact bytes, case-sensitive, may span lines; searched in the current
    /// text.
    str_replace: struct { old: []const u8, new: []const u8, occurrence: Occurrence = .unique },
    /// Becomes a minimal line diff, so undo and review see small hunks.
    whole_file: struct { text: []const u8, base_version: ?u64 = null },
};

/// What the policy sees.
pub const ProposalSummary = struct {
    tool: []const u8,
    uri: []const u8,
    hunks: usize,
    inserted_bytes: u64,
    deleted_bytes: u64,
};

pub const Decision = enum { apply, pending, deny };

/// Decides what happens to a valid proposal (E12/E16 supply it).
pub const ApplyPolicy = struct {
    ctx: *anyopaque,
    decide: *const fn (ctx: *anyopaque, session: u64, doc: DocHandle, summary: ProposalSummary) Decision,
};

/// Where pending changes are shown: the document's decoration store and
/// the owner to use for a new change, and who takes ownership of it.
pub const PendingPlace = struct { store: *store_mod.DecorationStore, owner: store_mod.OwnerId };

pub const PendingHost = struct {
    ctx: *anyopaque,
    place: *const fn (ctx: *anyopaque, doc: DocHandle) ?PendingPlace,
    /// The host now owns `change` (routes change events to it, destroys it).
    created: *const fn (ctx: *anyopaque, doc: DocHandle, change: *PendingChange) void,
};

/// Sent for every applied agent edit (E12 review history, E16 audit log).
/// Slices are valid during the callback.
pub const AgentEditApplied = struct {
    session: u64,
    doc: DocHandle,
    version: u64,
    /// Changed ranges in the new version.
    ranges: []const Range,
    /// "Agent <session> <tool>", the undo group label.
    label: []const u8,
};

pub const AppliedListener = struct {
    ctx: *anyopaque,
    onApplied: *const fn (ctx: *anyopaque, ev: *const AgentEditApplied) void,
};

pub const Rejection = union(enum) {
    stale_handle,
    read_only,
    /// The base version is no longer in the change log: re-read.
    stale_version_evicted: struct { base_version: u64, current_version: u64 },
    too_large: struct { inserted_bytes: u64, limit: u64 },
    /// An edit is outside the text at its base version.
    out_of_bounds: struct { len: u64 },
    overlapping_edits,
    /// The user changed the same text since the base version; ranges are in
    /// current coordinates.
    conflict: struct { ranges: []Range },
    not_found,
    not_unique: struct { count: u64 },
    /// `nth` asked for a match past the last one.
    no_such_occurrence: struct { count: u64 },
    denied,
    /// The policy chose pending but there is nowhere to show it.
    no_pending_host,
};

pub const Outcome = union(enum) {
    applied: struct { version: u64, ranges: []Range, crlf_adjusted: bool = false },
    pending: struct { change: *PendingChange, crlf_adjusted: bool = false },
    rejected: Rejection,

    /// Frees the ranges (a pending change belongs to the host).
    pub fn deinit(o: *Outcome, gpa: Allocator) void {
        switch (o.*) {
            .applied => |a| gpa.free(a.ranges),
            .rejected => |r| switch (r) {
                .conflict => |c| gpa.free(c.ranges),
                else => {},
            },
            .pending => {},
        }
    }
};

/// The edit API of one agent session.
pub const AgentEditSession = struct {
    gpa: Allocator,
    reg: *DocumentRegistry,
    session: u64,
    policy: ApplyPolicy,
    pending_host: ?PendingHost = null,
    /// Most inserted text one proposal may carry.
    max_inserted: u64 = 10 << 20,
    listeners: std.ArrayList(AppliedListener) = .empty,
    /// The last version read per document, kept so line edits and
    /// whole-file proposals against it can be rebased.
    reads: std.AutoHashMapUnmanaged(u32, Snapshot) = .empty,

    pub fn init(gpa: Allocator, reg: *DocumentRegistry, session: u64, policy: ApplyPolicy) AgentEditSession {
        return .{ .gpa = gpa, .reg = reg, .session = session, .policy = policy };
    }

    pub fn deinit(s: *AgentEditSession) void {
        var it = s.reads.valueIterator();
        while (it.next()) |snap| snap.release();
        s.reads.deinit(s.gpa);
        s.listeners.deinit(s.gpa);
    }

    pub fn subscribe(s: *AgentEditSession, l: AppliedListener) Allocator.Error!void {
        try s.listeners.append(s.gpa, l);
    }

    /// Reads lines of the current version and remembers it as this
    /// session's base for the document.
    pub fn readLines(s: *AgentEditSession, h: DocHandle, range: ?LineRange, o: ReadOptions, gpa: Allocator) (Allocator.Error || error{StaleHandle})!ReadResult {
        const doc = s.reg.get(h) orelse return error.StaleHandle;
        try s.remember(h, doc);
        return text_query.readLines(gpa, doc.tree, doc.version, range, o);
    }

    fn remember(s: *AgentEditSession, h: DocHandle, doc: *Document) Allocator.Error!void {
        const gop = try s.reads.getOrPut(s.gpa, @intFromEnum(h.id));
        if (gop.found_existing) {
            if (gop.value_ptr.version == doc.version and gop.value_ptr.doc_id == doc.id) return;
            gop.value_ptr.release();
        }
        gop.value_ptr.* = doc.snapshot();
    }

    /// The tree of `h` at `version`: current, or the last version read.
    fn treeAt(s: *AgentEditSession, h: DocHandle, doc: *Document, version: u64) ?PieceTree {
        if (version == doc.version) return doc.tree;
        const snap = s.reads.getPtr(@intFromEnum(h.id)) orelse return null;
        if (snap.version != version or snap.doc_id != doc.id) return null;
        return snap.tree;
    }

    /// Validates, rebases and applies (or queues, or denies) a proposal.
    /// `tool` names the agent tool for labels and the policy.
    pub fn propose(s: *AgentEditSession, h: DocHandle, p: Proposal, tool: []const u8) !Outcome {
        const doc = s.reg.get(h) orelse return .{ .rejected = .stale_handle };
        if (s.reg.isReadOnly(h)) return .{ .rejected = .read_only };
        var crlf_adjusted = false;
        // 1. A ChangeSet at some base version.
        var owned: ChangeSet, const base_version: u64 = switch (p) {
            .change_set => |c| .{ try c.cs.clone(s.gpa), c.base_version },
            .line_edits => |l| blk: {
                const t = s.treeAt(h, doc, l.base_version) orelse return stale(l.base_version, doc);
                const edits = try s.gpa.alloc(pt.Edit, l.edits.len);
                defer s.gpa.free(edits);
                for (l.edits, edits) |le, *e| {
                    if (le.end_line < le.start_line) return .{ .rejected = .{ .out_of_bounds = .{ .len = text_query.lineCount(t) } } };
                    e.* = .{ .range = text_query.lineBytes(t, le.start_line, le.end_line), .text = le.new_text };
                }
                break :blk .{ ChangeSet.fromEdits(s.gpa, t.len(), edits) catch |e| return .{ .rejected = try fromEditsRejection(e, t.len()) }, l.base_version };
            },
            .str_replace => |r| blk: {
                var res = try s.strReplace(doc, r.old, r.new, r.occurrence);
                switch (res) {
                    .ok => |*ok| {
                        crlf_adjusted = ok.crlf_adjusted;
                        break :blk .{ ok.cs, doc.version };
                    },
                    .rejected => |rej| return .{ .rejected = rej },
                }
            },
            .whole_file => |w| blk: {
                const v = w.base_version orelse doc.version;
                const t = s.treeAt(h, doc, v) orelse return stale(v, doc);
                break :blk .{ try minimalChange(s.gpa, t, w.text), v };
            },
        };
        defer owned.deinit();
        if (owned.insertedBytes() > s.max_inserted) return .{ .rejected = .{ .too_large = .{ .inserted_bytes = owned.insertedBytes(), .limit = s.max_inserted } } };
        // 2. Rebase onto the current version.
        var cs = switch (try s.rebase(doc, &owned, base_version)) {
            .ok => |c| c,
            .rejected => |rej| return .{ .rejected = rej },
        };
        defer cs.deinit();
        if (cs.isIdentity()) return .{ .applied = .{ .version = doc.version, .ranges = &.{}, .crlf_adjusted = crlf_adjusted } };
        // 3. Ask the policy.
        const summary: ProposalSummary = .{
            .tool = tool,
            .uri = s.reg.uri(h).?,
            .hunks = cs.replaces.len,
            .inserted_bytes = cs.insertedBytes(),
            .deleted_bytes = cs.deletedBytes(),
        };
        var label_buf: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "Agent {d} {s}", .{ s.session, tool }) catch label_buf[0..];
        switch (s.policy.decide(s.policy.ctx, s.session, h, summary)) {
            .deny => return .{ .rejected = .denied },
            .pending => {
                const host = s.pending_host orelse return .{ .rejected = .no_pending_host };
                const place = host.place(host.ctx, h) orelse return .{ .rejected = .no_pending_host };
                const change = try PendingChange.create(s.gpa, doc, place.store, place.owner, &cs, doc.version, label, s.origin(), .{});
                host.created(host.ctx, h, change);
                return .{ .pending = .{ .change = change, .crlf_adjusted = crlf_adjusted } };
            },
            .apply => {
                const ranges = try s.gpa.alloc(Range, cs.replaces.len);
                errdefer s.gpa.free(ranges);
                for (cs.replaces, cs.new_starts, ranges) |r, ns, *out| out.* = .{ .start = ns, .end = ns + r.text.len };
                try doc.applyChangeSet(&cs, s.origin());
                const ev: AgentEditApplied = .{ .session = s.session, .doc = h, .version = doc.version, .ranges = ranges, .label = label };
                for (s.listeners.items) |l| l.onApplied(l.ctx, &ev);
                return .{ .applied = .{ .version = doc.version, .ranges = ranges, .crlf_adjusted = crlf_adjusted } };
            },
        }
    }

    fn origin(s: *const AgentEditSession) document.EditOrigin {
        return .{ .agent = @truncate(s.session) };
    }

    const Rebased = union(enum) { ok: ChangeSet, rejected: Rejection };

    /// `cs` (at `base`) transformed through everything since, with the
    /// user winning ties; conflicting replaces are reported.
    fn rebase(s: *AgentEditSession, doc: *Document, cs: *const ChangeSet, base: u64) !Rebased {
        if (base == doc.version) {
            if (cs.base_len != doc.len()) return .{ .rejected = .{ .out_of_bounds = .{ .len = doc.len() } } };
            return .{ .ok = try cs.clone(s.gpa) };
        }
        var since = (try doc.change_log.compose(base, doc.version, s.gpa)) orelse return .{ .rejected = stale(base, doc).rejected };
        defer since.deinit();
        if (since.base_len != cs.base_len) return .{ .rejected = .{ .out_of_bounds = .{ .len = since.base_len } } };
        var t = try cs.transform(&since, false, s.gpa);
        if (!t.conflicted) return .{ .ok = t };
        t.deinit();
        // Report which replaces conflict, in current coordinates.
        var ranges: std.ArrayList(Range) = .empty;
        errdefer ranges.deinit(s.gpa);
        for (cs.replaces) |r| {
            var one = ChangeSet.fromEdits(s.gpa, cs.base_len, &.{r}) catch unreachable;
            defer one.deinit();
            var x = try one.transform(&since, false, s.gpa);
            defer x.deinit();
            if (!x.conflicted) continue;
            const cur = since.mapRange(r.range, .expand) orelse blk: {
                const p = since.mapPos(r.range.start, .left);
                break :blk Range{ .start = p, .end = p };
            };
            try ranges.append(s.gpa, cur);
        }
        return .{ .rejected = .{ .conflict = .{ .ranges = try ranges.toOwnedSlice(s.gpa) } } };
    }

    const StrResult = union(enum) { ok: struct { cs: ChangeSet, crlf_adjusted: bool }, rejected: Rejection };

    fn strReplace(s: *AgentEditSession, doc: *Document, old: []const u8, new: []const u8, occ: Occurrence) !StrResult {
        if (old.len == 0) return .{ .rejected = .not_found };
        var matches = try findAll(s.gpa, &doc.tree, old);
        defer matches.deinit(s.gpa);
        var adjusted_old: ?[]u8 = null;
        defer if (adjusted_old) |x| s.gpa.free(x);
        var adjusted_new: ?[]u8 = null;
        defer if (adjusted_new) |x| s.gpa.free(x);
        if (matches.items.len == 0) {
            // Agents often send LF snippets for CRLF files (and the other
            // way round): retry once with the document's line endings.
            const crlf_doc = usesCrlf(&doc.tree);
            const want_crlf = crlf_doc and std.mem.indexOfScalar(u8, old, '\n') != null and std.mem.indexOf(u8, old, "\r\n") == null;
            const want_lf = !crlf_doc and std.mem.indexOf(u8, old, "\r\n") != null;
            if (want_crlf or want_lf) {
                adjusted_old = try convertEol(s.gpa, old, want_crlf);
                adjusted_new = try convertEol(s.gpa, new, want_crlf);
                matches.deinit(s.gpa);
                matches = try findAll(s.gpa, &doc.tree, adjusted_old.?);
            }
        }
        const n = matches.items.len;
        const text = adjusted_new orelse new;
        const picked: []const Range = switch (occ) {
            .unique => if (n == 0) return .{ .rejected = .not_found } else if (n > 1) return .{ .rejected = .{ .not_unique = .{ .count = n } } } else matches.items,
            .all => if (n == 0) return .{ .rejected = .not_found } else matches.items,
            .nth => |i| if (i >= n) return .{ .rejected = .{ .no_such_occurrence = .{ .count = n } } } else matches.items[i..][0..1],
        };
        const edits = try s.gpa.alloc(pt.Edit, picked.len);
        defer s.gpa.free(edits);
        for (picked, edits) |r, *e| e.* = .{ .range = r, .text = text };
        const cs = ChangeSet.fromEdits(s.gpa, doc.len(), edits) catch |e| return .{ .rejected = try fromEditsRejection(e, doc.len()) };
        return .{ .ok = .{ .cs = cs, .crlf_adjusted = adjusted_old != null } };
    }

    /// The outline of the current text in `lang` (null: no structure).
    pub fn outline(s: *AgentEditSession, h: DocHandle, lang: *const @import("zg_syntax").Language, gpa: Allocator) !?@import("zg_syntax").Structure {
        const doc = s.reg.get(h) orelse return error.StaleHandle;
        var snap = doc.snapshot();
        defer snap.release();
        return @import("../syntax.zig").parseStructure(gpa, lang, &snap);
    }
};

/// The scope enclosing `line` in `structure` (innermost first), for AI
/// context chunking.
pub fn enclosingScope(gpa: Allocator, t: PieceTree, structure: *const @import("zg_syntax").Structure, line: u64) Allocator.Error!?@import("zg_syntax").Scope {
    const pos = t.lineStart(line);
    var out: std.ArrayList(@import("zg_syntax").Scope) = .empty;
    defer out.deinit(gpa);
    try structure.enclosingScopes(gpa, @intCast(@min(pos, std.math.maxInt(u32))), &out);
    return if (out.items.len > 0) out.items[0] else null;
}

fn stale(base: u64, doc: *const Document) Outcome {
    return .{ .rejected = .{ .stale_version_evicted = .{ .base_version = base, .current_version = doc.version } } };
}

fn fromEditsRejection(e: cs_mod.FromEditsError, len: u64) Allocator.Error!Rejection {
    return switch (e) {
        error.Overlap => .overlapping_edits,
        error.OutOfBounds => .{ .out_of_bounds = .{ .len = len } },
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Every non-overlapping occurrence of `needle` (exact bytes).
fn findAll(gpa: Allocator, t: *const PieceTree, needle: []const u8) !std.ArrayList(Range) {
    var out: std.ArrayList(Range) = .empty;
    errdefer out.deinit(gpa);
    var re = zg_regex.Regex.compile(gpa, needle, .{ .literal = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // literals always compile
    };
    defer re.deinit(gpa);
    var cache = try re.newCache(gpa);
    defer cache.deinit();
    var it = re.findIter(&cache, find.treeInput(t));
    while (it.next()) |m| try out.append(gpa, .{ .start = m.start, .end = m.end });
    return out;
}

/// Whether the text's first line break is CRLF.
fn usesCrlf(t: *const PieceTree) bool {
    if (t.lineCount() < 2) return false;
    const next = t.lineStart(1);
    return next >= 2 and t.byteAt(next - 2) == '\r';
}

fn convertEol(gpa: Allocator, s: []const u8, to_crlf: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (to_crlf) {
            if (s[i] == '\n' and (i == 0 or s[i - 1] != '\r')) try out.append(gpa, '\r');
            try out.append(gpa, s[i]);
        } else {
            if (s[i] == '\r' and i + 1 < s.len and s[i + 1] == '\n') continue;
            try out.append(gpa, s[i]);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The ChangeSet from `t` to `new_text`, one replace per line-diff hunk.
pub fn minimalChange(gpa: Allocator, t: PieceTree, new_text: []const u8) !ChangeSet {
    var a = try diff.LineSource.fromTree(gpa, t);
    defer a.deinit(gpa);
    var b = try diff.LineSource.fromBytes(gpa, new_text);
    defer b.deinit(gpa);
    var res = try diff.diffLines(gpa, &a, &b, .{ .intraline = .none, .context_lines = 0, .indent_heuristic = false });
    defer res.deinit(gpa);
    const edits = try gpa.alloc(pt.Edit, res.hunks.len);
    defer gpa.free(edits);
    for (res.hunks, edits) |hk, *e| {
        const old = spanBytes(&a, hk.old);
        const new = spanBytes(&b, hk.new);
        e.* = .{ .range = old, .text = new_text[@intCast(new.start)..@intCast(new.end)] };
    }
    var cs = ChangeSet.fromEdits(gpa, t.len(), edits) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // hunks are sorted and disjoint
    };
    // Lines compare without terminators, so a hunk next to a changed final
    // line break can be off; check, and fall back to one replace of the
    // differing middle.
    const got = try cs.applyToSlice(gpa, a.text);
    defer gpa.free(got);
    if (std.mem.eql(u8, got, new_text)) return cs;
    cs.deinit();
    const old = a.text;
    const pre = std.mem.indexOfDiff(u8, old, new_text) orelse @min(old.len, new_text.len);
    var suf: usize = 0;
    while (suf < old.len - pre and suf < new_text.len - pre and old[old.len - 1 - suf] == new_text[new_text.len - 1 - suf]) suf += 1;
    return ChangeSet.fromEdits(gpa, t.len(), &.{.{ .range = .{ .start = pre, .end = old.len - suf }, .text = new_text[pre .. new_text.len - suf] }}) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

fn spanBytes(src: *const diff.LineSource, span: diff.hunks.LineSpan) Range {
    const lines = src.lines;
    const a: u64 = if (span.start < lines.len) lines[@intCast(span.start)].start else src.text.len;
    const end = span.start + span.count;
    const b: u64 = if (end < lines.len) lines[@intCast(end)].start else src.text.len;
    return .{ .start = a, .end = b };
}
