//! The changeset model (E12.F01.S01.T01).

pub const ids = @import("ids.zig");
pub const provenance = @import("provenance.zig");
pub const changeset = @import("changeset.zig");
pub const hunks = @import("hunks.zig");
pub const state = @import("state.zig");

pub const ChangesetId = ids.ChangesetId;
pub const ChangeSetId = ids.ChangeSetId;
pub const BatchId = ids.BatchId;
pub const HunkRef = ids.HunkRef;
pub const BlobHash = ids.BlobHash;
pub const blobHash = ids.blobHash;

pub const Origin = provenance.Origin;
pub const Provenance = provenance.Provenance;
pub const writeProvenanceJson = provenance.writeProvenanceJson;
pub const parseProvenanceJson = provenance.parseProvenanceJson;

pub const LineRange = changeset.LineRange;
pub const ConflictKind = changeset.ConflictKind;
pub const ConflictInfo = changeset.ConflictInfo;
pub const Eol = changeset.Eol;
pub const BaseRef = changeset.BaseRef;
pub const FileOp = changeset.FileOp;
pub const Content = changeset.Content;
pub const Decision = changeset.Decision;
pub const Hunk = changeset.Hunk;
pub const FileState = changeset.FileState;
pub const FileChange = changeset.FileChange;
pub const State = changeset.State;
pub const Presentation = changeset.Presentation;
pub const Changeset = changeset.Changeset;

pub const HunkOptions = hunks.HunkOptions;
pub const deriveHunks = hunks.deriveHunks;

pub const transition = state.transition;
pub const fileTransition = state.fileTransition;
pub const recomputeState = state.recomputeState;

test {
    @import("std").testing.refAllDecls(@This());
}
