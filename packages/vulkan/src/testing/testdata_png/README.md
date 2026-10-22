# PNG decoder reference files

Tiny PNGs decoded by `png: decode reference files` in `../png.zig`. They were
written by a throwaway Python 3 script using the standard `zlib` module (not
by our encoder), so the decoder is checked against an independent writer.
Each row's filter type was chosen by hand:

| File | Format | Filters | Notes |
|---|---|---|---|
| `gray_3x2.png` | gray 8 | none, up | values 0,50,100 / 150,200,250 |
| `rgb_4x4_filters.png` | RGB 8 | sub, up, average, paeth (one per row) | r = 10+10x+40y, g = r+10, b = r+20 |
| `rgba_5x3_paeth.png` | RGBA 8 | paeth on every row | last pixel 40,80,120,128 |
| `rgba_stored_2x2.png` | RGBA 8 | none | zlib level 0 (stored blocks) |
| `rgba_deflate_16x16.png` | RGBA 8 | sub | gradient r = 16x, g = 16y, zlib level 9 |
