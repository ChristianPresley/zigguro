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
zg review policy explain PATH [--op OP] [--from OLD] [--origin ORIGIN] [--tool NAME] [--agent NAME] [--mode MODE] [--lines N]
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

**policy explain** shows what the edit policy decides for a change to
`PATH`, and which step or rule decided it. The policy reads the `review`
section of `.zigguro/settings.zon` (see
`packages/review/docs/policy.md`). `--op` is create, modify, delete,
rename (with `--from`) or mode. `--mode` is the agent's permission mode:
default, accept_edits, plan, dont_ask or bypass. `--lines` is the number
of changed lines; leave it out when it is unknown. Invalid rules are
reported on stderr. E16's own permission rules are not consulted.

**approvals** lists the requests a process (the IDE) waits on for
approval: id (`!N`), state, age, who asks, the title and command, and the
risk hints. `--all` adds answered, cancelled and expired ones.

**approve AID** allows a waiting request once; `--session` allows it for
the session (with the suggested rule), `--always [RULE]` saves RULE (else
the suggested one), `--edit TEXT` allows an edited input (commands, or
JSON for tool inputs, only when the request is editable). **deny AID
[--reason TEXT]** refuses it; the reason goes back to the agent. The
answer is appended to the store; the waiting IDE takes it within a
second (its review queue polls the journal). A request that is not
waiting any more exits 3.

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
| 3 | conflict: the base moved, the file, changeset or approval is decided already, a restore would overwrite later edits |
| 4 | not found: no store, changeset, file, hunk, checkpoint or approval |
| 5 | partially applied: a write failed after earlier files were written and could not be rolled back |

## Not yet

- `comment`, `threads` and `fix` arrive with review comments
  (E12.F05.S01); today they exit 1.
- The `review` events of `zg.stream/1`.
- Refusing hunks of a file zigguro has open with unsaved edits needs the
  IDE's `doc_open` records.

## zg agent --review

`zg agent` sends its file edits through the same review glue as the IDE:

- `--review defer` (the default): each turn's edits become one pending
  changeset; nothing is written. The agent reads its own pending changes
  back. At the end of the run the ids are printed on stderr, for
  `zg review show ID --patch` and `zg review accept ID --all`.
- `--review interactive`: on a terminal, each pending changeset of the
  run is offered at the end: `a` accept, `r` reject, `v` view (through
  `$PAGER` when set), `s` skip. Without a terminal it behaves as `defer`.
- `--review apply`: edits are written at once and recorded as
  auto-applied changesets (undoable from the IDE's review panel).
- `--review policy`: each turn is held, then the workspace's edit policy
  decides file by file. It applies what it auto-applies, rejects what it
  denies, and leaves the rest pending. `--permission-mode accept_edits`
  auto-applies plain edits outside protected paths, and `plan` denies
  everything.

The store is created by the first edit, so a run that edits nothing
leaves no `.zigguro/review/` behind. The IDE takes in what the CLI decided
while its review panel is open.
