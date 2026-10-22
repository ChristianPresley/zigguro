# zg review JSON

`zg review ... --json` prints NDJSON: one object per line, each with a
`type`. Keys are snake_case and always present (null when unknown). Line
numbers are 1-based. The golden tests in
`apps/zg/src/review_cli_test.zig` pin the format.

## changeset

`list --json` prints one per changeset; `show --json` prints it first.

```json
{"type":"changeset","id":1,"state":"pending","label":"Turn 1: parser",
 "origin":"agent","session":"01J9D3R79E0000000000000001","agent":0,"turn":1,
 "rationale":null,"created_ms":352800000,"decided_ms":null,
 "auto_applied":false,"checkpoint":null,"files":1,"added":2,"removed":1,"hunks":2}
```

| Key | Value |
| --- | ----- |
| `id` | changeset number |
| `state` | `pending`, `partially_applied`, `applied`, `rejected`, `superseded`, `discarded` |
| `origin` | `agent`, `inline_edit`, `lsp`, `search_replace`, `notes`, `scm_proposal`, `code_review`, `user_bulk` |
| `session`, `agent` | the agent behind it (ULID and subagent number), or null |
| `turn` | the agent turn, for `agent` origins |
| `created_ms`, `decided_ms` | Unix milliseconds |
| `checkpoint` | the checkpoint taken before it |
| `files`, `added`, `removed`, `hunks` | what is still open |

## file

After its changeset in `show --json`.

```json
{"type":"file","changeset":2,"path":"README.md","op":"modify","from":null,
 "state":"pending","binary":false,"added":2,"removed":0,"hunks":1}
```

`op` is `create`, `modify`, `delete`, `rename` (with `from`) or
`set_executable`. `state` is `pending`, `partially_applied`, `applied`,
`rejected`, `conflicted`, `stale` or `superseded`.

## hunk

After its file in `show --json`; `hunk` is the number `--hunk` selects.

```json
{"type":"hunk","changeset":2,"path":"README.md","hunk":1,"state":"pending",
 "base_start":2,"base_count":0,"new_start":2,"new_count":2,"conflict":null,
 "removed_lines":[],"added_lines":["","Usage."]}
```

`state` is `pending` or `conflicted` (with `conflict`: `user_edit`,
`external_change`, `sibling_changeset`, `base_missing`). `removed_lines`
and `added_lines` (without terminators) are there with `--patch`.

## checkpoint

`checkpoints --json`.

```json
{"type":"checkpoint","id":1,"session":"01J9D3R79E0000000000000001","agent":0,
 "turn":1,"label":"Turn 1: parser","created_ms":352800000,"pinned":false}
```

## approval

`approvals --json`: the store's approval record (`packages/review/src/
approvals/broker.zig`). `detail` is the request's detail JSON as a
string; `answer.t` is allow_once, allow_session, allow_always, deny or
edit, with `text` for all but allow_once.

```json
{"id":330712481793,"state":"pending","kind":"command","actor":{"t":"agent","session":"s1","agent":"main"},
 "title":"Run command","detail":"{\"command\":\"make\"}","command":"make","risk":["Runs a program on this machine."],
 "rule":"run_command(make)","editable":true,"created_ms":359880000}
```

## Coming

`thread` objects (review comments) arrive with E12.F05.S01.
