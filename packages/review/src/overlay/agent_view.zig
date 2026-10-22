//! What one agent sees (E12.F02.S01.T01): the workspace with its own
//! session's pending changes taken, for E10's file tools. The contract
//! is in `docs/contracts.md`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const overlay_fs = @import("overlay_fs.zig");
const ConflictIndex = @import("../rebase/conflict_index.zig").ConflictIndex;

const Allocator = std.mem.Allocator;
const OverlayFs = overlay_fs.OverlayFs;

pub const AgentView = struct {
    fs: *const OverlayFs,
    ref: proto.AgentRef,
    conflicts: ?*const ConflictIndex = null,

    fn spec(v: AgentView) overlay_fs.ViewSpec {
        return .{ .agent = .{ .session = v.ref.session, .agent = v.ref.agent } };
    }

    /// `read_file`: the text with this session's pending changes.
    pub fn readText(v: AgentView, arena: Allocator, path: []const u8) !?overlay_fs.Read {
        return v.fs.read(arena, v.spec(), path);
    }

    /// The base to submit an `edit_file` proposal against: the text the
    /// agent read. `Queue.addEdit` folds a proposal made on the session's
    /// own pending text into that changeset.
    pub fn baseFor(v: AgentView, arena: Allocator, path: []const u8) !?[]const u8 {
        const r = try v.readText(arena, path) orelse return null;
        return r.text;
    }

    /// `glob` and `grep` walk directories through this.
    pub fn listDir(v: AgentView, arena: Allocator, dir: []const u8) ![]overlay_fs.DirEntry {
        return v.fs.listDir(arena, v.spec(), dir);
    }

    pub fn stat(v: AgentView, arena: Allocator, path: []const u8) !?overlay_fs.Stat {
        return v.fs.stat(arena, v.spec(), path);
    }

    /// The line E10 appends to `read_file` and `edit_file` results when
    /// other sessions have pending changes on `path`.
    pub fn pendingWarning(v: AgentView, gpa: Allocator, path: []const u8) Allocator.Error!?[]u8 {
        const ci = v.conflicts orelse return null;
        return ci.warningFor(path, v.ref.session, gpa);
    }
};

pub fn agentView(fs: *const OverlayFs, ref: proto.AgentRef, conflicts: ?*const ConflictIndex) AgentView {
    return .{ .fs = fs, .ref = ref, .conflicts = conflicts };
}
