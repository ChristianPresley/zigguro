# Review comments

`zg_review.feedback` (E12.F03.S03.T01) holds review comment threads on
changesets: what a reviewer, an agent or an F08 code review run says
about a line range of a changed file, and the replies to it.

## Threads

A thread belongs to one changeset (`target`) and is anchored to lines of
one of its files:

| Field | Meaning |
| --- | --- |
| `anchor.path`, `anchor.side` | The file, and whether the lines are on the base side or the proposed (`new`) side. |
| `anchor.lines` | 0-based `[start, start + count)`; `count` 0 is a point between lines. |
| `anchor.hunk_key` | The key of the hunk the thread was started on, when it was. |
| `anchor.content_hash`, `anchor.text` | What the anchored lines said when the thread was last placed. |
| `label`, `blocking`, `tags` | Conventional Comments label, the blocking flag and free decorations. |
| `resolved`, `outdated` | Resolved threads collapse in views; outdated ones lost their lines. |
| `comments` | The first comment and its replies, oldest first. |

Authors are a user name, an agent (`AgentRef`) or an F08 code review run
id. Bodies are Markdown and are stored as written.

```zig
var store: CommentStore = .init(gpa, .{ .recorder = changesets.commentRecorder(), .id_base = tag << 32 });
const at: CommentAnchor = try .at(gpa, "src/main.zig", .new, new_text, .{ .start = 41, .count = 3 });
const p = parseLabelPrefix(body); // prefill the label dropdown
const t = try store.create(cs, at, p.label, p.blocking orelse false, body, .{ .user = "dana" }, now_ms);
_ = try store.reply(t, "Fixed.", .{ .agent = agent_ref }, now_ms);
try store.resolve(t, true);
```

## Labels

`parseLabelPrefix` reads a [Conventional Comments](https://conventionalcomments.org/)
prefix: `<label> [(<decorations>)]: ` with one of `issue`, `suggestion`,
`nitpick`, `question`, `praise`, `todo`, `chore`, `note`, `thought`,
`typo`, `polish` or `quibble`, in any case.

- `blocking` sets the blocking flag; `non-blocking` and `if-minor` clear
  it.
- Other decorations (such as `security`) are free tags. `create` stores
  the tags of the first comment's prefix on the thread.
- The label and the flag passed to `create` are the caller's choice: the
  UI prefills its dropdown from the prefix, and the user can change it
  (`setLabel`). The body is never rewritten.

A changeset with unresolved blocking threads shows a warning on "Accept
all" (`unresolvedBlocking`), but accepting stays allowed: the user is the
authority.

## Re-anchoring

The hash of an anchor is XxHash3 over the hashes of its lines. Each line
hash is XxHash3 of the line with whitespace normalised: trimmed, with
runs collapsed to one space and terminators dropped. So re-indenting a
line keeps its threads.

After a rebase or a revision, `reanchor(target, path, new_text, .{ side,
map })` moves each thread of that file and side:

1. When the caller has the old-to-new hunks (`map`, from the Rebaser's
   ChangeSet), the range is mapped through them. If the mapped lines hash
   the same, the thread moves there.
2. Otherwise the same lines are tried, then the nearest window of the
   same size within 50 lines, upwards first.
3. If no window matches, the thread is marked `outdated`. It keeps its
   last lines and text for display and is never dropped. A later
   revision that brings the text back brings the thread back too.

Threads on the base side change only when the base is rebased.
Re-anchoring 200 threads takes about 0.12 ms
(`review.comments.reanchor_200`; the budget is 5 ms).

## Persistence

Every change appends a `comment` record (journal kind 7) to the review
store:

| `op` | Carries |
| --- | --- |
| `create` | The thread: `cs`, `anchor`, `label`, `blocking`, `tags`, `created_ms`, and the first `comment`. |
| `reply`, `edit` | The `comment` (`edit` with `edited_ms`). |
| `resolve` | `resolved`. |
| `label` | `label`, `blocking`. |
| `reanchor` | The new `lines`. |
| `outdated` | Nothing more. |
| `snapshot` | A whole thread, with `replies`; written by compaction. |

```json
{"op":"create","thread":4294967297,"cs":12,"anchor":{"path":"src/main.zig","side":"new","lines":[41,3],"hash":1234,"text":"..."},"label":"issue","blocking":true,"created_ms":1761120000000,"comment":{"id":4294967298,"author":{"t":"user","name":"dana"},"body":"issue (blocking): ...","created_ms":1761120000000}}
```

`QueueSink.comments = store.restoreSink()` restores the records on a
load and on every tail, so threads that another process writes (the IDE
or `zg review`) show up within one poll. Restoring skips records it
already has and does not journal again. Thread and comment ids share one
counter that starts at the process's `id_base`, so processes never hand
out the same id.

Compaction (`gc.collect` with `Live.comments`) writes one `snapshot` per
thread of each kept changeset. The threads of dropped changesets are
dropped with them (`dropTarget`).

## In the IDE

The review glue (`apps/zigguro/src/agent/review_glue.zig`) owns the
workspace's `CommentStore`. It binds the store to the review store when
the store opens: comments are written at once, like approvals, and
`refresh` takes the threads that other windows or `zg review` wrote.

The hunk review view (`apps/zigguro/src/review/review_view.zig`) shows
the threads:

- Each hunk has a Comment button. A new thread anchors to the hunk's
  added lines, or to its removed lines when it only removes, and keeps
  the hunk's key. The label and blocking flag come from the body's prefix.
- A thread is shown under the hunk its lines overlap. Threads on no hunk
  (outdated, or on unchanged lines) are listed first.
- Thread rows have Reply and Resolve (Reopen once resolved). A resolved
  thread collapses to its first line.
- The header warns "⚠ N blocking comments unresolved". Accept all still
  works.

Fix requests in the IDE:

- The review glue owns `Feedback`. The workbench binds it to its agent
  (`apps/zigguro/src/agent/review_agent_port.zig`) and runs `pump` after
  each turn's changeset and each refresh. The workbench runs one agent,
  so another session counts as ended. Sessions are not saved yet, so
  "resume" is not offered; the view offers to send the request to the
  current agent instead.
- Request fix (in the header, when the focused file's changeset has open
  threads) sends them all. Threads show "sent" and, once the agent's
  revision changed their lines, "maybe addressed".
- Interdiff (in the header, once there is a previous revision or a
  superseded changeset) shows the changes between the two proposals;
  Full diff goes back.

Still to come: re-anchoring when an accepted hunk rebases the others,
the `m`/`r`/`R` keys, and Markdown rendering of the comment bodies.

## Threading

The store is used on the queue's owner thread. Agents' replies are
posted there.

## Fix requests and revisions

`Feedback` (E12.F03.S03.T02, `feedback/feedback.zig`) sends review
threads to the agent that made a changeset and follows its revision.
The app implements `AgentPort` over E10's agents; zg_review never
imports zg_ai.

**The message** (`feedback/message.zig`) is deterministic Markdown: a
header naming the changeset, then one numbered item per thread with
its label, location (1-based lines; "(removed lines)" for the base
side), a fenced quote of the proposed lines (at most 40, with the middle
cut), the comment and its replies. Then the extra request, if any, and
the ask to revise. Each thread is also a `range` context item. When the
text is over `max_tokens` (E10's estimator, `review.feedbackMaxTokens`,
default 4,000) the quotes are dropped and the locations and comments
stay. See `feedback/testdata/feedback_3_threads.md`.

**Delivery** follows the session's status: `running` steers the running
turn, `idle` starts a new turn, and `ended` returns `ask_resume`. The UI
then asks whether to resume the session or start a new one with the
message (`finishEnded`). The threads are marked `sent`.

**Revisions.** The request waits for the agent's next change:

- When the edits fold into the changeset itself (it was still
  undecided), its proposed texts change. `revision` goes up, and each
  changed file keeps its previous proposal as a blob in
  `FileChange.previous`, which is journaled with the changeset.
- When a new changeset of the same session touches one of its files
  (the old one was partly decided), the new one `supersedes` it and the
  open threads are copied onto it (`copied_from`).

Either way the threads are re-anchored to the new text. A sent thread
whose lines changed is tagged `maybe_addressed`.

**Interdiff.** `interdiff(older, newer, path)` returns the texts to
diff: the previous proposal against the current one when `older ==
newer`, otherwise the superseded changeset's proposal against its
successor's.

The queue listener only notes events; the owner calls `pump` after the
queue changes. Requests that are still waiting live in memory.
