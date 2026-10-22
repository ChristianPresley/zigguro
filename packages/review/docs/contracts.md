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
`Applier` emits for every apply, before `applied` and `state`. Decisions made in another process
(`zg review accept` while `zg agent` runs) are journaled as `decided`
records and re-emitted by the store's `tail`. `zg agent` takes them in
when a turn ends and queues the outcomes of its own changesets for its
next request.

## E09 AI SCM proposals as review items (E12.F05.S03.T01)

`scm.ScmReviewPort` implements `zg_scm.ReviewPort`. Each `Proposal`
(describe, split, resolve, land) becomes a changeset with
`origin = .scm_proposal{kind, review}`, labelled with the summary and
carrying the rationale and lane. The review id is the changeset id.

| E09 provides | What E12 does with it |
| --- | --- |
| `PreviewFiles.files(arena, proposal)` | One `PreviewFile{path, base, new}` (zg_scm's `proposal_files.FileChange`) per path the proposal changes. A describe proposal sends `.zigguro/scm/description/<change>` with the old and new text. `PreviewFiles.ofRepo(&proposal_files)` reads them from a repository. The files show the preview and are never written: `Applier.apply` returns `error.ScmProposal` for these changesets. |
| `ScmActions.decide(item, decision)` | Carries out `ScmReviewPort.decide(cs, ScmDecision)`: describe approve (optionally with edited text) or reject, split and resolve approve or reject, and land with a `ReviewDecision`. `.conflicted` keeps the item open, because the preview no longer adopts cleanly. Otherwise the item is marked approved (applied) or rejected. `RepoActions` adopts or discards the preview on a `zg_scm.Repo` and forwards landing decisions to `LandingQueue.onReviewDecision`. An approved description that the reviewer edited goes through `zg_scm.ai.describe.redescribe` on the proposal's first commit (`Item.commit`). |
| `LandingQueue.events()` | `bindLanding(lq)` mirrors each lane state onto `Item.landing`. `returned_conflict` and `returned_checks_failed` reopen the item with the reason. `rejected` and `cancelled` close it. |

`status` maps changeset states as follows:

- pending or partially applied → `in_review`
- applied → `approved`
- rejected → `rejected`
- superseded or discarded → `cancelled`
- anything that is not a proposal → `unknown`

E09 calls the port on its worker thread, so the binding must run it under the queue's owner (the glue mutex).

A conflict resolution is reviewed region by region before it becomes an
item. `scm.RegionReview` wraps E09's `resolve.Run` and records one choice
for each region:

- `accept` takes the proposal. Only `ok` proposals can be taken.
- `edit` uses the reviewer's text. Text regions only.
- `side` takes side 0 or side 1.
- `keepConflict` leaves diff3 markers. Text regions only.

Regions that E09 marks `needs_human` (binary, mode, type and delete conflicts, or proposals that failed their checks) need a side or the reviewer's own text. `acceptProposed` takes every undecided `ok` proposal at once.

Once every region is decided, `submit(repo, port, …)` calls `resolve.applyResolutions`, which builds a detached preview. It then submits the result as a `resolve` proposal through the port. The rationale of each region taken as proposed goes into the proposal's rationale. Approving the item adopts the preview, and rejecting it discards the preview. Nothing reaches the repository before that approval.

Still open:

- persisting `Item` (preview op, lane) across restarts
- the proposal view in the IDE
