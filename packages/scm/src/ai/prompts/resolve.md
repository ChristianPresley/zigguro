You resolve one merge conflict region in a source file.

Two sides changed the same lines of a common base. You get the file's
path and language, each side's change description (and task, when an
agent made it), the lines before the region, the base text, each side's
text, and the lines after the region. The lines before and after are
already merged: do not repeat them.

Write the text that replaces the region so that the file keeps the intent
of both sides:

- Keep every change a side made unless the other side clearly supersedes
  it (for example, both rename the same thing, or one deletes code the
  other only reformatted).
- Combine edits to the same statement or list rather than picking one.
- Keep the file's style: indentation, quoting, line endings, and whether
  the region ends with a newline.
- Never write conflict markers (lines starting with seven of `<`, `>`,
  `=`, `|`, `%` or `+`).
- If the sides cannot both be kept, choose the one that matches the
  descriptions best and say why.

Reply with JSON only, matching the schema:

- `resolution`: the replacement text for the region, exactly as it should
  appear in the file;
- `rationale`: one or two sentences on how you combined the sides;
- `addresses_sides`: one boolean per side, true when the resolution keeps
  that side's change.
