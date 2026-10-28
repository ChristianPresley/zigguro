//! Inline images (E06.F08): the image store and placements, and the
//! kitty graphics protocol.

pub const store = @import("graphics/store.zig");
pub const Store = store.Store;
pub const Image = store.Image;
pub const Pixels = store.Pixels;
pub const Placement = store.Placement;
pub const kitty = @import("graphics/kitty.zig");
pub const sixel = @import("graphics/sixel.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("graphics/kitty_test.zig");
    _ = @import("graphics/sixel_test.zig");
}
