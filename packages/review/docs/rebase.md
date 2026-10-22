# Rebase and conflicts between pending changes

Several agents, and you, can have changes pending on the same file. Two
pieces keep them valid.

## Rebasing one file

`zg_review.rebase.rebaseFile` (E12.F02.S02.T01, closed-file part) moves a
pending text change onto new content with a three-way merge:

- the base is the text the change was made against (from the blob store);
- one side is the new content;
- the other is the proposed text.

| Result | What happens to the file change |
| --- | --- |
| `unchanged` | The new content is the base already. |
| `clean` | Edits become the diff from the new content to the merged text. Hunks are derived again, and unchanged hunks keep their decision. |
| `conflicted` | Same as clean, but each conflict region keeps the proposed text. The hunks there get a `ConflictInfo` and go back to undecided. Accepting one takes the proposal; rejecting it keeps what is on disk. |
| `dropped_empty` | The new content already has the change. The file is `applied`, with nothing written. |
| `stale` | The file is gone, became binary, is over 64 MiB, or a delete's file changed. The file waits in `stale`. |

A text create whose path now exists is merged from an empty base and
becomes a modify. Binary changes, pure renames and mode changes are left
alone. A conflicted hunk that a later rebase leaves unchanged keeps its
conflict. Conflicts are journaled with the hunks.

## ConflictIndex

`zg_review.rebase.ConflictIndex` (E12.F02.S04.T01) follows the queue and
indexes the open hunks and whole-file operations of every open changeset
by path.

Pairs from different changesets:

| Kind | When |
| --- | --- |
| `overlap` | Line ranges intersect, or two insertions at one point. |
| `adjacent` | Ranges touch. A soft warning: a three-way merge treats it as a conflict. |
| `same_change` | The same replacement of the same lines, or identical creates or deletes. |
| `create_create` | Two creates of one path. |
| `delete_modify` | A delete and an edit of the same text. |
| `rename_target` | A rename onto a path another change creates or renames onto. |

Hunks are compared only when they were made against the same text. A
change against older text is stale, and the rebase that fixes it updates
the index. A queue event recomputes only the paths of that changeset.

When a changeset lands, the Applier's `applied` event is queued. The owner
then calls `rebaseApplied`, which rebases every other open change on the
written paths onto what was written. Conflicts are marked
`sibling_changeset`, with `other` naming the changeset that landed. A
sibling that made the same change is applied without a write.

`warningFor(path, session)` is the line an agent sees before it edits a
path other sessions have pending changes on. `acceptOrder` suggests an
order for "Accept in order": fewest conflicts within the set first, then
older first.

## Not yet

- Watching the workspace: the `Rebaser` that rebases on E08 watcher
  events, debounces, and suppresses the Applier's own writes.
- Open documents, which E05 `PendingChange` rebases as you type.
- Keeping the original base blob across repeated rebases. Each rebase
  merges from the base the change has at that time.
- The app binding: E10 appending `warningFor` to `read_file` and
  `edit_file` results, and the queue UI badges.
