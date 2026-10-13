# Emerge issues

Problems and gaps we hit while building the watch UI on Emerge 0.4.2. The
watch uses the headless raster backend (see UI.md). Each issue says how we
confirmed it and what hello_watch does about it.

## Clipping

### 1. A transformed element's nearby layers escape a rounded parent's clip

A rounded element clips its children to its rounded shape, and with
`clip_nearby()` it clips nearby layers too. But if any element between the
clipping parent and the layer's host is moved by a paint transform
(`Transform.move_x/y`, `Transform.rotate`), the host's nearby layers are
not clipped at all, not even to the parent's rectangle.

Confirmed with a headless probe: a 200x200 parent with `Border.rounded(100)`
and `clip_nearby()`, holding a child whose `Nearby.in_front` layer is a
full-size red box.

| Child | Red outside the circle? |
|---|---|
| `el([], host)` | no (clipped) |
| `el([Transform.move_x(-50)], host)` | yes, even past the parent's box |
| host with its own `clip_nearby()` | no |
| `el([Transform.move_x(-50)], host)`, host with `clip_nearby()` | yes |
| the layer itself has `Transform.move_x` | no |
| `el([padding_each(...)], host)` | no |

**Where it hit us:** pages slide in clipped to an arc, and a copy of the page
underneath is clipped to the arc too (see "Concave shapes" below). Any face
element positioned with a transform that hosted layers (hand tips, moon
discs, sparkles) showed through on the wrong side of the arc.

**Workaround:** inside pages, position elements with padding instead of
transforms, and never give a transformed element nearby layers. Hands are a
rotated column of tip and bar, and sparkles are an SVG
(`priv/images/sparkle.svg`) rather than layered bars.

### 2. Shadows and glows aren't clipped by a rounded parent

`Border.glow/2`, and presumably `Border.shadow/1`, on an element inside a
rounded, `clip_nearby()` parent paints outside the parent. This happens
whether the element is a plain child or a nearby layer.

Confirmed with a probe: a 40x40 box with `Border.glow(red, 60)` inside a
200x200 `Border.rounded(100)` parent shows red at the parent's corner, and
to the right of the parent.

The docs say outer shadows bleed past parent padding and are clipped only by
scroll containers. So this may be intended, but it makes a rounded clip
unreliable for anything with a glow.

**Workaround:** inside pages, a glow is a translucent disc behind the element
(`halo/3` in `HelloWatch.Clock.Face`). `Border.glow` stays only on the
top-level sliding shapes, which aren't clipped by anything.

### 3. No concave shapes, clip paths or masks

`Border.rounded/1` and `rounded_each/4` only make convex corners. There's no
way to clip content to a concave edge, an arbitrary path or a mask.

**Workaround:** a page sliding in from the right needs a hollow leading edge.
It comes in as a plain slab, and the page underneath is drawn again on top,
clipped to a convex arc that ends where the hollow edge should be. That
page doesn't move, so the copy is indistinguishable from it. The cost is
rendering the page underneath twice per frame. A clip path, or an inverted
rounded clip, would avoid it.

## Headless output

### 4. No BGRA or XRGB pixel format

Headless binary mode offers `:rgba8888`, `:rgb888`, `:gray8`, `:gray2` and
`:bw1`. Linux framebuffers, including this watch's (msm fbdev emulation,
XRGB8888), usually want B, G, R, X in memory. Converting each 454x454 frame
in Elixir cost about 55 ms of CPU on the watch, more than rendering it.

**Workaround:** draw everything with red and blue swapped
(`HelloWatch.Clock.Palette`). The RGBA bytes then already read as B, G, R,
X, and a frame goes to `/dev/fb0` as row copies. This is exact, because
antialiasing and gradients blend each channel independently. But every
colour, including SVG tints, has to go through the palette, and raster
images would need swapping too. A `:bgra8888` or `:xrgb8888` format would
remove the trick.

### 5. The first frames can come before custom fonts load

With `assets: [fonts: ...]`, the first headless frame, and
`EmergeSkia.render_to_png/2` called right after it, can be blank. We saw
all-black and all-white frames. A correct frame follows once the fonts have
loaded.

**Workaround:** tests and preview scripts wait about 500 ms and use the
latest frame. On the watch, the display just shows the next frame.

### 6. Finished enter animations snap back to the base attributes

After an `Animation.animate_enter/4` ends, the element is drawn with its
plain attributes again, not the last keyframe. A disc animated from
`move_x(0)` to `move_x(-454)`, without a base `move_x`, jumped back to
`move_x(0)` when the animation finished.

This may be by design, but the docs don't say so. It's easy to miss, because
it shows as a single stray frame.

**Workaround:** always set the final keyframe's values as plain attributes as
well (`slide_x/2` and `hollow_x/2` in `HelloWatch.Clock`).

### 7. Gradient stops lose their alpha

`Emerge.UI.Color.gradient/2` accepts `color_rgba` stops, but in headless
rendering on the host the per-stop alpha didn't come through. A mist from
`abyss` at 0.9 down to `abyss` at 0 drew as a nearly opaque band with hard
ends.

**Workaround:** draw fades as SVG linear gradients with `stop-opacity`, and
colour them with `Svg.color/1`, which keeps alpha
(`priv/images/mist-sky.svg`).

### 8. An element first drawn at a tiny scale is never drawn again (main)

With Emerge built from main (our `feat/drm-animation-pacing` branch), an
element mounted at `Transform.scale(0.001)` stayed invisible as its scale
was raised to 1, in both headless and DRM rendering. At 0.01 it draws
normally. Emerge 0.4.2 drew it.

**Workaround:** the closed inventory is scaled to 0.01, not 0.001, and hidden
with `Transform.alpha(0)`. A test checks the open inventory is drawn.

## Performance on the watch

These were measured on the GPU system with the DRM/OpenGL backend and
`stats: true`, using synthetic drags sent to the clock.

- **One core does it all.** The tree patch, layout and Skia draw run on one
  thread, a dirty I/O scheduler. During a drag it's pinned (about 1.3 CPU
  seconds a second), while the GPU takes about 3 ms a frame and the other
  three cores idle. A sky drag reached 20–27 frames a second: about 16 ms to
  patch the tree and 12–15 ms to draw, per update.
- **A new key rebuilds the subtree.** A settle that remounted the sky and the
  app under fresh keys (to restart `animate_enter`) took 80–86 ms to patch,
  and the settle showed only 5 frames. `Animation.change/3` on retained,
  stably keyed elements avoids the remount: the pulls use it now (`eased/2`
  in `HelloWatch.Clock`).

## Smaller things

- **`min`/`max` clash:** `use Emerge.UI` imports size helpers named `min/2`
  and `max/2`, so a plain `max(a, b)` on numbers fails or warns inside UI
  modules. We write `Kernel.max/2`.
- **No custom pixel layout:** there's no way to say "B, G, R, X with this
  stride"; see 4.

## Found while reading the source (not hit in use)

From the DRM backend research in UI.md:

- **`present` ignored on DRM:** the raster `present` option is ignored on the
  DRM backend (`_requested_raster_present`,
  `native/emerge_skia/src/backend/drm/gl.rs`).
- **No DPMS API:** 0.4.2 has no API to blank or power down the display. On
  the DRM backend Emerge owns the display, so an app can't blank it some
  other way, as hello_watch does with `/dev/fb0` today. Upstream is now
  implementing blanking and display control for DRM.
- **Hotplug polling:** the DRM render loop checks for a display change every
  750 ms, on a timer rather than on the kernel's hotplug events. See
  `hotplug_interval` (`native/emerge_skia/src/backend/drm/gl.rs:2613`, used
  at `:3553`, and in the loop's wait deadline at `:4026`) and
  `HOTPLUG_INTERVAL` (`backend/drm/vulkan.rs:70`).
  - The check is cheap: `get_connector(..., false)` doesn't force a probe
    (`backend/drm/core.rs:422`, `:440`).
  - It still wakes the render thread every 750 ms while the screen is on,
    even with nothing to draw. For a built-in panel that can't be unplugged
    the check does nothing.
  - Reacting to the kernel's hotplug events, or a configurable or optional
    interval, would remove the wakeup.
