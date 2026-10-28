//! zg_scm: the AI-first source control core (epic E09). This module holds the
//! content-addressed object store: object IDs, the object model and its
//! canonical encoding, the segmented store, chunked blobs, compaction,
//! GC and fsck; the commit graph (commit index, ancestry); and conflicts
//! (the `Merge` algebra and conflict markers); and the operation log
//! (operations, views, transactions, undo).

const std = @import("std");

/// Object kinds, BLAKE3 object IDs, change IDs.
pub const id = @import("store/id.zig");
/// Trees, changes, chunked blobs and their canonical-form rules.
pub const object = @import("store/object.zig");
/// The canonical binary encoding (and debug JSON).
pub const encode = @import("store/encode.zig");
/// Segment and index file formats.
pub const segment = @import("store/segment.zig");
/// The decode cache.
pub const cache = @import("store/cache.zig");
/// The segmented object store.
pub const store = @import("store/store.zig");
/// Content-defined chunking and streaming blob reads/writes.
pub const chunker = @import("store/chunker.zig");
/// Geometric segment compaction.
pub const compaction = @import("store/compaction.zig");
/// Mark-and-sweep garbage collection.
pub const gc = @import("store/gc.zig");
/// Store integrity checks.
pub const fsck = @import("store/fsck.zig");
/// The commit index segment file format.
pub const index_segment = @import("graph/index_segment.zig");
/// The commit index: positions, parents, generations, change IDs.
pub const index = @import("graph/index.zig");
/// Ancestry queries over the commit index.
pub const ancestry = @import("graph/ancestry.zig");
/// Lane layout for drawing history as a graph (CLI and GUI).
pub const layout = @import("graph/layout.zig");
/// The revset query language.
pub const revset = @import("graph/revset.zig");
/// `Merge(T)`: first-class conflicts and their algebra.
pub const merge = @import("merge/merge.zig");
/// Writing conflicts as marker text.
pub const materialize = @import("merge/materialize.zig");
/// Reading marker text back.
pub const parse_markers = @import("merge/parse_markers.zig");
/// Path-level three-way tree merges.
pub const tree_merge = @import("merge/tree_merge.zig");
/// Three-way and N-way file content merge.
pub const content_merge = @import("merge/content_merge.zig");
/// Git repositories through zg_git: merge, cherry-pick, revert, stash,
/// rebase and pull.
pub const gitbridge = struct {
    /// Results, commits and git's operation-state files.
    pub const common = @import("gitbridge/common.zig");
    /// Three-way merges of git trees, applied to the index and worktree.
    pub const merge_trees = @import("gitbridge/merge_trees.zig");
    /// `git merge`.
    pub const merge = @import("gitbridge/merge.zig");
    /// `git cherry-pick` and `git revert`.
    pub const pick = @import("gitbridge/pick.zig");
    /// `git stash`.
    pub const stash = @import("gitbridge/stash.zig");
    /// `git rebase` (merge backend).
    pub const rebase = @import("gitbridge/rebase.zig");
    /// `git pull`.
    pub const pull = @import("gitbridge/pull.zig");
};
/// Operation objects and their metadata.
pub const operation = @import("oplog/operation.zig");
/// Views: heads, refs, working copies and lanes at one operation.
pub const view = @import("oplog/view.zig");
/// The lock-free op heads directory.
pub const op_heads = @import("oplog/op_heads.zig");
/// Three-way view merges.
pub const merge_views = @import("oplog/merge_views.zig");
/// The editable repository inside a transaction.
pub const mutable_repo = @import("oplog/mutable_repo.zig");
/// Transactions: write and publish operations.
pub const transaction = @import("oplog/transaction.zig");
/// Loading the repository at an operation.
pub const repo = @import("oplog/repo.zig");
/// Undo, restore, the op log and op abandon.
pub const undo = @import("oplog/undo.zig");
/// Preview (detached) operations and view diffs.
pub const preview = @import("oplog/preview.zig");
/// Adopting a preview onto the current repo.
pub const adopt = @import("oplog/adopt.zig");
/// Rebasing descendants of rewritten and abandoned commits.
pub const rebase = @import("oplog/rebase.zig");
/// Provenance (F05): who wrote each line.
pub const prov = struct {
    /// Provenance records: actors, prompts under a privacy level, reviews.
    pub const record = @import("prov/record.zig");
    /// Per-file run-length line attribution.
    pub const attribution = @import("prov/attribution.zig");
    /// A change's manifest of attribution maps.
    pub const manifest = @import("prov/manifest.zig");
    /// Edit events in, attribution maps out.
    pub const recorder = @import("prov/recorder.zig");
    /// Attribution through rewrites and merges.
    pub const remap = @import("prov/remap.zig");
    /// Per-commit agents and sessions, for the provenance revsets.
    pub const index = @import("prov/index.zig");
};
/// AI workflows (F06): the ports other packages implement, and fakes.
pub const ai = struct {
    pub const ports = @import("ai/ports.zig");
    /// The lane landing queue.
    pub const landing = @import("ai/landing.zig");
    /// Tools for agents, through zg_ai's foreign-tool contract.
    pub const agent_tools = @import("ai/agent_tools.zig");
    /// The files a proposal changes, for review items.
    pub const proposal_files = @import("ai/proposal_files.zig");
    /// Drafting change descriptions (and approving edited ones).
    pub const describe = @import("ai/describe.zig");
    /// Proposing and applying conflict resolutions.
    pub const resolve = @import("ai/resolve.zig");
    /// Token-budgeted prompt context (diffs, statistics).
    pub const context = @import("ai/context.zig");
    /// The prompt template renderer.
    pub const prompts = @import("ai/prompts.zig");
    pub const testing = struct {
        pub const fake_model = @import("ai/testing/fake_model.zig");
        pub const fake_review = @import("ai/testing/fake_review.zig");
    };
};

pub const ObjectId = id.ObjectId;
pub const ChangeId = id.ChangeId;
pub const Kind = id.Kind;
pub const hashObject = id.hashObject;
pub const Tree = object.Tree;
pub const TreeEntry = object.TreeEntry;
pub const Change = object.Change;
pub const Signature = object.Signature;
pub const ChunkedBlob = object.ChunkedBlob;
pub const Store = store.Store;
pub const WriteBatch = store.WriteBatch;
pub const ObjectRef = store.ObjectRef;
pub const CommitIndex = index.CommitIndex;
pub const Pos = index.Pos;
pub const Merge = merge.Merge;
pub const Repo = repo.Repo;
pub const Transaction = transaction.Transaction;
pub const View = view.View;
pub const RefTarget = view.RefTarget;
pub const Operation = operation.Operation;
pub const OpMeta = operation.OpMeta;
pub const DetachedOp = preview.DetachedOp;
pub const ModelPort = ai.ports.ModelPort;
pub const ReviewPort = ai.ports.ReviewPort;
pub const ReviewId = ai.ports.ReviewId;
pub const ReviewStatus = ai.ports.ReviewStatus;
pub const ReviewDecision = ai.ports.ReviewDecision;
pub const Proposal = ai.ports.Proposal;
pub const CheckPort = ai.ports.CheckPort;
pub const NotificationPort = ai.ports.NotificationPort;
pub const LandingQueue = ai.landing.LandingQueue;

test {
    std.testing.refAllDecls(@This());
    _ = @import("store/encode_test.zig");
    _ = @import("store/store_test.zig");
    _ = @import("store/store_crash_test.zig");
    _ = @import("store/store_mp_test.zig");
    _ = @import("store/gc_test.zig");
    _ = @import("graph/index_test.zig");
    _ = @import("graph/ancestry_test.zig");
    _ = @import("graph/layout_test.zig");
    _ = @import("graph/revset_test.zig");
    _ = @import("merge/markers_test.zig");
    _ = @import("merge/content_merge_test.zig");
    _ = @import("gitbridge/gitbridge_test.zig");
    _ = @import("oplog/oplog_test.zig");
    _ = @import("oplog/view_delta.zig");
    _ = @import("oplog/oplog_concurrency_test.zig");
    _ = @import("oplog/preview_test.zig");
    _ = @import("prov/record.zig");
    _ = @import("prov/attribution.zig");
    _ = @import("prov/manifest.zig");
    _ = @import("prov/recorder.zig");
    _ = @import("prov/remap.zig");
    _ = @import("prov/index.zig");
    _ = @import("ai/testing/fake_model.zig");
    _ = @import("ai/testing/fake_review.zig");
    _ = @import("ai/landing_test.zig");
    _ = @import("ai/agent_tools_test.zig");
    _ = @import("ai/proposal_files.zig");
    _ = @import("ai/describe.zig");
    _ = @import("ai/resolve.zig");
    _ = @import("ai/context.zig");
    _ = @import("ai/prompts.zig");
}
