# 0009. GUI toolkit: declarative build over a retained, keyed node tree

Status: Accepted
Date: 2026-10-22

## Context

E04 needs a GUI runtime that every IDE surface (editor, terminal, review,
agent panes, dialogs) builds on, with near-instant frames as a hard
requirement. The options considered:

- Pure immediate mode (Dear ImGui style): simple to write, but layout,
  hit-testing, accessibility and damage tracking are recomputed every
  frame, and widget state needs ad-hoc id stacks.
- A fully retained object tree (DOM style): cheap incremental updates, but
  imperative mutation spreads state across widgets and makes tests and
  agent automation harder.
- Declarative build reconciled into a retained tree (React, GPUI, Iced):
  code reads like immediate mode, the runtime keeps nodes, layout and paint
  between frames and only redoes dirty work.

Rendering is E02's job (Vulkan and a software fallback), and real shaping
is E03's, so E04 must work before either exists.

## Decision

- Views build a node tree each time they are dirty through `Ui`. Nodes are
  matched to the previous frame by key: an identity path hashed with
  Wyhash from the parent key plus either an ordinal or an explicit
  `ui.id(...)`. Unmatched nodes are freed (`deinitState` runs once).
- Nodes live in a struct-of-arrays `NodeStore` with generational `NodeId`s.
  Widget kinds are comptime-generated vtables registered by type.
- App state follows GPUI: entities are owned by `App`, views are the unit
  of invalidation, `notify`/`observe`/`emit` queue effects that are flushed
  between frame phases. No closures are stored.
- A frame runs build, layout (cached per node, CSS Flexbox §9 subset plus
  stack and absolute), paint (per-node op caches; clean nodes are replayed),
  damage and present.
- Hover, press and focus are paint-only state: they never rebuild a view.
- Rendering goes through `zg_gui.paint.Canvas`, whose methods mirror E02's
  `r2d.DrawList`. Text goes through `zg_gui.paint.TextSystem`; `MonoText`
  gives deterministic metrics until E03 shaping lands.
- `TestApp` drives a window headlessly with layout and paint snapshots, so
  every widget is testable on every OS without a GPU.

## Consequences

- Widgets are plain structs (`Props`, optional `State`, `measure`, `paint`,
  `event`), easy to test and to generate.
- A steady-state rebuild of an unchanged list allocates nothing; idle
  frames do no work. Benches under `gui.*` track this.
- Dirty layout currently propagates to the root; relayout boundaries are a
  follow-up.
- zg_gui does not depend on zg_vulkan; the app wires a DrawList adapter in.
  The adapter is added by whichever of E02.F06 or this package lands second.
- Changing `Canvas`, `TextSystem` or `KeyHandler` follows the stability rule
  in `docs/interfaces.md`.

## References

- Spec issues: epic #5 (E04), index #1198.
- CSS Flexible Box Layout Module Level 1, §9 (layout algorithm):
  https://www.w3.org/TR/css-flexbox-1/#layout-algorithm
- GPUI ownership model (Zed): https://github.com/zed-industries/zed/tree/main/crates/gpui
