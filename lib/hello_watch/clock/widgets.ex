defmodule HelloWatch.Clock.Widgets do
  @moduledoc """
  Pieces for the alarm, timer and stopwatch apps, which place their parts
  at fixed spots on the panel and hit-test taps against the same spots.

  An app lays itself out as `{action, rect, element}` entries, a rect
  being `{x, y, width, height}` on the panel. `surface/1` draws them and
  `hit/2` finds the action under a tap; an entry with a nil action is only
  drawn, and one with a nil element is only a tap target.
  """
  use Emerge.UI

  alias HelloWatch.Clock.Palette

  # A tap this far outside a target still hits it.
  @slop 8

  @doc "The 454x454 body for `layout`."
  def surface(layout) do
    el(
      [width(px(454)), height(px(454))] ++
        for(
          {_action, rect, element} <- layout,
          element != nil,
          do: Nearby.in_front(place(rect, element))
        ),
      none()
    )
  end

  @doc "The action of the entry under `{x, y}` in `layout`, or nil."
  def hit(layout, {x, y}) do
    Enum.find_value(layout, fn
      {nil, _rect, _element} ->
        nil

      {action, {rx, ry, w, h}, _element} ->
        if x >= rx - @slop and x <= rx + w + @slop and y >= ry - @slop and y <= ry + h + @slop,
          do: action
    end)
  end

  defp place({x, y, w, h}, element),
    do:
      el(
        [width(px(w)), height(px(h)), Transform.move_x(x), Transform.move_y(y)],
        element
      )

  @doc "A rounded button reading `label`, in `tint`; `filled` fills it."
  def pill(label, tint, opts \\ []) do
    filled = Keyword.get(opts, :filled, false)

    el(
      [
        width(fill()),
        height(fill()),
        Border.rounded(Keyword.get(opts, :radius, 24)),
        Border.width(if(filled, do: 0, else: 2)),
        Border.color(Palette.c(tint, 0.7)),
        Background.color(if(filled, do: Palette.c(tint, 0.9), else: Palette.c(tint, 0.12)))
      ],
      el(
        [
          center_x(),
          center_y(),
          Font.family("Alegreya Sans"),
          Font.weight(500),
          Font.size(Keyword.get(opts, :size, 24)),
          Font.color(if(filled, do: Palette.c(:abyss), else: Palette.c(:bone)))
        ],
        text(label)
      )
    )
  end

  @doc """
  `text` with every digit in a cell `cell` pixels wide, so a running time
  doesn't jiggle as its digits change. Separators take a narrower cell.
  """
  def digits(text, size, cell, color, attrs \\ []) do
    row(
      [Font.family("Alegreya Sans"), Font.weight(500), Font.size(size), Font.color(color)] ++
        attrs,
      for char <- String.graphemes(text) do
        w = if char =~ ~r/\d/, do: cell, else: round(cell * 0.45)
        el([width(px(w))], el([center_x()], text(char)))
      end
    )
  end

  @doc "A line of plain text."
  def label(text, size, color, opts \\ []) do
    el(
      [
        center_x(),
        center_y(),
        Font.family("Alegreya Sans"),
        Font.size(size),
        Font.color(color)
      ] ++ if(Keyword.get(opts, :italic, false), do: [Font.italic()], else: []),
      text(text)
    )
  end

  @doc "`seconds` as h:mm:ss, or m:ss under an hour."
  def duration(seconds) do
    {h, m, s} = {div(seconds, 3600), div(rem(seconds, 3600), 60), rem(seconds, 60)}
    if h > 0, do: "#{h}:#{pad(m)}:#{pad(s)}", else: "#{m}:#{pad(s)}"
  end

  def pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  @doc "What `fun` returns, or `default` if the process it calls isn't there."
  def call(fun, default) do
    fun.()
  catch
    :exit, _reason -> default
  end
end
