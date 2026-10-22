# Vendored SPIR-V grammar

Data only (no code). `tools/spirv/grammar_gen.zig` reads it to generate
`tools/spirv/spec.zig`; the generator, builder, validator and
disassembler are ours (ADR-E02-004).

| File | Version | Source | SHA-256 |
| --- | --- | --- | --- |
| `spirv.core.grammar.json` | SPIR-V 1.6 revision 4 | https://github.com/KhronosGroup/SPIRV-Headers/blob/vulkan-sdk-1.4.335.0/include/spirv/unified1/spirv.core.grammar.json, tag `vulkan-sdk-1.4.335.0`, commit `b824a462d4256d720bebb40e78b9eb8f78bbb305` | `2768cbed9533c61dc9fe06e3a85b0c3533352a8c5f3d627302fb2678db880f71` |
| `extinst.glsl.std.450.grammar.json` | GLSL.std.450 version 100 revision 2 | same tag, `include/spirv/unified1/extinst.glsl.std.450.grammar.json` | `5d72e48247569f9b77a17a849db624350abc9d26f7f72b153bbcf15c37238239` |

License: MIT (Khronos), as stated in the `copyright` array at the top of
each file and in `LICENSE` (the first section of the repository's
`LICENSE` file, which covers both files). Fetched 2026-10-22.

To update: replace both files with the ones from a newer SPIRV-Headers
tag, record the tag, commit and hashes here, run `zig build spirvgen` and
review the diff of `spec.zig`. `zig build test` fails while the generated
file is stale.
