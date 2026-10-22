# Markdown test data

- `spec-0.31.2.txt`: the CommonMark specification, version 0.31.2, from
  https://github.com/commonmark/commonmark-spec (tag 0.31.2, `spec.txt`).
  Copyright John MacFarlane, licensed CC-BY-SA-4.0. Test-only; not shipped.
- `spec-gfm.txt`: the GitHub Flavored Markdown specification, version 0.29
  (gfm), from https://github.com/github/cmark-gfm (`test/spec.txt`).
  Licensed CC-BY-SA-4.0. Test-only; not shipped.
- `entities.json`: the HTML named character references from the WHATWG HTML
  Living Standard (https://html.spec.whatwg.org/entities.json), licensed
  CC-BY-4.0, exported from Python's `html.entities.html5` table because the
  WHATWG host is not reachable from the build environment.
  `tools/mdspec/gen_entities.zig` generates
  `packages/gui/src/markdown/entities_table.zig` from it; that table ships.
