# Smart typing

What typing, Enter, Backspace and the comment toggles do on top of plain
insertion. The code is in
`packages/editor/src/model/edit/{smart_edit.zig, pairs.zig, indent.zig, comment.zig}`;
every behaviour below has a scenario in
`packages/editor/testdata/golden/smart_edit/<lang>/cases.txt` (Zig, C, Rust,
Go, Python, TypeScript, JSON, HTML, CSS, Markdown, YAML, shell). Each command
applies one change for all selections, so one undo reverts it.

## Pairs

- **Auto-close.** Typing an opener from the language's `auto_close` list
  inserts its closer when the next character is the end of the line, a blank
  or one of `;:.,=}])>` (`language_defined`, VS Code's default). Settings:
  `always`, `before_whitespace`, `never`.
- **Never in strings or comments.** The token under the caret comes from the
  tier-1 tokenizer (`SyntaxTokens`). Inside a string only plain text is typed.
- **Quotes** do not auto-close after a letter, digit or `_`, so apostrophes
  (`don't`) and Rust lifetimes (`'a`) stay single.
- **Type over.** Typing a closer the editor inserted moves past it. A closer
  the user typed is never typed over. The editor forgets its closers when the
  caret jumps (`AutoPairs.clear`).
- **Backspace** between an auto-inserted pair deletes both.
- **Surround.** Typing an opener with text selected wraps the selection and
  keeps it selected. The pairs come from `surround` (HTML adds `<>`, `()`,
  `[]`, `{}`; Markdown adds `*` and `_`), defaulting to `auto_close`.

## Indentation

- **Enter** keeps the line's indentation, adds a level after an
  `indent_after` token (`:` in Python and YAML, `then`/`do` in shell) or an
  unclosed opener, and removes one after a `dedent_after` keyword (`return`,
  `pass`).
- **Between a pair** (`{|}`, `[|]`, `<p>|</p>`): the caret gets its own
  indented line and the closer moves to the line below.
- **Blank lines** keep no trailing whitespace.
- **Electric closers.** A closer typed first on its line re-indents the line
  to its opener's line.
- **Dedent keywords** (`else`, `elif`, `except`, `finally` in Python; `fi`,
  `done`, `esac`, `else` in shell) re-indent their line when completed by a
  non-word character (`else:`) or by Enter (`fi⏎`): to the previous line's
  indentation when deeper than it, else one level less.
- **The indent unit** is the language default (Go uses tabs) unless the
  document's guess (`indent.guess`, over the first 1000 indented lines) says
  otherwise.

## Comments

- **Toggle line comment** comments every selected line at the smallest
  indentation of the non-blank lines, or uncomments them when all already
  are (removing one space after the token). Blank lines are skipped. A
  language without a line comment (HTML, CSS, Markdown) wraps each line in
  its block comment instead.
- **Toggle block comment** wraps each selection (a caret: its line without
  indentation) in the block comment, or unwraps it.
- Selections grow over the inserted tokens, so the toggled text stays
  selected.

## Not yet

- Embedded languages (script in HTML, fenced code in Markdown) use the
  host's rules.
- Python string prefixes (`f"`, `r"`) do not auto-close.
- Markdown lists do not continue on Enter.
