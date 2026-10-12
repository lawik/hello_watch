defmodule HelloWatch.Clock.Pages do
  @moduledoc """
  The pages beside the face, each in its own colour: a title between two
  sparkles, a body, and a row of little moons for page dots with the current
  page's full. `render/3` lays out rows of text; `page/3` takes any body.
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Moon, Palette}

  @size 454
  @pages 5
  # Page 0 is the face, which paints its own sky.
  @colors {:night, :deep, :ley, :plum, :wine}

  # The panel is round, so the body starts past the title and is inset from
  # the left curve; rows narrow near the top and bottom.
  @body_top 112
  @body_left 70
  @label_width 104
  @max_rows 11

  @doc """
  A page of `rows`: `{label, value}` pairs, plain strings, or `""` for a
  gap.
  """
  def render(title, rows, page) do
    body =
      column(
        [padding_each(@body_top, 0, 0, @body_left), spacing(5)],
        rows |> Enum.take(@max_rows) |> Enum.map(&row_element/1)
      )

    page(title, body, page)
  end

  @doc "A page with `body` laid over the whole 454x454 panel."
  def page(title, body, page) do
    el(
      [
        width(px(@size)),
        height(px(@size)),
        Background.color(Palette.c(elem(@colors, page))),
        Nearby.in_front(title(title)),
        Nearby.in_front(body),
        Nearby.in_front(moons(page))
      ],
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

  defp moons(selected) do
    el(
      [width(px(@size)), padding_each(400, 0, 0, 0)],
      row(
        [center_x(), spacing(10)],
        for index <- 0..(@pages - 1) do
          if index == selected,
            do: Moon.disc(0.5, 14, attrs: [center_y(), Border.glow(Palette.c(:lilac, 0.5), 4)]),
            else: Moon.disc(0.13, 11, lit: :dusk, attrs: [center_y()])
        end
      )
    )
  end
end
