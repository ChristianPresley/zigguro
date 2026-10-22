//! pNext chaining with a compile-time `structextends` check.

const vk = @import("vk.zig");

/// Prepends `ext` to the pNext chain of `base`. Both are pointers to
/// Vulkan structs; `ext`'s type must extend `base`'s (vk.xml
/// `structextends`), which is checked at compile time.
pub fn chain(base: anytype, ext: anytype) void {
    const Base = @typeInfo(@TypeOf(base)).pointer.child;
    const Ext = @typeInfo(@TypeOf(ext)).pointer.child;
    if (comptime !vk.structExtends(Ext, Base)) @compileError(@typeName(Ext) ++ " does not extend " ++ @typeName(Base));
    ext.p_next = @ptrCast(@constCast(base.p_next));
    base.p_next = @ptrCast(ext);
}
