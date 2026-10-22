//! Keeps comment threads on their lines when a changeset's texts change
//! without an agent revision (E12.F03.S03): a rebase onto another
//! changeset's apply, a partial apply, an undo, or another process's
//! record. Threads on the proposed text follow it, threads on removed
//! lines follow the base; those whose lines are gone go outdated (see
//! `CommentStore.reanchor`). Agent revisions are `Feedback`'s, which
//! also tags the threads they may address; running both is harmless.
//!
//! Owner thread (the queue's): `listener()` only notes which changesets
//! changed; `pump` re-anchors them.

const std = @import("std");
const model = @import("../model/root.zig");
const comments = @import("comments.zig");

const Allocator = std.mem.Allocator;
const ChangesetId = model.ChangesetId;
const CommentStore = comments.CommentStore;
const ReanchorReport = comments.ReanchorReport;

const log = std.log.scoped(.zg_review);

pub const Follow = struct {
    gpa: Allocator,
    q: *model.Queue,
    comments: *CommentStore,
    /// Changesets with threads that changed since the last `pump`.
    noted: std.ArrayList(ChangesetId) = .empty,

    pub fn init(gpa: Allocator, q: *model.Queue, cs: *CommentStore) Follow {
        return .{ .gpa = gpa, .q = q, .comments = cs };
    }

    pub fn deinit(f: *Follow) void {
        f.noted.deinit(f.gpa);
    }

    /// A queue listener that notes changed changesets for `pump`.
    pub fn listener(f: *Follow) model.Listener {
        return .{ .ctx = f, .on = onEvent };
    }

    fn onEvent(ctx: *anyopaque, ev: *const model.Event) void {
        const f: *Follow = @ptrCast(@alignCast(ctx));
        const id = switch (ev.*) {
            .updated => |id| id,
            else => return,
        };
        if (f.comments.threadsOf(id).len == 0) return;
        if (std.mem.indexOfScalar(ChangesetId, f.noted.items, id) != null) return;
        f.noted.append(f.gpa, id) catch log.warn("comments on {f} may be left on old lines (out of memory)", .{id});
    }

    /// Re-anchors the threads of the changesets noted since the last call.
    pub fn pump(f: *Follow) void {
        while (f.noted.pop()) |id| {
            _ = f.reanchorAll(id) catch |e| log.warn("re-anchoring comments on {f} failed: {t}", .{ id, e });
        }
    }

    /// Moves every thread of `id` to its lines in the changeset's current
    /// texts.
    pub fn reanchorAll(f: *Follow, id: ChangesetId) !ReanchorReport {
        var rep: ReanchorReport = .{};
        const cs = f.q.get(id) orelse return rep;
        var arena_state: std.heap.ArenaAllocator = .init(f.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        for (cs.files) |*fc| {
            const t = switch (fc.content) {
                .text => |*t| t,
                else => continue,
            };
            if (!hasThreadOn(f.comments, id, fc.path)) continue;
            const base: []const u8 = if (t.base) |b| (try f.q.blobs.get(arena, b.hash)) orelse return error.MissingBlob else "";
            const proposed = try t.edits.applyToSlice(arena, base);
            add(&rep, try f.comments.reanchor(id, fc.path, proposed, .{ .side = .new }));
            add(&rep, try f.comments.reanchor(id, fc.path, base, .{ .side = .base }));
        }
        return rep;
    }
};

fn hasThreadOn(store: *const CommentStore, id: ChangesetId, path: []const u8) bool {
    for (store.threadsOf(id)) |t| if (std.mem.eql(u8, t.anchor.path, path)) return true;
    return false;
}

fn add(into: *ReanchorReport, r: ReanchorReport) void {
    inline for (std.meta.fields(ReanchorReport)) |fld| @field(into, fld.name) += @field(r, fld.name);
}
