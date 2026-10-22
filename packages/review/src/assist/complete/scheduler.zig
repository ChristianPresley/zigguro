//! When to ask for a completion (E12.F07.S01.T01). The scheduler is a
//! clockless state machine on the UI thread: the host reports edits,
//! cursor moves, invokes and accepts with the current time, asks for
//! `nextDeadline` to arm its one timer, and `poll`s when it fires. Tests
//! drive it with a virtual clock.
//!
//! - Triggers: the user's own edits that insert at most 64 bytes, cursor
//!   moves on the same line within a second of an edit, an explicit
//!   invoke, and a speculative request right after an accept. Undo, redo,
//!   agent and LSP edits, large pastes and multi-cursor edits never
//!   trigger, and they cancel a pending one.
//! - Adaptive debounce: an EWMA of the gaps between keystrokes; the
//!   debounce is `clamp(min(debounce, 0.8 × ewma), min_debounce,
//!   debounce)`, so fast typists wait less and a pause fires at once.
//! - Single flight: one request per document. A keystroke while it
//!   streams keeps it when the typed text is how the answer so far starts
//!   (the shown text is then trimmed by it), and cancels it otherwise.
//! - Version safety: a result counts only for the request still in
//!   flight; anything older is dropped.
//!
//! No allocation per keystroke once a document is known.

const std = @import("std");

pub const EngineOptions = struct {
    debounce_ms: u16 = 60,
    min_debounce_ms: u16 = 0,
    speculative: bool = true,
    cache_entries: u16 = 512,
    cache_bytes: u32 = 4 << 20,
    /// Inserts larger than this never trigger (pastes).
    max_trigger_insert: u32 = 64,
    /// A cursor move triggers this long after an edit.
    move_window_ms: u32 = 1000,
};

/// Why no completion is asked for (`ok`: ask).
pub const Gate = enum {
    ok,
    excluded_by_policy,
    disabled_language,
    disabled_glob,
    snoozed,
    multi_cursor,
    selection_active,
    ime_composing,
    popup_open,
    read_only,
    too_large,
    mid_word_no_fim,
};

/// What `gate` looks at, filled in by the host from the editor's state.
pub const GateInput = struct {
    excluded: bool = false,
    language_disabled: bool = false,
    glob_disabled: bool = false,
    snoozed: bool = false,
    carets: u32 = 1,
    multi_cursor_allowed: bool = false,
    selection: bool = false,
    ime_composing: bool = false,
    /// The LSP completion popup is open.
    popup_open: bool = false,
    ghost_wins: bool = false,
    read_only: bool = false,
    doc_bytes: u64 = 0,
    /// The text right after the cursor, up to the end of its line.
    after: []const u8 = "",
    explicit: bool = false,
    /// The provider fills the middle (server-side or FIM template).
    fim: bool = true,
};

/// Documents over this many bytes get no completions.
pub const max_doc_bytes = 10 << 20;

/// The first reason not to ask, cheapest checks first.
pub fn gate(in: GateInput) Gate {
    if (in.excluded) return .excluded_by_policy;
    if (in.language_disabled) return .disabled_language;
    if (in.glob_disabled) return .disabled_glob;
    if (in.snoozed) return .snoozed;
    if (in.carets > 1 and !in.multi_cursor_allowed) return .multi_cursor;
    if (in.selection) return .selection_active;
    if (in.ime_composing) return .ime_composing;
    if (in.popup_open and !in.ghost_wins) return .popup_open;
    if (in.read_only) return .read_only;
    if (in.doc_bytes > max_doc_bytes) return .too_large;
    if (in.after.len > 0 and !in.explicit) {
        if (isIdent(in.after[0])) return .mid_word_no_fim;
        if (!in.fim and !onlyClosers(in.after)) return .mid_word_no_fim;
    }
    return .ok;
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn onlyClosers(s: []const u8) bool {
    for (s) |c| switch (c) {
        ' ', '\t', '\r', '\n', ')', ']', '}', ';', ',', '"', '\'', '`' => {},
        else => return false,
    };
    return true;
}

pub const Origin = enum { user, undo, redo, agent, lsp, paste, other };

pub const Edit = struct {
    origin: Origin,
    inserted: u32,
    carets: u32 = 1,
    version: u64,
};

/// A request to start.
pub const Trigger = struct {
    doc: u64,
    version: u64,
    explicit: bool = false,
    speculative: bool = false,
};

/// What to do with the request in flight after a keystroke.
pub const InflightAction = union(enum) {
    none,
    /// Keep it; hide this many bytes of its answer (already typed).
    keep: u32,
    /// Cancel request `id`.
    cancel: u64,
};

const ns_per_ms = std.time.ns_per_ms;

/// Bytes typed during one request that keep it alive.
pub const max_typed = 256;

const Inflight = struct {
    id: u64,
    version: u64,
    speculative: bool,
    typed: [max_typed]u8 = undefined,
    typed_len: u16 = 0,
};

const DocState = struct {
    version: u64 = 0,
    ewma_ns: ?f64 = null,
    last_key_ns: ?u64 = null,
    last_edit_ns: ?u64 = null,
    due_ns: ?u64 = null,
    explicit: bool = false,
    speculative: bool = false,
    inflight: ?Inflight = null,
};

pub const Scheduler = struct {
    gpa: std.mem.Allocator,
    opts: EngineOptions,
    docs: std.AutoHashMapUnmanaged(u64, DocState) = .empty,

    pub fn init(gpa: std.mem.Allocator, opts: EngineOptions) Scheduler {
        return .{ .gpa = gpa, .opts = opts };
    }

    pub fn deinit(s: *Scheduler) void {
        s.docs.deinit(s.gpa);
    }

    /// Registers a document (the only allocation).
    pub fn open(s: *Scheduler, doc: u64, version: u64) !void {
        const gop = try s.docs.getOrPut(s.gpa, doc);
        if (!gop.found_existing) gop.value_ptr.* = .{ .version = version };
    }

    pub fn close(s: *Scheduler, doc: u64) void {
        _ = s.docs.remove(doc);
    }

    /// The debounce for `doc` now, in ns.
    pub fn debounceNs(s: *const Scheduler, doc: u64) u64 {
        const max: u64 = @as(u64, s.opts.debounce_ms) * ns_per_ms;
        const min: u64 = @as(u64, s.opts.min_debounce_ms) * ns_per_ms;
        const st = s.docs.get(doc) orelse return max;
        const ewma = st.ewma_ns orelse return max;
        const adaptive: u64 = @intFromFloat(0.8 * ewma);
        return std.math.clamp(@min(max, adaptive), min, max);
    }

    /// An edit to `doc`. A pending trigger is replaced. An edit that may
    /// not trigger drops it and cancels the request in flight (returned);
    /// for the user's typing the caller settles that request with `typed`.
    pub fn onEdit(s: *Scheduler, doc: u64, e: Edit, now: u64) InflightAction {
        const st = s.docs.getPtr(doc) orelse return .none;
        st.version = e.version;
        const triggers = e.origin == .user and e.inserted <= s.opts.max_trigger_insert and e.carets == 1;
        if (!triggers) {
            st.due_ns = null;
            st.last_edit_ns = null;
            return s.cancelInflight(doc);
        }
        if (st.last_key_ns) |last| {
            const gap: f64 = @floatFromInt(now -| last);
            // Gaps over 2 s are pauses, not typing speed.
            if (gap < 2 * std.time.ns_per_s) st.ewma_ns = if (st.ewma_ns) |w| 0.7 * w + 0.3 * gap else gap;
        }
        st.last_key_ns = now;
        st.last_edit_ns = now;
        st.explicit = false;
        st.speculative = false;
        st.due_ns = now + s.debounceNs(doc);
        return .none;
    }

    /// The cursor moved; `same_line` when it stayed on its line.
    pub fn onCursorMove(s: *Scheduler, doc: u64, same_line: bool, now: u64) void {
        const st = s.docs.getPtr(doc) orelse return;
        const recent = if (st.last_edit_ns) |t| now -| t <= @as(u64, s.opts.move_window_ms) * ns_per_ms else false;
        if (same_line and recent) {
            st.due_ns = now + s.debounceNs(doc);
        } else {
            st.due_ns = null;
        }
    }

    /// The user asked for a completion: now.
    pub fn invoke(s: *Scheduler, doc: u64, now: u64) void {
        const st = s.docs.getPtr(doc) orelse return;
        st.due_ns = now;
        st.explicit = true;
        st.speculative = false;
    }

    /// A completion was accepted whole: ask for the next one now, at low
    /// priority (any keystroke replaces it).
    pub fn accepted(s: *Scheduler, doc: u64, version: u64, now: u64) void {
        const st = s.docs.getPtr(doc) orelse return;
        st.version = version;
        if (!s.opts.speculative) return;
        st.due_ns = now;
        st.explicit = false;
        st.speculative = true;
    }

    /// Drops a pending trigger (focus lost, gate closed).
    pub fn disarm(s: *Scheduler, doc: u64) void {
        if (s.docs.getPtr(doc)) |st| st.due_ns = null;
    }

    /// When the next trigger is due, for the host's timer.
    pub fn nextDeadline(s: *const Scheduler) ?u64 {
        var best: ?u64 = null;
        var it = s.docs.valueIterator();
        while (it.next()) |st| if (st.due_ns) |d| {
            if (best == null or d < best.?) best = d;
        };
        return best;
    }

    /// The triggers due at `now`, at most `out.len`; returns how many.
    pub fn poll(s: *Scheduler, now: u64, out: []Trigger) usize {
        var n: usize = 0;
        var it = s.docs.iterator();
        while (it.next()) |e| {
            if (n == out.len) break;
            const st = e.value_ptr;
            const d = st.due_ns orelse continue;
            if (d > now) continue;
            st.due_ns = null;
            out[n] = .{ .doc = e.key_ptr.*, .version = st.version, .explicit = st.explicit, .speculative = st.speculative };
            n += 1;
        }
        return n;
    }

    /// Request `id` for `t` is on its way; returns the one it replaces,
    /// which the caller cancels.
    pub fn started(s: *Scheduler, t: Trigger, id: u64) ?u64 {
        const st = s.docs.getPtr(t.doc) orelse return null;
        const old = if (st.inflight) |f| f.id else null;
        st.inflight = .{ .id = id, .version = t.version, .speculative = t.speculative };
        return old;
    }

    /// The request in flight for `doc`, if any.
    pub fn inflight(s: *const Scheduler, doc: u64) ?u64 {
        const st = s.docs.get(doc) orelse return null;
        return if (st.inflight) |f| f.id else null;
    }

    /// The user typed `text` at the cursor while a request is in flight
    /// and its answer so far is `streamed`. A speculative request always
    /// goes; otherwise it stays while the typed text is how the answer
    /// starts.
    pub fn typed(s: *Scheduler, doc: u64, text: []const u8, streamed: []const u8) InflightAction {
        const st = s.docs.getPtr(doc) orelse return .none;
        const f = &(st.inflight orelse return .none);
        const total = @as(usize, f.typed_len) + text.len;
        if (f.speculative or total > max_typed or total > streamed.len) return s.cancelInflight(doc);
        @memcpy(f.typed[f.typed_len..total], text);
        f.typed_len = @intCast(total);
        if (!std.mem.startsWith(u8, streamed, f.typed[0..total])) return s.cancelInflight(doc);
        return .{ .keep = f.typed_len };
    }

    /// Forgets the request in flight; returns it for the caller to cancel.
    pub fn cancelInflight(s: *Scheduler, doc: u64) InflightAction {
        const st = s.docs.getPtr(doc) orelse return .none;
        const f = st.inflight orelse return .none;
        st.inflight = null;
        return .{ .cancel = f.id };
    }

    /// Request `id` finished. Returns how many bytes of its answer the
    /// user already typed, or null when the result is stale (another
    /// request replaced it, or the document moved on otherwise).
    pub fn finished(s: *Scheduler, doc: u64, id: u64) ?u32 {
        const st = s.docs.getPtr(doc) orelse return null;
        const f = st.inflight orelse return null;
        if (f.id != id) return null;
        st.inflight = null;
        return f.typed_len;
    }
};
