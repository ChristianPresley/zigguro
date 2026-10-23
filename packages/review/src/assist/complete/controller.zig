//! The ghost-text controller (E12.F07.S01.T04): one per editor. It turns
//! the engine's deliveries into E05 `GhostText`, follows the user's typing,
//! and handles accept, dismiss, the LSP popup, snooze and the status bar.
//!
//! - Each delivery is post-processed (cache hits too). A drop while
//!   streaming keeps the current ghost; a final drop removes it.
//! - Typing the start of the ghost consumes it (`GhostText.onType`) and
//!   tells the engine, which keeps the request in flight.
//! - `accept` returns false when no ghost is visible, so the command system
//!   runs the next binding for Tab (indent, snippet). An accept is one undo
//!   group with the completion's origin; accepting all of it asks for the
//!   next completion at once (speculative).
//! - While the LSP completion popup is open the ghost is hidden, unless the
//!   ghost wins. It comes back when the popup closes if the document did
//!   not change meanwhile.
//! - Snooze adds 5 minutes each time.
//!
//! The host forwards the document's changes (`onChange`, after the
//! decoration store's listener), cursor moves, focus and the popup state,
//! and passes the current time in ns.

const std = @import("std");
const zg_editor = @import("zg_editor");
const engine_mod = @import("engine.zig");
const scheduler = @import("scheduler.zig");
const postprocess = @import("postprocess.zig");
const telemetry = @import("telemetry.zig");

const Allocator = std.mem.Allocator;
const model = zg_editor.model;
const Document = model.document.Document;
const ChangeEvent = model.document.ChangeEvent;
const EditOrigin = model.document.EditOrigin;
const DecorationStore = model.decorations.store.DecorationStore;
const OwnerId = model.decorations.store.OwnerId;
const GhostText = model.decorations.ghost.GhostText;

pub const AcceptPart = model.decorations.ghost.AcceptPart;
pub const DismissReason = enum { escape, cursor_moved, popup_opened, edit_inconsistent, focus_lost };

pub const Status = enum { ready, requesting, snoozed, disabled_language, unhealthy };

pub const snooze_step_ns: u64 = 5 * std.time.ns_per_min;

pub const Options = struct {
    /// The ghost stays visible while the LSP popup is open.
    ghost_wins: bool = false,
    /// The origin of accept edits (their undo group).
    origin: EditOrigin = .{ .agent = 0 },
};

pub const Controller = struct {
    gpa: Allocator,
    doc: *Document,
    doc_id: u64,
    store: *DecorationStore,
    source: OwnerId,
    engine: *engine_mod.CompletionEngine,
    opts: Options,
    ghost: ?GhostText = null,
    /// The text of a ghost hidden by the popup, and the version it was
    /// hidden at.
    hidden: ?struct { at: u64, version: u64, text: []u8 } = null,
    shown_for: u64 = 0,
    snooze_until_ns: u64 = 0,
    language_disabled: bool = false,
    unhealthy: bool = false,
    stats: telemetry.Telemetry = .{},
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: Allocator, doc: *Document, doc_id: u64, store: *DecorationStore, source: OwnerId, engine: *engine_mod.CompletionEngine, opts: Options) Controller {
        return .{ .gpa = gpa, .doc = doc, .doc_id = doc_id, .store = store, .source = source, .engine = engine, .opts = opts, .arena = .init(gpa) };
    }

    pub fn deinit(c: *Controller) void {
        c.drop();
        c.dropHidden();
        c.arena.deinit();
    }

    /// A ghost is showing (the `ghostVisible` command context).
    pub fn visible(c: *const Controller) bool {
        return if (c.ghost) |g| g.visible else false;
    }

    /// The ghost's remaining text ("" when none).
    pub fn text(c: *const Controller) []const u8 {
        return if (c.ghost) |*g| (if (g.visible) g.remaining() else "") else "";
    }

    pub fn snoozed(c: *const Controller, now_ns: u64) bool {
        return now_ns < c.snooze_until_ns;
    }

    /// Snoozes 5 more minutes (from now, or from the current end).
    pub fn snooze(c: *Controller, now_ns: u64) void {
        c.snooze_until_ns = @max(now_ns, c.snooze_until_ns) + snooze_step_ns;
        c.dismiss(.escape);
    }

    pub fn status(c: *const Controller, now_ns: u64) Status {
        if (c.language_disabled) return .disabled_language;
        if (c.snoozed(now_ns)) return .snoozed;
        if (c.unhealthy) return .unhealthy;
        if (c.engine.sched.inflight(c.doc_id) != null) return .requesting;
        return .ready;
    }

    /// The engine delivered a completion (wire `Host.deliver` here).
    pub fn onDelivery(c: *Controller, d: engine_mod.Delivery, now_ns: u64) !void {
        if (d.doc != c.doc_id or d.version != c.doc.version) return;
        c.unhealthy = false;
        _ = c.arena.reset(.retain_capacity);
        const res = try postprocess.postprocess(c.arena.allocator(), d.request, d.text, d.final);
        const shown = switch (res) {
            .drop => {
                if (d.final) c.drop();
                return;
            },
            .show => |s| s,
        };
        // The user already typed `hide` bytes of it.
        if (d.hide > 0 and !std.mem.startsWith(u8, shown, d.text[0..@min(d.hide, d.text.len)])) return;
        const rest = shown[@min(d.hide, shown.len)..];
        if (rest.len == 0) {
            if (d.final) c.drop();
            return;
        }
        if (c.ghost) |*g| if (g.visible and std.mem.eql(u8, g.remaining(), rest)) return;
        c.drop();
        c.ghost = try GhostText.show(c.gpa, c.doc, c.store, d.at + d.hide, rest, .{
            .request_id = d.request_id,
            .source = c.source,
            .origin = c.opts.origin,
        });
        if (c.shown_for != d.request_id) {
            c.shown_for = d.request_id;
            c.stats.recordShown((now_ns -| d.started_ns) / std.time.ns_per_ms);
        }
    }

    /// The provider failed (wire `Host.failed` here).
    pub fn onFailed(c: *Controller) void {
        c.unhealthy = true;
    }

    /// A document change (forward from the document listener, after the
    /// decoration store's).
    pub fn onChange(c: *Controller, ev: *const ChangeEvent, now_ns: u64) !void {
        const rs = ev.changes.replaces;
        var inserted: u32 = 0;
        for (rs) |r| inserted +|= @intCast(r.text.len);
        const origin: scheduler.Origin = switch (ev.origin) {
            .user => .user,
            .undo => .undo,
            .redo => .redo,
            .agent => .agent,
            .lsp_edit, .format => .lsp,
            .reload => .other,
        };
        // Our own accept: the engine hears about it from `accept`.
        if (c.ghost) |g| if (g.applying) return;
        c.engine.onEdit(c.doc_id, .{ .origin = origin, .inserted = inserted, .carets = @intCast(@max(rs.len, 1)), .version = ev.new_version }, now_ns);
        if (origin == .user and rs.len == 1 and rs[0].range.start == rs[0].range.end) c.engine.typed(c.doc_id, rs[0].text);
        if (c.hidden != null) c.dropHidden();
        if (c.ghost) |*g| {
            if (try g.onType(ev) == .dismissed) c.drop();
        }
    }

    /// The caret moved without an edit (not for the move an edit makes).
    pub fn onCursorMove(c: *Controller, same_line: bool, now_ns: u64) void {
        c.engine.onCursorMove(c.doc_id, same_line, now_ns);
        if (c.ghost) |g| if (g.visible and !g.applying) c.dismiss(.cursor_moved);
    }

    /// Accepts all of the ghost, its next word or its next line. False
    /// when no ghost is visible (Tab falls through).
    pub fn accept(c: *Controller, part: AcceptPart, now_ns: u64) !bool {
        const g = if (c.ghost) |*g| g else return false;
        if (!g.visible) return false;
        const before = g.remaining().len;
        _ = try g.accept(part);
        const left = if (g.visible) g.remaining().len else 0;
        const full = left == 0;
        c.stats.recordAccept(full, before - left);
        if (full) {
            c.drop();
            c.engine.accepted(c.doc_id, c.doc.version, now_ns);
        }
        return true;
    }

    pub fn dismiss(c: *Controller, why: DismissReason) void {
        switch (why) {
            .popup_opened => {
                if (c.opts.ghost_wins) return;
                const g = if (c.ghost) |*g| g else return;
                if (!g.visible) return;
                c.dropHidden();
                if (c.gpa.dupe(u8, g.remaining())) |copy| {
                    c.hidden = .{ .at = g.at, .version = c.doc.version, .text = copy };
                } else |_| {}
                c.drop();
            },
            .escape, .focus_lost => {
                c.drop();
                c.engine.dismiss(c.doc_id);
            },
            .cursor_moved, .edit_inconsistent => c.drop(),
        }
    }

    /// The LSP popup closed: brings back a hidden ghost if nothing changed.
    pub fn popupClosed(c: *Controller) !void {
        const h = c.hidden orelse return;
        defer c.dropHidden();
        if (h.version != c.doc.version or c.ghost != null) return;
        c.ghost = try GhostText.show(c.gpa, c.doc, c.store, h.at, h.text, .{
            .request_id = c.shown_for,
            .source = c.source,
            .origin = c.opts.origin,
        });
    }

    fn drop(c: *Controller) void {
        if (c.ghost) |*g| g.deinit();
        c.ghost = null;
    }

    fn dropHidden(c: *Controller) void {
        if (c.hidden) |h| c.gpa.free(h.text);
        c.hidden = null;
    }
};
