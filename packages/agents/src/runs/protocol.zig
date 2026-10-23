//! The `zg agents host` protocol (E13.F01.S01.T03): JSON-RPC 2.0 over
//! NDJSON on a local socket. Method names and the shapes of their params
//! and results. Pure.

const std = @import("std");
const run = @import("run.zig");

pub const version = 1;

pub const methods = struct {
    /// `Hello` -> `HelloResult`; must be the first request.
    pub const hello = "host.hello";
    /// -> `[]RunSummary`
    pub const list = "runs.list";
    /// `IdParams` -> `RunRecord`
    pub const show = "runs.show";
    /// `StartParams` -> `IdParams`
    pub const start = "runs.start";
    /// `StopParams` -> `Ok`
    pub const stop = "runs.stop";
    /// `IdParams` -> `Ok`
    pub const pause = "runs.pause";
    /// `IdParams` -> `Ok`
    pub const resume_ = "runs.resume";
    /// `ReplyParams` -> `Ok`
    pub const reply = "runs.reply";
    /// `AdoptParams` -> `AdoptResult`: the host resumes runs another
    /// process paused and handed over.
    pub const adopt = "runs.adopt";
    /// `SubscribeParams` -> `SubscribeResult`, then `run.event`
    /// notifications.
    pub const subscribe = "runs.subscribe";
    /// Notification: `EventNote`.
    pub const event = "run.event";
    /// -> `Ok`; the host exits once its runs are handed back or done.
    pub const shutdown = "host.shutdown";
};

/// JSON-RPC error codes of this protocol.
pub const codes = struct {
    pub const unauthorized = -32001;
    pub const unknown_run = -32002;
    pub const bad_state = -32003;
    pub const failed = -32004;
};

pub const Hello = struct { version: u32 = version, token: []const u8 };
pub const HelloResult = struct { version: u32 = version, pid: i64 = 0 };
pub const Ok = struct { ok: bool = true };
pub const IdParams = struct { id: run.RunId };
pub const StartParams = struct { spec: run.RunSpec };
pub const StopParams = struct { id: run.RunId, how: enum { graceful, now } = .graceful };
pub const ReplyParams = struct { id: run.RunId, text: []const u8 };
pub const AdoptParams = struct { ids: []const run.RunId };
pub const AdoptResult = struct { adopted: u32, failed: u32 };
pub const SubscribeParams = struct { since: u64 = 0 };
pub const SubscribeResult = struct { seq: u64 };

/// One event with the host's global sequence number.
pub const EventNote = struct { seq: u64, id: run.RunId, revision: u64, kind: run.EventKind };

/// A row of `runs.list`.
pub const RunSummary = struct {
    id: run.RunId,
    kind: run.RunKind,
    status: run.RunStatus,
    title: []const u8,
    summary: []const u8,
    question: ?[]const u8,
    cost_micros: u64,
    created_ms: i64,
    ended_ms: ?i64,
    revision: u64,

    pub fn of(r: *const run.RunRecord) RunSummary {
        return .{
            .id = r.id,
            .kind = r.spec.kind,
            .status = r.status,
            .title = r.spec.title,
            .summary = r.summary,
            .question = r.question,
            .cost_micros = r.cost.micros,
            .created_ms = r.created_ms,
            .ended_ms = r.ended_ms,
            .revision = r.revision,
        };
    }
};

test "protocol shapes round trip" {
    const a = std.testing.allocator;
    const id = run.RunId.fromInt(42 << 80);
    const s = try std.json.Stringify.valueAlloc(a, EventNote{ .seq = 3, .id = id, .revision = 2, .kind = .status }, .{});
    defer a.free(s);
    const p = try std.json.parseFromSlice(EventNote, a, s, .{});
    defer p.deinit();
    try std.testing.expect(p.value.id.eql(id));
    try std.testing.expectEqual(run.EventKind.status, p.value.kind);
}
