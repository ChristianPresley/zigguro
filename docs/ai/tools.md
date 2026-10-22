# Agent tools

The tool system lives in `packages/ai/src/tools/`. Every tool an agent can
call is a `proto.ToolSpec`. Tools come from three kinds of sources:

- built-in tools from zg_ai,
- exporters in other packages (LSP, workspace, SCM),
- MCP servers.

## Registry and toolsets

`ToolRegistry` holds the sources. It lists them again only after one
reports a change, such as an MCP `list_changed` notification. Each listing
becomes an immutable generation that stays valid until the registry is
freed.

**Names.** A name must match `^[a-zA-Z0-9_.-]{1,64}$`.

- An MCP tool becomes `mcp__<server>__<tool>`. Characters outside the
  alphabet become `_`.
- A name longer than 64 bytes is cut to 55 bytes, followed by `_` and 8 hex
  digits of its hash. `ToolRegistry.originalName` maps it back.
- A tool whose name is invalid or already taken is skipped. The generation
  lists the skipped tools under `warnings`.

**Order.**

1. Built-in tools, in their list order.
2. Package exporters, in registration order.
3. MCP tools, sorted by server and then by tool.

**AgentTools.** `AgentTools` is an agent's `deps.Tools`. It filters the
registry with a `ToolsetConfig`:

- `allow` and `deny` take exact names, `*`, or `prefix*` (for example
  `mcp__github__*`).
- Deny wins over allow. A denied tool is left out of requests entirely.
- Rules with a pattern, such as `run_command(rm *)`, are checked when the
  tool is called, not here.
- Plan mode keeps only the read-only tools, plus `exit_plan_mode`,
  `todo_write` and `ask_user`.

**When the toolset is rebuilt.** The loop calls `list` while it builds a
request, and the toolset is rebuilt only there. A change in the middle of a
request takes effect at the next one. Each toolset has a hash over the
names, descriptions and schemas. When a rebuild changes the hash, a
"cache prefix invalidated by tool change" warning is logged, because the
provider's prompt cache starts over from the tools.

**Deferred tools.** When an agent has more than `defer_threshold` tools
(64 by default), tools marked `defer_loading` are left out of requests and
`tool_search` is added in their place.

- `tool_search{query, limit}` matches a tool's name as a substring, then
  its name as a subsequence ("cri" finds `create_issue`), then its
  description as a substring.
- It returns the matching tools with their schemas.
- The tools it returns are declared from the next request on.

## Command tools

| Tool | Input | Result |
| --- | --- | --- |
| `run_command` | `command`, optional `description`, `cwd`, `timeout_ms` (1,000 to 600,000; default 120,000), `background` | Output lines, then `Exit code: N`. |
| `command_output` | `handle`, optional `since_line`, `wait_ms` (at most 60,000) | New lines, the status, and `Next since_line: N`. |
| `kill_command` | `handle` | `Stopped cmd_N.` |

Every command gets a handle `cmd_N`, which only the agent that started it
can use.

**Timeouts and background commands.**

- A command still running at its timeout moves to the background. The
  result says so and includes the output so far.
- A command starting with `sleep` is stopped at its timeout instead.
- `background: true` returns the handle at once.
- Background commands are stopped after 30 minutes.

**Results.**

- A non-zero exit code is not an error, because the model needs to see
  failures as data. `is_error` is set only when the command could not
  start or was denied.
- Results keep the last 30,000 characters and say how many earlier lines
  were left out.
- `command_output` pages forward from `since_line`.
- Lines stream to the tool card while the command runs.

**Canceling.** Canceling a call interrupts the command and its process
tree.

**Where commands run.** Commands run through a `TerminalHost`:

- In the IDE, the host is E06's `TerminalService`. Each agent has its own
  visible terminal, unless the user turned that off.
- `zg agent` uses `ProcessHost`. It runs each command under `/bin/sh -c`
  (POSIX) or `cmd.exe /d /c` (Windows), and captures stdout and stderr.
  A session keeps the last `cwd` it was given, but a `cd` inside a command
  does not carry over.
- On POSIX, an interrupt sends SIGINT, then SIGTERM after 2 s, then SIGKILL
  after 2 more seconds. Each signal goes to the command's whole process
  group.
- On Windows, the command runs in a job object, and an interrupt
  terminates that job object.

**Policy.** E16 decides each command through `CommandPolicy`, using the
command, its `cwd`, the terminal session and the agent. A denial is
returned to the model as `Permission denied: <reason>`.

**Tests.** `run_test.zig` drives the tools against `FakeHost`, a scripted
host with virtual time. `process_host_test.zig` runs real processes,
including the process-tree stop.

## File tools

`read_file`, `edit_file`, `multi_edit` and `write_file` work through the
`Files` seam in `tools/builtin/files.zig`, so the same tools run against
the IDE's open documents and against the disk.

- **`read_file`** returns numbered lines and pages with `offset` and
  `limit`. It cuts long lines, decodes UTF-16 that has a BOM and refuses
  binary files. Images and PDFs go to the model as image or document
  parts when it accepts them. Text from an unsaved editor buffer is marked
  as such.
- **`edit_file`** replaces one match of `old_string`, or every match with
  `replace_all`. **`multi_edit`** applies several replacements to the text
  the agent read and proposes the result as one change, so all of them
  land or none do.
- **`write_file`** creates a file, or replaces one the agent has read.
- Every change is a proposal. `Files.propose` applies it, keeps it pending
  in a changeset for review, or rejects it (for example as stale), and
  the model is told which.
- `ReadTracker` records what each agent has read and at which version.
  An agent must read a file before it edits or replaces it.
- `zg agent` uses `DiskFiles`, which applies proposals directly. The IDE
  adapts `Files` to the editor's agent edit sessions.

## The invoke pipeline

Every tool call goes through `tools/invoke.zig`, in this order:

1. **Validation.** The input is checked against the tool's schema. An
   invalid input returns the errors to the model and nothing else runs.
2. **`PreToolUse` hooks.** A deny ends the call. An allow skips the
   approval prompt, but deny rules and plan mode still apply. An ask forces
   a prompt. An updated input is validated again.
3. **Permission.** `deps.Permission` (E16 in the IDE) allows, denies or
   prompts. An input the user edits in the approval is validated again.
4. **The handler.** A Zig error from the handler becomes an instruction to
   the model, for example to try a smaller request after a timeout.
5. **`PostToolUse` hooks** (`PostToolUseFailure` when the result is an
   error). Their extra context is appended to the result, and an updated
   output replaces it.
6. **Bounding.** Text over 30,000 characters is cut to its first and last
   2,000 characters, on line ends. The whole output is saved to
   `<spill dir>/<call id>.txt`, and the model is told the path so it can
   read the rest with `read_file`. `zg agent` saves under
   `<state dir>/tool-output`.

Every decision goes to the audit sink (`deps.Audit`). All of them except
plain permission allows are also published as `tool_decision` events. The
pipeline adds under 1 µs to a call that has no hooks and is allowed
(bench `ai.invoke_overhead`).

## Subsystem tools

Code intelligence, debugging, tasks, workspace search, notes, SCM and MCP
tools come from packages on zg_ai's layer, which zg_ai cannot import.
Each one exports its tools through `tools/adapters/foreign.zig`
`Exporter`, which uses only std types:

- `list` returns `ForeignTool`s: name, description, input schema, whether
  the tool is read-only or mutates, and MCP annotations.
- `call` returns an MCP `CallToolResult` as JSON text. `content` becomes
  the result parts, `structuredContent` becomes `structured_json`, and
  `isError` becomes `is_error`. A mutating tool also returns the id of the
  E12 changeset holding its change.

The app passes the exporters it has to `Adapters.registerAll`. A missing
subsystem registers nothing. Debug tools stay off unless the workspace
turns them on. Each adapter:

- keeps the exported names; MCP tools become `mcp__<server>__<tool>`;
- takes effects from the exporter. MCP annotations count only for servers
  the user trusts, and every tool of an untrusted server is treated as
  mutating;
- gives each call a deadline: 30 s for LSP and debug, 10 s for workspace
  and notes, 60 s for SCM, and 120 s for tasks and MCP;
- fails closed when a mutating tool succeeds without a changeset. The
  model gets an error and the result is dropped, so no exporter can write
  around review.

Calls lock the paths named in `path`, `file_path`, `file`, `uri` or
`paths`. Mutating SCM tools take the `.scm` lock.
