defmodule HelloWatch.Clock.MoonApp do
  @moduledoc """
  A small app, and a placeholder for more: tonight's moon, large, with its
  phase, how much of it is lit, and the days until the next full moon.
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Moon, Pages, Palette}

  @size 454
  @synodic_days 29.530588853

  @doc "`phase` is `Moon.phase/1` for now."
  def render(phase) do
    lit = round(Moon.lit(phase) * 100)
    days = round(Float.floor(:math.fmod(0.5 - phase + 1, 1) * @synodic_days))

    full =
      cond do
        days == 0 -> "full tonight"
        days == 1 -> "full tomorrow"
        true -> "full in #{days} days"
      end

    Pages.page(
      "Moon",
      column([width(px(@size)), padding_each(108, 0, 0, 0), spacing(14)], [
        # A faint rim, so a thin crescent still shows the whole moon.
        el(
          [center_x()],
          Moon.disc(phase, 168, attrs: [Border.width(2), Border.color(Palette.c(:lilac, 0.35))])
        ),
        el(
          [center_x(), Font.family("Macondo"), Font.size(26), Font.color(Palette.c(:bone))],
          text(name(phase))
        ),
        el(
          [
            center_x(),
            Font.family("Alegreya Sans"),
            Font.italic(),
            Font.size(17),
            Font.color(Palette.c(:lilac))
          ],
          text("#{lit}% lit · #{full}")
        )
      ]),
      :moon
    )
  end

  @doc "The phase's name."
  def name(phase) when phase < 0.03 or phase >= 0.97, do: "New moon"
  def name(phase) when phase < 0.22, do: "Waxing crescent"
  def name(phase) when phase < 0.28, do: "First quarter"
  def name(phase) when phase < 0.47, do: "Waxing gibbous"
  def name(phase) when phase < 0.53, do: "Full moon"
  def name(phase) when phase < 0.72, do: "Waning gibbous"
  def name(phase) when phase < 0.78, do: "Last quarter"
  def name(_phase), do: "Waning crescent"
end
