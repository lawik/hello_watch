defmodule HelloWatch.Clock.TimersApp do
  @moduledoc """
  Countdown timers (HelloWatch.Timers): a tap on a preset starts one, any
  number can run at once, and a tap on a running one cancels it. The three
  soonest are listed, counting down; HelloWatch.Clock redraws the view each
  second while one runs.
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Pages, Palette, Widgets}
  alias HelloWatch.Timers

  @presets [60, 180, 300, 600, 900, 1800]
  @shown 3

  def render(timers, now) do
    caption =
      cond do
        timers == [] -> "tap one to start"
        length(timers) > @shown -> "#{length(timers) - @shown} more running"
        true -> "tap a timer to cancel it"
      end

    Pages.page("Timers", Widgets.surface(layout(timers, now)), :timers, caption)
  end

  @doc "The timers running, soonest first, or none if the service isn't up."
  def timers, do: Widgets.call(&Timers.list/0, [])

  @doc "Starts or cancels the timer tapped at `at`."
  def tap(timers, at) do
    case Widgets.hit(layout(timers, DateTime.utc_now()), at) do
      {:start, seconds} -> Widgets.call(fn -> Timers.start(seconds) end, nil)
      {:cancel, id} -> Widgets.call(fn -> Timers.cancel(id) end, nil)
      nil -> nil
    end
  end

  defp layout(timers, now) do
    rows =
      timers
      |> Enum.take(@shown)
      |> Enum.with_index()
      |> Enum.map(fn {timer, i} ->
        {{:cancel, timer.id}, {87, 100 + i * 54, 280, 48}, timer_row(timer, now)}
      end)

    top = if timers == [], do: 168, else: 270

    presets =
      @presets
      |> Enum.with_index()
      |> Enum.map(fn {seconds, i} ->
        rect = {97 + rem(i, 3) * 90, top + div(i, 3) * 58, 80, 48}
        {{:start, seconds}, rect, Widgets.pill("#{div(seconds, 60)}m", :teal)}
      end)

    rows ++ presets
  end

  defp timer_row(timer, now) do
    left = Kernel.max(ceil(DateTime.diff(timer.ends, now, :millisecond) / 1000), 0)

    el(
      [
        width(fill()),
        height(fill()),
        Border.rounded(24),
        Background.color(Palette.c(:teal, 0.14)),
        padding_each(0, 20, 0, 22)
      ],
      row([width(fill()), center_y(), spacing(10)], [
        Widgets.digits(Widgets.duration(left), 34, 18, Palette.c(:bone), [center_y()]),
        el(
          [
            center_y(),
            Font.family("Alegreya Sans"),
            Font.italic(),
            Font.size(18),
            Font.color(Palette.c(:lilac))
          ],
          text(set_for(timer.seconds))
        ),
        el(
          [
            align_right(),
            center_y(),
            Font.family("Alegreya Sans"),
            Font.size(26),
            Font.color(Palette.c(:rose, 0.8))
          ],
          text("×")
        )
      ])
    )
  end

  defp set_for(seconds) when rem(seconds, 60) == 0, do: "from #{div(seconds, 60)} min"
  defp set_for(seconds), do: "from #{Widgets.duration(seconds)}"
end
