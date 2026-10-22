//! Rewind (E10.F08.S02.T01): undo the conversation, the code, or both back
//! to a user message, or summarize part of the conversation.
//!
//! - `conversation`: the transcript drops the target message and everything
//!   after it, and a `rewind{to_seq}` record makes the dropped records
//!   inactive (they stay in the file).
//! - `code`: E12 `restoreTo(checkpoint, .{ .scope = .session })` reverts the
//!   agent changesets applied since the checkpoint taken at the start of
//!   the target's turn. Files changed outside changesets are reported as
//!   untracked; symlinks and hard links are skipped with reasons.
//! - `summarize_from` / `summarize_up_to`: the compactor summarizes from the
//!   target on, or up to it. The new history is written after a
//!   `compaction` record so a resume reads exactly it.
//!
//! The target's prompt text is returned for the composer.

const std = @import("std");
const proto = @import("zg_ai_proto");
const records = @import("records.zig");
const writer_mod = @import("writer.zig");
const Agent = @import("../loop/Agent.zig");
const compactor = @import("../context/compactor.zig");
const request = @import("../provider/request.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const RewindAction = enum { code_and_conversation, conversation, code, summarize_from, summarize_up_to };

/// A message of the agent's transcript.
pub const MessageRef = struct { index: u32 };

/// A file the restore left alone.
pub const SkipReason = struct {
    path: []const u8,
    reason: []const u8,
};

/// The outcome of an E12 restore.
pub const RestoreOutcome = struct {
    restored_files: []const []const u8 = &.{},
    /// Files changed outside agent changesets (E08 file events attributed
    /// to agent terminals) since the checkpoint.
    untracked_changes: []const []const u8 = &.{},
    skipped: []const SkipReason = &.{},
};

/// E12.F04 `Checkpoints.restoreTo(id, .{ .scope = .session })`, awaited
/// (stub until E12 lands).
pub const CheckpointRestore = struct {
    ctx: *anyopaque,
    restore_to: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, checkpoint: u64) anyerror!RestoreOutcome,
};

pub const RewindDeps = struct {
    /// The session log (records `rewind`, `compaction` and new messages).
    log: ?*writer_mod.SessionWriter = null,
    checkpoints: ?CheckpointRestore = null,
    /// For the summarize actions.
    compactor: ?*compactor.Compactor = null,
    /// The request the agent would send next (system prompt and tools for
    /// the summarizer).
    base: ?*const request.Request = null,
};

pub const RewindReport = struct {
    restored_files: []const []const u8 = &.{},
    untracked_changes: []const []const u8 = &.{},
    skipped: []const SkipReason = &.{},
    /// The target's text, for the composer (conversation rewinds).
    prompt_text: ?[]const u8 = null,
    /// The checkpoint restored (code rewinds).
    checkpoint: ?u64 = null,
    /// The summary (summarize actions).
    summary: ?[]const u8 = null,
};

pub const RewindError = error{ InvalidTarget, NoCheckpoint, NoCheckpointStore, NoCompactor } || error{Busy} || Allocator.Error;

/// Rewinds agent `a` (idle) to message `to`. Slices of the report live in
/// `arena`.
pub fn rewind(a: *Agent, io: Io, arena: Allocator, to: MessageRef, action: RewindAction, focus: ?[]const u8, d: RewindDeps) !RewindReport {
    const msgs = a.messages();
    if (to.index >= msgs.len) return error.InvalidTarget;
    const target = msgs[to.index];
    const target_seq = a.messageSeq(to.index);
    var report: RewindReport = .{};

    switch (action) {
        .summarize_from, .summarize_up_to => {
            const c = d.compactor orelse return error.NoCompactor;
            const base = d.base orelse return error.NoCompactor;
            const range: @FieldType(compactor.Job, "range") = if (action == .summarize_from) .{ .from = to.index } else .{ .to = to.index };
            const res = try c.compact(io, arena, base, msgs, .{}, .{ .trigger = .manual, .focus = focus, .range = range });
            report.summary = res.summary;
            // Persist: a compaction record, then the whole new history.
            var seq = a.bus.lastSeq();
            const head = seq + 2;
            if (d.log) |w| try w.append(seq + 1, .{ .compaction = .{ .head_seq = head, .trigger = "manual", .tokens_before = res.tokens_before, .tokens_after = res.tokens_after, .model = res.model } });
            seq += 1;
            const seqs = try arena.alloc(u64, res.messages.len);
            for (res.messages, seqs) |m, *s| {
                seq += 1;
                s.* = seq;
                if (d.log) |w| try w.append(seq, records.Record.fromMessage(m));
            }
            if (d.log) |w| try w.sync();
            try a.setTranscript(res.messages, seqs, seq);
            return report;
        },
        .code, .code_and_conversation, .conversation => {},
    }

    if (action != .code) {
        if (target.role != .user or target.meta.synthetic or isToolResults(target)) return error.InvalidTarget;
    }
    if (action == .code or action == .code_and_conversation) {
        const cp = d.checkpoints orelse return error.NoCheckpointStore;
        const mark = a.checkpointBefore(target_seq) orelse return error.NoCheckpoint;
        const out = try cp.restore_to(cp.ctx, io, arena, mark.id);
        report.restored_files = out.restored_files;
        report.untracked_changes = out.untracked_changes;
        report.skipped = out.skipped;
        report.checkpoint = mark.id;
    }
    if (action == .conversation or action == .code_and_conversation) {
        report.prompt_text = try target.text(arena);
        try a.truncate(to.index);
        if (d.log) |w| {
            const seq = a.bus.lastSeq() + 1;
            a.bus.startAt(seq);
            try w.append(seq, .{ .rewind = .{ .to_seq = target_seq -| 1, .action = @tagName(action) } });
            try w.sync();
        }
    }
    return report;
}

fn isToolResults(m: proto.Message) bool {
    for (m.content) |b| if (b == .tool_result) return true;
    return false;
}
