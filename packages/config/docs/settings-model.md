# Settings model

How `zg_config` turns settings files into the values packages read. The
golden matrix in `src/store_test.zig` checks every rule below.

## Files and layers

Layers from lowest to highest precedence:

| # | Layer | File | Notes |
|---|---|---|---|
| 0 | default | `settings_schema.zon` of each package, comptime | never written |
| 1 | user | `<config>/settings.zon` | |
| 2 | workspace | workspace file `.settings` (multi-root) or `<root>/.zigguro/settings.zon` | |
| 3 | workspace_local | `<root>/.zigguro/settings.local.zon` | personal; kept out of SCM |
| 4 | folder | `<folder>/.zigguro/settings.zon` (multi-root) | resource scope only |
| 5 | editorconfig | `.editorconfig` chain | resource scope only |
| 6 | cli | `zigguro --settings <file or ZON>` | session only |
| 7 | policy | `<managed>/settings.zon` | locked |

A file is a ZON struct literal. Keys may be nested or dotted; both forms
mean the same setting:

```zig
.{
    .editor = .{ .tabSize = 2 },
    .@"editor.fontSize" = 13,
    .@"[zig]" = .{ .@"editor.tabSize" = 4 },
    .@"[zig][zon]" = .{ .@"editor.insertFinalNewline" = true },
}
```

Nested objects are flattened until the path names a declared setting. If
the path is itself an `object` setting, the object is its value.

## Resolution

For window scope (no folder, no language) the order is: default, user,
workspace, workspace_local, cli, then policy. Folder and editorconfig
layers never affect window scope.

For a folder and/or language query:

1. default
2. user, workspace, workspace_local, folder (that folder), editorconfig (that folder), cli
3. language blocks of those layers: blocks naming several languages first,
   then single-language blocks; within each group lower layers first
4. policy, then policy language blocks (multi, then single)

The last contribution wins for `merge = .replace`. So a language value beats
a non-language value at any layer, `[zig]` beats `[zig][zon]` in the same
layer, and a workspace `[zon][zig]` does not override a user `[zig]`.

### Merge modes

- `replace`: primitives and arrays replace.
- `merge_object`: objects merge key by key, recursively; the higher layer
  wins per key. The string `"default"` removes a key.
- `concat_unique`: lists accumulate across layers, lower layers first, with
  duplicates (by value) removed. Used by permission-like lists.

### Scopes

| Scope | user | workspace / local | folder / editorconfig | cli | policy |
|---|---|---|---|---|---|
| application, machine | yes | ignored (warning) | ignored | yes | yes |
| machine_overridable | yes | yes | yes | yes | yes |
| window | yes | yes | ignored | yes | yes |
| resource, language_overridable | yes | yes | yes | yes | yes |

Only `language_overridable` keys may appear in `[lang]` blocks.
`restricted = true` keys in workspace, local, folder and editorconfig layers
apply only while the workspace is trusted (E16 `ProjectTrust` through
`TrustPort`); changing trust republishes.

### Invalid values

Every value is validated against the schema. An invalid value is dropped
with a `file:line:col` diagnostic, so that key falls back to the next lower
layer; every other key still loads. Unknown keys warn with a did-you-mean
suggestion.

## Snapshots and threading

- Layer builds and snapshot builds run off the UI thread (any thread may
  call `setLayerSource`). The new snapshot is parked as pending and
  `UiMsg{ .kind = 0x1500_0001 }` is posted to the UI mailbox.
- The UI thread calls `publish()` at frame start. It swaps the pending
  snapshot in, diffs it against the previous one and calls subscribers with
  exactly the ids whose value changed in any scope.
- **Invariant:** UI-thread code reads `current()` without pinning, because
  swaps only happen in `publish()` on that thread, between frames.
- Other threads pin with `acquire()` and unpin with `release()`. A
  superseded snapshot is freed by `publish()`/`collect()` once unpinned.
- Reads never lock: `Handle.get` is an array index; resource and language
  lookups walk the few entries of that key, and merge-mode values for each
  (folder, language) pair are precomputed when the snapshot is built.

## Variables

Values are stored unexpanded. Consumers call `store.expand` for
`${workspaceFolder}`, `${userHome}` and `${env:NAME}`. `${secret:NAME}` is
only resolved by E16 at the point of use.
