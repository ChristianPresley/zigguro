# Checkpoints and restore

`zg_review.checkpoint.Checkpoints` (E12.F04). An agent turn starts with
`create(origin, turn, label)`. It returns at once (well under 1 ms) and
copies no file. It records two numbers:

- the newest `History` record id (`after_apply`);
- the next changeset id (`next_changeset`).

Every file the applier writes already has its preimage in the blob
store. So a checkpoint only needs to know which applies came after it.

## Restore (agent-only)

`restoreTo(arena, id, .{ .scope = .session })`:

1. It collects the applies after the checkpoint for this session (or for
   every agent with `.all_agents`), skipping applies that were undone.
   It groups them per file, oldest first.
2. It undoes them newest first. Each step is a three-way merge of the
   current content against that apply's pre and post images. A user's
   edit to other lines survives, even one made between two agent turns.
3. Some files are left as they are and reported as conflicts:
   - the user changed the same lines;
   - the user edited a file the agent created;
   - the user deleted a file the agent modified;
   - a file now sits where the agent deleted one.
4. All writes run as one transaction. If one fails, the writes already
   done are rolled back.
5. Changesets submitted after the checkpoint that are still open get
   closed. Pending ones become `discarded`. Partially applied ones become
   `rejected`.
6. The writes and the closed changesets, with their earlier states, are
   recorded as a `restore` in `History`.

`dry_run` returns the same report and writes nothing.

## Redo

`redo(arena, restore_id, .{})` reverses a restore from its record:

- Each file the restore wrote is reverted the same way, three-way, so
  edits made since the restore on other lines survive. Overlaps are
  conflicts and stay as they are.
- Each changeset the restore closed goes back to its earlier state
  (`pending` or `partially_applied`), if it is still `discarded` or
  `rejected`.
- The redo is recorded as an `undo` of the restore. A restore can be
  redone once, and the redone applies count again for later restores.

`dry_run` works as for restore.

## Retention

`store.gc.collect` drops a checkpoint unless it is pinned, was taken
within `decided_days`, or is among the newest `keep_last_n`. It keeps the
`History` records after the oldest kept checkpoint (and those of kept
changesets), and the blobs those records name. A dropped checkpoint can
no longer be restored. The next checkpoint id is journaled, so ids are
never reused.

## In the app

`apps/zigguro/src/agent/review_glue.zig` binds this to the workbench
agent:

- `deps.Checkpoints` (E10) is `Checkpoints.createErased`, so the agent
  loop takes a checkpoint at the start of every user turn.
- Agent writes to files that are not open in the editor still go to disk
  directly. Each one is recorded in `History` (an `apply` with no
  changeset) under the agent's session, so restore can revert it.
- E10 rewind's `CheckpointRestore` calls `restoreTo` with session scope.
  Conflicts come back as skipped files with a reason.

Until the review UI lands, proposals are applied at once rather than held
in the queue. Edits to documents open in the editor are not recorded.
Contents stay in memory for the app's run.

## Differences from Claude Code checkpointing

| Claude Code limitation | zigguro |
|---|---|
| Changes made by bash commands are not tracked | The same: only changes that went through review are reverted. The untracked report (E08 watcher attribution) is not done yet. |
| External changes (other sessions, the user) are not tracked | They are kept: each revert is a three-way merge, and overlaps are reported as conflicts instead of being overwritten. |
| Not a replacement for version control | The same. Full mode through E09 operations is not done yet. |
| Restoring discards later checkpoints' work | Later changesets are marked `discarded`, not deleted, and `redo` brings back both the files and those changesets. |
