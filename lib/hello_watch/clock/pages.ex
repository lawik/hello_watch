defmodule HelloWatch.Clock.Pages do
  @moduledoc """
  The views beside the face: the cloudy backdrop, a title along the top of
  the rim between two sparkles, an optional caption along the bottom, and a
  body. `render/4` lays out rows of text, each starting at the panel's left
  edge where it sits and sized to fit before the right edge; `page/4` takes
  any body.
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Arc, Backdrop, Moon, Palette}

  @size 454
  @center div(@size, 2)

  # Rows are centred on the panel's middle, but start no higher than this.
  @body_top 96
  # Row heights for working out where each row sits, so it can be sized to
  # the panel's width there.
  @label 22
  @value 34
  @big 64
  @line 30
  @gap 12
  @spacing 8
  # Kept clear of the rim either side.
  @margin 30

  @doc """
  A view of `rows`: `{label, value}` pairs, `{:big, label, value}` for a
  headline value, plain strings, or `""` for a gap. `view` picks the backdrop's tint; `caption` runs along the bottom.
  """
  def render(title, rows, view, caption \\ nil) do
    heights = Enum.map(rows, &row_height/1)
    total = Enum.sum(heights) + @spacing * (length(rows) - 1)
    top = Kernel.max(@body_top, round(@center - total / 2))

    {elements, _} =
      Enum.map_reduce(Enum.zip(rows, heights), top, fn {row, h}, y ->
        {row_element(row, y), y + h + @spacing}
      end)

    body =
      column(
        [width(px(@size)), padding_each(top, 0, 0, 0), spacing(@spacing)],
        elements
      )

    page(title, body, view, caption)
  end

  @doc "A flat colour for areas next to a view, as it slides in."
  def background(_view), do: Backdrop.color()

  @doc "A view with `body` laid over the whole 454x454 panel."
  def page(title, body, view, caption \\ nil) do
    el(
      [
        width(px(@size)),
        height(px(@size)),
        Backdrop.background()
      ] ++
        Enum.map(
          Backdrop.layers(view) ++ title(title) ++ caption(caption) ++ [body],
          &Nearby.in_front/1
        ),
      none()
    )
  end

  @title_size 38

  defp title(title) do
    # The sparkles sit just past either end of the title, on its arc.
    half = Arc.width(title, :macondo, @title_size) / 2 + 22
    degrees = half / (@center - 40) * 180 / :math.pi()

    sparkle = fn degrees, tilt ->
      el(
        [
          width(px(@size)),
          height(px(@size)),
          padding_each(34, 0, 0, 0),
          Transform.rotate(degrees)
        ],
        Moon.sparkle(12, :lilac, [center_x()], tilt)
      )
    end

    Arc.rim(title, :top,
      font: :macondo,
      size: @title_size,
      color: Palette.c(:candle),
      inset: 20,
      tracking: 1
    ) ++ [sparkle.(-degrees, 8), sparkle.(degrees, -8)]
  end

  defp caption(nil), do: []

  defp caption(caption),
    do: Arc.rim(caption, :bottom, font: :italic, size: 22, color: Palette.c(:lilac), inset: 22)

  defp row_height(""), do: @gap
  defp row_height({:big, _label, _value}), do: @label + @big
  defp row_height({_label, _value}), do: @label + @value
  defp row_height(_line), do: @line

  defp row_element("", _y), do: el([height(px(@gap))], none())

  defp row_element({:big, label, value}, y) do
    column([spacing(0)], [
      label(label, y),
      line(to_string(value), y + @label, @big, "Macondo", :macondo, 56)
    ])
  end

  defp row_element({label, value}, y) do
    column([spacing(0)], [
      label(label, y),
      line(to_string(value), y + @label, @value, "Alegreya Sans", :sans, 28)
    ])
  end

  defp row_element(line, y), do: line(to_string(line), y, @line, "Alegreya Sans", :sans, 24)

  # A line of text from the panel's left edge where it sits, sized to fit
  # before the right edge.
  defp line(text, y, h, family, font, size) do
    {left, width} = span(y, h)

    el(
      [
        height(px(h)),
        padding_each(0, 0, 0, left),
        Font.family(family),
        Font.size(Arc.fit(text, font, size, width)),
        Font.color(Palette.c(:bone))
      ],
      el([center_y()], text(text))
    )
  end

  defp label(label, y) do
    {left, _width} = span(y, @label)

    el(
      [
        height(px(@label)),
        padding_each(0, 0, 0, left),
        Font.family("Alegreya Sans"),
        Font.italic(),
        Font.size(18),
        Font.color(Palette.c(:lilac))
      ],
      text(label)
    )
  end

  # Where the panel's left edge is, and how wide it is, along the narrower
  # of a line's top and bottom edges.
  defp span(y, h) do
    width = Arc.chord(Kernel.max(abs(y - @center), abs(y + h - @center)), @margin)
    {round((@size - width) / 2), width}
  end
end
