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

## Budgets

Measured by `zig build bench -- --filter tasks` in `packages/agents`:
a cold open of 10,000 task files under 250 ms (`tasks/index_10k`) and a
filtered, sorted query over them under 10 ms (`tasks/query_10k`). Only
the first 16 KiB of each file is read for the index.
