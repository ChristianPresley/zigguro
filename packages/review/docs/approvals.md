# Approvals inbox

`zg_review.approvals` hosts E16's approval tickets (E12.F05.S02.T01). When
`zg_security.Engine.decide` returns `ask`, E16 presents the request through
`ApprovalBroker.approvalPort()`, a `zg_security.contracts.ApprovalPort`.
The waiting caller (E06's terminal service, E10's invoke pipeline) blocks
in `ApprovalTicket.await(io)` until a view answers.

## One model, many views

Every view lists the same items: E10's agent cards (filtered to their
session), the review panel's inbox, toasts and `zg review approvals`.

| Call | What it does |
| --- | --- |
| `present(req)` | Copies the request and adds it as `pending` (a `created_ms` of 0 becomes now). Any thread. |
| `presentChained(req, previous)` | The same, for a request that re-asks an edited input. |
| `await(id, io)` | Blocks until answered, cancelled or expired. Cancelling `io` cancels the request and returns `error.Canceled`. |
| `answer(id, answer, view)` | First answer wins; later ones get `error.AlreadyAnswered`. `edit` needs `req.editable` (`error.NotEditable`). |
| `cancel(id)` | The turn ended: the item leaves every view, the waiter gets a denial. |
| `expireDue(now_ms)` | With `Options.timeout_ms` (the `approvals.timeoutSeconds` setting), expires old pending requests; the waiter gets a denial. The owner calls it on a timer. |
| `list(arena, filter)`, `get(id)`, `pendingCount(filter)` | Pending first, then oldest first. `Filter.session` selects one agent session; cancelled items are never listed. |
| `addListener(l)` | `changed(id, state)` after each change, outside the lock. |
| `prune(before_ms)` | Frees items answered before `before_ms`. |

`commandView(req, arena)` gives a command request's line with the `cwd`,
`terminal` and `shell` keys of `req.detail_json` (E06 and E10 put them
there).

## In the IDE

The workbench owns one broker for the window and passes it to the agent
host (`ToolApprovals` presents through its port) and to the review glue,
which `bind`s it to the review store when that opens. The review queue
panel lists the requests at its top (`apps/zigguro/src/review/
approvals_view.zig`): one card per request (`approval_card.zig`), with
keys `y` `s` `Y` `n` `e` `j` `k` `o`. A new request shows the panel; while
the window is unfocused, requests within 1.5 s share one toast. The
status bar shows "⚑ N approvals".

## States

`pending`, then one of `allowed_once`, `allowed_session`,
`allowed_always`, `denied`, `edited_allowed` (from the answer), or
`cancelled`, or `expired`.

## Persistence and audit

With `Options.recorder` set to the review store's `approvalRecorder()`,
every change appends an `approval` record (journal kind 6) holding the
whole item. A load restores them through `QueueSink.approvals`
(`restoreSink()`): the last record of an id wins, and a request that was
still pending comes back `expired`, since its waiter died with its
process. A compaction does not keep approval records.

Approvals are answered in the process that asked. Processes sharing a
store use distinct `Options.id_base` values (the glue uses the store's
process tag) so their ids do not collide.

E12 never writes the audit log: the waiting caller passes the `Answer` to
E16's `Engine.recordAnswer`, which saves grants and rules and appends the
audit record.

## Budget

`review.approvals.round_trip` (present, answer, await): about 1 µs. The
rest of "answer to resumed waiter < 1 ms" is one `Io.Event` wake.
