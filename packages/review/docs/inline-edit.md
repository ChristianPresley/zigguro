# Inline edit

Inline edit (E12.F06.S01) rewrites a selection from an instruction, or
answers a question about it, and streams the result as a diff in place.

## Pieces

| Piece | Where | Role |
| --- | --- | --- |
| `buildPrompt` | `zg_review.assist.inline_edit.prompt` | System and user text: the selection in `<selection>` tags with 80 lines of context before it and 40 after. The rules and diagnostics are included, and earlier rounds become follow-up turns. |
| `StreamParser` | `…inline_edit.stream_parser` | Pulls the rewrite out of the answer's `<rewrite>` tag. It tolerates a code fence and a cut-off close tag, and flags `unterminated` and `no_open_tag`. |
| `StreamDiff` | `…inline_edit.stream_diff` | Turns the partial rewrite into edits against the original selection. The edits never move backward while streaming. |
| `InlineEditSession` | `…inline_edit.session` | One edit or question. When the stream ends, it puts the edits in the queue as one changeset (origin `inline_edit`, presentation `.inline_`), then accepts or rejects it. |
| `InlineModel` | `apps/zigguro/src/agent/inline_model.zig` | Binds the session's `ModelPort` to an E10 provider. It streams on a worker and posts the text to the UI thread. |
| `InlineEditBar` | `apps/zigguro/src/review/inline_edit_bar.zig` | The prompt bar: the instruction field, status, buttons, the question's answer and the instruction history. |

zg_review sits below zg_ai, so the model is a port that the app binds.

## Keys

The bar's defaults are in `InlineEditBar.Keys`, and the host can rebind them.

| Command | Default | Notes |
| --- | --- | --- |
| `inlineEdit.start` | Ctrl+K (Cmd+K) | The host binds it in `editorTextFocus`. If the user has Ctrl+K chords bound, it uses Ctrl+K Ctrl+I instead. In Vim mode it is `<leader>k`. |
| `inlineEdit.submit` | Enter | Edits the selection. Once an edit is ready, Enter sends a follow-up. |
| `inlineEdit.ask` | Alt+Enter | Asks a question. The answer streams as Markdown, and "Apply as edit" turns it into an edit. |
| `inlineEdit.accept` | Ctrl+Enter | Applies the whole edit. |
| `inlineEdit.reject` | Escape, or Ctrl+Backspace | Rejects the edit. Ctrl+Backspace rejects only while an edit is ready; otherwise it deletes a word in the field. |
| `inlineEdit.cancel` | Escape while streaming | Stops the stream. The bar stays open. |
| `inlineEdit.toAgent` | Ctrl+L | Hands the selection and the instruction to the agent pane. If an edit is pending, the first press asks and the second discards it. |
| `inlineEdit.historyPrev/Next` | Up / Down | Recalls earlier instructions. This works only when the field is empty or still shows a recalled entry unchanged. |

The bar keeps the last 50 instructions per workspace. `History.save` and
`History.load` write them one per line, with `\` and newlines escaped.

## Not yet

- Hosting the bar above the selection (a `block_above` decoration) and
  showing the live edits as a pending change both need EditorView hooks.
- Predicted outputs: no E10 provider forwards a prediction yet.
- Cassettes and the bench.
