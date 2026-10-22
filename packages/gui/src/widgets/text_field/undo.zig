//! Undo for text fields (E04.F05.S02.T01). Each step is one replacement
//! (the bytes removed and inserted at an offset) plus the selection before
//! and after it. Typing and deleting coalesce into word-sized steps.

const std = @import("std");
const model = @import("model.zig");

const Selection = model.Selection;

/// What made an edit; only edits of the same kind coalesce.
pub const Kind = enum(u8) {
    /// Typed text.
    typing,
    /// Backspace.
    delete_back,
    /// Delete.
    delete_forward,
    /// Paste, cut, IME commit, word deletes: always a step of its own.
    other,
};

/// One undoable replacement.
pub const Edit = struct {
    /// Where the replacement starts.
    at: u32,
    /// The bytes that were there.
    removed: []const u8,
    /// The bytes put there.
    inserted: []const u8,
    sel_before: Selection,
    sel_after: Selection,
    kind: Kind,
};

/// The undo and redo stacks of one field.
pub const UndoStack = struct {
    gpa: ?std.mem.Allocator = null,
    done: std.ArrayList(Owned) = .empty,
    undone: std.ArrayList(Owned) = .empty,
    /// When false the next edit starts a new step.
    can_merge: bool = false,
    last_ms: u64 = 0,

    /// At most this many steps are kept.
    pub const max_steps = 1000;
    /// Edits further apart than this never coalesce.
    pub const merge_ms = 1000;

    const Owned = struct {
        at: u32,
        removed: std.ArrayList(u8) = .empty,
        inserted: std.ArrayList(u8) = .empty,
        sel_before: Selection,
        sel_after: Selection,
        kind: Kind,

        fn deinit(o: *Owned, gpa: std.mem.Allocator) void {
            o.removed.deinit(gpa);
            o.inserted.deinit(gpa);
        }

        fn view(o: *const Owned) Edit {
            return .{ .at = o.at, .removed = o.removed.items, .inserted = o.inserted.items, .sel_before = o.sel_before, .sel_after = o.sel_after, .kind = o.kind };
        }
    };

    /// Frees every step.
    pub fn deinit(u: *UndoStack) void {
        const gpa = u.gpa orelse return;
        for (u.done.items) |*o| o.deinit(gpa);
        for (u.undone.items) |*o| o.deinit(gpa);
        u.done.deinit(gpa);
        u.undone.deinit(gpa);
        u.* = .{};
    }

    /// The number of undo steps.
    pub fn depth(u: *const UndoStack) usize {
        return u.done.items.len;
    }

    /// Ends the current step: the next edit never merges into it (caret
    /// moves, focus changes, undo).
    pub fn breakGroup(u: *UndoStack) void {
        u.can_merge = false;
    }

    /// Records `e` (its slices are copied), merging it into the previous
    /// step when it continues it. Clears the redo stack.
    pub fn record(u: *UndoStack, gpa: std.mem.Allocator, e: Edit, now_ms: u64) !void {
        u.gpa = gpa;
        for (u.undone.items) |*o| o.deinit(gpa);
        u.undone.clearRetainingCapacity();
        defer {
            u.last_ms = now_ms;
            u.can_merge = e.kind != .other;
        }
        if (u.can_merge and now_ms -| u.last_ms <= merge_ms and u.done.items.len > 0) {
            const last = &u.done.items[u.done.items.len - 1];
            if (try merge(gpa, last, e)) return;
        }
        if (u.done.items.len >= max_steps) {
            var old = u.done.orderedRemove(0);
            old.deinit(gpa);
        }
        var o: Owned = .{ .at = e.at, .sel_before = e.sel_before, .sel_after = e.sel_after, .kind = e.kind };
        errdefer o.deinit(gpa);
        try o.removed.appendSlice(gpa, e.removed);
        try o.inserted.appendSlice(gpa, e.inserted);
        try u.done.append(gpa, o);
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n';
    }

    fn merge(gpa: std.mem.Allocator, last: *Owned, e: Edit) !bool {
        if (last.kind != e.kind) return false;
        switch (e.kind) {
            .typing => {
                if (e.removed.len != 0 or e.at != last.at + last.inserted.items.len) return false;
                // A new word after whitespace starts a new step.
                const prev = last.inserted.items;
                if (prev.len > 0 and isSpace(prev[prev.len - 1]) and e.inserted.len > 0 and !isSpace(e.inserted[0])) return false;
                try last.inserted.appendSlice(gpa, e.inserted);
            },
            .delete_back => {
                if (e.inserted.len != 0 or last.inserted.items.len != 0 or e.at + e.removed.len != last.at) return false;
                const prev = last.removed.items;
                if (prev.len > 0 and !isSpace(prev[0]) and e.removed.len > 0 and isSpace(e.removed[e.removed.len - 1])) return false;
                try last.removed.insertSlice(gpa, 0, e.removed);
                last.at = e.at;
            },
            .delete_forward => {
                if (e.inserted.len != 0 or last.inserted.items.len != 0 or e.at != last.at) return false;
                try last.removed.appendSlice(gpa, e.removed);
            },
            .other => return false,
        }
        last.sel_after = e.sel_after;
        return true;
    }

    /// Moves the newest step to the redo stack and returns it; the caller
    /// replaces `inserted` at `at` with `removed` and restores `sel_before`.
    pub fn undo(u: *UndoStack) ?Edit {
        const o = u.done.pop() orelse return null;
        u.undone.append(u.gpa.?, o) catch {
            u.done.appendAssumeCapacity(o);
            return null;
        };
        u.can_merge = false;
        return u.undone.items[u.undone.items.len - 1].view();
    }

    /// Moves the newest undone step back and returns it; the caller
    /// replaces `removed` at `at` with `inserted` and restores `sel_after`.
    pub fn redo(u: *UndoStack) ?Edit {
        const o = u.undone.pop() orelse return null;
        u.done.append(u.gpa.?, o) catch {
            u.undone.appendAssumeCapacity(o);
            return null;
        };
        u.can_merge = false;
        return u.done.items[u.done.items.len - 1].view();
    }
};

test {
    std.testing.refAllDecls(@This());
}
