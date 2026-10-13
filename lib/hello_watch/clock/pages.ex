defmodule HelloWatch.Clock.Pages do
  @moduledoc """
  The views beside the face: the cloudy backdrop, a title between two
  sparkles, and a body. `render/3` lays out rows of text; `page/3` takes any
  body.
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Backdrop, Moon, Palette}

  @size 454

  # The panel is round, so the body starts past the title and is inset from
  # the left curve; rows narrow near the top and bottom.
  @body_top 112
  @body_left 70
  @label_width 104
  @max_rows 11

  @doc """
  A view of `rows`: `{label, value}` pairs, plain strings, or `""` for a
  gap. `view` picks the backdrop's tint.
  """
  def render(title, rows, view) do
    body =
      column(
        [padding_each(@body_top, 0, 0, @body_left), spacing(5)],
        rows |> Enum.take(@max_rows) |> Enum.map(&row_element/1)
      )

    page(title, body, view)
  end

  @doc "A flat colour for areas next to a view, as it slides in."
  def background(_view), do: Backdrop.color()

  @doc "A view with `body` laid over the whole 454x454 panel."
  def page(title, body, view) do
    el(
      [
        width(px(@size)),
        height(px(@size)),
        Backdrop.background()
      ] ++
        Enum.map(Backdrop.layers(view) ++ [title(title), body], &Nearby.in_front/1),
      none()
    )
  end

  defp title(title) do
    el(
      [width(px(@size)), padding_each(44, 0, 0, 0)],
      row([center_x(), spacing(12)], [
        Moon.sparkle(12, :lilac, [center_y()], 8),
        el(
          [Font.family("Macondo"), Font.size(34), Font.color(Palette.c(:candle))],
          text(title)
        ),
        Moon.sparkle(12, :lilac, [center_y()], -8)
      ])
    )
  end

  defp row_element(""), do: el([height(px(8))], none())

  defp row_element({label, value}) do
    row([spacing(8)], [
      el(
        [
          width(px(@label_width)),
          center_y(),
          Font.family("Alegreya Sans"),
          Font.italic(),
          Font.size(17),
          Font.color(Palette.c(:lilac))
        ],
        text(label)
      ),
      el(
        [Font.family("Alegreya Sans"), Font.size(20), Font.color(Palette.c(:bone))],
        text(String.slice(to_string(value), 0, 22))
      )
    ])
  end

  defp row_element(line) do
    el(
      [Font.family("Alegreya Sans"), Font.size(19), Font.color(Palette.c(:bone))],
      text(String.slice(to_string(line), 0, 30))
    )
  end
end
