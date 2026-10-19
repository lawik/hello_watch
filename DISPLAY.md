# Display: DRM on the watch and driving it from Emerge

What we know about the display stack on the TicWatch Pro 3, and how
`hello_watch` renders with [Emerge](https://hexdocs.pm/emerge) 0.4.2. Option B
below is what the app now uses. Power-related display findings are in
[POWER-MANAGEMENT.md](POWER-MANAGEMENT.md).

Sources:

- The watch `nerves-0453` (system v0.2.0, kernel 7.1.3), read-only, on
  2026-10-12.
- The system's kernel config and patches in `../system/ticwatch_pro3`.
- Emerge 0.4.2's Elixir and Rust sources, fetched into `deps/emerge`.
- [lawik/nerves_phone](https://github.com/lawik/nerves_phone), which runs
  Emerge on a Fairphone 3.

## Summary

- **The kernel side is ready.** The MSM DRM/KMS driver owns the panel
  (`/dev/dri/card1`, connector `DSI-1`, 454×454) with a native panel driver.
  The display pipeline powers down when the screen is off.
- **The userspace side isn't.** The system ships no `libgbm`, `libEGL`,
  GLES or Mesa. Emerge's DRM backend always presents through EGL on a GBM
  surface, so it can't run on the current system at all.
- There are two ways forward:
  - **A. Add Mesa to the system** (GBM + EGL + freedreno for the Adreno 504)
    and use Emerge's DRM backend. Emerge then owns the screen, touch input,
    gestures and page flips.
  - **B. No system change.** Use Emerge headless with the raster renderer.
    It sends RGB888 frames to our process, which writes them to `/dev/fb0` as
    `Display` does today. The catch is input: a headless viewport has no
    public way to feed it touches, so Emerge's buttons and swipe events
    wouldn't fire. We'd keep our own touch, swipe and button handling.
- B works today; A is the "real" Emerge integration but needs a system build
  and has open questions about power and the GPU.

## The display stack on the watch

| | |
|---|---|
| SoC / GPU | SDM429W, Adreno 504 (`oxili` power domains, off at idle) |
| Kernel DRM | `msm` module (DPU/MDP5 + DSI with the 12 nm PHY), loaded by `nerves_uevent` after boot; SimpleDRM shows the bootloader's framebuffer until then |
| Panel | `panel-mobvoi-rover` (RM69330 or ICNA3310 AMOLED), **DSI command mode**, TE pin wired, one mode: 454×454 at 60 |
| Nodes | `/dev/dri/card1`, `/dev/dri/renderD128`, no `card0` (the index is taken by SimpleDRM before msm replaces it) |
| fbdev | `msm` fbdev emulation on `/dev/fb0` (`msmdrmfb`), XRGB8888, pitch 1920, owned by fbcon, plane 0 / `sspp_8` |
| Backlight | `/sys/class/backlight/1a94000.dsi.0`, 0–255, sent to the panel as a DCS brightness command |
| Touch | `Zinitix Capacitive TouchScreen`, evdev multitouch (`input2`) |
| Buttons | `pm8941_pwrkey` (`input0`), `gpio-keys` (`input1`, one key labelled "Volume Up") |
| Haptics | `gpio-vibrator` (`input3`, force-feedback) |
| Userspace libs | `libudev` only: no libdrm, libgbm, libEGL, GLES, Mesa, libinput, xkbcommon, fontconfig |

What that means for rendering:

- **Command mode** means the panel keeps its own frame memory. A frame goes
  over DSI only when something is committed, and a static screen costs no
  transfers. There's no VRR to drive, and an app's "frame rate" is how
  often it commits.
- **No partial updates.** Upstream MSM sends the full 454×454 frame on every
  commit, so fewer commits matter more than smaller damage rectangles.
- **Off is off.** Blanking (`/sys/class/graphics/fb0/blank` = 4) gives DPMS
  Off, and MDSS, the display controller and DSI are runtime-suspended.
- **Display node path.** Point anything that opens DRM at `/dev/dri/card1`
  (or a `/dev/dri/by-path/` alias). Emerge defaults to `card0`, which doesn't
  exist here.

## How hello_watch draws

`HelloWatch.Clock` is an Emerge viewport (option B below):

- **Rendering.** The viewport renders headless with the raster renderer
  (`config :emerge, compiled_backends: []` on the target) and sends packed
  RGB888 frames to `HelloWatch.Clock.Display`. It rerenders only when the
  screen changes: every second on the face, every 5 s on the network page,
  and as readings arrive on the sensor page. It never rerenders with the
  screen off.
- **Display.** `Display` writes each new frame to `/dev/fb0`, swapping to
  the framebuffer's B, G, R byte order and padding rows to its stride, and
  skips frames identical to the last one.
  - Screen off fades the backlight to 0 in 10 steps, then blanks.
  - Wake waits for the next frame before unblanking, so the old frame never
    flashes, then fades back up.
- **Input.** `Clock.Touch` and `Clock.Button` read evdev and send `:touch`,
  `{:swipe, dir}` and `:toggle_display` to the viewport. The root element
  also has Emerge's `on_swipe_left/right`, for a windowed run on a host.
- **Release.** `mix.exs` keeps only the aarch64 raster NIF; the others are
  15-25 MB each.

Measured on nerves-0453 (2026-10-12):

| | |
|---|---|
| Pixels on `/dev/fb0` | correct (accent centre, black corners, white 12 o'clock tick) |
| BEAM CPU, face on, 1 frame/s | 555 ms per 10 s, about 55 ms per frame (render + convert + write) |
| BEAM CPU, screen off | 6 ms per 5 s |
| Screen off | blank 4, brightness 0, DPMS Off |
| Wake | blank 0, brightness 255, DPMS On |

The conversion to B, G, R in Elixir is likely a large share of those 55 ms
(not yet profiled). Dropping the second hand when nobody is looking would
cut the frames 60×.

## Option A: Emerge's DRM backend

This is the nerves_phone setup:

```elixir
config :emerge, compiled_backends: [drm: [:opengl]]
# viewport options
backend: :drm, drm_card: "/dev/dri/card1", hw_cursor: false
```

### What the NIF needs

The prebuilt `libemerge_skia-v0.4.2-nif-2.15-aarch64-unknown-linux-gnu--drm.so`
was downloaded by `mix deps.get`. Its `NEEDED` list is:

```
libgbm.so.1  libstdc++.so.6  libgcc_s.so.1  libm.so.6  libc.so.6  ld-linux-aarch64.so.1
```

`libEGL.so.1` (and through it GLES) is loaded with `dlopen` at runtime.
`libstdc++` is in the system; **`libgbm` and `libEGL` aren't,** so today the
NIF wouldn't even load on the watch. KMS (the `drm` crate does its own
ioctls) and evdev input (the `evdev` crate) need no extra libraries. Fonts
come from registered assets, so there's no fontconfig dependency.

### Raster on DRM still needs EGL

The viewport docs list `rendering_api: [raster: [present: :cpu]]` for DRM,
and nerves_phone uses it with a comment saying it renders "into a KMS dumb
buffer". In 0.4.2's source, though, the DRM presenter reads the option and
drops it: `let _requested_raster_present = config.raster_present;`
(`native/emerge_skia/src/backend/drm/gl.rs:2608`). Every DRM frame is
presented through EGL on a GBM surface with `eglSwapBuffers`. With
`:raster`, Skia draws on the CPU and the result is uploaded as a GL texture.
So even CPU rendering needs a working EGL/GBM stack on the watch.

The system would need Buildroot's `mesa3d` with GBM, EGL and GLES2, and one
of:

- the **freedreno** Gallium driver: real GPU, Adreno 504 is a5xx and supported
  by freedreno. nerves_phone saw Emerge's OpenGL path on the Adreno 506 spin
  a core at 100% and wedge its render thread. That was the same driver
  family, which is a warning sign, though the cause wasn't pinned down.
- **kmsro + a software rasteriser** (softpipe/llvmpipe) presenting to the
  msm display. This avoids the GPU but adds a software GL copy for every
  frame. **Unverified** that it works with msm's display-only path.

Either way it means a new system release and a bigger rootfs.

### What Option A gets us

- **Input built in.** The DRM backend reads evdev directly. A multitouch
  screen with `ABS_MT_POSITION_*` and `BTN_TOUCH` is treated as direct touch:
  one pointer, with presses taken from `BTN_TOUCH`. Emerge's
  `Event.on_press`, `Event.on_swipe_left/right/up/down`, scrolling and
  sliders would all work. **Unverified** that the Zinitix axes map 1:1 to the
  454×454 panel without a calibration step.
- **Real page flips** with TE and vsync pacing. Unchanged scenes aren't
  redrawn.
- **The same app on the host,** in a Wayland window.

### Open problems with Option A

- **Screen off.** Emerge has no DPMS or "display off" API: the only CRTC
  `ACTIVE` handling in the DRM backend is a probe and restore. While Emerge
  holds DRM master, our current `/dev/fb0` blanking goes through the fbdev
  emulation and won't control the CRTC. The backlight's `bl_power` = 4 only
  sets panel brightness to 0, which leaves MDSS and DSI powered. Real
  screen-off would need one of these:
  - stopping the viewport, so it releases master, then blanking;
  - an Emerge feature that sets `ACTIVE` = 0;
  - accepting a dark but powered pipeline.

  This needs a test.
- **Idle wakeups.** The DRM render loop rechecks connectors every 750 ms
  (`hotplug_interval`, `gl.rs:2613`), even when nothing changes. That's about
  1.3 wakeups/s for a watch that otherwise sleeps. It's small, but it's
  periodic, and it would also need handling around suspend.
- **Buttons aren't UI input.** Emerge reads the keyboard-like devices too,
  but the power key and side button belong to our own handler, as nerves_phone
  does with `input_event` alongside Emerge. evdev hands every event to every
  reader, so both can read the same device.
- **The touch that wakes the screen** shouldn't press anything. nerves_phone
  puts a full-screen catcher in front while the screen is off; the same
  applies here.
- **Device node:** set `drm_card: "/dev/dri/card1"`.

## Option B: Emerge headless raster, our own presenter

```elixir
config :emerge, compiled_backends: []   # minimal raster artifact, no GPU/desktop deps
# viewport options
backend: :headless, rendering_api: :raster, width: 454, height: 454,
headless: [mode: :binary, target: frame_sink_pid, pixel_format: :rgb888]
```

- **The NIF** is the "minimal raster" artifact (the NameBadge profile):
  Skia on the CPU, embedded FreeType, SVG and images, no EGL/GBM/Wayland.
  Built for `aarch64-unknown-linux-gnu`. It only needs libstdc++ and glibc,
  which the system has. (Inferred from the build docs and Cargo features;
  that artifact hasn't been downloaded and checked yet.)
- **Frames** arrive as `{:emerge_skia_frame, %VideoInterop.Frame{}}` with
  packed RGB888 (`stride = 454 * 3`), only when the viewport rerenders.
  Without `target_fps` there's no frame cadence, which is exactly what a
  command-mode panel wants. The sink converts to XRGB8888 with the 1920-byte
  pitch and `pwrite`s to `/dev/fb0`, which is today's `Display.encode/3`.
  Skipping frames identical to the last one is cheap.
- **Screen off and on** keeps working as today (fbdev `blank`), and the MDSS
  and DSI power down.
- **Input is the cost.** Headless viewports have no input source, and Emerge
  has no public API to inject pointer events: `EmergeSkia.TestHarness` is
  private (`@moduledoc false`) and only moves the cursor. So:
  - `Event.on_press` and `on_swipe_*` won't fire on the watch.
  - Our `Touch` and `Button` processes keep detecting taps and swipes and
    send plain messages to the viewport (`handle_info/2` →
    `Viewport.rerender/1`).
  - The UI is laid out with Emerge, but hit-testing is ours. For a watch with
    a few full-screen pages and swipes, that's manageable; for buttons or
    lists, it isn't.
- **Host development:** the same viewport can run on the host with
  `backend: :wayland` and real input, or headless in tests, where frames can
  be checked with `EmergeSkia.render_to_png/2`.
- **Costs:** an extra copy and conversion per frame in Elixir (454×454×4 ≈
  824 KB). That's fine at a few frames per second and a minute-resolution
  face, but it rules out smooth animation.

## Comparison

| | A: DRM backend | B: headless raster → fbdev |
|---|---|---|
| System change | Mesa (GBM, EGL, GLES, driver) | none |
| Works today | no | yes (pending a test) |
| Touch, gestures, buttons in UI | Emerge | ours, via messages |
| Rendering | GPU or CPU + GL upload | CPU |
| Presentation | KMS page flip, vsync/TE | fbdev write → driver damage flush |
| Screen off | open question (no DPMS API; master held) | fbdev `blank`, as today |
| Idle wakeups from UI stack | 750 ms hotplug poll | none |
| Animation | yes | not really |
| Risk | freedreno/Emerge GL hang seen on FP3 | input reimplemented |

## Recommendation

**Start with B.** It needs no system release, keeps the power behaviour we
already measured, and moves drawing (faces, the power meter, text) to Emerge,
which is most of the benefit. Keep the existing touch, swipe and button code
and route it into the viewport as messages.

**Revisit A** if the UI grows real widgets (lists, buttons, scrolling), or
Emerge gains one of:

- a CPU or dumb-buffer DRM presenter that doesn't need EGL;
- a display-power API;
- an input-injection API for headless viewports.

Any of these would remove the main obstacles; worth asking upstream.

## To verify on the watch

Done: the raster NIF loads on the system (it links only libstdc++, libgcc_s
and glibc); a 454×454 frame through `Display` keeps up with a 1 Hz face.

Still open:

1. Touch, swipes and the button on the new UI, by hand.
2. For option A only, after adding Mesa:
   - Can Emerge's DRM backend take master on `card1` while fbcon owns the
     plane?
   - Do the touch coordinates line up?
   - What happens to MDSS and DSI power when the screen "turns off"?
