# Workflow files

A workflow (E13.F08.S01) splits a large job across many agents: map over
files or questions, run branches in parallel, vote, loop until a check
passes, pause for approval. Workflows are declarative ZON files, so they
are reviewable, diffable and safe to run from automations. Project
workflows live in `.zigguro/workflows/<name>.zon`; `zg workflow validate
FILE` checks one.

```zon
.{
    .version = 1,
    .name = "audit-files",
    .description = "Find a class of problem in many files and rank the findings",
    .args = .{ .{ .name = "glob" }, .{ .name = "check" } },
    .steps = .{
        .{ .id = "files", .builtin = .{ .name = "files.glob", .input = "$args.glob" } },
        .{ .id = "audit", .phase = "Audit", .map = .{
            .over = "$.files",
            .as = "file",
            .agent = .{ .prompt = "Check {{$file}} for {{$args.check}}.", .schema = "findings.schema.json" },
        } },
        .{ .id = "report", .phase = "Report", .reduce = .{ .prompt = "Rank these findings: {{$.audit[*].findings[*]}}" } },
    },
}
```

Unknown fields are errors. Problems are reported before any agent starts.

## The workflow

| Field         | Default   | Meaning                                                        |
|---------------|-----------|----------------------------------------------------------------|
| `version`     | required  | `1`                                                            |
| `name`        | required  | `[a-z][a-z0-9-]*`                                              |
| `description` | `""`      | shown in lists                                                 |
| `args`        | none      | arguments (below), passed as JSON: `--args '{"glob":"…"}'`     |
| `steps`       | required  | at least one step, run in order                                |
| `limits`      | see below | concurrency and spend                                          |
| `profile`     | null      | E16 permission profile for the workers; `command` steps need one that allows commands |

`args` entries: `name`, `type` (`.string`, `.number`, `.bool`, `.json`,
`.choice`; default `.string`), `required` (default true), `default`,
`options` (for choices), `description`.

`limits`: `max_parallel` (8, at most 64) agents at once in this workflow,
`max_agents` (1,000, the cap), `max_map_items` (4,096, the cap), and
optional budgets `max_cost_micros`, `max_tokens`, `max_wall_ms` split
across the workers.

## Steps

Every step has an `id` (`[a-z][a-z0-9_]{0,31}`, unique in the workflow),
an optional `phase` (groups steps in the progress view), an optional
`when` (a path; the step is skipped unless its value is truthy) and
exactly one of the kinds below.

### `agent` and `reduce`

One subagent. `reduce` is the same shape, used for fan-in.

| Field         | Default    | Meaning                                                            |
|---------------|------------|--------------------------------------------------------------------|
| `prompt`      | required   | text with `{{$.path}}` placeholders, or `"@library/id"`            |
| `with`        | none       | for `@library` prompts: `.{ .name = "question", .value = "$args.question" }` (a path or literal text) |
| `agent_def`   | null       | E10 agent definition                                               |
| `tools`       | definition | tool allowlist                                                     |
| `model_role`  | null       | E10 model role                                                     |
| `schema`      | null       | output JSON Schema, inline (`"{…}"`) or a `.json` file next to the workflow |
| `isolation`   | `.shared`  | `.lane` gives the worker its own E09 lane (writers)                |
| `label`       | null       | shown in the progress view                                         |
| `stall_ms`    | 600000     | no activity for this long restarts the agent (at least 1000)       |
| `max_retries` | 5          | schema-validation retries and stall restarts (at most 10)          |
| `citations`   | false      | the answer must cite sources                                       |
| `sources`     | null       | path to the source ids it may cite                                 |

With a `schema`, the result is validated JSON; a schema that can never be
satisfied (a `required` key excluded by `additionalProperties: false`) is
rejected at load.

### `map`

Fan-out: one body per item of `over`.

| Field            | Default  | Meaning                                                  |
|------------------|----------|----------------------------------------------------------|
| `over`           | required | path to an array (at most `max_map_items` items)         |
| `as`             | `item`   | the item's name in the body (`$file`); `$item`/`$index` always work |
| `max_parallel`   | limits   | at most 64                                               |
| `max_fail_ratio` | 0.2      | the step succeeds if at most this share of items failed  |
| `agent` / `command` / `builtin` | | exactly one: the body                           |

The result is an array in input order, `null` for items that failed.

### `parallel`

A list of steps (branches) that run at once. The result is an object
keyed by branch id; later steps can also read a branch by its own id.
Branches cannot read each other.

### `vote`

| Field    | Default     | Meaning                                                   |
|----------|-------------|-----------------------------------------------------------|
| `n`      | required    | copies of `agent` (2 to 9)                                |
| `decide` | `.majority` | `.majority`, `.unanimous` or `.judge`                     |
| `agent`  | required    | the agent each copy runs                                  |
| `judge`  | null        | with `.judge`: an agent that sees `$candidates`           |

### `loop_until`

Evaluator-optimizer: repeat `agent` until `check` passes. The agent and the
check can read the loop's own last result (`$.<id>`).

| Field                   | Default  | Meaning                                                  |
|-------------------------|----------|----------------------------------------------------------|
| `agent`                 | required | the agent each round runs                                |
| `check`                 | required | exactly one of `command` (exit 0 passes), `path` (truthy passes), `judge` (an agent whose result has `"pass": true`) |
| `max_rounds`            | 8        | 1 to 50                                                  |
| `stop_when_no_progress` | 2        | stop after this many rounds in a row with the same failure; status "no progress" |

### `gate`

Human approval: the run waits in `needs_input` with an approval card.
`title` (required) and `show` (a path whose value the card shows).
Approving continues; rejecting stops the run with "rejected at gate".

### `builtin`

A Zig function: `name` and `input` (a path; default `$`, the whole
scope). Shipped: `files.glob`, `scm.changed_files`, `lanes.collect`,
`artifact.write_table`, `research.verify`, `research.write_report`.

### `command`

`argv`, `cwd` (null: the workspace) and `expect_exit` (0; null accepts
any). Runs through the E06 terminal service with approval; needs the
workflow's `profile` to allow commands.

## Paths

Steps read earlier results with JSONPath-lite:

| Path                          | Value                                          |
|-------------------------------|------------------------------------------------|
| `$.plan`                      | step `plan`'s result                           |
| `$.plan.subquestions[0].q`    | a field of an element                          |
| `$.research[*].findings[*]`   | every finding of every researcher (flattened)  |
| `$args.glob`                  | an argument                                    |
| `$item`, `$index`, `$<as>`    | inside a `map`: the item and its index         |
| `$`                           | everything so far                              |

A path may only read steps that ran before (validated). A missing key or
index gives nothing, never an error. `when` and `check.path` use
truthiness: null, false, 0, `""`, `[]` and `{}` are false.

## Prompts

`{{$.path}}` placeholders in a prompt are replaced by the value: strings
as they are, anything else as compact JSON, wildcard paths as a JSON
array. Values over 32 KiB are written to a file in the run folder and the
prompt gets the path and the start of the value instead. Values from
untrusted sources (web pages, trigger payloads) are wrapped in
`<untrusted-data>` blocks. `\{{` is a literal `{{`.

`"@research/lead"` uses the prompt library entry `research/lead`
(docs/formats/prompts.md), rendered with the `with` bindings.
