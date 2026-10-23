//! Images (E04.F06.S02): decoders for PNG (E03), JPEG, GIF and BMP behind
//! one façade, all producing premultiplied sRGB RGBA8, a linear-light
//! downscaler, the image cache with its GPU textures, and the image view.

pub const image = @import("image.zig");
pub const decode_mod = @import("decode.zig");
pub const gif = @import("gif.zig");
pub const bmp = @import("bmp.zig");
pub const lzw = @import("lzw.zig");
pub const jpeg = @import("jpeg.zig");
pub const downscale_mod = @import("downscale.zig");
pub const textures = @import("textures.zig");
pub const anim_player = @import("anim_player.zig");
pub const cache = @import("cache.zig");
pub const view = @import("view.zig");

pub const Image = image.Image;
pub const Frame = image.Frame;
pub const Format = image.Format;
pub const Limits = image.Limits;
pub const DecodeError = image.DecodeError;
pub const sniff = decode_mod.sniff;
pub const decode = decode_mod.decode;
pub const decodeScaled = decode_mod.decodeScaled;
pub const downscale = downscale_mod.downscale;
pub const ImageCache = cache.ImageCache;
pub const Handle = cache.Handle;
pub const Source = cache.Source;
pub const ImageTextures = textures.ImageTextures;
pub const ImageView = view.ImageView;
pub const ImageViewProps = view.ImageViewProps;
pub const ImageViewState = view.ImageViewState;
pub const imageView = view.imageView;

test {
    _ = image;
    _ = decode_mod;
    _ = gif;
    _ = bmp;
    _ = lzw;
    _ = jpeg;
    _ = downscale_mod;
    _ = textures;
    _ = anim_player;
    _ = cache;
    _ = view;
    _ = @import("view_test.zig");
    _ = @import("jpeg_test.zig");
    _ = @import("gif_test.zig");
    _ = @import("bmp_test.zig");
}
