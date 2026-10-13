defmodule HelloWatch.Clock.Sky do
  @moduledoc """
  The sky above every view, pulled down into sight: the watch's global
  switches as constellations drawn in the shape of their icons. One glows
  when its switch is on and is dim when it's off; a tap on it flips it (see
  HelloWatch.Clock.Controls).
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Backdrop, Palette}

  @size 454
  # Each constellation (priv/images/sky-<id>-<on|off>.svg) is this square.
  @figure 180
  # A tap within this many pixels of a bright star hits it.
  @reach 70
  # The cloud along the lower edge (priv/images/edge-sky.svg): its height,
  # and where the edge is in it.
  @fringe 220
  @fringe_edge 90
  # The mist over it (priv/images/mist-sky.svg), and where the edge is in it.
  @mist 230
  @mist_edge 70

  # Where each switch's constellation is centred.
  @constellations %{
    wifi: {138, 172},
    bluetooth: {316, 172},
    tailscale: {227, 320}
  }

  # Faint background stars, fixed so the sky doesn't shimmer between frames.
  @dust (
          :rand.seed(:exsss, {7, 11, 13})

          for _ <- 1..44 do
            {:rand.uniform(420) + 16, :rand.uniform(420) + 16, Enum.random([1.5, 2, 2, 3]),
             Enum.random([0.25, 0.35, 0.5])}
          end
        )

  @doc "`controls` is `HelloWatch.Clock.Controls.read/1`, or `nil` before the first read."
  def render(controls) do
    by_id = Map.new(controls || [], &{&1.id, &1})

    layers =
      Backdrop.layers(:sky) ++
        dust() ++
        Enum.map(@constellations, fn {id, {x, y}} ->
          place(constellation(id, match?(%{on: true}, by_id[id])), x, y, @figure)
        end)

    sky =
      el(
        [width(px(@size)), height(px(@size)), Backdrop.background(), clip_nearby()] ++
          Enum.map(layers, &Nearby.in_front/1),
        none()
      )

    el([width(px(@size)), height(px(@size)), Nearby.below(fringe())], sky)
  end

  # The sky's lower edge, soft: a mist of its darkest blue over the edge,
  # fading out into the sky and down over whatever it's pulled over, and a
  # line of cloud along the edge itself.
  # It hangs below the sky, outside its clip, and moves with it.
  defp fringe do
    el(
      [
        width(px(@size)),
        height(px(@mist - @mist_edge)),
        Nearby.in_front(fringe_svg("images/mist-sky.svg", @mist, -@mist_edge, Palette.c(:abyss))),
        Nearby.in_front(
          fringe_svg("images/edge-sky.svg", @fringe, -@fringe_edge, Palette.c(:blue, 0.6))
        )
      ],
      none()
    )
  end

  defp fringe_svg(source, height, y, color),
    do:
      svg(
        [width(px(@size)), height(px(height)), Transform.move_y(y), Svg.color(color)],
        source
      )

  @doc "The switch whose star is at `{x, y}`, or nil."
  def hit({x, y}) do
    Enum.find_value(@constellations, fn {id, {sx, sy}} ->
      if :math.sqrt((x - sx) ** 2 + (y - sy) ** 2) <= @reach, do: id
    end)
  end

  defp dust do
    for {x, y, size, alpha} <- @dust do
      place(
        el(
          [
            width(px(size)),
            height(px(size)),
            Border.rounded(size / 2),
            Background.color(Palette.c(:bone, alpha))
          ],
          none()
        ),
        x,
        y,
        size
      )
    end
  end

  # Its lines, a glow behind its stars and the stars
  # (priv/images/sky-<id>-<layer>.svg), lit when on and dim when off.
  defp constellation(id, on) do
    {lines, glow, stars} =
      if on,
        do: {Palette.c(:lilac, 0.55), Palette.c(:candle, 0.9), Palette.c(:bone)},
        else: {Palette.c(:dusk, 0.35), Palette.c(:dusk, 0.2), Palette.c(:dusk, 0.85)}

    layer = fn name, color ->
      svg(
        [width(px(@figure)), height(px(@figure)), Svg.color(color)],
        "images/sky-#{id}-#{name}.svg"
      )
    end

    el(
      [
        width(px(@figure)),
        height(px(@figure)),
        Nearby.in_front(layer.("glow", glow)),
        Nearby.in_front(layer.("stars", stars))
      ],
      layer.("lines", lines)
    )
  end

  defp place(child, x, y, size),
    do: el([padding_each(round(y - size / 2), 0, 0, round(x - size / 2))], child)
end
