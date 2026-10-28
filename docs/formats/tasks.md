# Task files

The task board is a folder of Markdown files, one per task, in
`.zigguro/tasks/` in the workspace. Each file is readable and editable in
any editor and in Obsidian: the board reads the properties at the top and
leaves everything else alone. Agents and people use the same files, so a
task created by `task_create`, from the board or by hand is the same thing.

```markdown
---
id: T-0042
title: Write the task format docs
status: ready
priority: P1
assignee: agent:writer
labels: [docs, agents]
depends_on: [T-0040, T-0041]
due: 2026-11-01
created: 2026-10-23T12:00:00Z
---
# Write the task format docs

Explain the properties and the query language.
```

New files are named `T-0042-<slug>.md`, where the slug comes from the
title. The name is only a convenience; the `id` property is what counts,
and renaming a file never changes its task.

## Properties

| Property | Value | Default |
| --- | --- | --- |
| `id` | `T-0042` (also `t-42` or `42`) | required |
| `title` | text | the first `# ` heading, else the file name |
| `status` | `backlog`, `ready`, `in_progress`, `review`, `blocked`, `done`, `cancelled` | `backlog` |
| `priority` | `P0` (most urgent) to `P3`, or `0` to `3` | `P2` |
| `assignee` | a person, or `agent:<definition>` | none |
| `labels` | a list, or one comma-separated string | none |
| `depends_on` | a list of task ids | none |
| `due` | `YYYY-MM-DD` (a datetime keeps its date) | none |
| `created` | a date or datetime, set when the task is created | none |
| `rank` | the order within a column (written by the board) | none |
| `claimed_by` | the run working on the task (written when an agent claims it) | none |
| `github` | `owner/repo#123` when synced with GitHub Issues | none |
| `project` | the slug of the project the task belongs to ([projects](projects.md)); new tasks get the active project | none |

Statuses accept any case and `-` or a space for `_`, so Obsidian's
`In Progress` works. Every other property (`tags`, `aliases`, your own) is
kept byte for byte, as are comments, quoting style and line endings.

A file never fails to load. One with no frontmatter, no valid id, an
unknown status, a bad priority, a bad date or a non-id in `depends_on` is
still shown on the board with a warning saying what is wrong. Two files
with the same id are both shown and flagged as duplicates. Dependency
cycles (including a task that depends on itself) are flagged, never
refused.

A task is **blocked** while any task it depends on is not `done` or
`cancelled`, or does not exist. When a task finishes, every task it was
the last open dependency of gets an `unblocked` event, which task
triggers (`automation.md`) can react to.

## Ids

Ids come from a counter in `.zigguro/state/tasks.zon`
(`.{ .version = 1, .next = 43 }`), which is kept above the largest id on
the board. Ids are never reused, even after a delete.

## Who writes what

- A person's change (board, palette, `zg task`) is written straight to the
  file. If the file is open in the editor, the change goes through the
  editor buffer instead, so it shows up there and is undoable.
- An agent's change is a review changeset (E12), except for `status` and
  `claimed_by`, which agents may set directly (policy
  `agents.tasks.auto_apply_fields`). Creating and deleting tasks are
  always changesets for agents.
- Deleting from the board moves the file to `.zigguro/tasks/.trash/`.
- Edits made outside the app are picked up through the file watcher.

## Query language

The board's filter box, the `task_list` tool and task triggers share one
query language. A query is terms separated by spaces; a task must match
every term. A leading `-` negates a term. Keys and values ignore case.

| Term | Matches |
| --- | --- |
| `status:ready` | the status; `status:ready,review` for either |
| `label:docs` | tasks with the label |
| `assignee:alice` | the assignee; `assignee:agent:*` any agent, `assignee:*` anyone (`-assignee:*` unassigned) |
| `priority:P1` | the priority; `>=P1` means P1 or more urgent (also `>`, `<=`, `<`) |
| `due:2026-11-01` | the due date; with `<`, `<=`, `>`, `>=`, and `today` in place of a date |
| `due:overdue` | due before today and not finished |
| `blocked:true` | blocked by an open dependency (`false` for not blocked) |
| `claimed:true` | claimed by a run (`yes`/`no` work too) |
| `text:"some words"` | the title contains the text |
| `id:T-0042` | that task |
| `project:book` or `p:book` | tasks tagged with that project; `project:none` for untagged |
| `words` or `"a phrase"` | the title contains it |
| `sort:priority` | order by `id` (default), `priority`, `due`, `created` or `title`; `sort:-due` reverses. Ties keep id order; undated tasks sort last by due |

Grammar:

```
query  = { space } [ term { space { space } term } ] { space }
term   = [ "-" ] ( key ":" value | word | phrase )
key    = "status" | "label" | "assignee" | "priority" | "due"
       | "blocked" | "claimed" | "text" | "id" | "sort"
value  = [ op ] ( word | phrase )
op     = ">=" | "<=" | ">" | "<" | "="
phrase = '"' { any character but '"' } '"'
```

An unknown key, an empty value, a bad status, priority, date or boolean,
or an unclosed quote makes the whole query invalid; the board shows the
error under the filter box instead of guessing.

## Claims

An agent claims a task before working on it, so two agents never work on
the same one. A claim is a lock file, `.zigguro/tasks/.claims/T-0042.lock`
(never committed: the folder has its own `.gitignore`):

```
run=01JABCDEFGHJKMNPQRSTVWXYZ0
until=1792757700
pid=4242
host=virindi
```

- Claiming needs the task `ready` (or `backlog`, when a person starts an
  agent on it from the board), every dependency finished, and no live
  claim. The lock is written whole to a temporary file and renamed into
  place without replacing, so exactly one claimer wins, across threads
  and processes. The task then gets `status: in_progress` and
  `claimed_by: <run>`.
- A lease lasts 15 minutes. The app renews the leases of running agents
  every 5 minutes; a claim not renewed within 30 seconds after it ends is
  stale. The reaper (every minute) puts stale claims' tasks back in
  `ready` and notes it in the task's agent log, so a crashed run's task
  is free again within the lease plus a minute. Another claimer may also
  take over a stale lock.
- Releasing ends the claim: `done` and `review` set that status;
  `failed` and `abandoned` put the task back in `ready` with a note.

## Agent log

Claims that expire, progress notes and completions are appended to a
`## Agent log` section at the end of the task (added when missing):

```markdown
## Agent log

- 01JABCDEFGHJKMNPQRSTVWXYZ0: parser done, writing tests
- 01JABCDEFGHJKMNPQRSTVWXYZ0 finished (review): Fixed the parser and added 12 tests
```

These lines are written directly; every other change an agent makes to a
task is a changeset for review.

## Agent tools

| Tool | Does |
| --- | --- |
| `task_list` | Tasks matching a query (default: open tasks by priority) |
| `task_get` | A task's properties, blockers and body |
| `task_create`, `task_update` | Propose a task or a change (reviewed) |
| `task_claim`, `task_claim_next` | Claim a task, or the most urgent ready one matching a query |
| `task_progress` | Add a note to the agent log |
| `task_complete` | Finish with outcome `review` or `done` |
| `task_release` | Give the task back, with the reason |

`TaskCreated` and `TaskCompleted` hooks (settings `ai.hooks`, as in Claude
Code) run before an agent creates or completes a task; exit code 2
blocks it and stderr goes back to the agent.

Starting an agent on a task (S on the board) claims the task for the new
run, then runs the assignee's agent definition (`agent:<name>`) with the
task as the prompt. Tasks labelled `code` run in their own lane.

## GitHub Issues

A workspace's tasks can sync with one repository's issues, from the app
or with `zg tasks gh pull|push|publish|status` (token in `GITHUB_TOKEN`
or `GH_TOKEN`; `--repo OWNER/NAME` the first time).

| Task | Issue |
| --- | --- |
| `title` (and the body's first `# ` heading) | title |
| the body below it, without `## Agent log` | body |
| `done` / `cancelled` / anything else | closed as completed / closed as not planned / open |
| `labels` | labels (a set, ignoring case) |
| `assignee` (a person) | the first assignee |

- **Pull** imports open issues as `backlog` tasks with
  `github: owner/repo#N` (closed issues and pull requests are not
  imported) and brings changes to linked tasks. An issue reopened on
  GitHub reopens a finished task as `ready`; an open task keeps its
  status. Only issues updated since the last pull are fetched, so an
  unchanged repository costs one request answered `304 Not Modified`.
- **Push** sends local changes of linked tasks. A task whose issue was
  deleted on GitHub is unlinked and kept.
- **Publish** creates an issue for a task. Only a person's "Publish to
  GitHub" does this; pull and push never create issues.
- `--label` (setting `labels_filter`) limits the sync to issues with
  those labels, and published tasks get them.

Each field merges against the last values both sides agreed on. A field
changed on one side is copied to the other. A field changed on both
sides, to different values, is a **conflict**: neither side is
overwritten, and a review item shows both (accepting it takes GitHub's
value). Labels never conflict: what either side added is kept and what
either side removed is dropped. The agent log and an `agent:*` assignee
stay local. Requests are paced as GitHub asks: one at a time, a second
apart for writes, and rate limits waited out.

The sync's state (the agreed values, as hashes for the title and body,
and the list's ETag) is `.zigguro/state/gh_sync.zon`, rewritten
atomically after each pull, push or publish.

## Budgets

Measured by `zig build bench -- --filter tasks` in `packages/agents`:
a cold open of 10,000 task files under 250 ms (`tasks/index_10k`) and a
filtered, sorted query over them under 10 ms (`tasks/query_10k`). Only
the first 16 KiB of each file is read for the index.
