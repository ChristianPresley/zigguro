# Commands

Every action a user, an agent, an extension or the `zg` CLI can trigger is a
command: a stable string id (`editor.toggleLineComment`), a title for the
palette, an optional args schema and an optional enablement clause. Key
bindings, menus, the palette, toolbar buttons, macros and agent tool calls
all go through the same `CommandRegistry` in `src/commands/registry.zig`.

## Ids

- Ids are dotted lowercase-first words: `<area>.<verb><Object>`, such as
  `workbench.showCommands` or `scm.commitStaged`. `CommandRegistry.validId`
  accepts 1 to 128 characters from `[A-Za-z0-9_.:-]`.
- Extension commands start with `<extension name>.`.
- `CommandId` is a dense `u32`; `none` (0) means "nothing bound" and is what a
  disable binding resolves to. `CommandId` values are E04 `ActionId` values:
  convert with `@enumFromInt(@intFromEnum(x))`.

## Declaring

```zig
const id = try reg.register(.{
    .id = "editor.toggleLineComment",
    .title = "Toggle Line Comment",
    .category = "Editor",
    .enablement = "editorTextFocus && !editorReadonly",
    .effects = .{ .ui_only = false, .writes_files = true },
    .handler = .{ .ctx = editor, .run = toggleComment },
});
```

| Field | Meaning |
| --- | --- |
| `args` | A `SettingDef` (usually `.type = .object` with `properties`) that args are validated against before the handler runs. `null` means the command takes no args; a def of type `any` accepts anything. |
| `enablement` | When-clause that must hold for `execute`; otherwise `error.Disabled`. |
| `palette`, `palette_when` | Hide a command from the palette, or show it only when a clause holds. |
| `agent` | Whether agents may call it: `never`, `ask` (permission prompt, default) or `allow`. |
| `effects` | What it may do (reads workspace, writes files, runs a process, network, destructive). E10 shows these in permission prompts and filters the agent tool catalogue with them. |
| `repeat` | Whether key auto-repeat re-runs it (false for toggles). |
| `source` | `builtin`, `extension`, `skill`, `user_macro` or `agent_defined`; `unregisterSource` removes everything one source registered. |

### Lazy commands

Extensions declare commands in their manifest without running code.
`registerLazy` records the metadata and an `Activator`. The first `execute`
queues the invocation (it returns at once) and calls the activator, which
starts the extension host. When the host calls `setHandler`, the queued
invocations run in order and their completions fire. If activation fails,
`failActivation` fails them with `error.ActivationFailed`; the app calls
`tick(now)` from its frame loop so activations stuck longer than
`activation_timeout_ms` fail the same way. A command with neither handler
nor activator returns `error.NotActivated`.

## Executing

- `execute(id, args, origin)` on the UI thread.
- `executeForResult` when the caller wants the handler's `Result` (text or
  JSON in the caller's arena).
- `executeJson` parses JSON args (E10 tool calls).
- `executeArgText` takes canonical ZON text (E04 key dispatch). Keymaps
  intern their args at build time with `internArgs`, so the key path does no
  parsing; unknown text is parsed once and cached.
- `post(id, args, origin, done)` from any thread: the invocation is queued,
  `ui_msg_kind` (`0x1500_0002`) is posted to the UI mailbox, and the UI loop
  calls `drainPosted`, which runs it and calls `done` on the UI thread.

Every invocation is checked in this order: the id exists, the enablement
clause holds (evaluated against the current context stack and settings),
the args match the schema, the command is activated. The registry keeps a
ring of the last 1000 executions; `history(out)` returns them newest first,
and the palette shows the first `commands.historySize` (default 50) as its
"recently used" group.

## Built-in commands

| Id | Args | Purpose |
| --- | --- | --- |
| `noop` | none | Swallow a key: bind it to `noop` so it neither runs anything nor reaches the widget. |
| `workbench.runCommandById` | `{ id, args? }` | Run another command (for menus and macros). |
| `workbench.runCommands` | `{ commands: [{ id, args? }] }` | Run several in order; stops at the first error. |
