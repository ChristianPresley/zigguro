//! The module root tools/shaderc compiles the shader programs from
//! (E02.F05). It sits in `src/` so the programs can share
//! `r2d/prim.zig` with the renderer; zg_vulkan itself never imports it.

pub const all = @import("shaders/programs.zig").all;
pub const interface = @import("shaders/programs.zig").interface;
