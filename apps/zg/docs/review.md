# zg review

`zg review` works the review queue of the workspace in the current
directory from a terminal (E12.F03.S05.T01). It reads and writes the same
store as the IDE, `.zigguro/review/`, and decides through the same
`Applier`, so it can run while zigguro has the workspace open: each
process appends its records to the journal and reads the other's.

```
zg review list [--state pending|all] [--agent SESSION] [--json]
zg review show ID [--patch] [--file PATH] [--json]
zg review accept ID (--all | --file PATH... | --hunk PATH:N[,N...] | --hunk PATH:*) [--yes]
zg review reject ID (same selectors)
zg review checkpoints [--session SESSION] [--json]
zg review restore CKPT [--mode agent|full] [--dry-run]
zg review debug-dump [--from SEQ]
```

`ID` is a changeset number, `3` or `#3`. `SESSION` is an agent session id
(26-character ULID) or any prefix of it, in any case. Every command
answers `--help`.

## Commands

**list** prints the changesets waiting for review (pending or partially
applied), or every changeset with `--state all`, in submission order. The
table has the id, state, files, lines added and removed, age, origin
(`agent 01J9D3` for a session's main agent, `agent 01J9D3/2` for its
subagent 2) and label. Rows are cut to the terminal width (`COLUMNS`, or
100).

**show** prints who made a changeset, when and why, then one line per
file: `A` create, `M` modify, `D` delete, `R` rename, `X` executable bit.
`--patch` adds a unified diff of each file with three lines of context;
each hunk header names the hunk's number and state, which is what
`--hunk` selects:

```
@@ -8,3 +8,4 @@ hunk 2 [pending]
```

`--file PATH` limits the patch (and the JSON) to one file.

**accept** and **reject** decide part or all of a changeset:

- `--all`: every file still open. On a terminal it asks first, unless
  `--yes` is given.
- `--file PATH` (repeatable): every hunk of that file, or the file itself
  when it has no hunks (delete, rename, mode change, binary).
- `--hunk PATH:N[,N...]`: those hunks of the file, numbered from 1 as
  `show --patch` prints them; `PATH:*` is the whole file.

Accepted text is written to disk at once. Decided hunks leave the file,
so the hunks that remain are numbered again from 1 (run `show --patch`
again before picking more). A file whose content changed since the agent
read it is refused with exit 3 and nothing is written: review it in
zigguro, where the change is rebased, or reject it.

**checkpoints** lists the turn checkpoints, oldest first, optionally of
one session.

**restore** reverts what review applied after a checkpoint: only that
checkpoint's session (`--mode agent`, the default) or every agent's
(`--mode full`). Changesets submitted after it are discarded. When a file
was changed since on the same lines nothing is written and the conflicts
are listed (exit 3). `--dry-run` prints what would change.

**debug-dump** prints the store's journal records as NDJSON objects
`{"seq":N,"kind":"changeset|remove|checkpoint|apply|ids","record":{...}}`,
from record `--from` on.

## Output

Colour is used when stdout is a terminal and `NO_COLOR` is not set. With
`--json` every command prints one JSON object per line; the objects are
described in [review-json.md](review-json.md).

## Exit codes

| Code | Meaning |
| ---- | ------- |
| 0 | ok |
| 1 | usage error |
| 2 | the store could not be read or written |
| 3 | conflict: the base moved, the file or changeset is decided already, a restore would overwrite later edits |
| 4 | not found: no store, changeset, file, hunk or checkpoint |
| 5 | partially applied: a write failed after earlier files were written and could not be rolled back |

## Not yet

- `comment`, `threads`, `fix`, `approvals`, `approve` and `deny` arrive
  with review comments and approvals (E12.F05); today they exit 1.
- `zg agent --review interactive|defer|policy` and the `review` events of
  `zg.stream/1`.
- Refusing hunks of a file zigguro has open with unsaved edits needs the
  IDE's `doc_open` records.
