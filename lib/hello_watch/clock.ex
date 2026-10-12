defmodule HelloWatch.Clock do
  @moduledoc """
  A moon-phase clock face, then battery, network, sensor and Tailscale
  pages, as an Emerge viewport. Time defaults to UTC.

  Pages follow the finger: the page being dragged is a disc, glowing at its
  edge, and the next page shows beneath it as a crescent that waxes as the
  disc moves away, like the moon. Letting go past halfway turns the page;
  short of that it springs back.

  On the watch the viewport renders headless with Emerge's CPU raster
  renderer and sends each new frame to `HelloWatch.Clock.Display`, which puts
  it on the framebuffer (see UI.md). Started with `display: nil` and
  `backend: :wayland` it opens a window instead, for working on the UI on a
  host.

  A frame is only rendered when something on screen changes: once a minute
  for the face, which has no second hand, every few seconds for the battery
  and network pages, and as readings arrive on the sensor page. Nothing
  renders while the screen is off.

  Left alone, the screen dims after `@dim_timeout`. A touch or swipe brings
  it back. After `@idle_timeout` the screen goes off and HelloWatch.Suspend
  may suspend the watch.
  """
  use Emerge
  require Logger

  alias HelloWatch.Clock.{BatteryPage, Display, Face, Moon, Pages, Palette, TailscalePage}
  alias HelloWatch.{Power, Sensors, Tailscale}

  @pages [:clock, :battery, :network, :sensors, :tailscale]
  @battery 1
  @network 2
  @sensors 3
  @tailscale 4

  # The hub delivers every event to a single reader, so one stream serves the
  # whole app: charge alone while the face is up, plus the rest on the sensor
  # page, and nothing while the screen is off. See HelloWatch.Sensors.open/1.
  @idle_stream [:battery]
  @sensor_stream [:battery, :heart, {:accel, 25}, {:gyro, 25}]

  @dim_timeout :timer.seconds(15)
  @idle_timeout :timer.minutes(2)
  @power_interval :timer.seconds(5)
  # How often the Tailscale page rereads tailscaled, to catch the login URL
  # appearing and the login completing.
  @tailscale_interval :timer.seconds(2)
  # How long a page takes to wane away on a swipe.
  # How long a page takes to slide all the way off, and how far a drag has
  # to go, in pixels, to turn the page when the finger lets go.
  @transition_ms 520
  @slide 480
  @commit_px 227
  # A drag that hasn't moved for this long is settled as if let go, in case
  # its release went missing.
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
      page: Enum.at(@pages, state.page),
      time_zone: state.time_zone,
      battery: state.battery,
      power: state.power,
      estimate: state.estimate
    }
  end

  @impl Viewport
  def mount(opts) do
    {config, opts} = Keyword.split(opts, [:display, :time_zone])
    display = Keyword.get(config, :display, Display)
    # The framebuffer takes the renderer's bytes as they are; see Palette.
    Palette.bgr(display != nil)

    power = Power.read()

    state =
      %{
        display: display,
        on: true,
        dimmed: false,
        page: 0,
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
        # How far a finger has dragged the page, while it's down.
        drag: nil,
        drag_timer: nil,
        # The page sliding off or back after a drag lets go: %{top:, below:,
        # from:, to:, n:}.
        moving: nil,
        transitions: 0
      }
      |> schedule_tick()
      |> schedule_power()
      |> stream(@idle_stream)
      |> start_idle_timer()

    {:ok, state, Keyword.merge(viewport(display), opts)}
  end

  defp viewport(nil) do
    [
      otp_app: :hello_watch,
      title: "HelloWatch",
      width: 454,
      height: 454,
      assets: [fonts: @fonts]
    ]
  end

  defp viewport(display) do
    viewport(nil) ++
      [
        backend: :headless,
        rendering_api: :raster,
        headless: [mode: :binary, target: display.target(), pixel_format: :rgba8888]
      ]
  end

  @impl Viewport
  def render(state) do
    {below, top} =
      cond do
        state.drag != nil ->
          {neighbour(state, state.drag),
           held(page(state, state.page), state.drag, state.transitions)}

        state.moving != nil ->
          {state.moving.below, sliding(page(state, state.moving.top), state.moving)}

        true ->
          {state.page, nil}
      end

    # Emerge's own gestures, for a windowed host; on the watch, drags come
    # from HelloWatch.Clock.Touch.
    el(
      [
        width(px(454)),
        height(px(454)),
        Event.on_swipe_left({:swipe, :left}),
        Event.on_swipe_right({:swipe, :right})
      ] ++ if(top, do: [Nearby.in_front(top)], else: []),
      page(state, below)
    )
  end

  defp page(state, 0) do
    Face.render(local_time(state), Moon.phase(DateTime.utc_now()), battery(state))
  end

  defp page(state, @battery), do: BatteryPage.render(battery(state), @battery)
  defp page(_state, @network), do: Pages.render("Network", network_rows(), @network)
  defp page(state, @sensors), do: Pages.render("Sensors", sensor_rows(state), @sensors)
  defp page(state, @tailscale), do: TailscalePage.render(state.tailscale, @tailscale)

  # The page under the finger is a full disc, moonlight at its edge, that
  # moves with the drag. The round panel shows only where it still overlaps,
  # a lens that thins as it goes, so the page beneath appears as a crescent
  # with a concave edge that waxes to full, like the moon.
  defp held(tree, dx, n), do: el(disc_attrs({:held, n}) ++ [Transform.move_x(dx)], tree)

  # Let go, the disc carries on off the panel or springs back, from where
  # the finger left it. A new key for each one animates it from the start.
  defp sliding(tree, moving) do
    ms = Kernel.max(round(@transition_ms * abs(moving.to - moving.from) / @slide), 120)

    el(
      disc_attrs({:sliding, moving.n}) ++
        [
          Transform.move_x(moving.to),
          Animation.animate_enter(
            [[Transform.move_x(moving.from)], [Transform.move_x(moving.to)]],
            ms,
            :ease_out
          )
        ],
      tree
    )
  end

  defp disc_attrs(key) do
    [
      key(key),
      width(px(454)),
      height(px(454)),
      Border.rounded(227),
      Border.glow(Palette.c(:lilac, 0.5), 10)
    ]
  end

  # Dragging left brings in the next page, right the previous one.
  defp neighbour(state, dx) do
    step = if dx <= 0, do: 1, else: -1
    Integer.mod(state.page + step, length(@pages))
  end

  @impl Viewport
  # The tick stops once the screen is off, so a dark watch never wakes the
  # BEAM just to skip a frame; wake/1 restarts it.
  def handle_info({:tick, ref}, %{tick_ref: ref, on: true} = state) do
    state = schedule_tick(state)
    {:noreply, if(state.page == 0, do: Viewport.rerender(state), else: state)}
  end

  def handle_info({:tick, ref}, %{tick_ref: ref} = state),
    do: {:noreply, %{state | tick_ref: nil}}

  def handle_info({:power, ref}, %{power_ref: ref, on: true} = state) do
    state = schedule_power(read_power(state))
    # The face redraws every second anyway; the network page has no tick.
    {:noreply, if(state.page in [@battery, @network], do: Viewport.rerender(state), else: state)}
  end

  def handle_info({:power, ref}, %{power_ref: ref} = state),
    do: {:noreply, %{state | power_ref: nil}}

  def handle_info(:refresh, state) do
    state = %{state | render_timer: nil}
    {:noreply, if(state.on, do: Viewport.rerender(state), else: state)}
  end

  def handle_info(:toggle_display, state) do
    now = System.monotonic_time(:millisecond)

    if state.last_press == nil or now - state.last_press >= 250 do
      state = %{state | last_press: now}
      {:noreply, if(state.on, do: sleep(state), else: wake(state))}
    else
      {:noreply, state}
    end
  end

  # Tapping the Tailscale page while logged out starts a login; its QR code
  # shows once tailscaled has a URL.
  def handle_info(
        :tap,
        %{on: true, page: @tailscale, tailscale: %{state: "NeedsLogin", logging_in: false}} =
          state
      ) do
    try do
      Tailscale.login()
    catch
      :exit, reason -> Logger.warning("Tailscale login: #{inspect(reason)}")
    end

    {:noreply, read_tailscale(state)}
  end

  def handle_info(:tap, state), do: {:noreply, state}

  def handle_info({:tailscale, ref}, %{tailscale_ref: ref, on: true, page: @tailscale} = state),
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

      state.on and state.page == @tailscale ->
        {:noreply, Viewport.rerender(%{state | tailscale: info})}

      true ->
        {:noreply, %{state | tailscale: info}}
    end
  end

  def handle_info(:touch, %{on: true} = state), do: {:noreply, start_idle_timer(state)}
  def handle_info(:touch, state), do: {:noreply, wake(state)}

  def handle_info(:dim, %{on: true, dimmed: false} = state) do
    if state.display, do: state.display.dim()

    {:noreply, %{state | dimmed: true, dim_timer: nil}}
  end

  def handle_info(:dim, state), do: {:noreply, state}

  def handle_info(:screen_timeout, %{on: true} = state), do: {:noreply, sleep(state)}
  def handle_info(:screen_timeout, state), do: {:noreply, state}

  def handle_info({:swipe, _direction}, %{on: false} = state), do: {:noreply, state}

  # A swipe in a host window turns the page in one go.
  def handle_info({:swipe, direction}, state) when direction in [:left, :right],
    do: {:noreply, turn(state, if(direction == :left, do: -1, else: 1), 0)}

  def handle_info({:drag, _dx}, %{on: false} = state), do: {:noreply, state}

  def handle_info({:drag, dx}, state) do
    if state.drag_timer, do: Process.cancel_timer(state.drag_timer)
    dx = latest_drag(dx)
    timer = Process.send_after(self(), {:drag_timeout, dx}, @drag_timeout)
    {:noreply, Viewport.rerender(%{state | drag: dx, drag_timer: timer, moving: nil})}
  end

  def handle_info({:drag_timeout, dx}, %{drag: dx} = state),
    do: handle_info({:release, dx}, state)

  def handle_info({:drag_timeout, _dx}, state), do: {:noreply, state}

  def handle_info({:release, _dx}, %{on: false} = state),
    do: {:noreply, cancel_drag_timer(%{state | drag: nil})}

  def handle_info({:release, dx}, state) do
    state = cancel_drag_timer(%{state | drag: nil})

    if abs(dx) >= @commit_px,
      do: {:noreply, turn(state, dx, dx)},
      else: {:noreply, slide(state, state.page, neighbour(state, dx), dx, 0)}
  end

  # The sliding page is off the panel, or back in place, by now.
  def handle_info({:moved, n}, %{moving: %{n: n}} = state),
    do: {:noreply, Viewport.rerender(%{state | moving: nil})}

  def handle_info({:moved, _n}, state), do: {:noreply, state}

  def handle_info({port, _payload} = message, %{sensor_port: port} = state)
      when is_port(port) do
    {:noreply, queue_render(handle_sensor(state, Sensors.decode(port, message)))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Turns to the page `direction` points to (negative is the next page),
  # sliding the current one off from `from`.
  defp turn(state, direction, from) do
    old = state.page
    next = neighbour(state, direction)
    to = if direction <= 0, do: -@slide, else: @slide

    state
    |> leave_page(old)
    |> Map.put(:page, next)
    |> enter_page(next)
    |> start_idle_timer()
    |> slide(old, next, from, to)
  end

  defp slide(state, top, below, from, to) do
    n = state.transitions + 1
    ms = Kernel.max(round(@transition_ms * abs(to - from) / @slide), 120)
    Process.send_after(self(), {:moved, n}, ms + 80)
    moving = %{top: top, below: below, from: from, to: to, n: n}
    Viewport.rerender(%{state | moving: moving, transitions: n})
  end

  defp cancel_drag_timer(%{drag_timer: nil} = state), do: state

  defp cancel_drag_timer(state) do
    Process.cancel_timer(state.drag_timer)
    %{state | drag_timer: nil}
  end

  # Drags queue up while a frame renders; only the newest position matters.
  defp latest_drag(dx) do
    receive do
      {:drag, next} -> latest_drag(next)
    after
      0 -> dx
    end
  end

  defp sleep(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    if state.dim_timer, do: Process.cancel_timer(state.dim_timer)
    close_sensors(state.sensor_port)
    if state.display, do: state.display.sleep()
    HelloWatch.Suspend.screen_off()

    %{state | on: false, idle_timer: nil, dim_timer: nil, sensor_port: nil, sensors: %{}}
  end

  defp wake(state) do
    state =
      %{state | on: true}
      |> read_power(restart: true)
      |> enter_page(state.page)
      |> start_idle_timer()
      |> ensure_ticking()
      |> Viewport.rerender()

    if state.display, do: state.display.wake()
    HelloWatch.Suspend.screen_on()
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

  defp undim(state) do
    if state.display, do: state.display.undim()
    %{state | dimmed: false}
  end

  defp enter_page(state, @sensors), do: stream(state, @sensor_stream)
  defp enter_page(state, @tailscale), do: state |> enter_page(0) |> read_tailscale()
  defp enter_page(%{sensor_port: nil} = state, _), do: stream(state, @idle_stream)
  defp enter_page(state, _), do: state

  # Drop the last readings on the way out: they would otherwise sit on the page
  # looking live when the stream that produced them is no longer running.
  defp leave_page(state, @sensors), do: %{stream(state, @idle_stream) | sensors: %{}}
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

  defp queue_render(%{page: @sensors, on: true, render_timer: nil} = state),
    do: %{state | render_timer: Process.send_after(self(), :refresh, 200)}

  defp queue_render(state), do: state

  defp local_time(state) do
    now = DateTime.utc_now()

    case DateTime.shift_zone(now, state.time_zone) do
      {:ok, local} -> local
      {:error, _reason} -> now
    end
  end

  # The watch's hostname and addresses.
  defp network_rows do
    hostname =
      case :inet.gethostname() do
        {:ok, name} -> to_string(name)
        _ -> "unknown"
      end

    interfaces =
      case :inet.getifaddrs() do
        {:ok, ifs} ->
          Enum.flat_map(ifs, fn {name, attrs} ->
            attrs
            |> Keyword.get_values(:addr)
            |> Enum.reject(&(loopback?(&1) or link_local?(&1)))
            |> Enum.map(&(:inet.ntoa(&1) |> to_string()))
            |> Enum.with_index()
            |> Enum.map(fn {address, i} ->
              {if(i == 0, do: to_string(name), else: ""), address}
            end)
          end)

        _ ->
          ["interfaces unavailable"]
      end

    [{"hostname", hostname}, ""] ++ interfaces
  end

  # fe80:: addresses are too long for the round page and of no use to read.
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
      {"heart rate", "#{number(heart["value"], 0)} bpm"},
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
