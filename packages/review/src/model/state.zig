//! Changeset and file state machines (E12.F01.S01.T01).
//!
//! Changeset: `open_batch → pending` at commit; `pending → partially_applied
//! | applied | rejected | superseded | discarded`; `partially_applied →
//! applied | rejected`; `applied → pending` only through "undo accept".
//! `superseded` and `discarded` are terminal.
//!
//! File: decisions move a file between `pending`, `partially_applied`,
//! `applied` and `rejected` (and back, for undo). Rebase marks it
//! `conflicted` or `stale` and back. `superseded` is terminal.
//!
//! Any other transition is a programming error: it asserts in safe builds
//! and returns `error.InvalidTransition` otherwise.

const std = @import("std");
const changeset = @import("changeset.zig");

const State = changeset.State;
const FileState = changeset.FileState;
const Changeset = changeset.Changeset;
const FileChange = changeset.FileChange;

pub const TransitionError = error{InvalidTransition};

/// Whether a changeset may go from `from` to `to`.
pub fn allowed(from: State, to: State) bool {
    return switch (from) {
        .open_batch => to == .pending,
        .pending => switch (to) {
            .partially_applied, .applied, .rejected, .superseded, .discarded => true,
            else => false,
        },
        .partially_applied => to == .applied or to == .rejected,
        .applied => to == .pending,
        .rejected, .superseded, .discarded => false,
    };
}

/// Whether a file may go from `from` to `to`.
pub fn fileAllowed(from: FileState, to: FileState) bool {
    if (from == to) return false;
    return switch (from) {
        .pending, .partially_applied => true,
        .applied => to == .pending or to == .partially_applied,
        .rejected => to == .pending,
        .conflicted => to == .pending or to == .partially_applied or to == .rejected or to == .stale or to == .superseded,
        .stale => to == .pending or to == .rejected or to == .conflicted or to == .superseded,
        .superseded => false,
    };
}

pub fn transition(cs: *Changeset, to: State) TransitionError!void {
    if (!allowed(cs.state, to)) {
        std.debug.assert(false);
        return error.InvalidTransition;
    }
    cs.state = to;
}

pub fn fileTransition(fc: *FileChange, to: FileState) TransitionError!void {
    if (!fileAllowed(fc.state, to)) {
        std.debug.assert(false);
        return error.InvalidTransition;
    }
    fc.state = to;
}

/// The state of a file with hunks, from their decisions. Files without
/// hunks, conflicted, stale and superseded files keep their state.
pub fn fileStateFromHunks(fc: *const FileChange) FileState {
    if (fc.hunks.len == 0) return fc.state;
    switch (fc.state) {
        .conflicted, .stale, .superseded => return fc.state,
        else => {},
    }
    var taken: usize = 0;
    var undecided: usize = 0;
    for (fc.hunks) |h| switch (h.decision) {
        .accepted, .edited => taken += 1,
        .undecided => undecided += 1,
        .rejected => {},
    };
    if (undecided == 0) return if (taken > 0) .applied else .rejected;
    return if (taken > 0) .partially_applied else .pending;
}

/// The changeset state its files imply: every file decided ⇒ `applied`
/// when any landed, else `rejected`; some landed ⇒ `partially_applied`;
/// else `pending`. `open_batch`, `superseded` and `discarded` are kept.
pub fn derivedState(cs: *const Changeset) State {
    switch (cs.state) {
        .open_batch, .superseded, .discarded => return cs.state,
        else => {},
    }
    var landed = false;
    var open = false;
    for (cs.files) |f| switch (f.state) {
        .applied => landed = true,
        .partially_applied => {
            landed = true;
            open = true;
        },
        .rejected, .superseded => {},
        .pending, .conflicted, .stale => open = true,
    };
    if (!open) return if (landed) .applied else .rejected;
    return if (landed) .partially_applied else .pending;
}

/// Brings every file with hunks in line with its decisions, then sets the
/// changeset state from its files. A move the state machine does not
/// allow (rejecting the rest of a partially applied changeset after an
/// undo, say) goes through `pending`.
pub fn recomputeState(cs: *Changeset) void {
    for (cs.files) |*f| f.state = fileStateFromHunks(f);
    const to = derivedState(cs);
    if (to == cs.state) return;
    if (!allowed(cs.state, to)) cs.state = .pending;
    if (to != cs.state) cs.state = to;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "state: transition table exhaustive" {
    const S = State;
    const ok = [_][2]S{
        .{ .open_batch, .pending },
        .{ .pending, .partially_applied },
        .{ .pending, .applied },
        .{ .pending, .rejected },
        .{ .pending, .superseded },
        .{ .pending, .discarded },
        .{ .partially_applied, .applied },
        .{ .partially_applied, .rejected },
        .{ .applied, .pending },
    };
    for (std.enums.values(S)) |from| for (std.enums.values(S)) |to| {
        var want = false;
        for (ok) |p| if (p[0] == from and p[1] == to) {
            want = true;
        };
        try testing.expectEqual(want, allowed(from, to));
    };
}

test "state: file transitions" {
    try testing.expect(fileAllowed(.pending, .applied));
    try testing.expect(fileAllowed(.applied, .pending));
    try testing.expect(fileAllowed(.partially_applied, .pending));
    try testing.expect(fileAllowed(.pending, .conflicted));
    try testing.expect(fileAllowed(.conflicted, .pending));
    try testing.expect(!fileAllowed(.superseded, .pending));
    try testing.expect(!fileAllowed(.rejected, .applied));
    for (std.enums.values(FileState)) |s| try testing.expect(!fileAllowed(s, s));
}

fn testFile(hunks: []changeset.Hunk, st: FileState) FileChange {
    return .{ .path = "p", .op = .modify, .content = .none, .hunks = hunks, .state = st };
}

test "state: recompute from mixed file states" {
    var h1 = [_]changeset.Hunk{
        .{ .id = 0, .base_lines = .{ .start = 0, .count = 1 }, .new_lines = .{ .start = 0, .count = 1 }, .replace_span = .{ 0, 1 } },
        .{ .id = 1, .base_lines = .{ .start = 5, .count = 1 }, .new_lines = .{ .start = 5, .count = 1 }, .replace_span = .{ 1, 2 } },
    };
    var files = [_]FileChange{ testFile(&h1, .pending), testFile(&.{}, .pending) };
    var cs: Changeset = .{ .id = @enumFromInt(1), .prov = undefined, .files = &files, .state = .pending, .created_ms = 0 };

    h1[0].decision = .accepted;
    recomputeState(&cs);
    try testing.expectEqual(FileState.partially_applied, files[0].state);
    try testing.expectEqual(State.partially_applied, cs.state);

    h1[1].decision = .rejected;
    recomputeState(&cs);
    try testing.expectEqual(FileState.applied, files[0].state);
    try testing.expectEqual(State.partially_applied, cs.state);

    files[1].state = .rejected;
    recomputeState(&cs);
    try testing.expectEqual(State.applied, cs.state);

    // Undo the accept: all rejected now.
    h1[0].decision = .rejected;
    recomputeState(&cs);
    try testing.expectEqual(FileState.rejected, files[0].state);
    try testing.expectEqual(State.rejected, cs.state);

    // A conflicted file keeps the changeset open.
    var cs2: Changeset = .{ .id = @enumFromInt(2), .prov = undefined, .files = &files, .state = .pending, .created_ms = 0 };
    h1[0].decision = .undecided;
    h1[1].decision = .undecided;
    files[0].state = .conflicted;
    files[1].state = .applied;
    recomputeState(&cs2);
    try testing.expectEqual(FileState.conflicted, files[0].state);
    try testing.expectEqual(State.partially_applied, cs2.state);
}
