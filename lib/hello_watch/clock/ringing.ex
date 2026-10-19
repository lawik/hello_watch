defmodule HelloWatch.Clock.Ringing do
  @moduledoc """
  What covers the panel while an alarm or a timer rings: what it is, under
  a slowly pulsing ring, until a tap stops it (see HelloWatch.Clock).
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Palette, Widgets}

  @size 454
  @ring 330

  @doc "The cover for `{:alarm, alarm}` or `{:timer, timer}` ringing."
  def render({kind, item}) do
    {title, value} =
      case kind do
        :alarm -> {"Alarm", "#{Widgets.pad(item.hour)}:#{Widgets.pad(item.minute)}"}
        :timer -> {"Time's up", Widgets.duration(item.seconds)}
      end

    el(
      [
        key(:ringing),
        width(px(@size)),
        height(px(@size)),
        Border.rounded(@size / 2),
        Background.color(Palette.c(:abyss)),
        Nearby.in_front(pulse())
      ],
      column([center_x(), center_y(), spacing(6)], [
        el(
          [center_x(), Font.family("Macondo"), Font.size(44), Font.color(Palette.c(:candle))],
          text(title)
        ),
        el([center_x()], Widgets.digits(value, 88, 46, Palette.c(:bone))),
        el(
          [
            center_x(),
            Font.family("Alegreya Sans"),
            Font.italic(),
            Font.size(22),
            Font.color(Palette.c(:lilac))
          ],
          text("tap to stop")
        )
      ])
    )
  end

  defp pulse do
    el(
      [
        width(px(@ring)),
        height(px(@ring)),
        Transform.move_x(div(@size - @ring, 2)),
        Transform.move_y(div(@size - @ring, 2)),
        Border.rounded(@ring / 2),
        Border.width(3),
        Border.color(Palette.c(:candle, 0.8)),
        Animation.animate(
          [
            [Transform.scale(0.92), Transform.alpha(0.9)],
            [Transform.scale(1.06), Transform.alpha(0.2)],
            [Transform.scale(0.92), Transform.alpha(0.9)]
          ],
          1600,
          :ease_in_out,
          :loop
        )
      ],
      none()
    )
  end
end
