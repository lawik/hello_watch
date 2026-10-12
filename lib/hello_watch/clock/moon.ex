defmodule HelloWatch.Clock.Moon do
  @moduledoc """
  Moons and sparkles, the ornaments of the face and pages.

  `phase/1` is the real moon's age for a moment, as a fraction of the
  synodic month: 0 is new, 0.5 full. `disc/3` draws a moon at any phase from
  two overlapping discs clipped to a circle: a crescent is a lit moon with a
  dark disc slid over it, a gibbous a dark moon with a lit disc slid in, so
  the terminator curves the right way on both sides of half.
  """
  use Emerge.UI

  alias HelloWatch.Clock.Palette

  @synodic_days 29.530588853
  # A new moon: 2000-01-06 18:14 UTC.
  @known_new ~U[2000-01-06 18:14:00Z]

  @doc "The moon's phase at `time`, from 0 (new) through 0.5 (full) to 1."
  def phase(%DateTime{} = time) do
    days = DateTime.diff(time, @known_new, :second) / 86_400
    cycles = days / @synodic_days
    cycles - Float.floor(cycles)
  end

  @doc "How much of the moon's face is lit at `phase`, from 0 to 1."
  def lit(phase), do: (1 - :math.cos(2 * :math.pi() * phase)) / 2

  @doc """
  A moon `size` px across at `phase`. Waxing moons are lit on the right, as
  seen from the northern hemisphere. Options: `:lit` and `:dark` palette
  names, and `:attrs` for the moon's own element (position, glow).
  """
  def disc(phase, size, opts \\ []) do
    lit = Palette.c(Keyword.get(opts, :lit, :bone))
    dark = Palette.c(Keyword.get(opts, :dark, :shadow))
    attrs = Keyword.get(opts, :attrs, [])
    amount = lit(phase)
    # +1 slides towards the right, the lit side of a waxing moon.
    side = if phase < 0.5, do: 1, else: -1

    {base, inner} =
      cond do
        amount < 0.03 ->
          {dark, none()}

        amount > 0.97 ->
          {lit, none()}

        abs(amount - 0.5) < 0.06 ->
          {dark, half(size, lit, side)}

        amount < 0.5 ->
          {lit, slid(size, dark, -side * size * amount * 1.15)}

        true ->
          {dark, slid(size, lit, side * size * (1 - amount) * 1.15)}
      end

    el(
      [
        width(px(size)),
        height(px(size)),
        Border.rounded(size / 2),
        Background.color(base),
        clip_nearby(),
        Nearby.in_front(inner)
      ] ++ attrs,
      none()
    )
  end

  defp slid(size, color, by) do
    el(
      [
        width(px(size)),
        height(px(size)),
        Border.rounded(size / 2),
        Background.color(color),
        Transform.move_x(by)
      ],
      none()
    )
  end

  defp half(size, color, side) do
    el(
      [
        width(px(size / 2)),
        height(px(size)),
        Transform.move_x(if(side > 0, do: size / 2, else: 0)),
        Background.color(color)
      ],
      none()
    )
  end

  @doc "A four-pointed sparkle `size` px across, tilted by `tilt` degrees."
  def sparkle(size, color, attrs \\ [], tilt \\ 0) do
    ray = fn long, short ->
      el(
        [
          width(px(long)),
          height(px(short)),
          center_x(),
          center_y(),
          Border.rounded(Kernel.min(long, short) / 2),
          Background.color(Palette.c(color))
        ],
        none()
      )
    end

    thickness = Kernel.max(size / 7, 1.5)

    el(
      [
        width(px(size)),
        height(px(size)),
        Transform.rotate(tilt),
        Nearby.in_front(ray.(size, thickness)),
        Nearby.in_front(ray.(thickness, size)),
        Nearby.in_front(ray.(size / 2.6, size / 2.6))
      ] ++ attrs,
      none()
    )
  end
end
