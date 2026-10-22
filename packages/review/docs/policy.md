# Edit policy

`zg_review.policy.ReviewPolicy` (E12.F05.S01.T01) decides, file by file,
what happens to an agent's proposed change:

- `auto_apply`: it is applied at once;
- `review`: it waits in the queue;
- `deny`: it is refused.

By default everything waits for review.

## Settings

The `review` section of the workspace settings,
`.zigguro/settings.zon` (`rules.loadWorkspace`, nested form only, until
the app reads settings through E15's store), in ZON:

```zon
.{
    .rules = .{
        .{ .paths = .{"docs/**/*.md"}, .agents = .{"docs-writer"}, .max_changed_lines = 200, .action = .auto_accept },
        .{ .paths = .{ "**/*.lock", "zig-pkg/**" }, .action = .review_required },
        .{ .origins = .{.lsp}, .tools = .{"format"}, .action = .auto_accept },
    },
    .protected = .{ "secrets/**" },
}
```

A rule matches a file when every field it sets matches. An empty list
matches anything:

- `paths` are E08 globs on workspace-relative paths. For a rename, both
  the old and the new path must match.
- `tools` and `agents` are names or globs.
- `origins` are the changeset origins: `agent`, `inline_edit`, `lsp`,
  `search_replace`, `notes`, `scm_proposal`, `code_review` and
  `user_bulk`.
- `ops` are `create`, `modify`, `delete`, `rename` and `mode`.
- `max_changed_lines` counts the lines added plus the lines removed. A
  delete counts every line of the file. When the count is unknown, an
  `auto_accept` rule does not match, but a `review_required` rule does.

A rule with an invalid glob is reported and ignored. An invalid
`auto_accept` rule therefore never applies anything.

## Order

For each file, the first step that gives an answer decides:

1. E16 denies the write (a deny rule or managed policy), or the session
   is in plan mode: **deny**.
2. E16's managed policy asks: **review**.
3. The path is protected: **review**. Protected paths are `.zigguro/**`,
   `.git/**`, `**/.env*`, `.github/workflows/**`, `build.zig`,
   `build.zig.zon`, E16's workspace defaults and `review.protected`.
4. The permission mode:
   - `accept_edits` or `bypass`: **auto-apply** creates and edits inside
     the workspace. Deletes, renames and mode changes go on to the rules.
   - `dont_ask`: **review**.
5. The first matching `review_required` rule: **review**.
6. The first matching `auto_accept` or `review` rule decides.
7. **Review**.

E16 is asked through `SecurityProbe`, which must never present an
approval. Without a probe, the policy fails closed: everything is
reviewed.

## Applying

`autoApply` runs after a changeset is submitted. As one apply, it lands
the files to auto-apply and rejects the denied ones; the rest stay
pending. A changeset that landed something is marked `auto_applied`.
`recentlyAutoApplied` lists those changesets, and `Applier.undoApply`
reverts one.

`editorPolicy` answers E05's `ApplyPolicy` for an edit to an open
document. Such an edit is a `modify` with an unknown line count. `pending`
means review.

## In the app

`ReviewGlue` (the IDE, and `zg agent --review policy`) has a `policy`
mode. A turn's edits are held until the turn ends. They are then
submitted as one changeset and `autoApply` runs on it. The probe asks E16
nothing, because the agent's tool permissions have already run. It
reports the permission mode the session runs in. `zg review policy
explain` prints a verdict and its reason.
