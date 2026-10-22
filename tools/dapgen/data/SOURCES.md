# Vendored Debug Adapter Protocol schema

Data file only (no code). `tools/dapgen` reads it to generate
`packages/dap/src/gen/protocol.zig`; the generator itself is ours.

| File | Source | SHA-256 |
| --- | --- | --- |
| `debugAdapterProtocol.json` | https://github.com/microsoft/debug-adapter-protocol/blob/main/debugAdapterProtocol.json (published at https://microsoft.github.io/debug-adapter-protocol/debugAdapterProtocol.json) | `ff8ae4c6cfd588a050e9346c35fd104748a27ef4518d1c3268529ca6f8ff5818` |

Fetched 2026-10-22 from the `main` branch. The hash is also emitted into
the generated file as `schema_sha256`.

To update: replace the file, record the new hash here, run
`zig build dapgen` and review the diff of `protocol.zig`.
