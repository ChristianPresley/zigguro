# Automation files

An automation runs an agent (or a workflow) without anyone at the keyboard:
on a cron schedule, once at a set time, or when files, the repository or
the task board change. Each automation is one file,
`.zigguro/automations/<name>.zon`, in the workspace. The manager UI, the
`automation_create`/`automation_update` agent tools and
`zg automation enable|disable` all write the same file, and
`zg automation validate` checks every file (exit 1 on any problem, so it
can run in CI).

```zig
.{
    .version = 1,
    .name = "daily-digest",
    .description = "Summarize yesterday's merged changes into today's daily note",
    .enabled = true,
    .triggers = .{.{ .schedule = .{ .cron = "0 9 * * 1-5", .jitter_s = 120 } }},
    .action = .{ .agent = .{
        .prompt = "Summarize what merged since {{last_run_at}} into the daily note for {{date}}.",
        .agent_def = "writer",
        .model = "sonnet",
    } },
    .profile = "unattended-notes-write",
    .isolation = .shared,
    .overlap = .skip,
    .catch_up = .latest,
    .budgets = .{ .max_cost_micro_usd = 500_000, .max_wall_ms = 900_000 },
}
```

## Fields

| Field | Type | Default | Meaning |
|---|---|---|---|
| `version` | integer | `1` | Format version. Other values are rejected. |
| `name` | string | required | `[a-z0-9][a-z0-9-]{0,63}`, equal to the file name without `.zon`. |
| `description` | string | `""` | Shown in the manager and `zg automation list`. |
| `enabled` | bool | `true` | A disabled automation never fires. |
| `triggers` | list | required, at least one | What starts a run (below). |
| `action` | union | required | `.agent` or `.workflow` (below). |
| `profile` | string | `"unattended-readonly"` | The E16 permission profile the run uses. |
| `isolation` | `.shared` or `.lane` | `.shared` | `.lane` runs in its own SCM lane. |
| `overlap` | `.skip`, `.queue` or `.replace` | `.skip` | What happens when a fire comes while the last run is still going: skip the fire, hold at most one until the run ends, or stop the old run and start the new one. |
| `catch_up` | `.latest` or `.none` | `.latest` | Fires missed while the machine slept or the app was closed (up to 7 days back): run the most recent one once, or none. |
| `budgets.max_cost_micro_usd` | integer | required for unattended triggers | Per-run cost cap in millionths of a dollar. Every trigger is unattended, so in practice it is always required. |
| `budgets.max_wall_ms` | integer | none | Per-run wall-clock cap. |
| `budgets.max_turns` | integer | none | Per-run model turn cap. |
| `budgets.monthly_cap_micro_usd` | integer | none | Month-to-date cap across this automation's runs; fires past it are skipped (`budget_exhausted`) and you are warned once. |
| `max_runs_per_hour` | integer | none | Fires past it in a sliding hour are skipped (`rate_limited`). Separately, all automations together fire at most 60 times an hour. |
| `max_chain_depth` | integer | `3` | How many automations may trigger each other in a row. |

### Triggers

| Trigger | Fields | Notes |
|---|---|---|
| `.schedule` | `cron` (string), `jitter_s` (integer, optional) | Five-field cron (`minute hour day-of-month month day-of-week`) in local time, with `JAN`–`DEC`, `SUN`–`SAT`, `7` = Sunday and `@yearly`, `@monthly`, `@weekly`, `@daily`, `@hourly`. `L`, `W`, `#`, `?`, seconds fields and `@reboot` are rejected. When day-of-month and day-of-week are both restricted, a day matches if either does (POSIX). `jitter_s` delays each fire by a fixed amount derived from the workspace and the name; by default there is none for schedules more frequent than every 10 minutes, otherwise a tenth of the interval, at most 5 minutes. |
| `.once` | `at` (string) | Local `YYYY-MM-DD HH:MM`. Fires once, then the automation is marked completed. |
| `.files` | `globs` (list), `events` (`.{ .created, .modified, .deleted, .renamed }`, all on by default), `debounce_ms` (default 2000) | Gitignore-style globs relative to the workspace; a leading `!` excludes, and the last match wins. |
| `.scm` | `events` (list of `.change_created`, `.op_committed`, `.lane_landed`, `.conflict_detected`, `.git_fetched`, `.bookmark_moved`), `revset` (optional) | |
| `.task` | `events` (list of `.created`, `.status_changed`, `.assigned`, `.commented`), `query` (optional) | `query` uses the task board's syntax, for example `status:ready label:agent`. |

Daylight saving: a wall time that happens twice (clocks going back) fires
once, at the first occurrence; a wall time that does not exist (clocks
going forward) fires at the first valid instant after the gap, so 02:30
in a 02:00 to 03:00 gap fires at 03:00.

#### Event triggers

- **Globs**: `*` (within a directory, dotfiles too), `**` (any depth),
  `?`, `[abc]`, `[!a-z]`, `{zig,zon}`. A pattern without a `/` matches
  at any depth (`*.md`); with one it is relative to the workspace root
  (`docs/*.md`). A trailing `/` matches a directory's contents. Changes
  under `.zigguro/runs/`, `.zigguro/state/`, `.git/` and `.zg/` never
  trigger.
- **Debounce**: file changes are collected until `debounce_ms` passes
  without another one, then the automation fires once with all of them.
- **Payload**: the run gets the event as data, never as part of the
  prompt: `{"event":"files","paths":[{"path":"docs/a.md","kinds":["modified"]}],"truncated":false}`
  (at most 1,000 paths), `{"event":"scm","kind":"lane_landed","change_ids":[...],"descriptions":[...],"lane":"..."}`
  or `{"event":"task","kind":"created","task":{...}}`. A prompt can name
  the files with `{{trigger.files}}`.
- **Loops**: changes an automation's own run made do not trigger it. A
  run triggered by another automation's changes counts one level deeper;
  past `max_chain_depth` (default 3) the fire is skipped and you get a
  notification.
- **Tasks**: `query` supports `status:`, `label:` (each must be
  present), `assignee:`, `priority:P1` or `priority:>=P1` (P1 or more
  urgent), and words that must appear in the title. The run claims the
  task before it starts; a task someone else claimed is skipped.

### Actions

| Action | Fields |
|---|---|
| `.agent` | `prompt` (required), `agent_def`, `skill`, `skill_args`, `model` |
| `.workflow` | `workflow` (required), `args` (JSON text) |

The prompt may use `{{now}}` (local `YYYY-MM-DD HH:MM`), `{{date}}`,
`{{last_run_at}}`, `{{last_run_summary}}` (the automation's previous run),
`{{trigger.files}}` (the changed files, comma separated) and
`{{trigger.event}}`. Unknown variables are left as written. Everything
else a trigger carries (file lists, SCM events, task JSON) reaches the
model as untrusted data after the prompt, never as instructions.

## Profiles

Three profiles ship for automations. None of them ever prompts: a tool
call that would ask is denied, and the model sees the denial. What each
one allows comes from its E16 permission rule set:

- `unattended-readonly`: read, search and web tools only.
- `unattended-notes-write`: writes limited to the notes vault, through review.
- `unattended-lane-write`: writes only in the run's own lane, through review.

## Trust

An automation that arrives with the repository (a clone or a pull) is
loaded disabled until you approve its exact content once, in the manager
("New automation from the repository: review and enable") or with
`zg automation approve NAME`. It cannot be run by hand before that
either. A file changed afterwards needs approval again. Automations you
create or edit yourself (manager, `zg automation enable|disable`) are
approved as you save them. Approvals live in your state directory
(`<state>/pins/automations.zon`, for example
`~/.local/state/zigguro/pins` on Linux), never in the workspace, so a
repository cannot approve its own automations.

## Where state lives

- `.zigguro/state/scheduler.zon`: the next fire id and, per automation,
  the last due time handled, its fire id and status, and whether a one-off
  automation completed. Written atomically after each fire.
- `.zigguro/state/scheduler.lock`: only the process holding this lock
  (the GUI or `zg agents host`) fires automations; the other retries every
  30 seconds.
- `.zigguro/runs/automations/<name>.jsonl`: one line per fire or skip,
  `{"t":…,"due":…,"fire":…,"reason":"scheduled|catch_up|once|manual|triggered","run":"<run id>"|null,"skip":"overlap|rate_limited|…"|null}`.

`zg automation list --json` output follows
[`automation.schema.json`](automation.schema.json).
