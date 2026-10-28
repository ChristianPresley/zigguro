# Prompt library files

The prompt library (E13.F08.S02) holds reusable prompts and prompt
templates. Press `Ctrl+Alt+L` (palette: `library.open`) to search it and
insert a prompt into the agent pane, Mission Control's dispatch box or the
document-mode ask box. From the command line: `zg library list|show|render`.

## Where entries come from

| Source  | Location                          | Notes                                   |
|---------|-----------------------------------|-----------------------------------------|
| project | `.zigguro/prompts/**/*.md`        | shared with the repository              |
| user    | `<config>/prompts/**/*.md`        | your own, on every workspace            |
| builtin | shipped with zigguro              | `doc/*` document actions, `research/*`  |
| skill   | E10 skills (`SKILL.md`)           | inserted as `/name args`, never inlined |

An entry's id is its path below the prompts folder without `.md`:
`.zigguro/prompts/research/lead.md` is `research/lead`. When ids collide,
project beats user beats built-in, so creating `doc/shorten.md` in your
user folder replaces the built-in "Shorten" document action everywhere.
Ids use lowercase letters, digits, `.`, `_` and `-`, with `/` between
segments.

## File format

Markdown with optional YAML frontmatter:

```markdown
---
title: Research lead planner
description: Decompose a research question into non-overlapping sub-questions
tags: [research, planning]
variables:
  - {name: question, type: text, required: true}
  - {name: effort, type: choice, options: [quick, standard, deep], default: standard}
---
You are the lead researcher... {{question}}
{{#if effort == "deep"}}Look for evidence against the likely answer.{{/if}}
```

| Key           | Default                    | Meaning                                |
|---------------|----------------------------|----------------------------------------|
| `title`       | the file name              | shown in the picker                    |
| `description` | empty                      | searched and shown under the title     |
| `tags`        | none                       | searched; a list or `a, b`             |
| `variables`   | the names the body uses    | the form the picker shows              |

A variable has `name`, `type` (`text`, `multiline`, `choice`, `number`,
`bool`, `path`, `selection`; default `text`), `options` (choices),
`default` and `required` (default false). Only the frontmatter is read
when the library is indexed; the body loads when an entry is previewed or
used.

## Template language

Deliberately small: no loops and no code.

| Syntax                                | Meaning                                            |
|---------------------------------------|----------------------------------------------------|
| `{{name}}`                            | the variable's value                               |
| `{{name\|default:"x"}}`               | `x` when no value is given                         |
| `{{name\|choice:a,b,c}}`              | declares a choice variable inline                  |
| `{{#if name}}…{{/if}}`                | when the value is non-empty and not false/no/off/0 |
| `{{#if name == "x"}}…{{else}}…{{/if}}`| compares the value                                 |
| `{{selection}}` `{{file}}` `{{date}}` | the editor's selection, file and today's date      |
| `{{clipboard}}`                       | the clipboard (the picker asks first)              |
| `\{{`                                 | a literal `{{`                                     |

A name used in the body but not declared is a required text variable,
unless it has a default or is one of the editor values above. Values that
do not fit their declaration (a choice not in the list, a number that is
not a number) are reported before anything is inserted.

Skill bodies keep their own `$ARGUMENTS`/`$0`/`$name` substitution: the
library shows them but inserts `/name args`, and E10 runs the skill (and
honours `disable-model-invocation`).

## Usage counts

How often each entry was inserted in a workspace is kept in
`.zigguro/state/library.zon` and lifts frequently used entries in search.

## Agent tools

`library_search{query}` and `library_get{id}` let agents read house
prompts. `library_create{id, title, body}` proposes a new project prompt as
a reviewed change. Workflows refer to entries as `"@research/lead"`; a
change to an entry's text changes the replay key of the agents that use it.
