# The review queue view

`zg_review.queue_view.QueueModel` (E12.F03.S01.T01) is what the queue panel
and `zg review` show. It is UI-agnostic and follows the queue's events.

## Rows

The rows form a flattened tree:

- **Group** rows. There are none when grouping is `none`.
- **Changeset** rows: label (cut to 120 bytes), files, +added −removed,
  conflicts, and creation time.
- **File** rows, shown only under expanded changesets.

`toggle(i)` expands or collapses row `i`. `version` changes whenever the
rows would.

Groups:

| `group_by` | Groups |
| --- | --- |
| `session` (default) | One per agent session, titled with the session's display name and the end of its id. Changes without an agent go in their origin's group. |
| `agent` | The same, with subagents apart. |
| `origin` | Agent, Inline edit, LSP, Search/Replace, Notes, SCM, Code review, Bulk edit. |
| `path` | The top-level directory of the first file. |
| `none` | No groups. |

Groups are ordered newest first, and so are the changesets inside them.
Changesets applied without review in the last 24 hours are pinned at the
bottom, under "Recently auto-applied (last 24 h)", whatever the state
filter says; the filter's other terms (text, path, agent, origin,
conflicts) apply to them as usual.

## Filters

`parseFilter` reads `key:value` tokens plus free text:

| Token | Matches |
| --- | --- |
| `state:pending`, `state:applied`, `state:open`, `state:all`, … | States. Repeated tokens add up. The default is pending and partially applied. |
| `origin:agent`, `origin:lsp`, … | Origins. Repeated tokens add up. |
| `agent:name` | A substring of the agent's display name. |
| `path:src/**` | An E08 glob that any file of the changeset matches. |
| `conflicts:yes` / `conflicts:no` | Changesets with or without a conflict, on a hunk or with another changeset (ConflictIndex). |
| free text | A substring of the label, paths or agent name. |

Matching ignores case. Filtering 5,000 changesets takes under 8 ms in a
release build.

## Counts

`counts()` covers every open changeset, whatever the filter: pending
changesets, undecided hunks, changesets with conflicts, and per-session
totals. These feed the agent tabs and the status bar. Approvals (F05) are
not counted yet.
