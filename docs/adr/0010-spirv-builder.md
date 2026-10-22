# 0010. Shaders are Zig programs over our own SPIR-V builder

Status: Accepted
Date: 2026-10-22

(Spec reference: ADR-E02-004, epic E02.F05.)

## Context

The Vulkan renderer needs a handful of small shaders (the prim
ubershader, a dual-source subpixel-text fragment shader, a composite
pass). ADR 0001 rules out glslang, shaderc, DXC and SPIRV-Tools, so
SPIR-V has to come from Zig.

Zig 0.16's self-hosted SPIR-V backend (`spirv64-vulkan`) can emit vertex
and fragment shaders but has no image or sampler types (`@SpirvType`
landed after 0.16), a set/binding decoration swap fixed only in 0.17, and
about half of the behaviour tests passing. Shaders that sample a bindless
texture array or write dual-source outputs cannot be expressed with it.

The SPIR-V binary format is small and fully described by the
machine-readable grammar in SPIRV-Headers.

## Decision

- `tools/spirv` is our SPIR-V toolkit: `spec.zig` generated from the
  vendored grammar (`tools/spirv/data`, MIT), a module builder that
  hash-conses types and constants and emits the canonical section order,
  a structural validator, a disassembler and a typed DSL.
- Shader programs are ordinary Zig functions in
  `packages/vulkan/src/shaders/*.zig` that call the DSL. `tools/shaderc`
  runs them at build time, validates every module (failing with
  `<program>: <instruction> at word <n>: <issue>`) and writes
  `<name>.spv`, `<name>.spvasm` and `shaders.zig` into
  `packages/vulkan/src/shaders/gen`.
- The generated directory is checked in, like `vk.zig`: zg_vulkan embeds
  the modules without running the toolchain (a package cannot import
  files outside its folder), output is byte-identical on every host by
  construction, and `zig build test` (`check-gen`) fails when it is
  stale. The `.spvasm` files are the shader goldens.
- Modules target SPIR-V 1.3 (Vulkan 1.1+), memory model Logical GLSL450;
  descriptor indexing uses `SPV_EXT_descriptor_indexing`.
- Semantic validation is the Khronos validation layer's job (it runs
  spirv-val internally) in the lavapipe GPU tests.
- The Zig `spirv64-vulkan` frontend stays an opt-in probe (E02.F05.S01.T03)
  until a pinned Zig supports sampled image arrays, push constants and
  dual-source output.

## Consequences

- No external shader compiler or Zig backend limitation blocks a shader
  feature; adding an instruction is a DSL method plus a unit test.
- Shader code is more verbose than GLSL. The DSL stays limited to what the
  E02 shaders use.
- The CPU-side `extern struct`s (`r2d.Prim`, push constants) are the
  single source of truth for buffer layouts (`@offsetOf`/`@sizeOf`).
- A shader change is a regeneration plus a reviewed `.spvasm` diff.

## References

- [SPIR-V Specification (unified)](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html)
- [SPIRV-Headers spirv.core.grammar.json](https://github.com/KhronosGroup/SPIRV-Headers/blob/main/include/spirv/unified1/spirv.core.grammar.json)
- [SPIR-V GLSL.std.450 extended instruction set](https://registry.khronos.org/SPIR-V/specs/unified1/GLSL.std.450.html)
- [Ali Cheraghi: Zig and GPUs](https://alichraghi.github.io/blog/zig-gpu/)
