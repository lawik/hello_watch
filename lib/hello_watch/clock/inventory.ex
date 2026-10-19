defmodule HelloWatch.Clock.Inventory do
  @moduledoc """
  Looking inward: a dark circle that swells up from the bottom edge as it's
  pulled up, holding the things the watch is for, each a small moon in a
  ring. A tap on one opens it.
  """
  use Emerge.UI

  alias HelloWatch.Clock.Palette

  @center 227
  # The full circle just covers the round panel.
  @radius 240
  @ring 124
  @token 56
  # A tap within this many pixels of a token hits it.
  @reach 50

  # Each app's icon is priv/images/app-<app>.svg, lit in its tint.
  @tints %{
    clock: :bone,
    alarms: :candle,
    timers: :teal,
    stopwatch: :moss,
    battery: :teal,
    network: :moss,
    sensors: :rose,
    moon: :candle,
    tailscale: :lilac
  }

  @doc """
  The circle at `scale` (0 is closed, 1 open), with `apps` in a ring from
  twelve o'clock and `current` marked. With `ms`, it eases to `scale` from
  wherever it is on screen.
  """
  def render(apps, current, scale, ms \\ nil) do
    size = 2 * @radius
    growth = [key(:inventory)] ++ HelloWatch.Clock.eased(grown(scale), ms) ++ hidden(scale, ms)

    el(
      [
        width(px(size)),
        height(px(size)),
        Transform.move_x(@center - @radius),
        Border.rounded(@radius),
        Background.color(Palette.gradient([:midnight, :abyss], 180)),
        clip_nearby()
      ] ++ growth ++ Enum.map(items(apps, current), &Nearby.in_front/1),
      none()
    )
  end

  # Closed and still, the circle isn't drawn at all, though it stays mounted.
  defp hidden(scale, nil) when scale <= 0, do: [Transform.alpha(0)]
  defp hidden(_scale, _ms), do: []

  # The circle at `scale`: it grows about its centre, which rises from the
  # panel's bottom edge to the middle as it does, so it swells up from below.
  # At a scale much below 0.01 Emerge (main) never draws it again as it grows.
  defp grown(scale) do
    scale = Kernel.max(scale, 0.01)
    [Transform.scale(scale), Transform.move_y(round(@center - @radius + (1 - scale) * @center))]
  end

  @doc "The app whose token is nearest `{x, y}` on the panel, among `apps`, or nil."
  def hit(apps, {x, y}) do
    {app, distance} =
      apps
      |> positions()
      |> Enum.map(fn {app, {px, py}} -> {app, :math.sqrt((x - px) ** 2 + (y - py) ** 2)} end)
      |> Enum.min_by(&elem(&1, 1))

    if distance <= @reach, do: app
  end

  # Token centres on the panel, round the ring from twelve o'clock.
  defp positions(apps) do
    count = length(apps)

    apps
    |> Enum.with_index()
    |> Enum.map(fn {app, i} ->
      angle = 2 * :math.pi() * i / count
      {app, {@center + @ring * :math.sin(angle), @center - @ring * :math.cos(angle)}}
    end)
  end

  defp items(apps, current) do
    Enum.flat_map(positions(apps), fn {app, {x, y}} ->
      # Positions inside the circle, whose corner sits off the panel.
      {lx, ly} = {x - @center + @radius, y - @center + @radius}

      icon =
        svg(
          [width(px(@token)), height(px(@token)), Svg.color(Palette.c(tint(app)))],
          "images/app-#{app}.svg"
        )

      [place(icon, lx, ly, @token)] ++ if(app == current, do: [mark(lx, ly)], else: [])
    end)
  end

  defp tint(app), do: Map.get(@tints, app, :bone)

  # The app shown now: a small dot under its icon.
  defp mark(x, y),
    do:
      place(
        el(
          [width(px(5)), height(px(5)), Border.rounded(2.5), Background.color(Palette.c(:lilac))],
          none()
        ),
        x,
        y + @token / 2 + 4,
        5
      )

  defp place(child, x, y, size),
    do: el([padding_each(round(y - size / 2), 0, 0, round(x - size / 2))], child)
end
