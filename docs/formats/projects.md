# Project files

A project (E13.F09) groups runs, tasks, automations and artifacts around
one goal, such as a book or a release. A project has instructions and a set
of knowledge files. Every agent run started in the project sees both.
Runs started outside any project are unchanged.

## Layout

```
.zigguro/projects/<slug>/
    project.zon        title, description, knowledge, run defaults, pinned
    instructions.md    free-form instructions for agents (may be empty)
```

The slug is the directory name: lowercase letters, digits and `-`, at most
64 bytes, not starting with `-`. The files sit in the repository, so the
whole team shares them.

## project.zon

```zig
.{
    .version = 1,
    .title = "The Zig book",
    .description = "Chapters, sources and notes.",
    .knowledge = .{
        .{ .folder = .{ .path = "docs/book" } },
        .{ .folder = .{ .path = "notes", .glob = "**/*.md" } },
        .{ .notes_query = "tag:#book" },
        .{ .file = "README.md" },
        .{ .source = "zig comptime" },
    },
    .defaults = .{ .agent_def = "writer", .model = "fast" },
    .pinned = true,
}
```

| Field         | Meaning                                                              |
|---------------|----------------------------------------------------------------------|
| `version`     | Always `1`.                                                          |
| `title`       | Shown in the switcher and the prompt section. Required, ≤ 200 bytes. |
| `description` | One paragraph shown under the title.                                 |
| `knowledge`   | Where the knowledge files come from (below).                        |
| `defaults`    | `agent_def`, `model`, `profile` used by runs that name none.         |
| `pinned`      | Pinned projects are listed first.                                    |

Unknown fields are errors. A file that does not load is listed with its
line, column and reason instead of the project, and the other projects
still load.

### Knowledge items

| Item                                   | Files                                                        |
|----------------------------------------|--------------------------------------------------------------|
| `.{ .folder = .{ .path, .glob } }`     | Files under the folder whose path relative to it matches the glob (default `**/*`). |
| `.{ .notes_query = "tag:#book" }`      | Notes matching an E08 notes query.                           |
| `.{ .file = "README.md" }`             | One file.                                                    |
| `.{ .source = "query" }`               | Research source notes matching a query (E13.F05).            |

Paths are relative to the workspace and use `/`. Paths with `..`,
absolute paths and drive letters are refused. Files that the security
policy marks secret, such as `.env` files and anything under `secrets/`,
never appear and cannot be read through the project tools. A missing
folder or file is skipped with a warning.

## instructions.md

Plain Markdown, added to the system prompt as written. `@path` lines import
other files the same way agent memory files do. The path is relative to
the importing file. Imports go at most 4 levels deep. Cycles, missing
files and paths outside the workspace are skipped. The expanded text is
cut at 32 KiB, and the prompt then notes the cut.

## What agents see

A run that belongs to a project gets this section appended to its system
prompt:

```markdown
# Project: The Zig book

Chapters, sources and notes.

## Instructions

<instructions.md>

## Knowledge

- docs/book/ch1.md · Chapter one · 3 KB · 2026-10-23
- notes/idea.md · An idea · 4 B · 2026-10-23
+12 more

The contents are not included: read a file with project_knowledge_read, or search notes with search_notes.
```

A file's title is its frontmatter `title:`, else its first `# ` heading,
else its file name. The index lists at most 200 files and about 4,000
tokens. Anything beyond that is counted in the `+N more` line. File
contents are never inlined.

### Tools

| Tool                     | Input                       | Returns                                         |
|--------------------------|-----------------------------|-------------------------------------------------|
| `project_info`           | `{}`                        | Title, description, defaults and knowledge items as JSON. |
| `project_knowledge_list` | `{query?}`                  | Every knowledge file, filtered by a case-insensitive substring of its path or title. |
| `project_knowledge_read` | `{path, offset?, limit?}`   | Up to 64 KiB of one knowledge file, with a note on how to read the rest. |

All three only read. A path that is not one of the project's knowledge
files is refused.

## Changes

When you create or edit a project in the IDE, the files are written
directly. When an agent creates or edits one, the change becomes a
changeset for review, as every agent change under `.zigguro/` does.

The active project is remembered per workspace. New tasks, automations and
artifacts get its tag.

## Budget

`projects/knowledge_index_1000`: building the index of a folder of 1,000
Markdown files takes 7.4 ms against a 20 ms budget.
