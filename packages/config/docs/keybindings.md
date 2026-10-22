# Keybindings

Key bindings map key presses to commands. They are data: ZON files in the
same format whether they come from a package's defaults, a keymap preset,
a Vim/Emacs mode layer, an extension or the user's `keybindings.zon`.

## File format

A keybindings file is an array of entries:

```zig
.{
    .{ .key = "mod+shift+p", .command = "workbench.showCommands" },
    .{ .key = "mod+k mod+s", .command = "workbench.openKeybindings" },
    .{ .key = "ctrl+g", .macos = "cmd+l", .command = "editor.goToLine", .args = .{ .line = 1 } },
    .{ .key = "ctrl+w", .command = null, .when = "terminalFocus" },  // pass ctrl+w to the shell
    .{ .key = "mod+d", .command = "-editor.addSelectionToNextMatch" }, // remove a default
    .{ .key = "", .command = "-editor.action.rename" },               // remove every binding of it
    .{ .key = "shift shift", .command = "search.everywhere" },        // double tap
}
```

| Field | Meaning |
| --- | --- |
| `key` | The key spec (grammar below). |
| `linux`, `windows`, `macos` | Override `key` on that platform. |
| `command` | A command id; `"-id"` removes bindings; `null` or `""` disables the key. |
| `when` | Optional when-clause (see `context-keys.md`). |
| `args` | Optional args, validated against the command's args schema when it runs. |

Unknown fields are warnings. An unknown command id is a warning too: the
binding is kept but inert, and comes alive when the command is registered
(extensions register late). Every diagnostic carries the byte span of the
offending text, inside the string literal where that applies.

## Key spec grammar

```
spec   := stroke (' ' stroke){0,3} | modtap ' ' modtap
stroke := (mod '+')* key
mod    := ctrl|control|shift|alt|option|opt|super|cmd|meta|win|mod|cmdorctrl
key    := letter | digit | punctuation | any single character        (logical)
        | enter|escape|esc|tab|space|backspace|delete|insert|home|end|pageup|pagedown
        | up|down|left|right|f1..f24|numpad0..9|numpad_add|...|contextmenu|capslock
        | '[' W3C code ']'                                              (physical)
modtap := shift|ctrl|alt|super        (twice: a double tap, e.g. "shift shift")
```

- `mod` and `cmdorctrl` mean Cmd on macOS and Ctrl elsewhere.
- Up to four strokes form a chord (`mod+k mod+s`).
- A single character is a **logical** key: it matches whatever physical key
  produces that character on the current layout, so `ctrl+z` follows the Z
  key on QWERTZ. On non-Latin layouts (Russian, Greek) logical keys also
  match the US-layout position, so shortcuts keep working.
- `[KeyZ]`, `[Slash]` and the other W3C `code` names are **physical**: the
  key at that position whatever the layout prints on it.
- Named keys (`enter`, `f5`, `left`) are physical.
- Shifted symbols match by produced character too: `ctrl+?` matches
  Ctrl+Shift+/ on US.
- AltGr typing never triggers Ctrl+Alt bindings.

`keyboard.dispatch` = `physical` or `logical` restricts matching to one kind;
`auto` (default) matches both; when several bindings match, layer order decides.

Labels use the layout: `ctrl+[KeyZ]` shows "Ctrl+Y" on a German layout, and
macOS labels use the symbols ⌃ ⌥ ⇧ ⌘.

## Layers and precedence

Layers, lowest first: `builtin_default` (each package's defaults),
`preset` (`keyboard.preset`: `vscode`, `jetbrains`, `sublime`, `none`),
`mode_layer` (Vim or Emacs when `keyboard.vim.enabled` /
`keyboard.emacs.enabled`), `extension`, `user`. Within a layer, file order
applies. A later binding beats an earlier one when both match and their
when-clauses hold, as in VS Code.

- **Removal** (`"-id"`) deletes earlier bindings with the same key spec and
  command (and the same when-clause, if the removal has one). With
  `key = ""` it deletes every earlier binding of that command.
- **Disable** (`command = null`) binds the key to nothing. When it wins, the
  resolver answers "unbound", so the focused widget (editor, terminal) gets
  the key. This is how `ctrl+w` reaches the shell in the terminal.
- **Swallow**: bind the key to `noop` to consume it without doing anything.

## Presets

`src/keymap/presets/` ships the presets as ZON data, embedded at build time:

- `vscode.zon`, the default: VS Code's published defaults for the commands
  zigguro implements, plus the agent, review and mode-switch keys. Every
  entry has a comment naming its VS Code counterpart.
- `jetbrains.zon`: the IntelliJ IDEA Windows/Linux keymap (Shift Shift,
  Ctrl+Shift+A, Alt+Enter, Shift+F6, ...).
- `sublime.zon`: Sublime Text keys. Sublime's Mod+L takes the agent pane's
  key, so this preset moves the agent pane to Mod+Alt+L.

The VS Code keymap is always loaded first and the chosen preset applies on
top of it, both in the `preset` layer (`presets.presetLayers`). Onboarding
offers `presets.choices()` (VS Code, JetBrains, Sublime, Vim, Emacs).

## Importing VS Code keybindings

`import_vscode.importVsCodeKeybindings` reads a VS Code `keybindings.json`
(comments and trailing commas allowed) and reports each entry as `mapped`,
`unmapped`, `conflict` (it replaces a current binding to another command),
`invalid_key` or `invalid_when`. Command ids go through
`presets/vscode_commands.zon`; removals (`-command`) map to removals of the
zigguro id; when-clause context keys that differ are renamed, and unknown
ones are noted (they evaluate to false). `appendImported` adds the mapped and
conflicting entries to an existing `keybindings.zon`, each with a comment
naming the VS Code command.

## Resolution

`Resolver.resolve(stack, event)` returns one of:

| Resolution | Meaning |
| --- | --- |
| `none` | Not bound here (or disabled): the widget handles the key. |
| `pending` | A chord is in progress; the payload is its label ("Ctrl+K"). |
| `action` | Run a command; `arg` is the canonical ZON text of its args. |
| `swallow` | Consume the key; the payload is a status-bar message. |

Rules:

1. Release events only feed double-tap detection. Repeat events never
   continue chords and only fire single-stroke bindings whose command has
   `repeat = true`.
2. A key that starts both a single-stroke binding and a chord enters the
   chord with a deadline of `keyboard.chordTimeoutMs` (1000 ms). If nothing
   continues it, `onTimer` fires the single-stroke binding. If a key that
   does not continue the chord arrives first, the single-stroke binding
   fires and that key is processed again (`takeDeferred`).
3. A key that only starts chords waits without a timeout (as VS Code does).
4. A key that matches nothing while a chord is pending ends the chord and is
   swallowed with "(Ctrl+K, X) is not a command", or passed through when
   `keyboard.chordMismatch = passthrough`.
5. Escape while a chord is pending cancels it.
6. Two taps of the same modifier with nothing in between, within
   `keyboard.doubleTapMs` (300 ms), resolve the `shift shift` style specs.

`deadline()` tells the frame loop when to call `onTimer`; nothing polls, so
an idle app stays at 0 % CPU.

The which-key popup lists `continuations` while a chord is pending, and
menus and the palette show `labelFor(command)`: the highest-priority binding
of that command that no later binding of the same keys shadows.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| `keyboard.preset` | `vscode` | The base keymap. |
| `keyboard.chordTimeoutMs` | 1000 | Wait for a chord continuation when the prefix is also bound. |
| `keyboard.doubleTapMs` | 300 | Maximum gap between modifier taps. |
| `keyboard.chordMismatch` | `swallow` | What a non-continuing key does during a chord. |
| `keyboard.dispatch` | `auto` | Physical, logical or both. |
| `keyboard.vim.enabled`, `keyboard.emacs.enabled` | false | Mode layers (E05). |
| `keyboard.vim.passthroughKeys` | `mod+shift+p`, `mod+p`, `mod+,` | Keep their workbench meaning outside Vim insert mode. |
