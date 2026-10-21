# zigguro

An AI-native code editor built in pure Zig 0.16.

## Principles

- **Pure Zig.** Written entirely in Zig 0.16 with zero dependencies and no third-party code.
- **Custom UI.** Every pixel is drawn by zigguro itself; no UI toolkit or web view.
- **Fast.** Native performance from startup to keystroke.
- **Local-first.** Your code and your data stay on your machine.
- **Reviewed AI.** Every AI change is presented for review before it lands.

## Status

Early development. The foundations (build graph, `zg_core`, `zg_jsonrpc`, `zg_net`) are being implemented from the spec in the GitHub issues; the index issue #1198 maps spec IDs to issues.

## Building

Install Zig 0.16.0 (nothing else is needed), then:

```sh
zig build              # builds zig-out/bin/zigguro and zig-out/bin/zg
zig build test         # every package and tool
zig build run-zg -- --version
```

## Contributing

- [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md): toolchain, building, testing, style, layering.
- [docs/AGENTS.md](docs/AGENTS.md): how humans and AI agents claim issues and ship pull requests.
- [docs/definition-of-done.md](docs/definition-of-done.md), [docs/ownership.md](docs/ownership.md), [docs/adr/](docs/adr/README.md).

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
