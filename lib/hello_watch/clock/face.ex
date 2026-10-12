defmodule HelloWatch.Clock.Face do
  @moduledoc """
  The witch's clock: a night sky with the twelve phases of the moon for
  hours, tonight's real moon glowing among them, the day by its old name, a
  star-tipped wand for the minute hand, and the battery's charge faint
  behind the hands.

  Hands and markers are full-face layers rotated about the centre: a piece
  placed at twelve o'clock in a 454x454 box, turned by `Transform.rotate/1`.
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Moon, Palette}

  @size 454
  @center div(@size, 2)
  @marker_radius 188
  @battery_low 20

  # A few fixed stars, {x, y, size, alpha}: scattered, clear of the hands'
  # hub and the flask.
  @stars [
    {96, 168, 3, 0.7},
    {132, 118, 2, 0.5},
    {318, 112, 3, 0.6},
    {360, 170, 2, 0.5},
    {104, 262, 2, 0.45},
    {352, 286, 3, 0.55},
    {150, 356, 2, 0.4},
    {300, 362, 2, 0.45},
    {200, 84, 2, 0.5},
    {270, 196, 2, 0.35}
  ]
  @sparkles [{116, 214, 13, 10}, {338, 236, 10, -12}, {262, 82, 9, 20}]

  @days {"Moon's day", "Tiw's day", "Woden's day", "Thor's day", "Frigg's day", "Saturn's day",
         "Sun's day"}

  @doc """
  `time` is local, `moon` the real moon's phase (`Moon.phase/1`), and
  `battery` `%{percent: 0..100, status: :battery | :charging | :full}`, or
  `nil` when the watch can't tell.

  There's no second hand: the minute hand sits on the minute, and the face
  redraws once a minute.
  """
  def render(time, moon, battery) do
    hours = rem(time.hour, 12) + time.minute / 60

    layers =
      [charge(battery)] ++
        stars() ++
        markers(moon) ++
        [
          day(time),
          hand(hours / 12, 9, 14, 104, :bone, tip(:lilac, 9)),
          hand(time.minute / 60, 5, 20, 156, :bone, Moon.sparkle(18, :bone)),
          hub()
        ]

    el(
      [
        width(px(@size)),
        height(px(@size)),
        Background.color(Palette.gradient([:night, :midnight], 180))
      ] ++ Enum.map(layers, &Nearby.in_front/1),
      none()
    )
  end

  defp stars do
    dots =
      for {x, y, size, alpha} <- @stars do
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

    sparkles =
      for {x, y, size, tilt} <- @sparkles,
          do: place(Moon.sparkle(size, :lilac, [], tilt), x, y, size)

    dots ++ sparkles
  end

  # The twelve phases around the dial, full at twelve and new at six; the
  # one closest to the real moon is bigger and glows like a candle.
  defp markers(moon) do
    tonight = rem(round(moon * 12) + 6, 12)

    minute_dots =
      for minute <- 0..59, rem(minute, 5) != 0 do
        on_radius(minute / 60, @marker_radius + 12, 2, el(dot_attrs(2, :dusk), none()))
      end

    moons =
      for hour <- 0..11 do
        phase = rem(hour + 6, 12) / 12

        {size, attrs} =
          if hour == tonight,
            do: {30, [Border.glow(Palette.c(:candle, 0.55), 6)]},
            else: {20, []}

        on_radius(hour / 12, @marker_radius, size, Moon.disc(phase, size, attrs: attrs))
      end

    minute_dots ++ moons
  end

  defp dot_attrs(size, color),
    do: [
      width(px(size)),
      height(px(size)),
      Border.rounded(size / 2),
      Background.color(Palette.c(color))
    ]

  # Places `child`, `size` px square, centred on the circle of `radius` at
  # `turn` of the way round from twelve, kept upright.
  defp on_radius(turn, radius, size, child) do
    angle = turn * 2 * :math.pi()
    place(child, @center + radius * :math.sin(angle), @center - radius * :math.cos(angle), size)
  end

  defp place(child, x, y, size) do
    el(
      [Transform.move_x(x - size / 2), Transform.move_y(y - size / 2)],
      child
    )
  end

  defp day(%{year: _} = time) do
    weekday = Date.day_of_week(time)

    el(
      [width(px(@size)), padding_each(118, 0, 0, 0)],
      el(
        [center_x(), Font.family("Macondo"), Font.size(20), Font.color(Palette.c(:lilac))],
        text("#{elem(@days, weekday - 1)} · #{time.day}")
      )
    )
  end

  defp day(_time), do: none()

  # `back` is how far the hand reaches past the centre; `tip` sits at its end.
  defp hand(turn, thickness, back, length, color, tip) do
    el(
      [width(px(@size)), height(px(@size)), Transform.rotate(turn * 360)],
      el(
        [
          width(px(thickness)),
          height(px(length + back)),
          Transform.move_x(@center - thickness / 2),
          Transform.move_y(@center - length),
          Background.color(Palette.c(color)),
          Border.rounded(thickness / 2),
          Nearby.above(el([center_x(), Transform.move_y(tip_offset(tip))], tip))
        ],
        none()
      )
    )
  end

  defp tip(color, size), do: el(dot_attrs(size, color), none())

  # Tips overlap the hand's end by half their height.
  defp tip_offset(_tip), do: 8

  # A crescent moon at the hub, the hands' pivot.
  defp hub do
    place(
      Moon.disc(0.2, 18,
        lit: :candle,
        dark: :night,
        attrs: [Border.glow(Palette.c(:candle, 0.4), 3)]
      ),
      @center,
      @center,
      18
    )
  end

  # The charge, large and faint behind the hands; the battery page has the
  # details.
  defp charge(nil), do: none()

  defp charge(%{percent: percent}) do
    color = if percent <= @battery_low, do: Palette.c(:rose, 0.22), else: Palette.c(:bone, 0.1)

    el(
      [width(px(@size)), padding_each(250, 0, 0, 0)],
      el(
        [center_x(), Font.family("Macondo"), Font.size(96), Font.color(color)],
        text("#{percent}%")
      )
    )
  end
end
