//! The changeset model (E12.F01.S01.T01).

pub const ids = @import("ids.zig");
pub const provenance = @import("provenance.zig");
pub const changeset = @import("changeset.zig");
pub const hunks = @import("hunks.zig");
pub const state = @import("state.zig");
pub const blobs = @import("blobs.zig");
pub const batch = @import("batch.zig");
pub const events = @import("events.zig");
pub const queue = @import("queue.zig");
pub const merge3 = @import("merge3.zig");
pub const history = @import("history.zig");
pub const checkpoint = @import("checkpoint.zig");

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
pub const revive = state.revive;
pub const fileTransition = state.fileTransition;
pub const recomputeState = state.recomputeState;

pub const Blobs = blobs.Blobs;
pub const MemBlobs = blobs.MemBlobs;
pub const Event = events.Event;
pub const Listener = events.Listener;
pub const Queue = queue.Queue;
pub const Submitter = queue.Submitter;
pub const SubmitOptions = queue.SubmitOptions;
pub const Filter = queue.Filter;
pub const Journal = queue.Journal;

pub const History = history.History;
pub const Apply = history.Apply;
pub const ApplyFile = history.ApplyFile;
pub const Closed = history.Closed;
pub const ApplyKind = history.ApplyKind;
pub const Recorder = history.Recorder;

pub const Checkpoint = checkpoint.Checkpoint;
pub const CheckpointRecorder = checkpoint.CheckpointRecorder;
pub const CheckpointSink = checkpoint.CheckpointSink;
pub const CheckpointList = checkpoint.CheckpointList;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("queue_test.zig");
}
