# Testing

`zig build test` runs the unit tests of every package and tool. `zig build test-<pkg>` runs one package; `-Dtest-filter=<text>` selects tests by name. Tests use `std.testing.allocator` (leak-checked) and `std.testing.io`.

## Golden tests

`zg_core.testkit.golden` compares text output with checked-in snapshot files.

```zig
const golden = @import("zg_core").testkit.golden;
test "renders the outline" {
    try golden.expectGolden(std.testing.io, @src(), "outline", actual_text);
}
```

- The file is `<package>/testdata/golden/<source file stem>/<name>.golden`, resolved against `zg_options.package_root` (set per package by `zg_build.addPackage`), so the working directory does not matter.
- Default normalisation is `.text`: LF line endings, trailing whitespace stripped, exactly one final newline. Use `expectGoldenOpts(..., .{ .normalize = .exact })` for byte-exact output.
- Create or update golden files with `zig build test -Dupdate-golden` and review the diff before committing.
- On a mismatch the test prints a unified diff (Myers, `zg_core.testkit.diff`) and writes `<name>.golden.actual` next to the golden file; `*.golden.actual` is git-ignored.

## Fuzzing

Zig 0.16's fuzzer drives tests through `std.testing.fuzz(ctx, testOne, .{ .corpus = ... })`, where `testOne` receives a `*std.testing.Smith` that generates values.

```zig
test "fuzz: sse parser" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var chunks: [8][]const u8 = undefined;
            for (zg_core.testkit.fuzz.chunked(s, input, 8, &chunks)) |c| try parser.feed(c);
        }
    }.one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "sse") });
}
```

Rules:

- Name fuzz tests `"fuzz: <target>"`; every parser of untrusted input has one. `zig build fuzz-list` prints them as JSON for nightly CI.
- Seeds live in `packages/<pkg>/fuzz/corpus/<target>/*` (at most 1 MiB per target). `zg_build.addPackage` embeds them into the package's own `zg_corpus` module; read them with `zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "<target>")`.
- Without `--fuzz`, a fuzz test runs once per seed as an ordinary test, on every platform.
- Fuzz in ReleaseSafe: `zig build test -Doptimize=ReleaseSafe --fuzz=10K`. In Zig 0.16 `--fuzz` works on Linux only.
- Use `std.testing.allocator` so leaks fail; never do network or file I/O in a fuzz body; bound every size; feed streaming parsers through `chunked` so chunk boundaries are fuzzed too.
- Reproduce a crash with `zig build test -Dtest-filter="fuzz: <name>"` after adding the crashing input to the corpus, and commit the minimised input with the fix.
