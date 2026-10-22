//! Every shader program tools/shaderc compiles (E02.F05). Adding an entry
//! adds a declaration of the same name to the generated `shaders` module
//! (`gen/shaders.zig`); run `zig build shaderc` after a change.

const dsl = @import("spirv").dsl;
const solid = @import("solid.zig");

pub const all = [_]dsl.Program{
    .{ .name = "solid_vert", .stage = .vertex, .build = solid.vertex },
    .{ .name = "solid_frag", .stage = .fragment, .build = solid.fragment },
};
