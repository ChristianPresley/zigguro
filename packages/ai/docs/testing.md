# Testing zg_ai with `ScriptedProvider`

Every loop, UI, CLI and eval test drives a `ScriptedProvider`
(`src/provider/scripted.zig`) instead of a network provider. Each call to
`Provider.stream` plays the next scripted turn:

| Step | Effect |
| --- | --- |
| `.event = ev` | emits `ev` to the sink and folds it into the response |
| `.delay_ms = n` | sleeps `n` ms with `io.sleep` (cancellable) |
| `.fail = err` | returns `err` (any `Provider.StreamError`) |
| `.expect_request = f` | returns `error.InvalidRequest` unless `f(req)` |

Every request is deep-copied; read them back with `requests()`. When the
script runs out, `stream` returns `error.Protocol`.

## Text-only turn

```zig
const turns = [_][]const ScriptedProvider.Step{script.text("hello")};
const s = try ScriptedProvider.init(gpa, &turns, .all);
const p = s.provider();
defer p.deinit();
const resp = try p.stream(io, arena, &.{ .model = "m", .messages = &msgs }, .discard);
// resp.message.content[0].text.text == "hello", resp.stop == .end_turn
```

## Parallel tools

```zig
const turns = [_][]const ScriptedProvider.Step{
    script.tools(&.{ .{ "a", "read_file", "{\"path\":\"a\"}" }, .{ "b", "grep", "{\"q\":\"x\"}" } }),
    script.text("done"),
};
```

The first call returns a message with two `tool_use` blocks and stop reason
`tool_use`; the second (after the loop has sent the tool results) returns
"done".

## Mid-stream error

```zig
const turns = [_][]const ScriptedProvider.Step{&.{
    .{ .event = .{ .block_start = .{ .index = 0, .kind = .text } } },
    .{ .event = .{ .text_delta = .{ .index = 0, .text = "partial" } } },
    .{ .delay_ms = 5 },
    .{ .fail = error.Overloaded },
}};
```

The sink sees the partial text before `stream` fails with
`error.Overloaded`, which exercises retry and partial-commit paths.

## Conformance

Concrete providers call `conformance.runConformance` with a factory that
serves each `Fixture` body through `fake_server.FakeTransport`. The suite
checks that the response equals the fold of the emitted events, that the
result does not depend on chunk boundaries (1..64 bytes), the expected
text, tools, stop reason and usage, and that cancellation returns
`error.Canceled` within 50 ms.
