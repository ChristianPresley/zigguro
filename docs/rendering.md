# Rendering contract (zg_vulkan.r2d)

zigguro draws every pixel through `zg_vulkan.r2d`: E04 builds a `DrawList`
each frame and hands it to a `Renderer`. The renderer is Vulkan when a usable
GPU exists and the software renderer otherwise; both execute the same list
with the same math (`packages/vulkan/src/r2d/shading.zig`), and the software
output is the golden reference. Nothing in `r2d` refers to Vulkan.

## Who calls what

| Caller | Calls | Thread |
|---|---|---|
| App (`apps/zigguro`) | `zg_vulkan.createRenderer(gpa, io, opts)` with the window's `SurfaceTarget`, size and `EnvOverrides.fromMap(init.environ_map)` | startup |
| E04 | `DrawList.reset`, the primitive calls, `addDamage`, then hands the list to the render thread | UI |
| Render thread | `Renderer.render(&list)`, `resize` on configure | render |
| E03 (via E02's atlas bridge) | `createTexture` / `updateTexture` / `destroyTexture` for atlas pages | render |

The UI thread never waits on a fence, swapchain or present. Two draw lists
are double-buffered between the UI and render threads.

## Units and colours

- `RectF`, `Vec2`, `Radii`, `Insets`, glyph destinations: **logical** pixels.
  The list multiplies by the `scale` passed to `reset`.
- `PxRect` (damage) and `Size` (extent, layer sizes): **physical** pixels.
- Pixel centres are at +0.5. A quad covers the pixels whose centres lie in
  `[x0, x1) × [y0, y1)`; shapes are anti-aliased by their signed distance
  (`coverage = clamp(0.5 - d, 0, 1)`), so integer-aligned rectangles have
  exact edges.
- `Color` is sRGB-encoded RGBA8 with straight alpha; the list premultiplies.
  Blending is source-over in sRGB-encoded space (ADR-E02-007).

## Primitives

`rect`, `border` (per-edge widths, inside the rect), `shadow` (Gaussian
`sigma`, `spread` grows the shape), `linearGradient` (two stops, points in
the same space as the rect), `glyphs`, `image` / `imageFiltered`, and
layers. Radii are clamped to half the shorter side. Prims are drawn in
append order; there is no reordering.

## Clips

`pushClip(rect, radii)` / `popClip`. Clips intersect with the enclosing clip.
A plain clip inside a rounded one keeps the rounded corners it shares with
it. Two different rounded clips nested are approximated by the inner one cut
to the outer bounds. Prims wholly outside their clip or the target are
dropped when appended.

## Damage

- `addDamage(PxRect)` marks changed window pixels (up to 64 rectangles, more
  means everything). `damageAll()` marks everything.
- A list with no damage renders nothing: no submit, no present, no wakeup.
- The renderer repaints everything by itself on the first frame, on resize,
  after device loss and when a list ran out of memory (`alloc_failed`).
- E04 must still emit every prim that intersects the damage (the renderer
  culls the rest); prims outside the damage cost only a bounds test.
- Presenting backends repaint the union of the damage since the target buffer
  was last shown (buffer age) and pass this frame's damage on as present
  hints.

## Layers

```zig
if (dl.beginLayer(id, size, content_damage)) {
    // draw content in layer-local physical coordinates
    dl.endLayer();
}
dl.drawLayer(id, dst, scroll_px, opacity);
```

`beginLayer` returns false when the renderer still holds the layer and
`content_damage` is empty; then skip the content (and `endLayer`). Set
`dl.layer_query = renderer.layerQuery()` so the list can ask. Layers do not
nest. A layer's repaint is cleared to transparent before its content is
drawn. Changing a layer's content does not damage the window by itself:
add window damage where the layer is shown. If the renderer no longer holds
a layer (`dl.layerCached` is false) it repaints all of it, so draw the whole
content then.

Scroll layers (E02.F06.S03.T01) are wraparound textures: content pixel
(x, y) lives at texel `((x + origin.x) mod w, (y + origin.y) mod h)`.
Content coordinates are local to the region the layer holds (the viewport
plus overscan). To scroll the content by d without redrawing it:

```zig
origin = zg_vulkan.r2d.layers.scrolledOrigin(origin, d, size);
const n = zg_vulkan.r2d.layers.scrollDamage(d, size, &strips); // exposed strips
if (dl.beginScrollLayer(id, size, origin, strips[0..n])) {
    // draw the content (at least the strips) in local coordinates
    dl.endLayer();
}
dl.drawLayer(id, dst, .{ .y = scroll_within_region }, 1);
```

Backends repaint each damaged rect as up to four wrapped pieces
(`layers.wrapRects`); pieces at an offset draw translated copies of the
layer's prims. The composite samples with wraparound (a repeat sampler on
the GPU), so integer and fractional offsets show no seam; the
`scroll_layer_seam` scene checks this against unlayered rendering (1 LSB
integer, 2 LSB fractional) on both backends.

Layers count `w × h × 4` bytes against `RendererOptions.layer_budget_bytes`
(default 64 MiB, E15 `render.layer_budget_mb`). After each frame's layer
passes, the least recently composited layers not used in that frame are
evicted; their next `beginLayer` returns true and repaints everything.
Layers are always transparent (repaints clear to 0).

## Text and the atlas contract (E03)

- E03 rasterises glyphs into atlas pages and emits
  `GlyphQuad{ dst (logical px), uv (normalised u0,v0,u1,v1), page, format }`.
- Each page is a renderer texture: `r8` pages are `TextureFormat.r8`;
  `rgb_subpixel` and `rgba_color` pages are `rgba8` (subpixel pages store
  per-channel coverage with A = max; colour pages are premultiplied).
- `DrawList.setGlyphPages(ids)` maps `page` to the texture id.
- Glyphs are sampled with nearest filtering: E03 positions them on whole
  pixels (subpixel positioning is baked into the rasterised glyph).
- `TextAa.subpixel_rgb`/`subpixel_bgr` use dual-source blending on
  `rgb_subpixel` pages; on other pages, or when the backend lacks dual-source
  blending, text falls back to grayscale (subpixel pages averaged).
- Coverage correction: `cov^mix(gamma, 1/gamma, luma)` then
  `cov + contrast·cov·(1-cov)` (`TextParams`, tuned by E03, exposed by E15).
- E03 only appends glyphs to a page and evicts whole pages, so an atlas rect
  updated this frame is never one an in-flight frame samples.

## Terminal grids (E06)

Cell backgrounds are plain `rect`s with zero radii; glyphs go through
`glyphs` like any other text.

## Software renderer

`zg_vulkan.sw.SwRenderer` bins prims into 64×64 tiles and shades 8 pixels at
a time on up to 8 workers. Output is identical for any thread count and on
every CPU. It renders to a headless sink, to an shm presenter (E01
`allocCpuBuffer` ring with buffer age) or to a `CpuImage` (`renderToImage`).

## GPU shaders and pipelines

The Vulkan backend shades every prim with the same math as the software
renderer (`r2d/shading.zig`, mirrored op for op in
`src/shaders/sdf.zig`). Blending happens in sRGB-encoded space with
premultiplied colour, so sampled textures and render targets use UNORM
views (sRGB images get a UNORM view), and r8 glyph pages swizzle `r`
into every channel.

The frozen interface (`src/shaders/interface.zig`, guarded by
`shaders.interface_hash`):

| what | value |
|---|---|
| set 0, binding 0 | `readonly buffer Prims { Prim items[]; }` (64 B each, `PrimGpu` view) |
| set 0, binding 1 | `readonly buffer Clips { ClipGpu items[]; }` (bounds + radii, 32 B) |
| set 0, binding 2 | `sampler2D textures[]`: partially bound, update-after-bind, non-uniform index |
| push constants (32 B) | `viewport_px, inv_viewport, clip_base, text_gamma, text_contrast, flags` |
| composite push constants | `offset, size, slot, opacity, _, flags` (bit 0 = wrap) |

A texture id is its descriptor slot; slot 0 is "none". Prims are drawn
as instanced 4-vertex triangle strips: `firstInstance` is the index of
the first prim of a run in the prim buffer, and `clip_base` is the index
of the frame's clip 0 in the clip buffer. Pipelines: `prim` (every kind),
`text_subpixel` (dual-source blending, subpixel glyphs only; without
`dualSrcBlend` they draw through `prim` with averaged coverage) and
`composite` (full-screen triangle sampling a layer with wrap). All blend
`ONE, ONE_MINUS_SRC_ALPHA`; `text_subpixel` uses `ONE,
ONE_MINUS_SRC1_COLOR` for colour.

The pipeline cache persists at `<cache dir>/pipelines-<vendor>-<device>.bin`
behind a checked header (magic, version, payload hash, shader identity)
and the Vulkan header; any mismatch gives an empty cache.

`zig build test-vulkan-gpu` renders every scene
of the corpus through these pipelines on lavapipe and compares it with
the software goldens (`Tolerance.gpu`; observed max channel difference
2).

## Vulkan backend

`zg_vulkan.VkRenderer` implements `Renderer` on Vulkan. Each frame:
1. Wait for the frame slot.
2. Compute the repaint region (image age plus damage, at most 16 rects).
3. Copy prims and clips into the upload ring, and record pending texture uploads.
4. Run one dynamic-rendering pass per layer redrawn this frame, one scissored piece per wrapped damage rect, then a sync2 barrier makes the layer shader-readable.
5. Run one dynamic-rendering pass on the target. Each repaint rect is cleared to transparent, scissored, and drawn with the batches culled to it. Layer composites sample the layer's descriptor slot.
6. Copy the repainted rects out through the target.

Timestamps bracket the frame, uploads, layer passes and window pass
(`GpuTimer`, one query pool of 8 queries per frame slot). They are read
without waiting when the slot is reused, so `FrameStats.gpu_ns` trails by up to
frames_in_flight frames. Zone durations are also recorded as `zg_core.trace`
counters (`gpu.frame_ns`, `gpu.uploads_ns`, `gpu.layers_ns`, `gpu.main_ns`).
On Linux devices with calibrated timestamps, `gpu_start_ns` places the frame
on the CPU monotonic clock.

With no window damage and no layer redrawn, nothing is submitted. Targets
today are headless and in-memory readback. The whole scene corpus,
multi-frame damage and layer scenes included, matches the software goldens
on lavapipe (`zig build test-vulkan-gpu`, CI job `vulkan`).

## Render thread and pacing

`zg_vulkan.present.RenderThread.spawn(gpa, io, renderer, .{ .pacing, .refresh_ns, .notify })`
takes ownership of a `Renderer`. The UI thread fills `firstList()`, then
calls `post(list)`, which returns the list to fill next and never blocks. If the
render thread has not taken the previous post yet, that post is dropped
(latest wins). Its window damage is merged into the new list. The layers it
drew stop counting as cached, so the UI is woken (`notify`) to repaint them in
full. Lists answer `beginLayer` from the thread's own cache table. Forward
platform frame callbacks and configures with `onPlatformFrame`.

`FramePacer` picks the start of each frame:
- `present_wait2` / `present_wait` hold at most `max_queued` (1) frames in the queue.
- `platform_frame` waits for E01's frame callback after a presented frame.
- `timer` starts at most one frame per refresh interval.
- `immediate` is for headless targets.

With nothing posted, the thread sleeps on one event, so idle costs no wakeups.

## Golden images

`zg_vulkan.testing.expectImage(io, @src(), name, &img, tolerance)` compares
with `<package>/testdata/golden/<file stem>/<name>.png` and writes
`name.actual.png` and `name.diff.png` on failure; `-Dupdate-golden`
rewrites goldens (software output only). The scene corpus
(`src/testing/scenes.zig`, 32 scenes) runs in `zig build test-vulkan` and
`zig build test-golden`.
