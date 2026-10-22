# `zg agent` and the `zg.stream/1` protocol

`zg agent` runs the zigguro agent without the GUI. It is meant for scripts,
CI jobs and other programs. Other programs drive it over pipes with
`zg.stream/1`, a newline-delimited JSON protocol.

The code lives in `packages/ai/src/headless/`. The command itself is in
`apps/zg/src/cmd_agent.zig`.

## Modes

| Invocation | What happens |
| --- | --- |
| `zg agent -p "<prompt>"` | Runs one prompt, prints the answer and exits. |
| `cat log.txt \| zg agent -p "Why did this fail?"` | Same, with the piped input attached to the prompt as a `<stdin>` block. Input over 1 MiB is saved to a file under the state directory, and the prompt refers to it by path. |
| `zg agent --input-format stream-json --output-format stream-json` | Reads turns from stdin and writes events to stdout, as described below. |
| `zg agent` (on a terminal) | A line REPL. Ctrl-D exits. `/exit` and `/quit` also work; other slash commands arrive with E10.F09. |

`--output-format` is `text` (the default; the answer streams to stdout),
`json` (a single `result` object at the end) or `stream-json`. `zg agent
--help` lists every flag.

## Exit codes

These numbers never change meaning.

| Code | Meaning |
| --- | --- |
| 0 | The run finished. |
| 1 | The model or the harness failed: a provider error, a refusal, or an answer that still does not match `--json-schema` after one repair turn. |
| 2 | Invalid flags or arguments, an unknown model, or a session that cannot be found. |
| 3 | A budget ran out: `--max-turns`, `--max-budget-usd` or `--max-time`. |
| 4 | A tool call needed an approval that was not given. This happens with no prompt channel, a denied streamed prompt, or a timed-out streamed prompt. |
| 130 | Interrupted (SIGINT or Ctrl-C). The turn is cancelled and the session log is flushed. A second SIGINT exits at once. |
| 143 | Terminated (SIGTERM, Ctrl-Break, or the console closing). |

## Environment

| Variable | Use |
| --- | --- |
| `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY` | Provider keys. |
| `ZG_MODEL` | The default model. When it is not set, the default is `sonnet`. |
| `ZG_CASSETTE` | Records or replays provider HTTP in this file (see `zg_ai.testing.cassette`). |
| `ZG_CASSETTE_MODE` | `replay` (the default), `record` or `record_missing`. |
| `ZG_CASSETTE_SPEED` | `1` replays with the recorded timing. |
| `ZIGGURO_STATE_DIR` | Where sessions are saved, under `sessions/<workspace>/`. |

## Protocol

- Each message is one compact JSON object followed by `\n`, encoded as
  UTF-8. Output is flushed after every line.
- The first output line is always `system` with subtype `init`.
- The last output line is always exactly one `result`, including after an
  error or a signal.
- Unknown input fields are ignored.
- An input line with an unknown `type` is skipped, and a warning goes to
  stderr. An input line that is not valid JSON is handled the same way.
- Versioning: adding a field keeps `zg.stream/1`. Removing or renaming a
  field makes it `zg.stream/2`. The version is in `system/init` as
  `protocol`.

### Output lines

| `type` | Fields |
| --- | --- |
| `system` | `subtype` (`init`, `api_retry`, `compact_boundary`), `session_id`, `model`, `cwd`, `tools`, `mcp_servers`, `permission_mode`, `protocol`; `api_retry` adds `attempt` and `retry_delay_ms`. |
| `assistant` | `message` (role and content blocks, as in session files), `session_id`, `parent_tool_use_id`. |
| `user` | `message` with the `tool_result` blocks of a tool round, `session_id`. |
| `stream_event` | `event` (a provider stream event: `text_delta`, `block_start`, `tool_input_delta`, `usage`, `stop`, ...), `session_id`. Only written with `--include-partial`. |
| `permission_request` | `request_id`, `tool`, `input`, `reason`. Only written with `--permission-prompts stream`. |
| `result` | `subtype` (`success`, `error_max_turns`, `error_budget`, `error_during_execution`, `error_permission`, `error_interrupted`), `result`, `structured_output` (only with `--json-schema`), `session_id`, `num_turns`, `duration_ms`, `usage`, `total_cost_usd`, `is_error`, `permission_denials`. |

### Input lines

| `type` | Fields | Effect |
| --- | --- | --- |
| `user` | `message`: `{"role":"user","content": ...}`. The content is a string or a list of blocks; the text blocks are used. | Queued as the next turn. |
| `permission_response` | `request_id`, `behavior` (`allow` or `deny`), optional `message` and `updated_input`. | Answers a `permission_request`. A response may arrive before its request. |
| `interrupt` | — | Cancels the running turn. Queued turns still run. |

End of input ends the session after the queued turns. A permission request
that is still pending at that point is denied.

### Permission prompts

With `--permission-prompts stream`, a tool call that needs approval is
handled like this:

1. zigguro writes a `permission_request` line.
2. The tool waits until a `permission_response` with the same `request_id`
   arrives.
3. If no response arrives within 5 minutes (`ai.headless.permissionTimeout`),
   the call is denied.

Without that flag, a call that needs approval is denied. The run then
exits with 4, and the denial is listed under `permission_denials`.

`zg agent` offers the command tools `run_command`, `command_output` and
`kill_command` (see [tools.md](tools.md)). They run commands as child
processes of `zg`. A bare `--disallowed-tools` rule, such as
`run_command`, removes the tool from the requests.

`--allowed-tools` and `--disallowed-tools` take rules of the form `Tool` or
`Tool(pattern)`. The pattern is matched against the call's main argument:
`command`, `path`, `file_path`, `url` or `pattern`. A `*` in the pattern
matches any characters, and a trailing `:*` matches by prefix. Deny rules
win over allow rules.

## Example

Two turns, with a tool call approved over the pipe. The session id is
shortened here.

```
$ zg agent --input-format stream-json --output-format stream-json --permission-prompts stream
{"type":"user","message":{"role":"user","content":"build it"}}
{"type":"system","subtype":"init","session_id":"01J8…","model":"claude-sonnet-5-5","cwd":"/work","tools":["run"],"mcp_servers":[],"permission_mode":"default","protocol":"zg.stream/1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"run","input":{"command":"make"}}]},"session_id":"01J8…","parent_tool_use_id":null}
{"type":"permission_request","request_id":"perm_1","tool":"run","input":{"command":"make"},"reason":"run needs approval"}
{"type":"permission_response","request_id":"perm_1","behavior":"allow"}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"ran"}]}]},"session_id":"01J8…"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Built."}]},"session_id":"01J8…","parent_tool_use_id":null}
{"type":"user","message":{"role":"user","content":"thanks"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You're welcome."}]},"session_id":"01J8…","parent_tool_use_id":null}
^D
{"type":"result","subtype":"success","result":"You're welcome.","session_id":"01J8…","num_turns":3,"duration_ms":4120,"usage":{…},"total_cost_usd":0.0123,"is_error":false,"permission_denials":[]}
```

The golden test `packages/ai/testdata/golden/headless/two_turns_with_approval.golden`
contains the same exchange with `--include-partial`, replayed from a
cassette. `apps/zg/test/agent_e2e_test.zig` drives the built `zg` over real
pipes.

## Differences from Claude Code's stream-json

- `permission_request` and `permission_response` replace Claude Code's
  control-request messages for tool approval.
- `permission_request.input` is the tool's input as sent by the model.
  `updated_input` in a response is accepted but not applied yet.
- `result.subtype` adds `error_budget`, `error_permission` and
  `error_interrupted`.
- `usage` uses zigguro's field names (`input`, `output`, `cache_read`,
  `cache_write_5m`, `cache_write_1h`, `reasoning`, `server_tool_requests`).
- `stream_event.event` carries zigguro's provider-neutral stream events
  rather than raw Anthropic events.
- Message `meta` (timestamps and similar) is never written, so outputs
  compare byte for byte across runs.
- `user` output lines carry only tool results. The prompts you send are not
  echoed back.
