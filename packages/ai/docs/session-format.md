# Session file format (schema v1)

Every agent conversation is an append-only [JSON Lines](https://jsonlines.org/)
file (E10.F08.S01.T01):

```
<data_dir>/sessions/<workspace_key>/<session_id>.jsonl
<data_dir>/sessions/<workspace_key>/<session_id>.blobs/<sha256>   (large media)
```

- `data_dir` comes from E15 paths: XDG data home on Linux, `%LOCALAPPDATA%` on
  Windows.
- `workspace_key` is `<slug>-<hex16>`: a readable slug of the root's last path
  component and the first 16 hex digits of the SHA-256 of the canonical root
  path (`src/session/key.zig`). Auto memory uses the same key.
- `session_id` is a 26-character ULID.

The writer is `src/session/writer.zig`, the reader `src/session/loader.zig`,
the codecs `src/session/records.zig`. The golden fixture
[`testdata/sessions/all_records.golden`](../testdata/sessions/all_records.golden)
contains one line of every record type and is loaded by the tests, so it must
stay readable by every later version.

## Lines

Each line is one UTF-8 JSON object terminated by `\n`:

```json
{"v":1,"seq":N,"t":ms,"type":"<record type>", ...payload}
```

| Key | Meaning |
| --- | --- |
| `v` | Schema version of the writer. Readers accept any version and skip record types they do not know. |
| `seq` | Sequence number. Messages and events use the agent bus sequence, so stream-json output and session lines correlate. The header is `0`. |
| `t` | Unix milliseconds when the line was written. |
| `type` | The record type below. |

Keys are written in a fixed order. Messages use the `zg_ai_proto` JSON codecs
(`proto/json.zig`).

## Record types

### `header` (always the first line)

```json
{"v":1,"seq":0,"t":0,"type":"header","session":"01J80000000000000000000001","created":0,"cwd":"/work/repo","workspace_key":"repo-ddc5e473a09bd156","prompt_version":"p1","app_version":"0.0.0","origin":"cli","model":"claude-x"}
```

`parent` (`{"session":"<ulid>","seq":N}`) is present on forks: records with
`seq <= N` are read from the parent file. `origin` is one of `gui`, `cli`,
`subagent`, `schedule`.

### `user`, `assistant`, `tool_results`

A committed message. `tool_results` is a user-role message whose content holds
`tool_result` blocks.

```json
{"v":1,"seq":3,"t":0,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"running"},{"type":"tool_use","id":"t1","name":"read_file","input":{"path":"a"}}]}}
```

Images and documents whose base64 is 64 KiB or more are written to
`<session_id>.blobs/<sha256>` (decoded bytes) and referenced as
`{"source":{"type":"file","path":"<absolute path>"}}`.

### `event`

Harness events worth keeping: mode and model changes, approvals, hook
outcomes, errors, budget stops and recoveries.

```json
{"v":1,"seq":6,"t":0,"type":"event","kind":"mode","data":{"mode":"plan"}}
```

### `usage`

Token usage and cost of one model request.

```json
{"v":1,"seq":5,"t":0,"type":"usage","model":"claude-x","usage":{"input":10,"output":20,"cache_read":5,"cache_write_5m":0,"cache_write_1h":0,"reasoning":0,"server_tool_requests":0},"cost_micros":42}
```

### `compaction`

The active history restarts at `head_seq` (the compaction summary). Earlier
messages stay in the file for rewind and search.

```json
{"v":1,"seq":7,"t":0,"type":"compaction","head_seq":8,"trigger":"auto_threshold","tokens_before":1000,"tokens_after":100,"model":"claude-x"}
```

### `checkpoint`

An E12 checkpoint taken at the start of a user-prompted turn.

```json
{"v":1,"seq":2,"t":0,"type":"checkpoint","id":1,"turn":1,"label":"fix the bug"}
```

### `rewind`

The conversation head moved back to `to_seq`; later records stay in the file
but are inactive.

```json
{"v":1,"seq":9,"t":0,"type":"rewind","to_seq":1,"action":"conversation"}
```

### `title`

```json
{"v":1,"seq":8,"t":0,"type":"title","title":"Fix the bug"}
```

### `end`

```json
{"v":1,"seq":10,"t":0,"type":"end","reason":"exit"}
```

## Writing

- One writer per file, enforced with an exclusive file lock; a second writer
  gets `error.SessionLocked` and may fork instead.
- Records are buffered (64 KiB) and written after every committed record; the
  file is fsynced at turn end, on compaction and on close.
- With `ai.sessions.redactSecrets` (default on), user text and tool output pass
  through the E16 redactor before they are written.

## Reading and recovery

- **Torn tail.** If the last line lacks its `\n` or does not parse, the file is
  truncated to the last good newline.
- **Interrupted tool calls.** If the last assistant message has `tool_use`
  blocks and no `tool_results` follows, the loader synthesizes `is_error`
  results in memory (the file is not rewritten) telling the model the calls
  were cut off and to verify before running them again.
- **Tail-first.** The loader reads backwards in 64 KiB chunks until the last
  `compaction` record or the last 50 message records, parses only those and the
  header, and streams the earlier records later (`loadRest`).
- Corrupt lines in the middle are skipped; at worst a session opens with fewer
  records.

## Compatibility

Version bumps must stay backward-readable: add record types or optional keys,
never change the meaning of existing ones. Readers skip unknown record types.
