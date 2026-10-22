# zg_review model

The headless types every E12 feature builds on (`zg_review.model`,
E12.F01.S01.T01).

## Naming

E05's `ChangeSet` is a single-document text edit: sorted, non-overlapping
byte replaces against one text. E12's `Changeset` is a reviewable bundle
of file changes whose text edits are E05 `ChangeSet`s. `ChangeSetId` is an
alias of `ChangesetId` because E08 drafts spell it that way.

## Types

| Type | Meaning |
|---|---|
| `ChangesetId` | `enum(u64)`, increasing per workspace store, printed `#<n>`; 0 is never assigned |
| `BatchId` | an open batch of a queue (not persisted) |
| `HunkRef` | `{ cs, file, hunk }` |
| `BlobHash` | BLAKE3 of a blob (`blobHash(bytes)`) |
| `Origin` | what produced the change: agent turn, inline edit, LSP edit, search-and-replace, notes, SCM proposal, code-review suggestion, user bulk command |
| `Provenance` | origin, one-line label, rationale, tool call ids, workspace, lane, creation time |
| `BaseRef` | the base a text change was made against: hash, size, E05 document version, line terminators |
| `FileOp` | create (with executable bit), modify, delete, rename (from), set executable |
| `Content` | none, text (`base`, E05 `edits`), or binary (`base`, `new`, `new_size`) |
| `Hunk` | whole-line `base_lines` and `new_lines`, the `replace_span` of `edits.replaces` it covers, the decision, a conflict, and a content key |
| `FileChange` | path, op, content, hunks, state |
| `Changeset` | id, provenance, files, state, revision, supersedes, checkpoint, auto-applied flag, presentation, times; owns an arena |

## Hunks

`deriveHunks(gpa, base, lines, edits, opts)` groups the replaces of an E05
`ChangeSet` into whole-line hunks:

- A replace touches the lines from its start through its end. A change
  that ends exactly at a line start, with a line terminator just before
  that point on both sides, leaves that line out (whole-line inserts and
  deletes stay one-sided). A `\n` that lands right after a line's final
  `\r`, or a new final `\r` before a `\n`, joins them into one terminator,
  so both lines count as touched.
- Replaces within `merge_gap_lines` unchanged lines of each other share a
  hunk. Hunks are never split, so `replace_span` always covers whole
  replaces, and accepting a hunk accepts exactly those replaces.
- Line counts follow `zg_core.LineIndex` (`\n`, `\r\n`, a lone `\r`).
- `new_lines.start` follows the line deltas of the earlier hunks.
- Passing the previous hunks as `opts.previous` keeps the decision of every
  hunk whose base and new text are unchanged (XxHash3 key).

Creates have one hunk. Deletes, renames, mode changes and binaries have
none: their file decision is the only one.

## States

```
Changeset: open_batch → pending → partially_applied → applied | rejected
                        pending → applied | rejected | superseded | discarded
                        applied → pending           (undo accept)
File:      pending ⇄ partially_applied ⇄ applied, pending ⇄ rejected,
           conflicted / stale while rebasing, superseded (terminal)
```

`recomputeState` derives each file's state from its hunk decisions (all
decided: `applied` when any was taken, else `rejected`; some taken:
`partially_applied`), then the changeset's from its files (all decided:
`applied` when any landed, else `rejected`; some landed:
`partially_applied`; else `pending`).

## Provenance JSON

`writeProvenanceJson` and `parseProvenanceJson` use snake_case keys in
declaration order. The origin is an object whose `"type"` names the
variant. `AgentRef.session` is the 26-character Crockford ULID. Optional
fields are left out when null. Unknown keys are ignored.

```json
{"origin":{"type":"agent","ref":{"session":"01JABCDEFGHJKMNPQRSTVWXYZ0","agent":2,"tool_call":"toolu_1"},"turn":7,"model":"claude-x"},"label":"Turn 7: Fix the parser","tool_calls":["toolu_1","toolu_2"],"workspace":"/w","created_ms":1700000000000}
```

## Queue

`Queue` holds a workspace's changesets in submission order and belongs to
one owner thread. Producers build a batch and commit it:

```zig
const b = try q.beginBatch(prov);                  // any thread
try q.addEdit(b, "src/a.zig", base_text, doc_version, &edits);
try q.addCreate(b, "src/new.zig", bytes);
try q.addDelete(b, "old.zig", old_text);
try q.addRename(b, "x.zig", "y.zig");
try q.setExecutable(b, "run.sh", true);
const id = try q.commitBatch(b, .{});              // owner thread: visible now
const id2 = try q.submitter().commitBatch(b2);     // any thread: visible after drain()
```

- Paths become workspace-relative and `/`-separated. Paths outside the
  root, inside `.git/` or inside `.zigguro/review/` are rejected.
- Operations on one path combine (see `batch.zig`): edits compose, a
  create absorbs later edits, edit then delete is a delete, create then
  delete is nothing, delete then create is a whole-file edit.
- Base texts, deleted texts and created texts go to the `Blobs` port (a
  `MemBlobs` until the durable store lands). Hunks are derived at commit.
- An edit made on top of the same session's undecided edit of the same
  file folds into that changeset: the edits compose, the hunks are
  derived again, the earlier file records `folded_from`, and the new
  changeset keeps a `superseded` stub. A changeset whose every file
  folded is `superseded`. Other sessions never fold.
- `auto_apply` is ignored until the review policy exists (fail closed).
- Listeners get `submitted`, `updated`, `state` and `removed` events on
  the owner thread.
