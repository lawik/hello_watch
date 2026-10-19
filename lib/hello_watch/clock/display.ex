defmodule HelloWatch.Clock.Display do
  @moduledoc """
  Puts the clock's frames on the panel, and turns the panel off and on.

  The clock is an Emerge viewport rendered headless on the CPU (see DISPLAY.md):
  each new frame arrives here as 454x454 RGBA8888, drawn with red and blue
  swapped (see HelloWatch.Clock.Palette), so its bytes are already the B, G,
  R, X that the MSM driver's fbdev emulation stores (32 bpp XRGB8888, rows
  padded to 32 pixels). A frame goes to the framebuffer as row copies, with
  no work per pixel. SimpleDRM's 24 bpp framebuffer needs the fourth byte
  dropped from each pixel, which is slow but still works.

  During a swipe the viewport renders as fast as it can; frames that queue
  up behind a slow write are skipped for the newest.

  Going dark fades the panel brightness down, then blanks the framebuffer,
  which powers the panel and display pipeline down with the MSM driver. The
  fade costs a few DCS brightness commands rather than a frame per step.
  Without a backlight (SimpleDRM) the screen blanks at once.

  Waking unblanks only once the next frame is on the framebuffer, so the
  panel never flashes the frame it went dark with, then fades back up.

  `dim/0` and `undim/0` fade between full and a lower brightness while the
  screen is on: the AMOLED's draw goes with how brightly its pixels are lit.
  """
  use GenServer

  @size 454
  @row_bytes @size * 4
  @fade_steps 10
  @fade_step_ms 50
  # Brightness while dimmed, as a fraction of full (squared, see set_level/2).
  @dim_level 0.5
  # A wake whose viewport renders nothing new still has to light the panel.
  @unblank_timeout_ms 250

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The process the viewport sends its frames to."
  def target(server \\ __MODULE__), do: GenServer.whereis(server)

  def sleep(server \\ __MODULE__), do: GenServer.cast(server, :sleep)
  def wake(server \\ __MODULE__), do: GenServer.cast(server, :wake)
  def dim(server \\ __MODULE__), do: GenServer.cast(server, {:awake_level, @dim_level})
  def undim(server \\ __MODULE__), do: GenServer.cast(server, {:awake_level, 1.0})

  @impl true
  def init(opts) do
    sysfs = Keyword.get(opts, :sysfs, "/sys/class/graphics/fb0")

    with {:ok, fb} <- open(Keyword.get(opts, :device, "/dev/fb0"), sysfs) do
      unbind_fbcon(Keyword.get(opts, :vtconsole, "/sys/class/vtconsole/vtcon*"))

      state = %{
        fb: fb,
        sysfs: sysfs,
        backlight: backlight(Keyword.get(opts, :backlight, "/sys/class/backlight/*")),
        level: 1.0,
        # The brightness to show while on; the fade in on wake goes to it.
        awake_level: 1.0,
        asleep: false,
        blanked: false,
        pending_unblank: false,
        gen: 0,
        last: nil
      }

      set_level(state.backlight, 1.0)
      set_blank(sysfs, "0")
      {:ok, state}
    else
      error -> {:stop, {:unsupported_framebuffer, error}}
    end
  end

  @impl true
  def handle_info(
        {:emerge_skia_frame,
         %VideoInterop.Frame{
           storage: %VideoInterop.Binary{data: data, planes: [%{stride: @row_bytes}]}
         }},
        state
      )
      when byte_size(data) == @row_bytes * @size do
    data = newest(data)

    if data != state.last,
      do: :ok = :file.pwrite(state.fb.fd, 0, encode(data, state.fb.bpp, state.fb.stride))

    state = %{state | last: data}
    {:noreply, if(state.pending_unblank, do: unblank(state), else: state)}
  end

  def handle_info({:unblank_timeout, gen}, %{gen: gen, pending_unblank: true} = state),
    do: {:noreply, unblank(state)}

  def handle_info({:fade, gen, target}, %{gen: gen} = state) do
    step = 1 / @fade_steps

    level =
      if target > state.level,
        do: min(target, state.level + step),
        else: max(target, state.level - step)

    set_level(state.backlight, level)
    state = %{state | level: level}

    cond do
      level != target -> {:noreply, fade(state, target)}
      target == 0 -> {:noreply, blank(state)}
      true -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast(:sleep, state) do
    state = %{state | gen: state.gen + 1, pending_unblank: false, asleep: true}

    cond do
      state.blanked -> {:noreply, state}
      state.backlight -> {:noreply, fade(state, 0)}
      true -> {:noreply, blank(state)}
    end
  end

  def handle_cast(:wake, state) do
    state = %{state | gen: state.gen + 1, asleep: false}

    if state.blanked do
      Process.send_after(self(), {:unblank_timeout, state.gen}, @unblank_timeout_ms)
      {:noreply, %{state | pending_unblank: true}}
    else
      # Woken partway through fading out: fade back up from here.
      {:noreply, fade_in(state)}
    end
  end

  # Asleep, the new level only applies on the next wake.
  def handle_cast({:awake_level, level}, %{asleep: true} = state),
    do: {:noreply, %{state | awake_level: level}}

  def handle_cast({:awake_level, level}, state) do
    state = %{state | awake_level: level, gen: state.gen + 1}
    {:noreply, if(state.blanked, do: state, else: fade(state, level))}
  end

  @impl true
  def terminate(_reason, state), do: :file.close(state.fb.fd)

  # The latest frame waiting in the mailbox, or `data` if there's none.
  defp newest(data) do
    receive do
      {:emerge_skia_frame,
       %VideoInterop.Frame{
         storage: %VideoInterop.Binary{data: next, planes: [%{stride: @row_bytes}]}
       }}
      when byte_size(next) == @row_bytes * @size ->
        newest(next)
    after
      0 -> data
    end
  end

  @doc false
  # Rows are sub-binaries of the frame, so the 32 bpp path copies nothing.
  def encode(frame, 32, @row_bytes), do: frame

  def encode(frame, 32, stride) do
    pad = :binary.copy(<<0>>, stride - @row_bytes)
    for <<row::binary-size(@row_bytes) <- frame>>, do: [row, pad]
  end

  def encode(frame, 24, stride) do
    pad = :binary.copy(<<0>>, stride - @size * 3)

    for <<row::binary-size(@row_bytes) <- frame>>,
      do: [for(<<b, g, r, _x <- row>>, into: <<>>, do: <<b, g, r>>), pad]
  end

  defp fade(state, target) do
    Process.send_after(self(), {:fade, state.gen, target}, @fade_step_ms)
    state
  end

  defp fade_in(%{backlight: nil} = state), do: %{state | level: state.awake_level}
  defp fade_in(state), do: fade(state, state.awake_level)

  defp blank(state) do
    set_blank(state.sysfs, "4")
    %{state | blanked: true}
  end

  # The panel comes back at the brightness it went dark with: zero when it
  # faded out, so the fade in starts from black.
  defp unblank(state) do
    set_blank(state.sysfs, "0")
    fade_in(%{state | blanked: false, pending_unblank: false})
  end

  defp set_blank(sysfs, value) do
    _ = File.write(Path.join(sysfs, "blank"), value)
    :ok
  end

  defp backlight(glob) do
    with [dir | _] <- Path.wildcard(glob),
         {:ok, value} <- File.read(Path.join(dir, "max_brightness")),
         {max, _} when max > 0 <- Integer.parse(value) do
      %{path: Path.join(dir, "brightness"), max: max}
    else
      _ -> nil
    end
  end

  defp set_level(nil, _level), do: :ok

  # Squared, so the fade looks even to the eye rather than dropping off late.
  defp set_level(backlight, level) do
    _ = File.write(backlight.path, Integer.to_string(round(backlight.max * level * level)))
    :ok
  end

  defp open(device, sysfs) do
    with {:ok, [width, height]} <- dimensions(sysfs),
         true <- width == @size and height >= @size,
         {:ok, bpp} <- integer_attribute(sysfs, "bits_per_pixel"),
         true <- bpp in [24, 32],
         {:ok, stride} <- integer_attribute(sysfs, "stride"),
         true <- stride >= @size * div(bpp, 8),
         {:ok, fd} <- :file.open(String.to_charlist(device), [:raw, :binary, :read, :write]) do
      {:ok, %{fd: fd, bpp: bpp, stride: stride}}
    end
  end

  # Stop the kernel console from painting over the clock.
  defp unbind_fbcon(glob) do
    for path <- Path.wildcard(glob) do
      case File.read(Path.join(path, "name")) do
        {:ok, name} ->
          if String.contains?(name, "frame buffer"),
            do: File.write(Path.join(path, "bind"), "0")

        _ ->
          :ok
      end
    end
  end

  defp dimensions(sysfs) do
    with {:ok, value} <- attribute(sysfs, "virtual_size") do
      {:ok, value |> String.split(",") |> Enum.map(&String.to_integer/1)}
    end
  end

  defp integer_attribute(sysfs, name) do
    with {:ok, value} <- attribute(sysfs, name), do: {:ok, String.to_integer(value)}
  end

  defp attribute(sysfs, name) do
    case File.read(Path.join(sysfs, name)) do
      {:ok, value} -> {:ok, String.trim(value)}
      error -> error
    end
  end
end
