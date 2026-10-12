defmodule HelloWatch.Clock.Palette do
  @moduledoc """
  The witchy colours of the face and pages, and the channel swap that makes
  frames cheap to show.

  The framebuffer stores pixels as B, G, R, X bytes, and Emerge's headless
  renderer can only hand out R, G, B, A. Rather than reorder every pixel on
  the CPU, everything is drawn with red and blue swapped (`bgr/1`), so the
  rendered R, G, B, A bytes land as the B, G, R, X the panel reads, and a
  frame goes to the framebuffer as plain row copies. Antialiasing and
  gradients blend each channel the same way, so the swap is exact. A window
  on a host draws the true colours.

  Every colour in the UI comes through `c/1`, `c/2` or `rgb/1`.
  """
  import Emerge.UI.Color, only: [color_rgb: 3, color_rgba: 4]

  @colors %{
    # The night sky behind the face, fading down.
    night: {14, 9, 30},
    midnight: {5, 3, 12},
    # Moonlight and the moons' dark sides.
    bone: {240, 230, 210},
    shadow: {44, 34, 66},
    dusk: {120, 102, 150},
    # Decorations.
    lilac: {196, 164, 246},
    candle: {250, 184, 92},
    cork: {160, 104, 62},
    moss: {120, 222, 150},
    rose: {244, 116, 158},
    # The pages, each its own colour, sweeping in like a waxing moon.
    deep: {12, 20, 48},
    ley: {8, 38, 34},
    plum: {40, 12, 50},
    wine: {50, 10, 30},
    white: {255, 255, 255},
    black: {0, 0, 0}
  }

  @doc "Draw with red and blue swapped from now on (the watch's framebuffer)."
  def bgr(on?) when is_boolean(on?), do: :persistent_term.put({__MODULE__, :bgr}, on?)

  def bgr?, do: :persistent_term.get({__MODULE__, :bgr}, false)

  def c(name), do: rgb(Map.fetch!(@colors, name))
  def c(name, alpha), do: rgba(Map.fetch!(@colors, name), alpha)

  def rgb({r, g, b}), do: if(bgr?(), do: color_rgb(b, g, r), else: color_rgb(r, g, b))

  def rgba({r, g, b}, alpha),
    do: if(bgr?(), do: color_rgba(b, g, r, alpha), else: color_rgba(r, g, b, alpha))

  @doc "A linear gradient through the named colours, at `angle` degrees."
  def gradient(names, angle), do: Emerge.UI.Color.gradient(Enum.map(names, &c/1), angle)

  @doc "A colour as the R, G, B the panel shows, for tests reading frames."
  def value(name), do: Map.fetch!(@colors, name)
end
