# Revsets

A revset selects a set of commits. Revsets are used by the CLI (`-r`), UI filters, agents through MCP tools, and policy rules such as immutable heads and lane scopes. The language follows [Jujutsu's revsets](https://docs.jj-vcs.dev/latest/revsets/) and adds functions for AI provenance, lanes and review state.

Results come out children first, in the commit index's topological order. Evaluation is lazy. `trunk()..@` only visits the commits between the two, and `limit` stops a query early. Every query checks its deadline every 4096 commits. The UI passes 8 ms.

The implementation is in `src/graph/revset/`.

## Symbols

| Syntax | Meaning |
|---|---|
| `@` | This workspace's working-copy commit |
| `name@` | Workspace `name`'s working-copy commit |
| `name@remote` | Remote bookmark `name` on `remote` |
| `name` | A tag, bookmark or git ref, in that order. A conflicted ref stands for every commit it adds. |
| `3f9a…` | A commit ID prefix (hex). Hidden commits resolve too. |
| `kpqx…` | A change ID prefix (reverse hex `k`..`z`). Only visible commits resolve. |
| `"any text"` | A quoted name, for names with spaces or operator characters. `'raw'` strings skip escapes. |

Names may contain letters, digits, `_` and `/`, plus `.`, `-` or `+` between them. `release-1.2` is one name. `main-` is `main` followed by the parents operator.

An unknown name is an error. The error gives the span and, when a bookmark or tag is within edit distance 2, a suggestion.

## Operators

From tightest to loosest:

| Operator | Meaning | Example |
|---|---|---|
| `x-`, `x+` | Parents, children | `@-` is the working copy's parent |
| `::x` | Ancestors of x, including x | `::main` |
| `x::` | Descendants of x, including x | `main::` |
| `x::y` | Descendants of x that are ancestors of y | `main::@` |
| `..x` | Ancestors of x, without the root commits | `..@` |
| `x..` | Visible commits that are not ancestors of x | `main..` |
| `x..y` | Ancestors of y that are not ancestors of x | `trunk()..@` |
| `::` | Every visible commit | `:: ~ mine()` |
| `~x` | Visible commits not in x | `~empty()` |
| `x & y` | Intersection | `mine() & ::@` |
| `x ~ y` | Difference | `::@ ~ ::trunk()` |
| `x \| y` | Union | `main \| side` |

Range operators cannot be chained: write `(a::b)::c`.

## String patterns

Functions that match text take a pattern:

- `text`, `"text"` or `substring:"text"`: contains `text`.
- `exact:"text"`: equals `text`.
- `glob:"fix*"`: `*` matches within a path component, `**` matches across components, and `?` and `[a-z]` match single characters.
- The `-i` forms ignore ASCII case: `substring-i:`, `exact-i:`, `glob-i:`.
- `regex:"…"` needs zg-regex (E05.F03) and fails with "unavailable" until then.

`files()` treats a bare path as the path itself or anything under it: `files(src)` matches `src/main.zig`.

## Functions

### Graph

| Function | Meaning | Example |
|---|---|---|
| `all()` | Every visible commit (ancestors of the visible heads) | `all() ~ ::trunk()` |
| `none()` | The empty set | `present(x) \| none()` |
| `root()` | Visible commits with no parents | `root()..@` |
| `visible_heads()` | The view's heads | `visible_heads() & mine()` |
| `heads(x)` | Commits in x that are not ancestors of other commits in x | `heads(::@ & mine())` |
| `roots(x)` | Commits in x with no ancestor among the other commits in x | `roots(trunk()..@)` |
| `parents(x)` | Parents of x | `parents(@)` |
| `children(x)` | Visible children of x | `children(trunk())` |
| `ancestors(x[, depth])` | `::x`. With a depth, x is generation 1, so `ancestors(@, 2)` is `@` and its parents. | `ancestors(@, 5)` |
| `descendants(x[, depth])` | `x::`, optionally limited the same way | `descendants(trunk(), 2)` |
| `fork_point(x)` | The newest common ancestors of every commit in x | `fork_point(main \| side)` |
| `latest(x[, n])` | The n commits of x with the newest committer time (default 1) | `latest(mine(), 3)` |
| `present(x)` | x, or nothing when x names an unknown revision | `present(feature)` |
| `divergent()` | Visible commits whose change ID has another visible commit | `divergent() & mine()` |
| `evolog(x)` | x and every commit it rewrote, transitively (predecessors) | `evolog(@)` |
| `touched_by_op(op)` | Commits that operation `op` (a full ID) made visible | `touched_by_op(3f9a…)` |

### Commit contents

| Function | Meaning | Example |
|---|---|---|
| `description(p)` | Descriptions matching p | `description(glob:"fix*")` |
| `author(p)` | Author name or email matching p | `author(alice)` |
| `committer(p)` | Committer name or email matching p | `committer(exact:"ci@example.com")` |
| `mine()` | Authored by the configured user email (case-insensitive) | `mine() & ::@` |
| `empty()` | Commits whose tree equals their parent's | `~empty()` |
| `conflicts()` | Commits with unresolved conflicts | `conflicts() & ::@` |
| `files(p)` | Commits that change a path matching p (merges are compared with their first parent) | `files(glob:"**/*.zig")` |
| `signed()` | Commits with a signature | `trunk()..@ ~ signed()` |

### Refs

| Function | Meaning | Example |
|---|---|---|
| `bookmarks([p])` | Targets of bookmarks whose names match p | `bookmarks(glob:"feature/*")` |
| `remote_bookmarks([p[, remote]])` | Targets of remote bookmarks matching p and remote | `remote_bookmarks(main, origin)` |
| `untracked_remote_bookmarks([p[, remote]])` | The same, limited to untracked ones | `untracked_remote_bookmarks()` |
| `tags([p])` | Targets of tags matching p | `tags(glob:"v1.*")` |
| `trunk()` | `main@origin`, `master@origin` or `trunk@origin`, whichever exists first, else `root()` | `trunk()..@` |

### zigguro extensions

| Function | Meaning | Example |
|---|---|---|
| `agent([p])` | Changes with lines attributed to an agent whose `agent_name` or `model_id` matches p (any agent without p) | `agent(claude) & trunk()..@` |
| `human()` | Changes with no AI-attributed lines | `human() & mine()` |
| `session(id)` | Changes made in agent session `id` | `session("s-42")` |
| `lane([p])` | Changes in lanes whose names match p: from the lane's base to its workspace's working copy | `lane("refactor-*")` |
| `reviewed()`, `unreviewed()` | Review state from the E12 adapter | `unreviewed() & trunk()..@` |
| `why(path, line)` | The commits blame reports for that line | `why("src/main.zig", 120)` |
| `stack([x])` | The stack containing x (default `@`): `(trunk()..x)::` | `stack()` |

`agent()`, `human()` and `session()` need the provenance index (F05). `reviewed()` and `unreviewed()` need the review adapter (E12). `why()` needs history search (F05). Without its provider, a function fails with an "unavailable" error and a message that names the missing provider.

## Aliases

Aliases come from settings (`scm.revset_aliases`) and the repo's `config.zon`. A symbol alias is declared as `name`, and a function alias as `name(a, b)`. A user alias replaces a default with the same name and argument count. Expansion goes at most 32 levels deep, so a recursive alias is reported as an error instead of hanging.

The defaults:

| Alias | Definition |
|---|---|
| `immutable_heads()` | `trunk() \| tags() \| untracked_remote_bookmarks()` |
| `immutable()` | `::immutable_heads()` |
| `mutable()` | `~immutable()` |
| `stack()` | `stack(@)` |
| `stack(x)` | `(trunk()..x)::` |

An unknown function is reported with its span. When a function or alias name is within edit distance 2, the error also suggests it, for example "unknown function `descendents` (did you mean `descendants`?)".
