# Definition of done

A task is done when its pull request is merged with every box below ticked (the same checklist is in the pull request template).

- [ ] Tests cover the task's acceptance criteria and the tests listed in the issue.
- [ ] Every parser of untrusted input has a `fuzz:` test with a seed corpus.
- [ ] A benchmark exists when a performance budget applies, and the pull request states the measured numbers.
- [ ] Every `pub` declaration has a doc comment; user-facing docs are updated.
- [ ] `zig build test fmt-check check-layers` is green locally and in CI.
- [ ] No TODO without an issue link.
- [ ] An ADR exists when a decision affects more than one package.
- [ ] The pull request title, branch and commits pass `zig build prlint`.
