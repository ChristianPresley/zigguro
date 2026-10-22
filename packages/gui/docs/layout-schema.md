# Layout file schema

`zg_gui.dock.persist` saves the workbench layout as `layout.zon` in the
layout directory the app picks (per workspace). This page describes the file
and the rules for changing it.

The zigguro app keeps one layout per working folder in
`<state dir>/layouts/<16 hex digits of the folder's hash>/layout.zon`, where
the state dir is `%LOCALAPPDATA%\zigguro`, `$XDG_STATE_HOME/zigguro` or
`~/.local/state/zigguro` (`ZIGGURO_STATE_DIR` overrides it). Editor panels
store their file's absolute path as their state; the terminal, agent and
review panels store nothing. Runs with `--frames` neither read nor write the
layout.

## The file (version 1)

```zig
.{
    .version = 1,
    .windows = .{ .{ .id = "main", .rect = .{ 40, 40, 1280, 800 }, .monitor = "DP-1", .scale = 1.5, .maximized = false } },
    .panels = .{ .{ .ref = 2, .kind = "editor", .state = "src/main.zig:120" } },
    .groups = .{ .{ .id = 1, .tabs = .{2}, .active = 0, .pinned = 0, .preview = null } },
    .splits = .{ .{ .id = 7, .axis = .row, .children = .{ .{ .group = 1 }, .{ .group = 4 } }, .ratios = .{ 0.6, 0.4 } } },
    .areas = .{ .{ .root = .{ .split = 7 }, .visible = true, .size = 240 }, ... }, // left, right, bottom, center, agent
    .floating = .{ .{ .id = 9, .rect = .{ 100, 100, 600, 400 }, .monitor = "HDMI-1", .scale = 1, .root = .{ .group = 10 } } },
    .maximized = null,
    .focused = 1,
    .next_id = 11,
    .ui_state = .{ .{ .key = "explorer.collapsed", .value = "src,docs" } },
}
```

- `panels[].kind` is the panel kind's name, not its number, so kinds can be
  renumbered freely. A kind the app does not know loads as a placeholder
  panel that keeps the name and state and writes them back unchanged.
- `panels[].state` is opaque to the toolkit and owned by the panel kind.
  States above 64 KiB are dropped with a warning.
- Ids are the model's ids. `next_id` is the next id the model hands out, so
  ids stay unique across save and reload.
- `ui_state` holds small values that outlive a run (MRU lists, collapsed
  sections). Keys are dotted names owned by whoever sets them.
- Split `ratios` sum to 1. A share that is zero, negative or not finite is
  raised to a small minimum on load.

`toModel` checks the trees (every id exists, nothing is shared or cyclic)
and the model's invariants. A file that fails the check is treated like a
file that does not parse.

## Loading

| Result | When | What the app does |
| --- | --- | --- |
| `ok` | the current version parsed | uses it |
| `migrated` | an older version, migrated and parsed | uses it; the next save writes the current version |
| `missing` | no file | default layout |
| `corrupt` | unreadable, unparsable or invalid; the file is renamed `layout.zon.bad-<unix seconds>` | default layout |
| `too_new` | written by a newer build | default layout; the file is left alone |

Files above 4 MiB are not read.

## Saving

Saves are written to a temporary file and renamed over `layout.zon`, so a
crash or a failed write leaves the old file intact. `Persister` debounces
changes (1 s) and writes on a worker; an older snapshot never replaces a
newer one. Window close and quit call `saveNow`.

## Changing the schema

1. Adding a field: give it a default. Older files still parse, and no
   version bump is needed. Unknown fields are ignored on load, so an older
   build reading a newer file of the same version also works.
2. Removing, renaming or changing the meaning of a field: bump
   `schema_version` and add a migration to `migrations` (index = the version
   it migrates from). A migration rewrites the old text as the next version's
   text; `load` runs them in a chain.
3. Keep a fixture of each old version in `packages/gui/testdata/layout/`
   and a test that loads it through the chain.
4. Never reuse a removed field's name with a different meaning.

Version history:

- 0: no `.version` and no `.next_id`. Migrated by taking the largest id in
  use plus one.
- 1: current.
