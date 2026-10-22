# Hooks

Hooks are commands that run at points in the agent's life. They use the
same format and rules as Claude Code hooks, so a Claude Code hook script
works unchanged. The engine is `packages/ai/src/ext/hooks.zig`.

## Configuration

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "./scripts/check.sh", "timeout": 30 }] }
    ]
  }
}
```

`zg agent` reads hooks from these files, in this order:

| Layer | File |
|---|---|
| managed | `<managed>/hooks.json` |
| user | `<config>/hooks.json` |
| project | `.zigguro/hooks.json`, `.claude/settings.json` |
| local | `.zigguro/hooks.local.json`, `.claude/settings.local.json` |

`<config>` and `<managed>` are the directories in
`packages/config/docs/paths.md`. `"disableAllHooks": true` turns off every
hook except the managed ones. Project and local hooks run only in a
trusted workspace (E16). `zg agent` trusts the directory it runs in, as
`claude -p` does. Hooks in skill or agent frontmatter run only while that
skill or agent is active (`HookEngine.activate`). With an approver set
(the IDE), a project or local command runs only after the user approves
that exact command. A changed command needs approval again.

A handler has `command` and optionally:

- `args`: run `command` with these arguments and no shell;
- `timeout` (seconds, default 60);
- `shell` (`auto`, `bash`, `sh` or `powershell`);
- `onFailure` (`continue` or `block`);
- `statusMessage`.

With `shell: auto`, commands run under `bash -c`, falling back to
`/bin/sh -c`, and under `powershell -NoProfile -Command` on Windows.

## Events and matchers

The events are `SessionStart`, `SessionEnd`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`,
`Stop`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact` and
`Notification`. The agent loop calls `UserPromptSubmit`, `Stop`,
`PreToolUse` and `PostToolUse`/`PostToolUseFailure`. The app calls the
other events through `HookEngine.run`.

What a matcher is tested against depends on the event:

| Events | Matched against |
|---|---|
| tool events | the tool name |
| `SessionStart` | `startup`, `resume`, `compact` or `fork` |
| `PreCompact`, `PostCompact` | `manual` or `auto` |
| subagent events | the agent type |
| all other events | nothing: every hook runs |

The matcher itself can take three forms:

- `*`, empty or left out: matches everything.
- Only letters, digits, `_`, `-`, spaces, commas and `|`: a list of exact
  names.
- Anything else: a regex, searched unanchored.

Tool names match by the zigguro name or the Claude Code name, so `Bash`
matches `run_command` and `Edit|Write` matches `edit_file` and
`write_file`.

## Input and output

A hook reads one JSON object on stdin. It always has these fields:
`session_id`, `transcript_path`, `cwd`, `permission_mode`,
`hook_event_name`, and `agent_id` for subagents. Some events add more:

- tool events: `tool_name`, `tool_input`, `tool_use_id` and, after the
  call, `tool_response`;
- `UserPromptSubmit`: `prompt`;
- `SessionStart`: `source`;
- the compact events: `trigger`.

The environment has `ZIGGURO_PROJECT_DIR` and `CLAUDE_PROJECT_DIR`.

The exit code decides what happens:

- **0**: stdout is read as JSON if it is one object. For
  `UserPromptSubmit` and `SessionStart`, plain stdout is added as context.
- **2**: on `PreToolUse`, `UserPromptSubmit`, `Stop`, `SubagentStop`,
  `PreCompact` and `PermissionRequest`, the action is blocked and stderr is
  the reason. On other events, stderr goes to the model. Exit 2 wins over
  any JSON.
- **Anything else**, a timeout or a failure to start: a notice, unless the
  handler has `onFailure: block`.

The JSON output can contain:

- `continue: false` with `stopReason`;
- `decision: "block"` with `reason`;
- `systemMessage`;
- `hookSpecificOutput` with `permissionDecision` (`allow`, `deny` or
  `ask`), `permissionDecisionReason`, `updatedInput`, `additionalContext`
  and `updatedToolOutput`.

An updated input is validated against the tool's schema again before the
call runs. Context over 10,000 characters is saved to a file under the
state directory, and the model gets a preview and the file's path.

## Several hooks

All matching hooks for an event run in parallel. A command that appears
in more than one layer runs once. When their results conflict:

- `deny` wins over `ask`, and `ask` wins over `allow`;
- block reasons and contexts are joined;
- when more than one hook changes the tool input, the first in config
  order wins and a notice says so.

Each run goes to the audit sink with the event, command, exit code,
duration and decision. `zg agent` logs it at debug level and prints
notices on stderr.

Spawning a trivial hook and reading its answer takes about 2.3 ms on
Linux (bench `ai.hook_spawn_trivial`; budget 15 ms, 40 ms on Windows).
The engine tests run POSIX shell scripts (`packages/ai/testdata/hooks`)
and skip on Windows.
