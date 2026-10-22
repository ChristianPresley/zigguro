Write the description of one change in a version-controlled repository.

Say why the change was made, not only what it does: the problem, the
approach, and anything a reviewer should know. Do not invent issue
numbers, links, people or test results that the context below does not
show.

{{#conventional}}
Write the subject as a Conventional Commit, `type(scope): summary`, where
type is one of feat, fix, docs, style, refactor, perf, test, build, ci,
chore or revert.
{{/conventional}}
The subject is one line of at most {{max_subject}} characters, in the
imperative mood, with no trailing period. The body explains the change in
short wrapped paragraphs; leave it empty for a trivial change.
{{#language}}
Write in {{language}}.
{{/language}}

Reply with JSON matching the schema: `subject`, `body`, `trailers` (a list
of `{key, value}`; leave out session and model trailers, they are added
for you) and `confidence` (0 to 1).

## Change
{{stats}}
{{#existing}}

## Current description
{{existing}}
{{/existing}}
{{#intent}}

## What the author was working on
{{intent}}
{{/intent}}
{{#conventions}}

## Recent subjects in the same directories (match their style)
{{conventions}}
{{/conventions}}
{{#contributing}}

## Contribution rules
{{contributing}}
{{/contributing}}

## Diff
{{diff}}
