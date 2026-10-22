//! Every shader program tools/shaderc compiles (E02.F05). Adding an entry
//! adds a declaration of the same name to the generated `shaders` module
//! (`gen/shaders.zig`); run `zig build shaderc` after a change.

const dsl = @import("spirv").dsl;
const solid = @import("solid.zig");
const prim = @import("prim.zig");
const text_subpixel = @import("text_subpixel.zig");
const composite = @import("composite.zig");

/// The descriptor and push-constant interface the programs are built
/// against; shaderc records `interface.hash()` as `interface_hash`.
pub const interface = @import("interface.zig");

pub const all = [_]dsl.Program{
    .{ .name = "solid_vert", .stage = .vertex, .build = solid.vertex },
    .{ .name = "solid_frag", .stage = .fragment, .build = solid.fragment },
    .{ .name = "prim_vert", .stage = .vertex, .build = prim.vertex },
    .{ .name = "prim_frag", .stage = .fragment, .build = prim.fragment },
    .{ .name = "text_subpixel_frag", .stage = .fragment, .build = text_subpixel.fragment },
    .{ .name = "composite_vert", .stage = .vertex, .build = composite.vertex },
    .{ .name = "composite_frag", .stage = .fragment, .build = composite.fragment },
};
