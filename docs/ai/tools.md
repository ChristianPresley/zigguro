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
  `todo_write`, `ask_user` and `run_command` for read-only commands (see
  [Plan mode](#plan-mode)).

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
2. **Plan mode.** In plan mode a call that plan mode does not allow is
   refused here, before any hook runs, even when the model calls a tool
   the toolset left out.
3. **`PreToolUse` hooks.** A deny ends the call. An allow skips the
   approval prompt, but deny rules and plan mode still apply. An ask forces
   a prompt. An updated input is validated again.
4. **Permission.** `deps.Permission` (E16 in the IDE) allows, denies or
   prompts. An input the user edits in the approval is validated again.
5. **The handler.** A Zig error from the handler becomes an instruction to
   the model, for example to try a smaller request after a timeout.
6. **`PostToolUse` hooks** (`PostToolUseFailure` when the result is an
   error). Their extra context is appended to the result, and an updated
   output replaces it.
7. **Bounding.** Text over 30,000 characters is cut to its first and last
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

## Web tools

**`web_fetch`** (`tools/builtin/web_fetch.zig`) fetches one URL:

- Only https. An http URL is upgraded and other schemes are refused.
- The E16 domain policy (`DomainPolicy`) decides each host before any
  request.
- Requests go through the `Transport` seam, so cassettes record them. A
  call has a 20 s timeout and a 10 MiB body cap.
- Redirects are followed on the same host only. A redirect to another
  host is returned to the model, which must call again, so an allowed
  domain cannot redirect the fetch somewhere else.
- HTML becomes Markdown through `html2md.zig`, which keeps the main
  content and drops navigation, footers, forms and scripts. Text and JSON
  stay as they are. A PDF becomes a document part when the model accepts
  documents. Anything else is described, not shown.
- `max_chars` (default 100,000) cuts the result. With `prompt`, the page
  goes to the `assist` model with the question, and only the answer
  returns.
- Pages are cached for 15 minutes (LRU, 32 MiB).

**`web_search`** (`tools/builtin/web_search.zig`) has three backends:

- `provider_native` declares the provider's own search tool, verbatim, to
  that provider's models only (`request.declFor` with `ToolSpec.native`).
  Other models do not see the tool.
- `http_json` calls a search API the user configured. A URL template, the
  headers and a mapping from the JSON answer to title, URL and snippet
  describe it. `allowed_domains` and `blocked_domains` filter the
  results.
- `disabled` registers nothing.

Every web result starts with `[untrusted web content from <host>]` and
only ever travels as a tool result, never in the system prompt. `zg agent`
registers `web_fetch` and the native search.

## Subagents

`task` (`subagent/task_tool.zig`) runs a subagent on a prompt and returns
its report. Several `task` calls in one turn run in parallel, at most
`max_concurrent` (20) at once.

Definitions are Markdown files with frontmatter (`subagent/defs.zig`):
`.zigguro/agents/*.md` in the workspace first, then the built-ins
`explore` (read-only, the cheap model), `plan` (read-only, plan mode) and
`general` (every tool). Keys: `name`, `description`, `tools`,
`disallowed-tools` (Claude Code names such as `Read` or `Bash` work),
`model` (`inherit`, `fast` or a model), `permission-mode`, `max-turns`,
`isolation` (`shared` or `workspace`), `skills`, `background` and
`effort`. The body is the system prompt, read when the agent starts.

A child (`subagent/runner.zig`):

- sees only its definition's prompt and the delegation prompt, never the
  parent's history;
- gets the definition's tools, without `task` at depth 3;
- runs in the definition's permission mode, else the parent's, and always
  in plan mode under a plan-mode parent;
- with `isolation: workspace`, works in its own E09 lane, whose handle the
  report returns while it has changes;
- shares the parent's permission engine, hooks and session log; its
  events reach `AgentManager.subscribeAll` with its own ref, whose
  `tool_call` is the parent's `task` call.

The report is the child's last answer, cut to 4k tokens, with a trailer:
`[agent explore · 3 tool calls · 12k tokens · $0.01 · files read: 2]`.
Cancelling the parent cancels its children. Spawning a child and getting
its report takes about 1.2 ms besides the model call (bench
`ai.subagent_spawn`).

## Plan mode

`plan/plan_mode.zig` switches an agent in and out of plan mode. In plan
mode:

- the toolset keeps the read-only tools, `exit_plan_mode`, `todo_write`,
  `ask_user`, `run_command` and `command_output`;
- `run_command` runs only commands on the read-only allowlist
  (`plan/readonly.zig`): `ls`, `cat`, `grep`, `find` without `-delete` or
  `-exec`, `git status`, `git log`, `git diff` and similar, joined by pipes
  only. Redirections, `;`, `&&`, background runs and command substitution
  are refused;
- the invoke pipeline and the headless permission engine both refuse
  anything else, so a hallucinated `edit_file` call does not run either;
- the system prompt carries the plan-mode addendum.

`exit_plan_mode {plan}` publishes `plan_proposed` and asks the approver.
The CLI approver shows the plan and asks `[a]` approve and auto-accept
edits, `[y]` approve, or `[n]` keep planning, with optional feedback. On
approval the plan, as the user edited it, is written atomically to
`.zigguro/plans/<session>.md`, `plan_approved` is published and recorded
in the session, the agent switches to the chosen mode, and the plan joins
the system prompt ("Current plan") and the compaction re-injection. The
session title becomes the plan's first heading. "Approve and clear
context" also replaces the history with the plan before the next request,
recorded as a compaction with trigger `plan_approved`. Keep planning
returns the feedback to the model and stays in plan mode.

`zg agent --permission-mode plan` and `-p` runs start in plan mode, with
read-only commands allowed; they do not register `exit_plan_mode` yet.
