defmodule HelloWatch.Clock.StopwatchApp do
  @moduledoc """
  A stopwatch to the hundredth of a second. A tap on the time or the button
  starts and stops it; reset clears a stopped one. It's counted in
  monotonic milliseconds, as `%{since:, total:}`: when it last started, if
  it's running, and the time run before that.

  While it runs, HelloWatch.Clock keeps the screen on and bright, so the
  watch never suspends under it, and redraws it about 25 times a second
  while it's shown.
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Pages, Palette, Widgets}

  @button {167, 306, 120, 54}

  def new, do: %{since: nil, total: 0}

  def running?(%{since: since}), do: since != nil

  @doc "The milliseconds on the stopwatch at monotonic time `now`."
  def elapsed(%{since: nil, total: total}, _now), do: total
  def elapsed(%{since: since, total: total}, now), do: total + now - since

  def render(stopwatch, now),
    do: Pages.page("Stopwatch", Widgets.surface(layout(stopwatch, now)), :stopwatch)

  @doc "The stopwatch after a tap at `at`, at monotonic time `now`."
  def tap(stopwatch, at, now) do
    case Widgets.hit(layout(stopwatch, now), at) do
      :toggle -> toggle(stopwatch, now)
      :reset -> new()
      nil -> stopwatch
    end
  end

  defp toggle(%{since: nil} = stopwatch, now), do: %{stopwatch | since: now}
  defp toggle(stopwatch, now), do: %{since: nil, total: elapsed(stopwatch, now)}

  defp layout(stopwatch, now) do
    ms = elapsed(stopwatch, now)
    {x, y, w, h} = @button

    buttons =
      cond do
        running?(stopwatch) ->
          [{:toggle, @button, Widgets.pill("stop", :rose)}]

        ms == 0 ->
          [{:toggle, @button, Widgets.pill("start", :moss)}]

        true ->
          [
            {:reset, {x - 72, y, w, h}, Widgets.pill("reset", :lilac)},
            {:toggle, {x + 72, y, w, h}, Widgets.pill("start", :moss)}
          ]
      end

    [{:toggle, {47, 150, 360, 120}, time(ms, running?(stopwatch))} | buttons]
  end

  # Minutes and seconds large, hundredths beside them; hours once there
  # are any.
  defp time(ms, running?) do
    seconds = div(ms, 1000)
    hundredths = Widgets.pad(div(rem(ms, 1000), 10))
    size = if seconds >= 3600, do: 64, else: 84
    color = if running? or ms == 0, do: Palette.c(:bone), else: Palette.c(:candle)

    row([center_x(), center_y()], [
      Widgets.digits(Widgets.duration(seconds), size, round(size * 0.52), color),
      Widgets.digits(
        "." <> hundredths,
        div(size, 2),
        round(size * 0.27),
        Palette.c(:lilac),
        [align_bottom(), padding_each(0, 0, round(size * 0.12), 0)]
      )
    ])
  end
end
