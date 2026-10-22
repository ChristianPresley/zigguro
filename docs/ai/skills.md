# Skills and slash commands

Skills are packaged instructions the user runs as `/name args` and the
model runs through the `skill` tool. They use the same format as Claude
Code skills and commands, so a `.claude/skills` directory works
unchanged. The code is in `packages/ai/src/ext/`: `skills.zig` (index and
expansion), `substitute.zig`, `skill_tool.zig`, `commands.zig` and
`builtin_commands.zig`.

## Where skills come from

A skill is a directory with a `SKILL.md` and any supporting files. A
command is a single Markdown file: a skill without a directory.

| Source | Skills | Commands |
|---|---|---|
| managed | `<managed>/skills/<name>/SKILL.md` | `<managed>/commands/**/<name>.md` |
| user | `<config>/skills/<name>/SKILL.md` | `<config>/commands/**/<name>.md` |
| project | `.zigguro/skills/<name>/SKILL.md` | `.zigguro/commands/**/<name>.md` |
| project (compat) | `.claude/skills/<name>/SKILL.md` | `.claude/commands/**/<name>.md` |

`skills.standardRoots` builds this list. When two share a name:

- managed beats user, and user beats project;
- within one source, a skill beats a command.

A `.zigguro/skills` directory below the project root (and `.claude/skills`
in compat mode) joins the index once the agent works in that directory
(`SkillIndex.activateFor`).

Loading reads only the frontmatter. The body is read when the skill runs,
so edits to a skill take effect at once. Indexing 200 skills takes about
1.1 ms (bench `ai.skill_index_200`; budget 5 ms).

## Frontmatter

All keys are optional:

- `name`: defaults to the directory or file name.
- `description`: defaults to the first paragraph of the body that is not
  a heading.
- `when_to_use`
- `argument-hint`
- `arguments`: names for positional arguments.
- `disable-model-invocation`: only the user can run the skill.
- `user-invocable: false`: only the model can run it.
- `allowed-tools`
- `model`
- `context: fork` with `agent`
- `paths`

`allowed-tools` takes Claude Code names, such as `Bash(git add:*)`, which
map to zigguro tools, such as `run_command(git add:*)`.

## Expansion

When a skill runs, its body is expanded in two steps.

### Arguments and variables

| Placeholder | Becomes |
|---|---|
| `$ARGUMENTS` | the argument string as typed |
| `$ARGUMENTS[N]`, `$N` | the N-th argument (from 0), split like a shell: quotes group, `\` escapes |
| `$name` | the argument at `name`'s position in `arguments` |
| `${ZIGGURO_SESSION_ID}`, `${ZIGGURO_SKILL_DIR}`, `${ZIGGURO_PROJECT_DIR}` | the session, the skill's directory, the project; `CLAUDE_` works in compat mode |
| `\$` | a literal `$` |

Other `$words`, such as `$HOME`, are left alone. If the body has no
argument placeholder and arguments were given, `ARGUMENTS: <value>` is
appended.

### Shell injection

`` !`cmd` `` (at the start of a line, or after a space or `(`) and
` ```! ` fenced blocks run before the text is sent, and their output
replaces them. Ordinary code fences are left alone.

Each command:

- runs in a hidden terminal (`HostShell` over the terminal host);
- is checked by the command policy, which never prompts;
- has its output capped at 16 KiB.

A refused or failed command aborts the whole invocation with the reason.
`ai.skills.disableShellExecution` replaces each injection with a notice
instead.

## The `skill` tool

`skill {name, args?}` runs a skill for the model. Its description lists
the skills the model may run, sorted by name. Each entry is the
description plus `when_to_use`, cut to 1,536 characters. The listing
leaves out:

- skills with `disable-model-invocation`;
- skills with `paths`, until a matching file has been touched.

The result is the base directory, the expanded body and the supporting
files. The skill's `allowed-tools` rules are passed to the `GrantSink`,
which pre-approves them for the rest of the turn. A `context: fork`
skill runs in a subagent (`agent`, default `general`; names match
ignoring case), and the tool returns that agent's report.

## Slash commands

`commands.parse` reads `/name args`. `CommandRegistry.resolve` checks the
built-in commands first, then the skills a user can run.

The built-ins are `/clear`, `/compact`, `/context`, `/memory`, `/model`,
`/plan`, `/mode`, `/branch`, `/rewind`, `/resume`, `/rename`, `/cost`,
`/agents`, `/skills`, `/hooks`, `/export`, `/init` and `/help`.

`registerWithPalette` registers each built-in as `ai.<name>` and each
user-runnable skill as `ai.skill.<name>`, through a `PaletteSink` that
the app adapts to E15's command registry.
