# Completion context

`zg_review.assist.complete` (E12.F07.S01.T02) builds the request for a
ghost-text completion. The scheduler (#940), the provider adapters (#944)
and the ghost-text controller (#946) build on it.

## Request

`buildRequest(arena, text, cursor, options)` takes an immutable snapshot of
the document's text and returns a `CompletionRequest`. A
`ContextBudget` sets the token budget: 2,048 tokens by default, split 60%
for the prefix, 15% for the suffix and 25% for extras. A `TokenEstimate`
counts tokens. The app binds E10's calibrated estimator; the default
assumes four bytes per token.

- **Prefix.** The prefix runs back from the cursor in whole lines. It
  starts with a path line (`// path: src/x.zig`, or `#` or `--`
  depending on the language). The file's import block is reserved first,
  if it is at most half the budget. That block runs up to the last import
  line in the first 30 lines, with patterns per language. If the
  enclosing scope (`Scopes`, from E05 Structure) starts within 1.5 times
  the budget, the prefix starts at the scope instead, and the header stays
  only if it still fits.
- **Suffix.** The suffix runs forward in whole lines up to its budget. It
  stops five lines after the enclosing scope ends.
- **Extras.** `NeighbourIndex` supplies extra snippets. The query is the
  set of identifiers in the 30 lines before the cursor. The best 3 windows
  of other documents are added, plus this document's best window outside
  the prefix and suffix, as long as they fit the extra budget.
- **Multi-line or single-line.** A request is multi-line when the user
  explicitly asked for a completion, or when the cursor ends a line that
  is blank or opens a block: `{`, `(`, `[`, `=>`, or `:` in Python.
  Closing characters after the cursor still count as the end of the line.
  A single-line request stops at `\n` and allows 32 tokens. A multi-line
  request allows 256 tokens and has no stops; the dedent rule and the
  template's end tokens end it (T04).

## Neighbours

`NeighbourIndex` keeps the 20 documents viewed or edited most recently,
with a copy of each one's text. Each document is cut into 60-line windows
that overlap by 30 lines. Each window keeps the 32-bit hashes of its
identifiers, and windows are rebuilt lazily after an edit. Windows are
ranked by Jaccard similarity with the query. Documents marked `excluded`
by the security policy are never returned.

## FIM templates

`fim.render(arena, template, request, repo_name)` writes the raw prompt for
a completion-only provider:

- **PSM:** prefix token, prefix, suffix token, suffix, middle token.
- **SPM:** suffix token and suffix first, then prefix token, prefix and
  middle token.
- **Repository-level:** used when the template has `repo_tok` and
  `file_sep_tok`. The prompt starts with the repository name, then has one
  file block per extra snippet, then the current path, then the FIM
  triplet.

`fim.stops` adds the template's end tokens to the request's stops.

The token strings come from `templates.zon`, and each entry cites its
model card: Qwen2.5-Coder, StarCoder2, Code Llama, DeepSeek-Coder and
CodeGemma. Providers that apply the template on the server (llama.cpp
`/infill`, Ollama `suffix`) take the structured fields and need no
template.

## Bench

`review.complete.build_request_100k` builds a request in the middle of a
100,000-line file, with 20 neighbour documents of 2,000 lines each. The
budget is under 2 ms.
