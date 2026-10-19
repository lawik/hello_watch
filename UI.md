# UI: what the watch should feel like, and why

This describes the design of hello_watch's interface, for anyone porting it to
another framework or device. It records what the owner asked for, what they
turned down, and the details that make it work on a 454×454 round AMOLED. The
display stack and Emerge backends are covered in [DISPLAY.md](DISPLAY.md),
Emerge's quirks in [EMERGE-ISSUES.md](EMERGE-ISSUES.md), and power in
[POWER-MANAGEMENT.md](POWER-MANAGEMENT.md).

Quotes are the owner's own words from the design sessions (2026-10-12 to
2026-10-15). Treat them as requirements. The numbers are what the code uses
now, and were tuned on the watch; keep them unless the new device is
different.

## The spirit

> Make the colors and any decorations quirky and delightful. Find a more
> humane font. Make it way more witchy.

Followed straight away by the correction that sets the limit:

> The weird names for the screens are over the top. The information doesn't
> have to be wrong.. […] Brewing is also over the top. I kind of like Moon's
> day so I'll allow it.

So the rule is **witchy in its look, plain in its words.** The ornaments are
moons, sparkles, stars, a potion flask and clouds of night sky. Every title,
label and status is ordinary English: "Battery", "Network", "Charging", "On
battery", "Low". The one licensed exception is the face's old day names
("Moon's day · 16", "Tiw's day", "Woden's day", …). Don't bring back invented
screen names (an earlier draft had "Ley Lines", "The Coven" and a "Brewing"
charge status) or fanciful wording for data.

Second rule: **flat, not shiny.**

> the glow or edge gradient is a bit tacky, drop that, flat is fine.

No glows on edges, no bevels, no outer shadows. Soft light only comes from
big, mild gradients (the clouds) and from flat translucent halo discs behind a
few ornaments.

## The places: sky above, inventory below, apps between

> I want a new UI paradigm piece that is on every view. […] swipe down and
> that will shift our view upwards and show stars that is where control
> things like wifi, bluetooth, tailscale, etc. They are the global constants.
> […] Pulling up instead should expand a circular dark section, as if we are
> looking into our own inventory. This would be our apps, utilities, things
> we use the watch for.
>
> So the sky has the constellations, necessary things, constant things which
> consult now and then. The inward looking menu has our things. What we
> choose to use.

This is the core metaphor, and it should survive any port:

- **Apps** are what's on screen: the face, alarms, timers, stopwatch, battery,
  network, sensors, moon, Tailscale.
- **The sky** (drag down from anywhere): system switches, drawn as
  constellations. Outward and constant.
- **The inventory** (drag up from anywhere): the apps, as tokens in a dark
  circle. Inward and personal.
- **Sideways drags** move through recently used apps.

There are no other navigation devices: no back button, page dots, menus or
tab bars.

## Moving between apps

> not interlocking, the one you pull in is pulled in on top, covering the old
> previous one which is removed when the transition is done. regardless of
> direction we pull in on top. So the UI you were on does not move. Only the
> new screen moves in and not really immediately

> Each screen transition should be a swipe and to make the roundness more
> interesting the incoming screen should swipe in with a rounded edge. The
> color of the new screen concave. Take inspiration from phases of the moon.

The rules (all in `HelloWatch.Clock`):

- **Cover, don't push.** The current app never moves. The incoming one slides
  over it from either side and covers it, like the moon's shadow sweeping
  across. The old app is dropped once it's covered.
- **The leading edge is an arc.** From the right it's concave, a gentle arc of
  radius 400 (`@arc`). From the left it's convex, radius 240 (`@convex_arc`),
  close to the panel's own curve.
- **"Not really immediately."** The first 30 px of a drag do nothing (`@dead`),
  then the incoming app catches up at 1.15× the finger (`@catch_up`). A drag
  must not twitch the screen.
- **It follows the finger** while dragging, with no animation.
- **Letting go past halfway switches.** That's 227 px (`@commit_px`). Short of
  it, the app slides back out.
- **The settle eases out.** It takes 520 ms for a full panel width
  (`@transition_ms`), scaled to the distance left, and never less than 120 ms.
- **Recents order.** Dragging right goes back to older apps, left forward to
  newer ones. Opening an app from the inventory puts it first. At either end
  of the list a drag does nothing.

Two later refinements, both important:

> the convex and concave parts of each app are still single-color while the
> gradients mismatch that. They should be part of the gradiented shape.

Each view's backdrop is wider than the panel (170 px past each side,
`Backdrop`'s `@reach`), and the sliding shape clips it. So the bulge of a
convex edge shows the same gradient and clouds as the rest of that view, and
not a flat fill.

> if emerge allows it we could also have the edges as we are swiping be
> transparently gradient cloudy stuff instead of the hard convex/concave bit

A band of soft cloud puffs rides each leading edge, over the seam
(`priv/images/edge-convex.svg` and `edge-concave.svg`). It's tinted with the
incoming view's first cloud colour at 55% alpha.

The owner signed this off: "I like the side-to-side transitions now."

## The sky (drag down)

- **The sky drops in from above.** It covers 454 px of travel. The app below
  doesn't simply get pushed down:

  > When pulling the sky down the current screen can shift down a bit but it
  > should be more of a parallax. or it could even be re-angled as we are
  > shifting our perspective up

  The app follows at 0.3 of the sky's movement (`@sky_parallax`) and shrinks
  by up to 12% (`@sky_recede`), as if the view tips up from the ground to the
  stars. The "re-angled" perspective idea hasn't been tried.
- **A soft lower edge.** "The sky transition also needs to be a soft gradient
  of some kind." The sky's bottom edge is a mist of its darkest blue that
  fades into the sky and over the app below, with a line of blue cloud along
  the edge (`mist-sky.svg`, `edge-sky.svg`). It's never a hard line.
- **Constellations, no labels.** There's one per switch: Wi-Fi, Bluetooth,
  Tailscale, NervesHub, in a 2×2 grid. Each is drawn in the shape of its icon,
  with lines, a glow behind the stars, and the stars:

  > we could make glowing constellation-looking icons for wifi and bluetooth,
  > tailscale's logo translates into stars pretty well too.

  > the constellation for nerveshub […] doesn't relate to the Nerves N logo at
  > all so it doesn't make any sense […] I'd prefer the segmented N shape.

  A constellation must read as its logo. Abstract star patterns aren't
  enough.
- **On is lit, off is dim.** When on: lilac lines, candle glow, bone stars.
  When off: everything in dusky violet, faint. A tap on one flips it. A faint
  fixed starfield (seeded, so it doesn't shimmer between frames) fills the
  rest.

## The inventory (drag up)

- **A dark circle swells up from the bottom edge.** It grows from nothing
  until it just covers the panel, and its centre rises from the bottom edge to
  the middle as it grows. It opens over 300 px of travel.

  > The app orb is good but should expand from the bottom of the display, not
  > the middle.
- **Icons only.** The apps sit in a ring from twelve o'clock (ring radius 124,
  56 px icons), each lit in its own tint. A small lilac dot under one marks
  the current app.

  > The app icons in the app drawer look weird and like a mix of blocks and
  > circles. We should do only icons because the density with labels is
  > terrible and hard to read.
- **A tap opens the nearest icon within 50 px.** The circle closes as the app
  opens.

## Letting go of a pull

This applies to both the sky and the inventory.

> If I release it halfway it tends to just stay there instead of finishing or
> reverting. It should finish if past 40% or something like that.

- **Past 40% it finishes; otherwise it reverts** (`@open_at`). For closing,
  the mirror applies: it closes once pulled back past 40%.
- **It must never stay half open.** If no release arrives within 1 s of the
  last move (`@drag_timeout`), the pull settles as if released. Touch
  releases do go missing.
- **A drag locks to one axis.** It can open the sky or the inventory, or turn
  the page, never two at once.

The "stuck orb" was in part an Emerge bug: an element mounted during a pull
skipped its easing, and the DRM presenter could drop that frame. The fix was
to keep the inventory mounted at all times, hidden at scale 0. See
EMERGE-ISSUES.md.

## Colour

`HelloWatch.Clock.Palette` holds every colour, and nothing outside it uses a
literal:

| Use | Names |
|---|---|
| Base of every backdrop, top to bottom | `twilight` {14,22,58} → `abyss` {5,8,26} |
| Darker night (inventory, moon dark sides) | `night`, `midnight`, `shadow` |
| Text and moonlight | `bone` {240,230,210} |
| Labels, captions, ornaments | `lilac` {196,164,246}, `dusk` |
| Accents | `candle` (warm amber), `moss`, `rose`, `teal`, `blue`, `cork` |

> Make the background colors mild gradients from a dark blue. Essentially make
> a few really big gradients so we get that cloudy effect.

- **Clouds.** Every view has the same dark-blue base gradient, with two layers
  of very large, soft white radial gradients on top (`clouds-a.svg`,
  `clouds-b.svg`) at 32% and 24% strength.
- **One tint per view.** Each view tints its two cloud layers its own way, so
  each app has a mood without having its own background colour:

  | View | Clouds |
  |---|---|
  | clock | lilac, blue |
  | alarms | candle, blue |
  | timers | teal, lilac |
  | stopwatch | moss, blue |
  | battery | teal, blue |
  | network | moss, teal |
  | sensors | rose, lilac |
  | moon | bone, blue |
  | tailscale | rose, blue |
  | sky | blue, teal |
- **The panel is AMOLED,** and the base gradient is nearly black, so it's cheap
  to show.
- **Status colour is sparing.** Rose means low battery or recording. Moss,
  candle and rose fill the flask by charge level, and lilac fills it while
  charging.

## Type

> Find a more humane font.

- **Macondo** (a calligraphic display face) is for page titles, big numbers,
  the face's day line and the battery percentage.
- **Alegreya Sans** is for everything else. Use regular for values, medium
  for emphasis (the recording timer, digits), and italic for labels and
  captions.

Both are OFL-licensed and live in `priv/fonts`.

Readability was a complaint: "everything is unreadably small". The current
sizes are:

| Text | Size |
|---|---|
| Titles | 38 px |
| Values | 28 px |
| Headline values | 56 px |
| Body lines | 24 px |
| Labels | 18 px italic |
| Captions | 22 px italic |
| Faint battery figure on the face | 96 px |

Don't go smaller without checking on the watch.

## Text follows the round panel

> the text layouts are boxy in the various views […] We should layout along
> the curve of the display to whatever extent we can

> You didn't align the text with the left-hand side curve. You centered it.

The Arc and Pages modules handle this (`HelloWatch.Clock.Arc`,
`HelloWatch.Clock.Pages`):

- **Titles curve along the top rim** in Macondo, with a sparkle just past each
  end. They read clockwise with the glyph tops outward.
- **An optional caption curves along the bottom rim** in italic lilac. It reads
  counterclockwise with the glyphs upright, so both rims read left to right.
  The caption holds a page's secondary detail, like "Charging · 4.27 V" or
  "6% lit · full in 12 days".
- **Rows start at the panel's left edge where they sit.** Each row is indented
  to where the circle's left side is at that height, so a block of text hugs
  the left curve like a margin. **Rows are not centred.** The owner corrected
  this explicitly.
- **Text shrinks to fit the chord.** Each row is sized down until it fits the
  chord at its height (`Arc.fit/5`, 30 px margin each side), and never below
  12 px.
- **Glyph widths come from the TTF.** Emerge can't measure text, so `Arc`
  reads the advance widths from the font files at compile time. A port to a
  framework that measures text, or draws text on a path, can drop that and
  keep the layout rules.
- **Long, useless data is dropped.** The network page shows one IPv4 address
  per interface. IPv6 addresses were unreadable at a useful size.

## The face

- **The hour markers are the twelve phases of the moon,** full at twelve and
  new at six. Tonight's real phase is drawn bigger, in a faint candle halo.
  Dusk dots mark the minutes.
- **The minute hand is a wand.** It's bone-coloured with a sparkle at the tip.
  The hour hand is shorter and has a lilac dot at its tip.
- **The hub is a small crescent moon** in a candle halo.
- **There's no second hand.** The face redraws once a minute, on the minute.
- **The day line** is in Macondo lilac, for example "Frigg's day · 16".
- **The battery percentage sits behind everything,** large and faint (bone at
  10% alpha, rose at 22% when it's 20% or less):

  > Just have a more faded version of that percentage in the back of the main
  > screen.

  The details live on the Battery page instead.
- **A few fixed stars and three lilac sparkles** are scattered clear of the
  hands.

## The other apps

- **Battery.** The owner wanted to see the charge left, not the power draw.
  The page shows a round-bottomed potion flask filled to the charge, with
  bubbles while charging, and the percentage in Macondo. The caption gives the
  status and voltage. The flask is the one "potion" that survived, on its own
  page as asked.
- **Moon.** Tonight's moon, large, with a faint rim so a thin crescent still
  shows the whole disc. Below it is the phase name. The caption shows how much
  is lit and the days until the full moon.
- **Network and Sensors** are rows of label and value. The heart rate is the
  sensors page's headline value.
- **Tailscale** shows its state. A tap while logged out shows a QR code of the
  login URL, sized to the largest square that fits between the title and the
  caption.
- **Alarms, Timers and Stopwatch** are drafts (2026-10-15) that the owner
  hasn't tried on the watch yet:
  - They lay out fixed rectangles and hit-test taps against the same
    rectangles, with 8 px of slop (`HelloWatch.Clock.Widgets`).
  - Buttons are pills, and digits sit in fixed-width cells so times don't
    jitter.
  - The stopwatch shows hundredths in lilac and redraws every 40 ms while
    running. It keeps the screen on, as asked.
  - An alarm or timer that rings wakes the screen and opens its app under an
    opaque cover with a pulsing ring, saying what rang. It buzzes every 2 s
    until a tap or the top button stops it, or a minute passes.

## Overlays

> Include UI that slides in indicating recording state and duration lapsed.

- **The recording badge.** Holding the bottom button records a voice memo. A
  wine-coloured pill slides down from the top edge, with a pulsing rose dot
  and the elapsed time. When the button is released it slides back up, still
  showing the final time. It stays mounted off screen, so it eases in and out
  and never pops.
- **The ringing cover** sits above everything, including the sky and the
  inventory.

## Input

- **Taps and drags.**
  - A touch that moves 12 px becomes a drag and locks to its main axis.
  - A touch that moves less than 25 px is a tap.
  - Only the latest drag position matters. Drag messages that queue up during
    a render are collapsed.
- **The touch that wakes the screen doesn't press anything.** Touches and taps
  are ignored while the screen is off, apart from waking it.
- **Top button.**
  - It turns the screen off or on, debounced to 250 ms.
  - While something rings, it dismisses it instead.
- **Bottom button.** It records while held.

## Rendering as a design constraint

The battery is weak and the panel holds its own image, so a frame is drawn
only when something visible changes:

| When | What redraws |
|---|---|
| Face | once a minute |
| Battery and network views | every 5 s |
| Sensors view | as readings arrive, at most every 200 ms |
| Timers | every second |
| Running stopwatch | every 40 ms |
| Drags | each move |
| Animations | while they run |
| Screen off | nothing |

> can we also control the refresh to be less frequent even when on? adapting
> to activity?

- **Dimming and sleep.** After 15 s untouched the screen dims to 25%. After
  2 min it goes off, and the watch may suspend. Any touch resets both timers.
  A running stopwatch or something ringing keeps it on and bright.
- **Looping animations are costly** because they keep frames coming. The
  recording dot pulses only while the badge is shown. Nothing on the resting
  face animates.
- **Interaction may be heavy, rest must be idle.** Transitions and pulls ran at
  20–27 frames a second on the GPU build, which the owner judged "good overall
  but not fully smooth". The work is single-threaded in Emerge: tree patch,
  layout and draw.

What kept it fast enough:

- **Stable keys.** The app, the sky and the inventory keep the same keys from
  the first frame of a pull to the last. A new key rebuilds the whole subtree,
  which cost 80–86 ms a frame.
- **Easing in place.** Settles ease the existing elements to new attributes
  (`Animation.change`) rather than remounting them with enter animations.
- **Few layers.** Glows are flat halo discs, not blurs, and the clouds are
  pre-made SVGs tinted at draw time.

## Emerge workarounds a port can drop

These shaped the code, not the design. A port to a framework without these
gaps can do the simple thing:

- **The concave edge is faked.** Emerge has no concave shapes or clip paths.
  The incoming app comes in with a straight edge, and the current app is drawn
  again on top, clipped to a convex arc. That copy doesn't move, so it looks
  identical to the app beneath.
- **Positions use padding, not transforms.** Emerge doesn't clip a transformed
  element's layers to a rounded parent, and every view is clipped while it
  slides.
- **Glows are halo discs.** For the same reason: shadows escape the clip.
- **The palette swaps red and blue on the framebuffer renderer,** so frames can
  be copied to `/dev/fb0` without per-pixel conversion. The DRM renderer
  draws true colours.
- **Icons and ornaments are white SVGs tinted with `Svg.color`,** so one file
  serves every tint.

## Where things are

| | |
|---|---|
| Viewport, state, gestures, transitions, timings | `lib/hello_watch/clock.ex` |
| Colours | `clock/palette.ex` |
| Cloudy backdrops and tints | `clock/backdrop.ex` |
| Face | `clock/face.ex` |
| Moons and sparkles | `clock/moon.ex` |
| Page layout along the curve | `clock/pages.ex`, `clock/arc.ex` |
| Sky and its switches | `clock/sky.ex`, `clock/controls.ex` |
| Inventory | `clock/inventory.ex` |
| Battery, moon and Tailscale pages | `clock/battery_page.ex`, `clock/moon_app.ex`, `clock/tailscale_page.ex` |
| Alarm, timer and stopwatch drafts | `clock/alarms_app.ex`, `clock/timers_app.ex`, `clock/stopwatch_app.ex`, `clock/widgets.ex`, `clock/ringing.ex` |
| Recording badge | `clock/recording.ex` |
| Touch and buttons | `clock/touch.ex`, `clock/button.ex` |
| Art | `priv/images/*.svg` |
| Fonts | `priv/fonts` |
