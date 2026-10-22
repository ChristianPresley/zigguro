//! zg spirv: our SPIR-V toolkit (ADR-E02-004). Std-only; used at build
//! time by `tools/shaderc` to turn the shader programs in
//! `packages/vulkan/src/shaders` into SPIR-V.

pub const spec = @import("spec.zig");
pub const builder = @import("builder.zig");
pub const validate = @import("validate.zig");
pub const disasm = @import("disasm.zig");
pub const dsl = @import("dsl.zig");

pub const Module = builder.Module;
pub const Function = builder.Function;
pub const Id = builder.Id;

test {
    _ = builder;
    _ = validate;
    _ = disasm;
    _ = dsl;
}
