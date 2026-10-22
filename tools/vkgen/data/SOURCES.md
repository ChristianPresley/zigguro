# Vendored Vulkan registry

Data only (no code). `tools/vkgen` reads it to generate
`packages/vulkan/src/vk/vk.zig`; the generator itself is ours.

| File | Version | Source | SHA-256 |
| --- | --- | --- | --- |
| `vk.xml` | Vulkan 1.4.330 (`VK_HEADER_VERSION` 330) | https://github.com/KhronosGroup/Vulkan-Docs/blob/v1.4.330/xml/vk.xml, tag `v1.4.330`, commit `7cddacb641328e95304047b55f229139d0c710a5` | `b9a8d8166867713dc09314bbfb032668086c4bbf75d73f1bf87b791b7ff0e804` |

License: `Apache-2.0 OR MIT` (SPDX header at the top of `vk.xml`, kept
unchanged). Fetched 2026-10-22.

To update: replace `vk.xml` with the file from a newer Vulkan-Docs tag,
record the tag, commit and hash here, run `zig build vkgen` and review the
diff of `vk.zig`. `zig build test` fails while the generated file is stale.
