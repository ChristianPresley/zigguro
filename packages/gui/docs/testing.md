# Testing UI with TestApp and .zgui

`zg_gui.testing.TestApp` runs a window headlessly. It uses `MonoText` (fixed
metrics) and a recording canvas, so layouts and paint records come out the
same on every OS. Tests drive it with high-level actions and semantic
queries. Agents and UI tests can use `.zgui` scripts, which do the same
thing one line at a time.

## TestApp

```zig
var page: MyPage = .{};
const t = try TestApp.init(gpa, .{ .root = .of(&page), .size = .{ .w = 800, .h = 600 } });
defer t.deinit();
_ = t.settle();
try t.click(.{ .role = .button, .name = "Run" });
t.press(.key_s, .{ .ctrl = true });
t.typeText("hello");
t.advance(500); // the virtual clock: timers, tooltips, toasts
try std.testing.expect(t.find(.{ .role = .tooltip }) != null);
```

A `Query` matches on `role`, `name`, `name_contains`, `test_id` (from
`BoxDesc.test_id`) and `kind` (the widget's `name`). `within` limits the
search to one node's subtree. `findNth` and `count` work with the same
queries. `layoutSnapshot`, `semanticsSnapshot` and `paintSnapshot` return
text you can compare with golden files.

## .zgui scripts

Each line is one command, and `#` starts a comment:

```
open Counter start=2                 # a view registered with the runner
click role=button name="Increment"
dblclick|rclick|hover <query>
type "Ada Lovelace"
press ctrl+a                         # also escape, shift+f10, KeyA, left
scroll testid=list 0 -120
drag role=tab name="a.zig" to 900,200   # or: to <query>
wait 500ms
resize 1024 768 [2]
theme dark|light|hc-dark|hc-light
expect role=checkbox name="Enabled" checked
expect role=textbox text="Ada"       # also exists, absent, focused,
                                     # unchecked, disabled, value=, count=
snapshot layout|semantics|pixels "name"
```

Queries are `key=value` terms, and all of them must match:

| Term | Matches |
| --- | --- |
| `role=button` | the accessible role (`switch` for `switch_`) |
| `name="Run"` | the accessible name, exactly |
| `name~="Ru"` | a substring of the accessible name |
| `testid=x` | `BoxDesc.test_id` |
| `kind=tab` | the widget kind |
| `nth=2` | the third match, counting from 0 |
| `within(<query>)` | only inside the first match of the inner query |

The runner parses the whole script before running any of it, so a syntax
error such as `3:9: unknown role "buton"` stops the script before anything
happens. When a command fails, the runner reports its line. If a query
finds nothing, the error also lists the five closest names:

```
2:1: nothing matches role=button name="Incremnet"; closest: button "Increment", button "Reset", ...
```

`script.run(gpa, src, .{ .views = &views, .snapshot = sink }, &diag)` runs
a script. `script.runFile` reads the script from a file first, which is
what `zg ui-test` uses. A `ViewEntry` creates its view from the
`key=value` words after its name. The snapshot sink receives each
snapshot's text. In this package's tests the sink compares it with
`testdata/golden/scripts/<name>.<kind>.golden`; run
`zig build test-gui -Dupdate-golden` to update those files. For now,
`pixels` captures the recorded draw list rather than rendered pixels.

The example scripts are in `src/testing/scripts/*.zgui`, and
`src/testing/script_test.zig` runs them against the `Counter`, `Form` and
`Dock` views in `src/testing/examples.zig`.

From the command line, `zg ui-test` runs scripts against the same views:

```
zg ui-test packages/gui/src/testing/scripts/*.zgui
zg ui-test --snapshots out/ --update my.zgui
```

Each snapshot is compared with `<snapshots>/<name>.<kind>` (by default
`snapshots/` next to the script). A missing file is written, and a
different one fails the script unless `--update` is given. The command
exits 0 when every script passes, 1 when one fails (with the failing line
and the closest names, or the first differing snapshot line) and 2 on a
usage error. `zig build test-zg` runs it on the example scripts and checks
the snapshots against this package's goldens.
