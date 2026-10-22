# Context keys

Context keys are the names a when-clause tests (`editorTextFocus && !editorReadonly`).
They come from three places, looked up in this order by `EvalEnv.lookup`:

1. **The focus stack.** E04 passes the focused widget's `KeyContext` chain, outermost first.
   A context's `name` is true while it is on the stack, and its `attrs` are string keys
   (`vim.mode == normal`). The innermost context wins.
2. **Global keys** in the `ContextKeyService`, set by the package that owns them.
3. **Settings**: `config.<key>` reads the effective value from the settings snapshot
   (`config.editor.wordWrap == on`).

An unknown key evaluates to `undef`, which is falsy, so a clause that names a key
nobody sets is simply false. Owners intern a key once with `key(name)` and then
`set` it by id; every effective change bumps `generation()`, which label caches
(menus, palette, keybinding hints) use to know when to recompute.

## Grammar

The when-clause grammar is VS Code's (precedence `!` > comparison > `&&` > `||`):

```
expr := or ; or := and ('||' and)* ; and := unary ('&&' unary)*
unary := '!' unary | cmp
cmp := primary [ ('=='|'!='|'==='|'!=='|'<'|'<='|'>'|'>=') value | '=~' regex | ['not'] 'in' key ]
primary := '(' expr ')' | 'true' | 'false' | key
value := bareword | 'single quoted' | number ; regex := '/' body '/' flags
key := [A-Za-z_$][A-Za-z0-9_.:$-]*
```

`<`, `<=`, `>` and `>=` need whitespace on both sides, because keys may contain
`-`. The right side of `==` is always a literal. `in` tests membership in the
list held by another key (`resourceExtname in supportedExts`). Clauses compile
once into bytecode (`When.compile`, with diagnostics carrying byte offsets) and
evaluate without allocating (`When.eval`).
`when/dnf.zig` turns a clause into disjunctive normal form for the conflict
analyzer (`mayOverlap`).

## Standard keys

The table is generated from `standard_keys` in `src/when/context.zig`;
`registerStandard` interns them all and sets the platform keys.

| Key | Owner | Meaning |
| --- | --- | --- |
| `editorTextFocus` | E05 | An editor text area has keyboard focus |
| `editorFocus` | E05 | An editor (text or its widgets) has focus |
| `editorReadonly` | E05 | The focused editor is read-only |
| `editorLangId` | E05 | Language id of the focused editor |
| `editorHasSelection` | E05 | The focused editor has a non-empty selection |
| `editorHasMultipleSelections` | E05 | The focused editor has several cursors |
| `textInputFocus` | E04 | Any text input (editor or field) has focus |
| `inputFocus` | E04 | Any input widget has focus |
| `terminalFocus` | E06 | A terminal has focus |
| `terminal.altScreen` | E06 | The focused terminal shows the alternate screen |
| `sideBarVisible` | E04 | The side bar is visible |
| `panelVisible` | E04 | The bottom panel is visible |
| `activePanel` | E04 | Id of the active panel |
| `activeViewlet` | E04 | Id of the active side bar view |
| `resourceScheme` | E08 | URI scheme of the active resource |
| `resourceFilename` | E08 | File name of the active resource |
| `resourceExtname` | E08 | Extension of the active resource, with the dot |
| `resourceLangId` | E08 | Language id of the active resource |
| `isLinux` | E15 | Running on Linux |
| `isWindows` | E15 | Running on Windows |
| `isMac` | E15 | Running on macOS |
| `inQuickOpen` | E04 | A quick pick (palette) is open |
| `inDebugMode` | E07 | A debug session is active |
| `agentFocus` | E10 | The agent panel has focus |
| `agentRunning` | E10 | An agent turn is running |
| `agentAwaitingApproval` | E10 | An agent waits for a permission decision |
| `reviewQueueNonEmpty` | E12 | The review queue has pending changesets |
| `suggestWidgetVisible` | E05 | The completion list is visible |
| `ghostVisible` | E10 | Inline AI ghost text is visible |
| `inSnippetMode` | E05 | A snippet session is active |
| `scm.hasChanges` | E09 | The repository has uncommitted changes |
| `workspaceTrusted` | E16 | The workspace is trusted |

## Adding a key

Add a row to `standard_keys` (name, owning epic, one-line meaning) and to this table
in the same PR. Extension keys are namespaced `<extension name>.<key>` and set through
ZEP; they are not listed here.
