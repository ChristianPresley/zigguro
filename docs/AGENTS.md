# Working on zigguro as an agent

zigguro is specified as GitHub issues: Epic > Feature > Story > Task, each titled with a stable spec ID such as `[E05.F02.S01.T03]`. Issue #1198 maps every spec ID to its issue number. Many agents work concurrently, so this protocol is strict.

## Picking work

- Pick a **Task** issue (label `task`). Prefer `P0`, then `P1`, then `P2`; `good-first-agent-task` tasks are fully independent.
- Read its parent Story and Feature, and the Epic's architecture section.
- Every spec ID under the task's **Dependencies** must be closed, or available behind its documented interface (see [interfaces.md](interfaces.md)). Otherwise pick another task.
- Never pick a task labelled `status:claimed` or `status:blocked`.

## Claiming

- Comment `claim` on the task issue and add the label `status:claimed`.
- A claim with no linked pull request after 3 days lapses; anyone may remove the label.
- Work on one task (or one tightly coupled set of tasks in the same story) at a time.

## Branches

- Name: `<type>/<spec-id lowercase>-<slug>`, e.g. `feat/e00.f05.s01.t01-framers`. `<type>` is a conventional-commit type.
- Branches created by the Claude agent harness are named `claude/<slug>` and are also accepted.
- Branch from `main`; rebase on `main` rather than merging it into your branch when you can.

## Commits

- Conventional Commits 1.0.0: `type(scope): description`. The scope is a package short name (`core`, `jsonrpc`, `net`, `platform`, ...) or one of `build`, `ci`, `docs`, `repo`, `tools`, `apps`.
- One commit per file, with a body that describes the file.
- Footer: `Spec: <ID>` naming the task the commit implements. Agents also add their `Co-Authored-By:` line.
- `zig build prlint -- --commits <file>` checks the header and footer.

## Pull requests

- Title: `type(scope): description [<spec ID>]`, e.g. `feat(net): add SSE parser [E00.F06.S02.T01]`.
- Fill in every section of the pull request template, including the budget numbers when the task has a performance budget.
- Reference each implemented task with `Closes #N`.
- Open the pull request as a draft until CI is green, then mark it ready.

## Definition of done

See [definition-of-done.md](definition-of-done.md). In short: tests, a fuzz target for every parser of untrusted input, a benchmark when a budget applies, doc comments on every `pub` declaration, `zig build test fmt-check check-layers` green, no TODO without an issue link, and an ADR when a decision affects more than one package.

## Cross-package changes

- Changing another package's files, or anything in `build.zig`, `packages/build`, `tools/` or `.github/`, needs a separate pull request labelled `cross-package`, reviewed by the owning epic (see [ownership.md](ownership.md)).
- For an API change, open an issue labelled `api-change` against the owning package first.
- Make interim changes behind a new function; never break an existing signature in the same pull request.
- A new `-D` option goes into `zg_build` (and [build-options.md](build-options.md)) in a `cross-package` pull request; never declare options ad hoc in a package.

## When blocked

- Comment `blocked: <spec-id or reason>` on the task and add `status:blocked`.
- Pick another task.
- Do not stub another package's functionality inside yours, except through test doubles under `src/testing/`.

## Hard rules

1. Zig 0.16 std only. No `@cImport`, no `.url` dependencies, no vendored code.
2. No blocking I/O on the UI thread.
3. Every `pub` declaration has a doc comment.
4. Tests are required.
5. Never edit files outside your package except via a separate PR labelled `cross-package` that the owning epic reviews.
6. Do not change another package's public API without an ADR or a linked issue.
7. Never weaken CI.
