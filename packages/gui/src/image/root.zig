//! Images (E04.F06.S02): decoders for PNG (E03), JPEG, GIF and BMP behind
//! one façade, all producing premultiplied sRGB RGBA8, and a linear-light
//! downscaler.

pub const image = @import("image.zig");
pub const decode_mod = @import("decode.zig");
pub const gif = @import("gif.zig");
pub const bmp = @import("bmp.zig");
pub const lzw = @import("lzw.zig");
pub const jpeg = @import("jpeg.zig");
pub const downscale_mod = @import("downscale.zig");

pub const Image = image.Image;
pub const Frame = image.Frame;
pub const Format = image.Format;
pub const Limits = image.Limits;
pub const DecodeError = image.DecodeError;
pub const sniff = decode_mod.sniff;
pub const decode = decode_mod.decode;
pub const decodeScaled = decode_mod.decodeScaled;
pub const downscale = downscale_mod.downscale;

test {
    _ = image;
    _ = decode_mod;
    _ = gif;
    _ = bmp;
    _ = lzw;
    _ = jpeg;
    _ = downscale_mod;
    _ = @import("jpeg_test.zig");
    _ = @import("gif_test.zig");
    _ = @import("bmp_test.zig");
}
