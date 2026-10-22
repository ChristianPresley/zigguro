# Completion

`zg_review.assist.complete` (E12.F07.S01) builds the request for a
ghost-text completion, decides when to send it, and streams the answer
from a FIM provider. The ghost-text controller (#946) builds on these.

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

## Scheduling

`Scheduler` (E12.F07.S01.T01) decides when to ask. It has no clock of its
own: the host reports edits, cursor moves, invokes and accepts, each with
the current time. The host arms one timer from `nextDeadline` and calls
`poll` when that timer fires. Tests drive it with a virtual clock.

- **Triggers.** A user edit that inserts at most 64 bytes with one caret
  triggers. So does a cursor move on the same line within a second of an
  edit, an explicit invoke (fires at once), and a speculative request
  right after an accept.
  - Undo, redo, agent and LSP edits, larger pastes and multi-cursor edits
    never trigger. They drop a pending trigger and cancel the request in
    flight.
- **Debounce.** The debounce is `clamp(min(debounce, 0.8 × ewma),
  min_debounce, debounce)`, where `ewma` tracks the gaps between
  keystrokes. Gaps over 2 s are pauses and do not count.
- **Single flight.** Each document has at most one request in flight.
  `typed` decides what happens when the user types while a request
  streams:
  - The request is kept when the typed bytes are how its answer starts
    (`keep = n`: hide the first `n` bytes).
  - It is cancelled otherwise, when the user has typed past what has
    streamed, and always when it is speculative.
  - `finished` returns null for a result that a later request replaced.
- **Gate.** `gate` gives the first reason not to ask, cheapest check first:
  1. policy exclusion
  2. language, then glob
  3. snooze
  4. multiple carets
  5. a selection
  6. IME composition
  7. the LSP popup (unless the ghost text wins)
  8. read-only
  9. documents over 10 MB
  10. mid-word: an identifier character after the cursor, or other
      non-closing text when the provider cannot fill in the middle. An
      explicit invoke skips this check.

Once a document is open, a keystroke allocates nothing.

`CompletionEngine` puts the scheduler, the cache and a provider together.
Everything runs on the UI thread except the provider call, which runs on
its own task and sends its text back through `Host.post`. When `tick`
finds a trigger due, the engine takes a snapshot of the document from the
host. A snapshot older than the trigger starts nothing. A cache hit is
delivered at once; otherwise the engine builds the request and starts the
provider. `Host.deliver` gets the text so far, how many leading bytes the
user already typed (to hide), and whether it is final. `typed` keeps or
cancels the request in flight, and `dismiss` drops everything for a
document. A request that was replaced or cancelled is never delivered.
The host must stop running posted callbacks once it calls `deinit`.

`Cache` holds up to 512 finished completions in 4 MiB, least recently
used first out. Its keys are the document, the model, and XxHash3 hashes
of the last 2 KiB of prefix and the first 256 bytes of suffix. `extend`
serves the rest of a cached completion that the user typed through after
dismissing it. `invalidateDoc` clears a document's completions after a
non-typing edit.

## Providers

A `FimProvider` (E12.F07.S01.T03) streams the middle for a
`CompletionRequest` into a `Sink`. The call blocks, so the engine runs it
on a worker task. Cancelling that task returns `error.Canceled` and drops
the connection: llama.cpp and Ollama stop generating when the client goes
away, and a half-read connection never goes back to the pool. Each
provider's `caps.server_side_template` says whether it fills the middle
itself; `gate` uses it to decide about mid-line requests.

`HttpFim` talks to three kinds of server through `zg_net`:

| Kind | Request | Stream |
| --- | --- | --- |
| llama.cpp | `POST /infill`: `input_prefix`, `input_suffix`, `input_extra` (the snippets), `n_predict`, `stop`, `stream`, `cache_prompt`, optional `id_slot` | SSE, `content` and `stop` |
| Ollama | `POST /api/generate`: `model`, `prompt` (the snippets as comments, then the prefix), `suffix`, `raw: false`, `keep_alive`, `options.num_predict`, `options.stop`, `options.temperature` | NDJSON, `response` and `done` |
| OpenAI-style | `POST /v1/completions`: `model`, `prompt` from `fim.render`, `max_tokens`, up to four `stop`s, `temperature`, `stream` | SSE, `choices[0].text`, then `[DONE]` |

- **End tokens.** The OpenAI-style output ends at the first end token or
  FIM marker of the template, even when it is split across chunks.
- **No retries.** A failed completion is not retried. Three failures in a
  row make the provider unhealthy for 30 seconds (`healthy` drives the
  status-bar indicator). While it is unhealthy, `complete` returns
  `error.Unhealthy` without sending a request.
- **Warm-up.** `warm` opens a connection with a cheap request (`/health`,
  `/api/version` or `/v1/models`) at most once a minute. The host calls it
  on editor focus.
- **Endpoints.** HTTPS and loopback are always allowed. Plain HTTP to
  another host needs `allow_insecure_http` (`completions.allowInsecureHttp`,
  for LAN servers). The API key comes from E16 secrets, is sent as a bearer
  token, and is never logged.

`ChatFim` uses a chat model with no FIM support. The system prompt asks
for only the code that replaces `<CURSOR>`, and the user message is the
snippets followed by the file with the cursor marked, sent at temperature
0. A reply wrapped in a Markdown fence is unwrapped. zg_review does not
import zg_ai, so the app binds a `ChatPort` to E10's `Provider.stream`.
The app also builds providers from E10's ModelRegistry (role `completion`).

## Bench

`review.complete.build_request_100k` builds a request in the middle of a
100,000-line file, with 20 neighbour documents of 2,000 lines each. The
budget is under 2 ms.

`review.complete.scheduler_10k_keys` runs 10,000 keystrokes through the
scheduler. It covers the UI thread's share of the time from keystroke to
request.
