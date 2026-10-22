# Agent evaluations

`zig build eval` runs the agent scenarios in `packages/ai/eval` against
fixture workspaces, grades what each run leaves behind, and fails when a
scenario regresses against `packages/ai/eval/baseline.json`. It runs
offline and takes a few seconds; CI runs it in the `eval` job.

```
zig build eval                          # the whole suite
zig build eval -Deval-filter=edit_      # scenarios whose name contains edit_
zig build eval -Deval-update-baseline   # accept the current results
zig build eval -Deval-live -Deval-model=sonnet   # record cassettes (maintainers)
```

The report is a table on stdout and `zig-out/eval/report.json`: per
scenario, pass or fail, each grader's verdict, turns, tokens, cost and wall
time. Workspaces stay in `.zig-cache/eval/<scenario>` for inspection.

## Layout

- `scenarios/<name>.zon`: one `Scenario` (`zg_ai.testing.eval`).
- `fixtures/<name>/`: starting workspaces. Each run copies its fixture into
  a fresh directory, so scenarios run concurrently (one per CPU).
- `cassettes/<name>.jsonl`: recorded provider HTTP (see
  `testing/cassette.zig`).
- `baseline.json`: the accepted results.

## Scenarios

```zig
.{
    .name = "edit_single",
    .fixture = "notes",
    .prompt = "Change alpha to ALPHA in a.txt.",
    .script = .{
        .{ .tools = .{.{ .name = "read_file", .input = "{\"path\":\"a.txt\"}" }} },
        .{ .tools = .{...}, .expect = .{"alpha"} },
        .{ .text = "Changed alpha to ALPHA.", .expect = .{"a.txt"} },
    },
    .graders = .{
        .{ .file_contains = .{ .path = "a.txt", .needle = "ALPHA\nbeta" } },
        .{ .file_unchanged = "sub/b.txt" },
        .no_permission_denials,
    },
}
```

The model is one of:

- **A script** (`script`): the model's turns written out: text, tool calls
  (input as JSON text) and token usage. `expect` lists text that must be in
  the request a turn answers, in its system prompt, messages or tool
  results. A harness that drops tool results, history or a compaction
  summary fails there.
  Scripts run as the `cassette` model (200k window, $3/$15 per Mtok).
- **A cassette** (`cassette`): recorded provider HTTP replayed through the
  real provider. `model` is then a catalog model.
- **Live** (`-Deval-live -Deval-model=<id>`): the real provider. Missing
  exchanges are recorded into `cassettes/<name>.jsonl` (`record_missing`).

The agent runs headless (`runPrint`) with stream-json output and no memory
files, with the file and command tools rooted in the workspace and `task`
with the built-in subagents. Subagents play the same script, so their
turns sit between the parent's, in order. A scenario also sets `permission_mode` (default `accept-edits`), `max_turns`,
`allowed_tools` and `disallowed_tools` (flag syntax), `hooks`
(`PreToolUse` rules matching a tool and a substring of its input),
`followup` (a second prompt run with `--continue`) and
`compact_after_tokens` (compact once the request grows by that many
tokens).

## Graders

| Grader | Passes when |
|---|---|
| `file_contains` | the file contains the text |
| `file_unchanged` | the file matches the fixture (or is still missing) |
| `command_succeeds` | the command exits 0 in the workspace within 60 s; `zig` is the zig running the build |
| `tool_used`, `tool_not_used` | the transcript has (or lacks) a call to the tool |
| `max_turns` | at most this many model calls |
| `max_cost_usd` | the run cost at most this much |
| `final_text_matches` | a `zg_regex` pattern matches the final answer |
| `no_permission_denials` | no call was denied |

A scenario passes when every grader passes, every `expect` was met and the
script was used up.

## Regressions

A regression is a scenario that passed in the baseline and fails now, a
new scenario that fails, or turns or cost grown by more than 25%. Update
the baseline with `-Deval-update-baseline` after an intended change.

With tool results dropped from the loop, 28 of the 36 original scenarios
fail. MCP scenarios wait on the MCP client wiring (E11).
