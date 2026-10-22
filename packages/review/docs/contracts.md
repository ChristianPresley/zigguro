# Contracts with other epics

## E10 file tools read through AgentView (E12.F02.S01.T01)

An agent's edits wait in the review queue until someone accepts them.
Until then the agent has to see its own pending text, or its next edit
would be made against stale content. E10's file tools therefore go
through `zg_review.overlay.AgentView`
(`agentView(&overlay_fs, agent_ref, conflict_index)`):

| Tool | Call |
| --- | --- |
| `read_file(path)` | `readText(arena, path)`: the text with this session's pending changes. Null means the file does not exist in the agent's view (a pending delete, or a rename source). |
| `edit_file(path)`, `write_file(path)` | Make the edits against `baseFor(path)`, the same text `read_file` returned, and submit them with `Queue.addEdit(batch, path, base, null, edits)` (or `Submitter`). The queue folds an edit made on the session's own pending text into that changeset. |
| `glob`, `grep`, `list_dir` | `listDir(arena, dir)` and `readText`: pending creates and rename targets are listed, while pending deletes and rename sources are hidden. |
| Any of the above | Append `pendingWarning(gpa, path)` to the result when it is not null. It lists other sessions' pending changesets on the path. |

Rules:

- Subagents of a session share its view (`Options.subagents_share_view`,
  default true).
- `Read.stale` means a pending change was made against text that has
  changed since. The view merged it three ways, so the agent still sees
  its change.
- Calls run on the queue's owner thread. A tool running on a worker posts
  the read to it.
- Nothing here writes to the workspace.

In the app, the `Files` seam implemented in
`apps/zigguro/src/agent/editor_files.zig` is where this binds, together
with the turn seams of #1356: `end_turn` commits the turn's batch.
