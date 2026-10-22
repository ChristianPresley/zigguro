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

## E16 approvals through the broker (E12.F05.S02.T01)

`zg_review.approvals.ApprovalBroker.approvalPort()` is E16's
`contracts.ApprovalPort`, with no E12 copy of `ApprovalRequest` or
`Answer`. Ids are `ApprovalId` values (`@intFromEnum` at the boundary).
E06 and E10 put `cwd`, `terminal` (an integer id) and `shell` in
`ApprovalRequest.detail_json` for command requests; `commandView` reads
them. When an edited input still needs approval, the caller presents the
new request with `presentChained(req, previous)`. See `approvals.md`.

## E10 review outcomes as reminders (E12.F03.S04.T01)

Agents learn what review did with their changes through
`zg_review.feedback.OutcomeReporter`. E10's glue (the app, which owns
both the queue and the agent) creates one with an `OutcomeSink` and
does three things:

| Seam | Call |
| --- | --- |
| `OutcomeSink.deliver(outcome)` | Render it with `outcome.render(o, w, max_chars)` (2,000 by default) and queue the text as a reminder for `o.session` (`ReminderQueue.push(.other, text)`). The assembler adds it to the next user message after that message's tool results, so a stream is never interrupted. |
| Before each request of a session | `flush(session)`: any outcomes still waiting are delivered first. |
| On the owner thread, after queue changes and on a timer (about 1 s) | `pump(now_ms)`: delivers the outcomes of closed changesets, and partial ones 2 s after the last decision. |

Rules:

- Each batch of decisions is delivered once. A later outcome for the
  same changeset carries only the decisions made after the previous one.
- Only changesets made by an agent (`Origin.agentRef()`) are reported.
- The text ends with "Re-read files before editing them again." when a
  hunk was rejected or edited. A rejected change is gone from the
  agent's view, and the text says so.
- The reviewer's rewrites are shown as a unified diff from the proposal,
  at most 30 lines per file. A longer rewrite is reported as "The user
  rewrote N lines".
- E09 provenance: with `Options.records` set, `pump` checks that every
  hunk an apply took has a review reference (`ReviewRecords.has`), and
  writes the missing ones (`record`), logging each repair. The
  reference is `{apply, cs, path, hunk, decision, reviewer}`.

The decisions come from the queue's `decided` event, which the
`Applier` emits for every apply, before `applied` and `state`.
