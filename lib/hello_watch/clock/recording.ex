defmodule HelloWatch.Clock.Recording do
  @moduledoc """
  The badge that slides down from the top edge while a voice memo records
  (see HelloWatch.Recorder): a pulsing dot and the time recorded so far. It
  stays mounted, above the panel, while nothing records, so it eases in and
  out rather than popping.
  """
  use Emerge.UI

  alias HelloWatch.Clock.Palette

  @width 136
  @height 50
  @shown 26
  @hidden -(@height + 20)
  @slide_ms 260

  @doc """
  The badge showing `seconds` recorded, while `recording?`; otherwise tucked
  away, still showing the last recording's length as it slides out.
  """
  def render(seconds, recording?) do
    y = if recording?, do: @shown, else: @hidden

    el(
      [
        key(:recording),
        width(px(@width)),
        height(px(@height)),
        Transform.move_x(div(454 - @width, 2)),
        Border.rounded(@height / 2),
        Background.color(Palette.c(:wine, 0.92)),
        Border.width(1),
        Border.color(Palette.c(:rose, 0.5))
      ] ++ HelloWatch.Clock.eased([Transform.move_y(y)], @slide_ms),
      row([center_x(), center_y(), spacing(10)], [dot(recording?), time(seconds)])
    )
  end

  # It only pulses while shown: a loop keeps frames coming.
  defp dot(recording?) do
    pulse =
      if recording?,
        do: [
          Animation.animate(
            [[Transform.alpha(1.0)], [Transform.alpha(0.3)], [Transform.alpha(1.0)]],
            1200,
            :ease_in_out,
            :loop
          )
        ],
        else: []

    el(
      [
        width(px(14)),
        height(px(14)),
        center_y(),
        Border.rounded(7),
        Background.color(Palette.c(:rose))
      ] ++ pulse,
      none()
    )
  end

  defp time(s) do
    el(
      [
        center_y(),
        Font.family("Alegreya Sans"),
        Font.weight(500),
        Font.size(26),
        Font.color(Palette.c(:bone))
      ],
      text("#{div(s, 60)}:#{String.pad_leading(Integer.to_string(rem(s, 60)), 2, "0")}")
    )
  end
end
