# Vendored LSP meta models

Data files only (no code). `tools/lspgen` reads them to generate
`packages/lsp/src/gen/protocol.zig`; the generator itself is ours.

| File | metaData.version | Source | SHA-256 |
| --- | --- | --- | --- |
| `metaModel-3.17.json` | 3.17.0 | https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/metaModel/metaModel.json (published at https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/metaModel/metaModel.json) | `c207890d9e0f54d8f9e462a924670f563423ec9af90a0a369645ff55384c8d6d` |
| `metaModel-3.18.json` | 3.18.0 | https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.18/metaModel/metaModel.json (published at https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/metaModel/metaModel.json) | `ce9e95e3c2a1ef333f5b7d64be7c8d31138af736a3d128cd5d99165e9dd26a5d` |

Fetched 2026-10-22 from the `gh-pages` branch. The generated file is built
from the 3.18 model; the 3.17 model is kept so tests can check that both
parse and generate.

To update: replace the file, record the new hash here, run
`zig build lspgen` and review the diff of `protocol.zig`.
