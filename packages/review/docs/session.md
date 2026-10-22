# Review session

`zg_review.session.ReviewSession` (E12.F03.S02.T01) is the controller behind
reviewing hunk by hunk. The review editor and `zg review` drive it. It has
no UI and does no I/O of its own: every decision goes through the
`Applier`, on the queue's owner thread.

## Target and files

A session reviews a `Target`:

| Target | Files |
| --- | --- |
| `.changeset = id` | The changeset's files, in path order. |
| `.session = s` | Every pending or partially applied changeset of agent session `s`, oldest first, each in path order. Folding keeps one pending change per path and session, so a path shows once. |

The order stays stable while the session is open. Files that arrive later
(a new changeset, a fold that adds a path) are appended, and `FileRef.new`
marks them.

## Cursor and navigation

`cursor` is a file index into `files()` and a hunk index into that file.
The hunk index is null when the file has no hunks (delete, rename, binary).

| Call | Moves to |
| --- | --- |
| `next` / `prev` | The next or previous hunk, crossing files. |
| `nextFile` / `prevFile` | The first hunk of the next or previous file. |
| `nextUndecided` | The next open hunk or file, wrapping around. |
| `nextConflict` | The next hunk with a conflict, wrapping around. |
| `focus(c)` | `c`, clamped. |

The cursor follows its hunk by key when the file is re-derived by a rebase
or a fold.

## Decisions

| Call | Does |
| --- | --- |
| `acceptHunk` / `rejectHunk` | The focused hunk. On a file without hunks, the whole file. |
| `acceptFile` / `rejectFile` | Every open hunk of the focused file. |
| `acceptChangeset` | Every open file of the focused file's changeset. |

A decided hunk leaves its file, because the Applier re-derives the rest.
The cursor therefore stays on the same index, which is now the next
undecided hunk.

A decision that fails changes nothing. It returns a `Failure` whose
message is also in `last_error`, for example `BaseMoved` when the file
changed on disk.

`progress()` returns what has been decided in the session and the total:
decided plus the open hunks, with one per open file that has no hunks.

## Undo

`undo` pops the last decision.

- An accept is reverted with `Applier.undoApply`, a three-way revert. If a
  later edit overlaps, nothing changes, and the failure names the file.
- A reject wrote nothing. The file gets back its edits, hunks and state
  from before it.

Not done yet: line selection inside a hunk, and edit-before-accept. Both
wait for the Applier's line-level split.
