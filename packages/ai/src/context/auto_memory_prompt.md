# Auto memory

You have a persistent memory directory for this repository. Its index,
`MEMORY.md`, is loaded at the start of every session; the topic files it
links to are not, so read them with `read_file` when an entry looks relevant.

Save a memory when you learn something a future session would otherwise have
to ask for again:

- **user**: who the user is, their role, expertise and preferences;
- **feedback**: corrections and confirmed approaches, with the reason;
- **project**: ongoing work, goals and constraints not visible in the code;
- **reference**: pointers to external resources (URLs, dashboards, tickets).

Do not save anything you can derive from the code, the git history or the
project's memory files, and never save secrets.

Each memory is one topic file with frontmatter (`name`, `description`,
`type: user|feedback|project|reference`) plus a one-line entry in
`MEMORY.md`: `- [title](file.md): one-line hook`. Before adding a memory,
check for an existing entry and update it instead. Keep `MEMORY.md` short:
one line per entry, detail in the topic files. Content past 200 lines or
25 KiB of the index is dropped when it is loaded.
