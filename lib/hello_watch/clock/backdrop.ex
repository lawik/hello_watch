defmodule HelloWatch.Clock.Backdrop do
  @moduledoc """
  The sky behind every view: a dark blue gradient with two layers of big,
  soft clouds, tinted per view.

  The clouds are white radial gradients in SVG (`priv/images/clouds-*.svg`),
  coloured with `Svg.color/1`, which replaces their colour but keeps their
  alpha. The tint goes through the palette like every other colour, so it
  needs no separate red/blue-swapped files.
  """
  use Emerge.UI

  alias HelloWatch.Clock.Palette

  @size 454

  # Two cloud tints per view, and how strong each layer is.
  @tints %{
    clock: {:lilac, :blue},
    alarms: {:candle, :blue},
    timers: {:teal, :lilac},
    stopwatch: {:moss, :blue},
    battery: {:teal, :blue},
    network: {:moss, :teal},
    sensors: {:rose, :lilac},
    moon: {:bone, :blue},
    tailscale: {:rose, :blue},
    sky: {:blue, :teal}
  }
  @strength {0.32, 0.24}

  # How far the backdrop reaches past each side of the panel, matching the
  # cloud SVGs' width.
  @reach 170

  @doc """
  The backdrop for `view`, as layers to go first among a view root's nearby
  layers: the base gradient and two cloud layers. They're wider than the
  panel, so a view sliding in carries its sky into its curved edge; the
  panel, or the sliding shape, clips them.
  """
  def layers(view) do
    {a, b} = Map.get(@tints, view, {:lilac, :blue})
    {strength_a, strength_b} = @strength

    [
      el(
        [
          width(px(@size + 2 * @reach)),
          height(px(@size)),
          Transform.move_x(-@reach),
          Background.color(Palette.gradient([:twilight, :abyss], 180))
        ],
        none()
      ),
      cloud("images/clouds-a.svg", a, strength_a),
      cloud("images/clouds-b.svg", b, strength_b)
    ]
  end

  @doc "The base gradient, as an attribute: for areas the layers don't reach."
  def background, do: Background.color(Palette.gradient([:twilight, :abyss], 180))

  @doc "A flat colour close to the base."
  def color, do: Palette.c(:abyss)

  @doc "The tint of the soft cloud front on `view`'s leading edge as it slides in."
  def edge_tint(view) do
    {a, _b} = Map.get(@tints, view, {:lilac, :blue})
    Palette.c(a, 0.55)
  end

  defp cloud(source, tint, alpha) do
    svg(
      [
        width(px(@size + 2 * @reach)),
        height(px(@size)),
        Transform.move_x(-@reach),
        Svg.color(Palette.c(tint, alpha))
      ],
      source
    )
  end
end
