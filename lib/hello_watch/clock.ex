defmodule HelloWatch.Clock do
  @moduledoc """
  The watch's views, as an Emerge viewport. Time defaults to UTC.

  The things the watch is for are apps: the clock face, alarms, timers, a
  stopwatch, battery, network, sensors, the moon and Tailscale. Around
  every app are two more places:

    * **The sky,** pulled down from above: the watch's global switches as
      constellations (HelloWatch.Clock.Sky). The view shifts up to show it.
    * **The inventory,** pulled up from below: a dark circle that swells up from
      the bottom edge with the apps in a ring (HelloWatch.Clock.Inventory). A tap
      opens one.

  Holding the bottom button records a voice memo (HelloWatch.Recorder), and
  a badge with its running time slides down from the top meanwhile
  (HelloWatch.Clock.Recording).

  An alarm or timer that rings (HelloWatch.Alarms, HelloWatch.Timers) wakes
  the screen, opens its app under a cover saying what rang
  (HelloWatch.Clock.Ringing) and buzzes until a tap or the top button stops
  it, or `@ring_timeout` passes. The screen also stays on while the
  stopwatch runs.

  Dragging sideways moves through the most recently used apps: right goes
  back to older ones, left forward again. The next app slides in over the
  current one, which stays put; its leading edge is an arc, concave from the
  right and convex from the left. Letting go past halfway switches; short of
  that it slides back out.

  On the watch the viewport renders one of two ways, chosen with
  `renderer:`:

    * `:drm`: Emerge's DRM backend draws with OpenGL ES on the GPU and
      page-flips whole frames onto the panel. It also turns the display off
      and on and sets its brightness, from `config/2`; going dark powers the
      panel and display pipeline down.
    * `:framebuffer` (the default): headless on the CPU, each frame sent to
      `HelloWatch.Clock.Display`, which writes it to `/dev/fb0` (see DISPLAY.md).

  Started with `display: nil` and `backend: :wayland` it opens a window
  instead, for working on the UI on a host.

  A frame is only rendered when something on screen changes: once a minute
  for the face, which has no second hand, every few seconds for the battery
  and network views, and as readings arrive on the sensor view. Nothing
  renders while the screen is off.

  Left alone, the screen dims after `@dim_timeout`. A touch or swipe brings
  it back. After `@idle_timeout` the screen goes off and HelloWatch.Suspend
  may suspend the watch.
  """
  use Emerge
  require Logger

  alias HelloWatch.Clock.{
    AlarmsApp,
    Backdrop,
    BatteryPage,
    Controls,
    Display,
    Face,
    Inventory,
    Moon,
    MoonApp,
    Pages,
    Palette,
    Recording,
    Ringing,
    Sky,
    StopwatchApp,
    TailscalePage,
    TimersApp
  }

  alias HelloWatch.{AccessPoint, Power, Recorder, Sensors, Tailscale, Vibrator}

  # The inventory's ring, from twelve o'clock.
  @apps [:clock, :alarms, :timers, :stopwatch, :battery, :network, :sensors, :moon, :tailscale]

  # The hub delivers every event to a single reader, so one stream serves the
  # whole app: charge alone while the face is up, plus the rest on the sensor
  # view, and nothing while the screen is off. See HelloWatch.Sensors.open/1.
  @idle_stream [:battery]
  @sensor_stream [:battery, :heart, {:accel, 25}, {:gyro, 25}]

  @dim_timeout :timer.seconds(15)
  # The brightness while dimmed on DRM, as a share of the panel's range.
  @dim_brightness 0.25
  @idle_timeout :timer.minutes(2)
  # How long an alarm or timer rings unanswered, and its buzz, repeated
  # every `@buzz_every`.
  @ring_timeout :timer.minutes(1)
  @buzz [300, 150, 300, 150, 300]
  @buzz_every 2000
  # How often the running stopwatch redraws while shown.
  @stopwatch_frame 40
  @power_interval :timer.seconds(5)
  # How often the Tailscale view rereads tailscaled, to catch the login URL
  # appearing and the login completing, and how often the sky rereads the
  # switches while it's open.
  @tailscale_interval :timer.seconds(2)
  @controls_interval :timer.seconds(3)
  # How long an app takes to slide all the way in, and how far a drag has
  # to go, in pixels, to switch apps when the finger lets go.
  @transition_ms 520
  @commit_px 227
  # An incoming app is a slab bigger than the panel whose leading edge is
  # an arc: concave when it comes from the right, a gentle arc of radius
  # `@arc`; convex from the left, a rounder one of radius `@convex_arc`,
  # close to the panel's own. Over the panel's height an arc is its bulge
  # deep.
  @arc 400
  @bulge round(@arc - :math.sqrt(@arc * @arc - 227 * 227))
  @convex_arc 240
  @convex_bulge round(@convex_arc - :math.sqrt(@convex_arc * @convex_arc - 227 * 227))
  # The cloud fronts' SVG bands, {width, arc peak}; see priv/images/edge-*.svg.
  @convex_edge {460, 350}
  @concave_edge {306, 195}
  # The first pixels of a drag only arm it; then the view catches up.
  @dead 30
  @catch_up 1.15
  # How far a vertical drag travels to open the sky or the inventory fully,
  # and the share of that past which letting go opens or closes it.
  @sky_travel 454
  @inventory_travel 300
  @open_at 0.4

  # How far the app follows the sky down, and how much it shrinks away.
  @sky_parallax 0.3
  @sky_recede 0.12

  # A drag or pull that hasn't moved for this long is settled as if let go,
  # in case its release went missing.
  @drag_timeout 1000

  @fonts [
    %{family: "Macondo", source: "fonts/Macondo-Regular.ttf"},
    %{family: "Alegreya Sans", source: "fonts/AlegreyaSans-Regular.ttf"},
    %{family: "Alegreya Sans", source: "fonts/AlegreyaSans-Medium.ttf", weight: 500},
    %{family: "Alegreya Sans", source: "fonts/AlegreyaSans-Italic.ttf", italic: true}
  ]

  def toggle, do: send(__MODULE__, :toggle_display)

  def status do
    state = :sys.get_state(__MODULE__)

    %{
      on: state.on,
      page: state.app,
      overlay: state.overlay,
      recents: state.recents,
      time_zone: state.time_zone,
      battery: state.battery,
      power: state.power,
      estimate: state.estimate
    }
  end

  @impl Viewport
  def mount(opts) do
    {config, _opts} = Keyword.split(opts, [:display, :time_zone, :renderer])
    display = Keyword.get(config, :display, Display)
    renderer = if display, do: Keyword.get(config, :renderer, :framebuffer), else: :window
    # The framebuffer takes the renderer's bytes as they are; see Palette.
    Palette.bgr(renderer == :framebuffer)

    power = Power.read()

    state =
      %{
        display: display,
        renderer: renderer,
        on: true,
        dimmed: false,
        app: :clock,
        # Most recent first; sideways drags move through it.
        recents: [:clock],
        # :sky or :inventory while one is open.
        overlay: nil,
        time_zone: Keyword.get(config, :time_zone, "Etc/UTC"),
        last_press: nil,
        sensor_port: nil,
        battery: nil,
        power: power,
        estimate: Power.estimate(nil, power),
        sensors: %{},
        sensor_errors: %{},
        render_timer: nil,
        tick_ref: nil,
        power_ref: nil,
        idle_timer: nil,
        dim_timer: nil,
        tailscale: nil,
        tailscale_read: nil,
        tailscale_ref: nil,
        controls: nil,
        controls_read: nil,
        controls_ref: nil,
        control_task: nil,
        # How far a finger has dragged sideways, while it's down.
        drag: nil,
        drag_timer: nil,
        # The app sliding in or back out after a sideways drag lets go:
        # %{base:, incoming:, side:, from:, to:, n:}.
        moving: nil,
        # A vertical pull while the finger is down, %{kind:, at:, dy:} with
        # `at` from 0 (closed) to 1 (open), and its settling after letting
        # go, %{kind:, from:, to:, n:}.
        vdrag: nil,
        vdrag_timer: nil,
        vmoving: nil,
        transitions: 0,
        # While the bottom button records a memo, when it started, and the
        # seconds it has run, which the badge keeps showing as it leaves.
        recording: nil,
        record_seconds: 0,
        record_ref: nil,
        # The alarm open for editing in the alarms app, the stopwatch, and
        # the ticks that redraw the timers and the stopwatch while shown.
        alarm_edit: nil,
        stopwatch: StopwatchApp.new(),
        app_ref: nil,
        # The alarm or timer ringing: %{kind:, item:, ref:}.
        ringing: nil
      }
      |> schedule_tick()
      |> schedule_power()
      |> stream(@idle_stream)
      |> start_idle_timer()

    {:ok, state, viewport(renderer, display)}
  end

  defp viewport(:window, _display) do
    %Emerge.Config{
      output: %Emerge.Config.Window{title: "HelloWatch", size: {454, 454}},
      assets: [otp_app: :hello_watch, fonts: Enum.map(@fonts, &struct(Emerge.Config.Font, &1))]
    }
  end

  defp viewport(:framebuffer, display) do
    %{
      viewport(:window, display)
      | output: %Emerge.Config.Headless{size: {454, 454}, target: display.target()},
        renderer: [api: :raster]
    }
  end

  # The panel is DSI-1 on the display controller's KMS device, card1.
  defp viewport(:drm, display) do
    backlight =
      case Path.wildcard("/sys/class/backlight/*") do
        [device | _] -> %Emerge.Config.Backlight{device: device, brightness: 1.0}
        [] -> %Emerge.Config.Backlight{device: nil}
      end

    %{
      viewport(:window, display)
      | output: %Emerge.Config.DRM{
          card: "/dev/dri/card1",
          connector: "DSI-1",
          backlight: backlight,
          hotplug_interval_ms: nil
        },
        renderer: [api: :opengl],
        input: [cursor: [hardware: false]],
        # Frame timings for EmergeSkia.stats/2.
        diagnostics: [stats: true]
    }
  end

  @impl Viewport
  # On DRM, the display follows the screen's state: off while dark, and
  # dimmed after `@dim_timeout`.
  def config(%{output: %Emerge.Config.DRM{} = output} = previous, state) do
    backlight =
      if output.backlight.device,
        do: %{output.backlight | brightness: if(state.dimmed, do: @dim_brightness, else: 1.0)},
        else: output.backlight

    display = if state.on, do: :on, else: :off
    %{previous | output: %{output | display: display, backlight: backlight}}
  end

  def config(previous, _state), do: previous

  @impl Viewport
  def render(state) do
    {child, layers} = scene(state)
    {at, ms} = inventory_at(state)

    el(
      [width(px(454)), height(px(454))] ++
        swipes(state) ++
        Enum.map(
          [Inventory.render(@apps, state.app, at, ms) | layers] ++
            ringing(state.ringing) ++
            [Recording.render(state.record_seconds, state.recording != nil)],
          &Nearby.in_front/1
        ),
      child
    )
  end

  defp ringing(nil), do: []
  defp ringing(ringing), do: [Ringing.render({ringing.kind, ringing.item})]

  # How far open the inventory is, and with `ms`, easing there. It stays
  # mounted while closed, shrunk to nothing and hidden: Emerge (0.4.2) skips
  # the ease of an element mounted by the same pull, and that unanimated
  # frame can be dropped by its DRM presenter, which then kept showing the
  # half-open drag frame.
  defp inventory_at(%{vdrag: %{kind: :inventory, at: at}}), do: {at, nil}
  defp inventory_at(%{vdrag: %{}}), do: {0, nil}
  defp inventory_at(%{vmoving: %{kind: :inventory} = m}), do: {m.to, m.ms}
  defp inventory_at(%{vmoving: %{}}), do: {0, nil}
  defp inventory_at(%{overlay: :inventory}), do: {1, nil}
  defp inventory_at(_state), do: {0, nil}

  # Emerge's own gestures, for a window on a host. On the watch, drags come
  # from HelloWatch.Clock.Touch; Emerge's DRM backend reads the touchscreen
  # too, and its swipes would arrive twice.
  defp swipes(%{renderer: :window}) do
    [
      Event.on_swipe_left({:swipe, :left}),
      Event.on_swipe_right({:swipe, :right}),
      Event.on_swipe_down({:swipe, :down}),
      Event.on_swipe_up({:swipe, :up})
    ]
  end

  defp swipes(_state), do: []

  # What's on screen, as the root's child and the layers over it. The app
  # underneath is always in the same keyed element, and the sky and the
  # inventory keep their keys from first pull to last, so a pull's frames
  # only change attributes and Emerge never rebuilds those subtrees.
  defp scene(%{vdrag: %{kind: kind, at: at}} = state), do: pulled(state, kind, at, nil)

  defp scene(%{vmoving: %{} = m} = state), do: pulled(state, m.kind, m.to, m.ms)

  defp scene(%{overlay: overlay} = state) when overlay != nil,
    do: pulled(state, overlay, 1, nil)

  defp scene(%{drag: dx} = state) when dx != nil do
    side = side(dx)
    at = position(side, dx)
    incoming = neighbour(state, dx)

    {base(state, state.app),
     incoming(state, state.app, incoming, side, {at, at}, {:drag, state.transitions})}
  end

  defp scene(%{moving: %{} = m} = state),
    do:
      {base(state, m.base),
       incoming(state, m.base, m.incoming, m.side, {m.from, m.to}, {:moving, m.n})}

  defp scene(state), do: {base(state, state.app), []}

  # The sky or the inventory `at` the way open, from 0 to 1. With `ms`, it
  # eases there from wherever it is on screen.
  #
  # The app underneath lags behind the sky and shrinks a little, as if the
  # view tips up from the ground to the stars.
  defp pulled(state, :sky, at, ms) do
    shift = round(at * 454)
    app = [Transform.move_y(round(shift * @sky_parallax)), Transform.scale(1 - at * @sky_recede)]

    {el([key(:app)] ++ eased(app, ms), view(state, state.app)),
     [el([key(:sky)] ++ eased([Transform.move_y(shift - 454)], ms), Sky.render(state.controls))]}
  end

  # The inventory itself is always there; see render/1.
  defp pulled(state, :inventory, _at, _ms), do: {base(state, state.app), []}

  defp base(state, app), do: el([key(:app)], view(state, app))

  @doc false
  # `attrs`, and with `ms`, an ease to them from where they are now.
  def eased(attrs, nil), do: attrs
  def eased(attrs, ms), do: attrs ++ [Animation.change(attrs, ms, :ease_out)]

  defp view(state, :clock),
    do: Face.render(local_time(state), Moon.phase(DateTime.utc_now()), battery(state))

  defp view(state, :alarms),
    do: AlarmsApp.render(AlarmsApp.alarms(), state.alarm_edit, DateTime.utc_now())

  defp view(_state, :timers), do: TimersApp.render(TimersApp.timers(), DateTime.utc_now())

  defp view(state, :stopwatch),
    do: StopwatchApp.render(state.stopwatch, System.monotonic_time(:millisecond))

  defp view(state, :battery), do: BatteryPage.render(battery(state), :battery)

  defp view(_state, :network),
    do: Pages.render("Network", network_rows(AccessPoint.info()), :network, hostname())

  defp view(state, :sensors), do: Pages.render("Sensors", sensor_rows(state), :sensors)
  defp view(_state, :moon), do: MoonApp.render(Moon.phase(DateTime.utc_now()))
  defp view(state, :tailscale), do: TailscalePage.render(state.tailscale, :tailscale)

  # The app being pulled in slides over the one shown, which stays put.
  # `at` is where the incoming app's own content sits, as {from, to}: equal
  # while dragging, animated after letting go. Each layer gets the same
  # animation, so they move together.
  #
  # From the left, the app is a slab with a convex right edge: its content
  # and, past it, a bulge its backdrop reaches into.
  #
  # From the right, its left edge is concave. Emerge only rounds outwards,
  # so the slab comes in with a straight edge `@bulge` px ahead of its
  # content, and the app shown is drawn again on top, clipped to a convex
  # arc that ends where the concave edge should be. That copy doesn't move,
  # so it's indistinguishable from the app beneath, and the incoming app
  # appears to have a hollow edge.
  #
  # The shapes are transparent: each view's backdrop is wider than the panel
  # (HelloWatch.Clock.Backdrop), and a shape clips it. A front of soft cloud
  # rides each leading edge, over the seam.
  defp incoming(state, _base, app, :left, at, key) do
    [
      el(
        [
          key({key, :slab}),
          width(px(454 + @convex_bulge)),
          height(px(2 * @convex_arc)),
          Transform.move_y(227 - @convex_arc),
          Border.rounded_each(0, @convex_arc, @convex_arc, 0),
          clip_nearby(),
          padding_each(@convex_arc - 227, 0, 0, 0)
        ] ++ slide_x(at, 0),
        view(state, app)
      ),
      edge(app, "images/edge-convex.svg", @convex_edge, at, 454 + @convex_bulge, {key, :edge})
    ]
  end

  defp incoming(state, base, app, :right, at, key) do
    # Wide enough to cover the whole panel to the left of the arc.
    wide = 454 + 2 * @arc

    slab =
      el(
        [
          key({key, :slab}),
          width(px(454 + @bulge)),
          height(px(454)),
          clip_nearby(),
          padding_each(0, 0, 0, @bulge)
        ] ++ slide_x(at, -@bulge),
        view(state, app)
      )

    hollow =
      el(
        [
          key({key, :hollow}),
          width(px(wide)),
          height(px(2 * @arc)),
          Transform.move_y(227 - @arc),
          Border.rounded_each(0, @arc, @arc, 0),
          clip_nearby()
        ] ++ hollow_x(at, wide),
        view(state, base)
      )

    [slab, hollow, edge(app, "images/edge-concave.svg", @concave_edge, at, 0, {key, :edge})]
  end

  # The cloud front on a leading edge: an SVG band of puffs along the arc,
  # `{width, peak}` where peak is the arc's rightmost point in the band, which
  # starts 20 px above the panel. `tip` is where the arc peaks, past `at`.
  defp edge(app, source, {width, peak}, at, tip, key) do
    svg(
      [
        key(key),
        width(px(width)),
        height(px(494)),
        Transform.move_y(-20),
        Svg.color(Backdrop.edge_tint(app))
      ] ++ slide_x(at, tip - peak),
      source
    )
  end

  # The copy moves with the edge while its content stays put. The content is
  # held in place with padding, not a counter-transform: Emerge doesn't clip
  # a transformed child's nearby layers to a rounded parent.
  defp hollow_x({at, at}, wide), do: hollow_at(at, wide)

  defp hollow_x({from, to}, wide) do
    hollow_at(to, wide) ++
      [
        Animation.animate_enter(
          [hollow_at(from, wide), hollow_at(to, wide)],
          settle_ms(from, to),
          :ease_out
        )
      ]
  end

  defp hollow_at(at, wide),
    do: [Transform.move_x(at - wide), padding_each(@arc - 227, 0, 0, round(wide - at))]

  # A horizontal position of `offset` past `at`, animated when it moves.
  defp slide_x({at, at}, offset), do: [Transform.move_x(at + offset)]

  defp slide_x({from, to}, offset) do
    [
      Transform.move_x(to + offset),
      Animation.animate_enter(
        [[Transform.move_x(from + offset)], [Transform.move_x(to + offset)]],
        settle_ms(from, to),
        :ease_out
      )
    ]
  end

  defp settle_ms(from, to), do: Kernel.max(round(@transition_ms * abs(to - from) / 454), 120)

  # Which side the incoming app comes from: dragging left pulls the next
  # app in from the right.
  defp side(dx) when dx <= 0, do: :right
  defp side(_dx), do: :left

  # Where the incoming app's content sits for a drag of `dx`: fully out of
  # sight at the start, and at 0 when it covers the panel.
  defp position(side, dx) do
    travel = travel(dx)
    if side == :right, do: Kernel.max(454 - travel, 0), else: Kernel.min(away(:left) + travel, 0)
  end

  defp travel(d), do: Kernel.max(abs(d) - @dead, 0) * @catch_up

  # Fully out of sight, past the panel's rim with the leading edge.
  defp away(:right), do: 454 + @bulge
  defp away(:left), do: -(454 + @convex_bulge)

  # The app a sideways drag brings in from the recents: dragging right goes
  # back to an older one, left forward to a newer one. Nil at either end.
  defp neighbour(state, dx) do
    index = Enum.find_index(state.recents, &(&1 == state.app)) || 0
    target = if dx <= 0, do: index - 1, else: index + 1
    if target >= 0, do: Enum.at(state.recents, target)
  end

  @impl Viewport
  # The tick stops once the screen is off, so a dark watch never wakes the
  # BEAM just to skip a frame; wake/1 restarts it.
  def handle_info({:tick, ref}, %{tick_ref: ref, on: true} = state) do
    state = schedule_tick(state)
    {:noreply, if(state.app == :clock, do: Viewport.rerender(state), else: state)}
  end

  def handle_info({:tick, ref}, %{tick_ref: ref} = state),
    do: {:noreply, %{state | tick_ref: nil}}

  def handle_info({:power, ref}, %{power_ref: ref, on: true} = state) do
    state = schedule_power(read_power(state))

    {:noreply, if(state.app in [:battery, :network], do: Viewport.rerender(state), else: state)}
  end

  def handle_info({:power, ref}, %{power_ref: ref} = state),
    do: {:noreply, %{state | power_ref: nil}}

  def handle_info(:refresh, state) do
    state = %{state | render_timer: nil}
    {:noreply, if(state.on, do: Viewport.rerender(state), else: state)}
  end

  def handle_info(:toggle_display, %{ringing: %{}} = state), do: {:noreply, dismiss(state)}

  def handle_info(:toggle_display, state) do
    now = System.monotonic_time(:millisecond)

    if state.last_press == nil or now - state.last_press >= 250 do
      state = %{state | last_press: now}
      {:noreply, if(state.on, do: sleep(state), else: wake(state))}
    else
      {:noreply, state}
    end
  end

  def handle_info({:tap, _at}, %{on: false} = state), do: {:noreply, state}

  def handle_info({:tap, _at}, %{ringing: %{}} = state), do: {:noreply, dismiss(state)}

  # In the sky, a tap on a star flips its switch.
  def handle_info({:tap, at}, %{overlay: :sky, control_task: nil} = state) do
    case Sky.hit(at) do
      nil ->
        {:noreply, state}

      id ->
        task = Task.async(fn -> safely(fn -> Controls.toggle(id) end) end)
        {:noreply, %{state | control_task: task.ref}}
    end
  end

  # In the inventory, a tap on an app opens it as the circle closes.
  def handle_info({:tap, at}, %{overlay: :inventory} = state) do
    case Inventory.hit(@apps, at) do
      nil ->
        {:noreply, state}

      app ->
        state = state |> open_app(app) |> Map.put(:overlay, nil)
        {:noreply, settle_pull(state, :inventory, 1, 0)}
    end
  end

  # Tapping the Tailscale view while logged out starts a login; its QR code
  # shows once tailscaled has a URL.
  def handle_info(
        {:tap, _at},
        %{app: :tailscale, overlay: nil, tailscale: %{state: "NeedsLogin", logging_in: false}} =
          state
      ) do
    try do
      Tailscale.login()
    catch
      :exit, reason -> Logger.warning("Tailscale login: #{inspect(reason)}")
    end

    {:noreply, read_tailscale(state)}
  end

  def handle_info({:tap, at}, %{app: :alarms, overlay: nil} = state) do
    editing = AlarmsApp.tap(AlarmsApp.alarms(), state.alarm_edit, at)
    {:noreply, Viewport.rerender(%{state | alarm_edit: editing})}
  end

  def handle_info({:tap, at}, %{app: :timers, overlay: nil} = state) do
    TimersApp.tap(TimersApp.timers(), at)
    {:noreply, state |> schedule_app_tick() |> Viewport.rerender()}
  end

  def handle_info({:tap, at}, %{app: :stopwatch, overlay: nil} = state) do
    stopwatch = StopwatchApp.tap(state.stopwatch, at, System.monotonic_time(:millisecond))
    state = %{state | stopwatch: stopwatch}
    # Stopping it lets the screen dim and sleep again from here.
    state = if StopwatchApp.running?(stopwatch), do: state, else: start_idle_timer(state)
    {:noreply, state |> schedule_app_tick() |> Viewport.rerender()}
  end

  def handle_info({:tap, _at}, state), do: {:noreply, state}

  # An alarm or timer is due; see HelloWatch.Alarms and HelloWatch.Timers.
  def handle_info({:ring, kind, item}, state) do
    if state.ringing, do: Vibrator.stop()
    state = if state.on, do: start_idle_timer(state), else: wake(state)
    ref = make_ref()
    send(self(), {:buzz, ref})
    Process.send_after(self(), {:ring_timeout, ref}, @ring_timeout)
    app = if kind == :alarm, do: :alarms, else: :timers

    state =
      %{state | ringing: %{kind: kind, item: item, ref: ref}, overlay: nil, alarm_edit: nil}
      |> open_app(app)

    {:noreply, Viewport.rerender(state)}
  end

  def handle_info({:buzz, ref}, %{ringing: %{ref: ref}} = state) do
    Vibrator.pattern(@buzz)
    Process.send_after(self(), {:buzz, ref}, @buzz_every)
    {:noreply, state}
  end

  def handle_info({:buzz, _ref}, state), do: {:noreply, state}

  def handle_info({:ring_timeout, ref}, %{ringing: %{ref: ref}} = state),
    do: {:noreply, dismiss(state)}

  def handle_info({:ring_timeout, _ref}, state), do: {:noreply, state}

  def handle_info({:app_tick, ref}, %{app_ref: ref, on: true} = state),
    do: {:noreply, state |> schedule_app_tick() |> Viewport.rerender()}

  def handle_info({:app_tick, _ref}, state), do: {:noreply, state}

  def handle_info({:tailscale, ref}, %{tailscale_ref: ref, on: true, app: :tailscale} = state),
    do: {:noreply, read_tailscale(state)}

  def handle_info({:tailscale, ref}, %{tailscale_ref: ref} = state),
    do: {:noreply, %{state | tailscale_ref: nil}}

  def handle_info({ref, info}, %{tailscale_read: ref} = state) do
    Process.demonitor(ref, [:flush])
    timer = make_ref()
    Process.send_after(self(), {:tailscale, timer}, @tailscale_interval)
    state = %{state | tailscale_read: nil, tailscale_ref: timer}

    cond do
      info == state.tailscale ->
        {:noreply, state}

      state.on and state.app == :tailscale ->
        {:noreply, Viewport.rerender(%{state | tailscale: info})}

      true ->
        {:noreply, %{state | tailscale: info}}
    end
  end

  def handle_info({:controls, ref}, %{controls_ref: ref, on: true} = state)
      when state.overlay == :sky or state.vdrag != nil or state.vmoving != nil,
      do: {:noreply, read_controls(state)}

  def handle_info({:controls, ref}, %{controls_ref: ref} = state),
    do: {:noreply, %{state | controls_ref: nil}}

  def handle_info({ref, controls}, %{controls_read: ref} = state) do
    Process.demonitor(ref, [:flush])
    timer = make_ref()
    Process.send_after(self(), {:controls, timer}, @controls_interval)
    state = %{state | controls_read: nil, controls_ref: timer}

    if controls == state.controls,
      do: {:noreply, state},
      else: {:noreply, Viewport.rerender(%{state | controls: controls})}
  end

  # A switch was flipped; Tailscale may instead want logging in, which
  # happens on its view.
  def handle_info({ref, result}, %{control_task: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | control_task: nil}

    case result do
      :login ->
        state = state |> open_app(:tailscale) |> Map.put(:overlay, nil)
        {:noreply, Viewport.rerender(state)}

      _ ->
        {:noreply, read_controls(state)}
    end
  end

  # The bottom button records while held; see HelloWatch.Recorder.
  def handle_info({:record, true}, %{recording: nil} = state) do
    state = if state.on, do: start_idle_timer(state), else: wake(state)

    case safely(&Recorder.start/0) do
      {:ok, _path} ->
        state = %{state | recording: System.monotonic_time(:millisecond), record_seconds: 0}
        {:noreply, state |> schedule_record_tick() |> Viewport.rerender()}

      error ->
        Logger.warning("Recording: #{inspect(error)}")
        {:noreply, state}
    end
  end

  def handle_info({:record, false}, %{recording: since} = state) when since != nil do
    safely(&Recorder.stop/0)
    state = %{state | recording: nil, record_ref: nil} |> start_idle_timer()
    {:noreply, Viewport.rerender(state)}
  end

  def handle_info({:record, _down}, state), do: {:noreply, state}

  def handle_info({:record_tick, ref}, %{record_ref: ref} = state) do
    seconds = div(System.monotonic_time(:millisecond) - state.recording, 1000)
    state = schedule_record_tick(%{state | record_seconds: seconds})
    {:noreply, if(state.on, do: Viewport.rerender(state), else: state)}
  end

  def handle_info({:record_tick, _ref}, state), do: {:noreply, state}

  def handle_info(:touch, %{on: true} = state), do: {:noreply, start_idle_timer(state)}
  def handle_info(:touch, state), do: {:noreply, wake(state)}

  def handle_info(:dim, %{on: true, dimmed: false} = state) do
    if keep_on?(state),
      do: {:noreply, %{state | dim_timer: nil}},
      else: {:noreply, panel(%{state | dimmed: true, dim_timer: nil}, :dim)}
  end

  def handle_info(:dim, state), do: {:noreply, state}

  def handle_info(:screen_timeout, %{on: true} = state) do
    if keep_on?(state) or state.recording != nil,
      do: {:noreply, start_idle_timer(state)},
      else: {:noreply, sleep(state)}
  end

  def handle_info(:screen_timeout, state), do: {:noreply, state}

  def handle_info({:swipe, _direction}, %{on: false} = state), do: {:noreply, state}

  # Swipes in a host window do in one go what drags do on the watch.
  def handle_info({:swipe, direction}, state) when direction in [:left, :right] do
    dx = if direction == :left, do: -1, else: 1
    if state.overlay, do: {:noreply, state}, else: {:noreply, swipe(state, dx)}
  end

  def handle_info({:swipe, direction}, state) when direction in [:up, :down] do
    dy = if direction == :down, do: 1000, else: -1000
    handle_info({:vrelease, dy}, state)
  end

  def handle_info({:drag, _dx}, %{on: false} = state), do: {:noreply, state}

  def handle_info({:drag, dx}, state) do
    dx = latest_drag(:drag, dx)

    cond do
      state.overlay != nil or state.vdrag != nil ->
        {:noreply, state}

      neighbour(state, dx) == nil ->
        {:noreply, if(state.drag, do: Viewport.rerender(%{state | drag: nil}), else: state)}

      true ->
        if state.drag_timer, do: Process.cancel_timer(state.drag_timer)
        timer = Process.send_after(self(), {:drag_timeout, dx}, @drag_timeout)
        {:noreply, Viewport.rerender(%{state | drag: dx, drag_timer: timer, moving: nil})}
    end
  end

  def handle_info({:drag_timeout, dx}, %{drag: dx} = state),
    do: handle_info({:release, dx}, state)

  def handle_info({:drag_timeout, _dx}, state), do: {:noreply, state}

  def handle_info({:release, _dx}, %{drag: nil} = state), do: {:noreply, cancel_drag_timer(state)}

  def handle_info({:release, _dx}, %{on: false} = state),
    do: {:noreply, cancel_drag_timer(%{state | drag: nil})}

  def handle_info({:release, dx}, state) do
    state = cancel_drag_timer(%{state | drag: nil})

    side = side(dx)
    from = position(side, dx)

    if abs(dx) >= @commit_px,
      do: {:noreply, turn(state, dx, from)},
      else: {:noreply, slide(state, state.app, neighbour(state, dx), side, from, away(side))}
  end

  def handle_info({:vdrag, _dy}, %{on: false} = state), do: {:noreply, state}

  def handle_info({:vdrag, dy}, state) do
    dy = latest_drag(:vdrag, dy)

    case pull(state, dy) do
      nil ->
        {:noreply, state}

      vdrag ->
        state =
          if vdrag.kind == :sky and state.controls_read == nil,
            do: read_controls(state),
            else: state

        if state.vdrag_timer, do: Process.cancel_timer(state.vdrag_timer)
        timer = Process.send_after(self(), {:vdrag_timeout, dy}, @drag_timeout)
        vdrag = Map.put(vdrag, :dy, dy)

        {:noreply,
         Viewport.rerender(%{state | vdrag: vdrag, vdrag_timer: timer, vmoving: nil, moving: nil})}
    end
  end

  # A pull whose release never came settles from where it was left.
  def handle_info({:vdrag_timeout, dy}, %{vdrag: %{dy: dy}} = state),
    do: handle_info({:vrelease, dy}, state)

  def handle_info({:vdrag_timeout, _dy}, state), do: {:noreply, state}

  def handle_info({:vrelease, _dy}, %{on: false} = state),
    do: {:noreply, cancel_vdrag_timer(%{state | vdrag: nil})}

  def handle_info({:vrelease, dy}, state) do
    state = cancel_vdrag_timer(state)

    case pull(%{state | vdrag: nil}, dy) do
      nil ->
        {:noreply, Viewport.rerender(%{state | vdrag: nil})}

      %{kind: kind, at: at} ->
        open? = state.overlay == kind
        # Opening needs to get past @open_at; closing, back below 1 - @open_at.
        to = if (open? and at > 1 - @open_at) or (not open? and at >= @open_at), do: 1, else: 0
        state = %{state | vdrag: nil, overlay: nil} |> start_idle_timer()

        state =
          if kind == :sky and state.controls_read == nil, do: read_controls(state), else: state

        {:noreply, settle_pull(state, kind, at, to)}
    end
  end

  # The sky or inventory has finished opening or closing.
  def handle_info({:pulled, n}, %{vmoving: %{n: n} = m} = state) do
    overlay = if m.to == 1, do: m.kind, else: nil
    {:noreply, Viewport.rerender(%{state | vmoving: nil, overlay: overlay})}
  end

  def handle_info({:pulled, _n}, state), do: {:noreply, state}

  # The incoming app has covered the panel, or gone back out, by now.
  def handle_info({:moved, n}, %{moving: %{n: n}} = state),
    do: {:noreply, Viewport.rerender(%{state | moving: nil})}

  def handle_info({:moved, _n}, state), do: {:noreply, state}

  def handle_info({port, _payload} = message, %{sensor_port: port} = state)
      when is_port(port) do
    {:noreply, queue_render(handle_sensor(state, Sensors.decode(port, message)))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Where a vertical drag of `dy` has pulled the sky or the inventory to, as
  # %{kind:, at:} with `at` from 0 (closed) to 1 (open), or nil if it pulls
  # nothing. Down opens the sky or closes the inventory; up the reverse.
  defp pull(%{overlay: nil, drag: nil, moving: nil}, dy) when dy > 0,
    do: %{kind: :sky, at: Kernel.min(travel(dy) / @sky_travel, 1)}

  defp pull(%{overlay: nil, drag: nil, moving: nil}, dy) when dy < 0,
    do: %{kind: :inventory, at: Kernel.min(travel(dy) / @inventory_travel, 1)}

  defp pull(%{overlay: :sky}, dy) when dy < 0,
    do: %{kind: :sky, at: Kernel.max(1 - travel(dy) / @sky_travel, 0)}

  defp pull(%{overlay: :inventory}, dy) when dy > 0,
    do: %{kind: :inventory, at: Kernel.max(1 - travel(dy) / @inventory_travel, 0)}

  defp pull(_state, _dy), do: nil

  defp settle_pull(state, kind, from, to) do
    n = state.transitions + 1
    travel = if kind == :sky, do: 454, else: 300
    ms = Kernel.max(round(@transition_ms * abs(to - from) * travel / 454), 120)
    Process.send_after(self(), {:pulled, n}, ms + 80)
    vmoving = %{kind: kind, from: from, to: to, n: n, ms: ms}
    Viewport.rerender(%{state | vmoving: vmoving, transitions: n})
  end

  # Opens `app`, putting it first in the recents.
  defp open_app(%{app: app} = state, app), do: state

  defp open_app(state, app) do
    state
    |> leave_page(state.app)
    |> Map.merge(%{app: app, recents: [app | List.delete(state.recents, app)]})
    |> enter_page(app)
    |> start_idle_timer()
  end

  # Switches to the app `direction` points to (negative is newer), sliding
  # it in over the current one from `from`.
  defp turn(state, direction, from) do
    case neighbour(state, direction) do
      nil ->
        Viewport.rerender(state)

      next ->
        old = state.app

        state
        |> leave_page(old)
        |> Map.put(:app, next)
        |> enter_page(next)
        |> start_idle_timer()
        |> slide(old, next, side(direction), from, 0)
    end
  end

  defp swipe(state, direction), do: turn(state, direction, away(side(direction)))

  # A drag that never got past the dead zone has nothing to slide back.
  defp slide(state, _base, _incoming, _side, at, at), do: Viewport.rerender(state)

  defp slide(state, base, incoming, side, from, to) do
    n = state.transitions + 1
    Process.send_after(self(), {:moved, n}, settle_ms(from, to) + 80)
    moving = %{base: base, incoming: incoming, side: side, from: from, to: to, n: n}
    Viewport.rerender(%{state | moving: moving, transitions: n})
  end

  defp cancel_vdrag_timer(%{vdrag_timer: nil} = state), do: state

  defp cancel_vdrag_timer(state) do
    Process.cancel_timer(state.vdrag_timer)
    %{state | vdrag_timer: nil}
  end

  defp cancel_drag_timer(%{drag_timer: nil} = state), do: state

  defp cancel_drag_timer(state) do
    Process.cancel_timer(state.drag_timer)
    %{state | drag_timer: nil}
  end

  # Drags queue up while a frame renders; only the newest position matters.
  defp latest_drag(tag, d) do
    receive do
      {^tag, next} -> latest_drag(tag, next)
    after
      0 -> d
    end
  end

  # The screen stays on and bright while the stopwatch runs or something
  # rings. It also stays on while recording, as suspending would end it.
  defp keep_on?(state), do: StopwatchApp.running?(state.stopwatch) or state.ringing != nil

  defp dismiss(state) do
    Vibrator.stop()
    %{state | ringing: nil} |> start_idle_timer() |> Viewport.rerender()
  end

  # The timers count down each second while shown, the running stopwatch
  # faster. A new ref makes a tick already in flight a no-op.
  defp schedule_app_tick(state) do
    delay =
      cond do
        not state.on ->
          nil

        state.app == :timers and TimersApp.timers() != [] ->
          1000 - rem(System.system_time(:millisecond), 1000)

        state.app == :stopwatch and StopwatchApp.running?(state.stopwatch) ->
          @stopwatch_frame

        true ->
          nil
      end

    ref = if delay, do: make_ref()
    if ref, do: Process.send_after(self(), {:app_tick, ref}, delay)
    %{state | app_ref: ref}
  end

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The switches are read beside the viewport: the tailscale CLI takes a
  # moment on this CPU. The answer comes back as a message.
  defp read_controls(%{controls_read: nil} = state) do
    task = Task.async(fn -> safely(&Controls.read/0) end)
    %{state | controls_read: task.ref}
  end

  defp read_controls(state), do: state

  defp sleep(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    if state.dim_timer, do: Process.cancel_timer(state.dim_timer)
    close_sensors(state.sensor_port)
    HelloWatch.Suspend.screen_off()

    %{state | on: false, idle_timer: nil, dim_timer: nil, sensor_port: nil, sensors: %{}}
    |> panel(:sleep)
  end

  defp wake(state) do
    state =
      %{state | on: true}
      |> read_power(restart: true)
      |> enter_page(state.app)
      |> start_idle_timer()
      |> ensure_ticking()
      |> Viewport.rerender()
      |> panel(:wake)

    HelloWatch.Suspend.screen_on()
    state
  end

  # Tells the panel the screen went dark, woke, dimmed or undimmed. On DRM
  # that's Emerge's display and backlight (see config/2), which a render
  # applies; a wake has already rendered. Otherwise it's
  # HelloWatch.Clock.Display.
  defp panel(%{renderer: :drm} = state, :wake), do: state
  defp panel(%{renderer: :drm} = state, _change), do: Viewport.rerender(state)
  defp panel(%{display: nil} = state, _change), do: state

  defp panel(state, change) do
    apply(state.display, change, [])
    state
  end

  defp read_power(state, opts \\ []) do
    power = Power.read()
    %{state | power: power, estimate: Power.estimate(state.estimate, power, opts)}
  end

  # The hub's fuel gauge when it reports, else the estimate from the voltage.
  defp battery(%{battery: percent} = state) when is_number(percent),
    do: %{percent: round(percent), status: status(state.power), volts: state.power.volts}

  defp battery(%{estimate: %{percent: percent}} = state),
    do: %{percent: percent, status: status(state.power), volts: state.power.volts}

  defp battery(_state), do: nil

  defp status(%{source: :usb, status: "Full"}), do: :full
  defp status(%{source: :usb}), do: :charging
  defp status(_power), do: :battery

  # On the next minute. A new ref makes any tick already in flight a no-op.
  defp schedule_tick(state) do
    ref = make_ref()

    Process.send_after(
      self(),
      {:tick, ref},
      60_000 - rem(System.system_time(:millisecond), 60_000)
    )

    %{state | tick_ref: ref}
  end

  # On each whole second since the recording started.
  defp schedule_record_tick(state) do
    ref = make_ref()
    elapsed = System.monotonic_time(:millisecond) - state.recording
    Process.send_after(self(), {:record_tick, ref}, 1000 - rem(elapsed, 1000))
    %{state | record_ref: ref}
  end

  defp schedule_power(state) do
    ref = make_ref()
    Process.send_after(self(), {:power, ref}, @power_interval)
    %{state | power_ref: ref}
  end

  defp ensure_ticking(state) do
    state = if state.tick_ref, do: state, else: schedule_tick(state)
    if state.power_ref, do: state, else: schedule_power(state)
  end

  # Any interaction: back to full brightness and the second hand, and both
  # timeouts start over.
  defp start_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    if state.dim_timer, do: Process.cancel_timer(state.dim_timer)

    state = %{
      state
      | idle_timer: Process.send_after(self(), :screen_timeout, @idle_timeout),
        dim_timer: Process.send_after(self(), :dim, @dim_timeout)
    }

    if state.dimmed, do: undim(state), else: state
  end

  defp undim(state), do: panel(%{state | dimmed: false}, :undim)

  defp enter_page(state, :sensors), do: stream(state, @sensor_stream)
  defp enter_page(state, :tailscale), do: state |> enter_page(:clock) |> read_tailscale()

  defp enter_page(state, app) when app in [:timers, :stopwatch],
    do: state |> enter_page(:clock) |> schedule_app_tick()

  defp enter_page(%{sensor_port: nil} = state, _), do: stream(state, @idle_stream)
  defp enter_page(state, _), do: state

  # Drop the last readings on the way out: they would otherwise sit on the page
  # looking live when the stream that produced them is no longer running.
  defp leave_page(state, :sensors), do: %{stream(state, @idle_stream) | sensors: %{}}
  defp leave_page(state, :alarms), do: %{state | alarm_edit: nil}
  defp leave_page(state, _), do: state

  # tailscale CLI calls take a moment on this CPU, so they run beside the
  # viewport; the answer comes back as a message.
  defp read_tailscale(%{tailscale_read: nil} = state) do
    task =
      Task.async(fn ->
        try do
          Tailscale.info()
        catch
          :exit, _reason -> nil
        end
      end)

    %{state | tailscale_read: task.ref}
  end

  defp read_tailscale(state), do: state

  defp stream(state, sensors) do
    close_sensors(state.sensor_port)

    case Sensors.open(sensors) do
      {:ok, port} ->
        %{state | sensor_port: port, sensor_errors: %{}}

      {:error, reason} ->
        %{state | sensor_port: nil, sensor_errors: %{stream: inspect(reason)}}
    end
  end

  defp close_sensors(nil), do: :ok

  defp close_sensors(port) do
    if Port.info(port), do: Sensors.close(port)
  end

  defp handle_sensor(state, {:sensor, _port, event} = message) do
    case Sensors.sensor_from_event(event) do
      nil -> state
      sensor -> update_sensor(state, sensor, message)
    end
  end

  defp handle_sensor(state, {:sensor_error, _port, _reason, line}),
    do: put_in(state, [:sensor_errors, :stream], String.trim(line))

  defp handle_sensor(state, {:sensor_exit, _port, status}) do
    %{state | sensor_port: nil}
    |> put_in([:sensor_errors, :stream], "EXIT #{status}")
  end

  defp handle_sensor(state, _message), do: state

  defp update_sensor(state, :battery, {:sensor, _port, event}),
    do: %{state | battery: event["percent"]}

  defp update_sensor(state, sensor, {:sensor, _port, event}) do
    state
    |> put_in([:sensors, sensor], event)
    |> update_in([:sensor_errors], &Map.delete(&1, sensor))
  end

  defp queue_render(%{app: :sensors, on: true, render_timer: nil} = state),
    do: %{state | render_timer: Process.send_after(self(), :refresh, 200)}

  defp queue_render(state), do: state

  defp local_time(state) do
    now = DateTime.utc_now()

    case DateTime.shift_zone(now, state.time_zone) do
      {:ok, local} -> local
      {:error, _reason} -> now
    end
  end

  # While the access point is up, its name and passphrase to join it with.
  # Then each interface's address: its IPv4 one if it has one, as IPv6
  # addresses are too long to read at a useful size.
  @doc false
  def network_rows(nil), do: interface_rows()

  def network_rows(%{ssid: ssid, psk: psk}),
    do: [{"access point", ssid}, {"password", psk} | interface_rows()]

  defp interface_rows do
    case :inet.getifaddrs() do
      {:ok, ifs} ->
        for {name, attrs} <- ifs,
            addresses =
              attrs
              |> Keyword.get_values(:addr)
              |> Enum.reject(&(loopback?(&1) or link_local?(&1))),
            addresses != [],
            do:
              {to_string(name),
               :inet.ntoa(Enum.find(addresses, hd(addresses), &(tuple_size(&1) == 4)))}

      _ ->
        ["interfaces unavailable"]
    end
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      _ -> nil
    end
  end

  # fe80:: addresses are of no use to read.
  defp link_local?({0xFE80, _, _, _, _, _, _, _}), do: true
  defp link_local?(_), do: false

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false

  # Heart rate and motion, from the sensor hub.
  defp sensor_rows(state) do
    heart = state.sensors[:heart] || %{}
    accel = state.sensors[:accel] || %{}
    gyro = state.sensors[:gyro] || %{}

    [
      {:big, "heart rate", "#{number(heart["value"], 0)} bpm"},
      sensor_error(state, :heart),
      {"accel", xyz(accel)},
      sensor_error(state, :accel),
      {"gyro", xyz(gyro)},
      sensor_error(state, :gyro),
      stream_error(state)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp xyz(reading), do: Enum.map_join(["x", "y", "z"], "  ", &number(reading[&1], 2))

  defp stream_error(state) do
    case state.sensor_errors[:stream] do
      nil -> nil
      error -> {"stream", error}
    end
  end

  defp sensor_error(state, sensor) do
    case state.sensor_errors[sensor] do
      nil -> nil
      error -> {"", error}
    end
  end

  defp number(nil, _digits), do: "--"

  defp number(value, digits) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: digits)

  defp number(value, _digits), do: to_string(value)
end
