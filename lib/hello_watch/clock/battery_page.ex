defmodule HelloWatch.Clock.BatteryPage do
  @moduledoc """
  The battery page: a round-bottomed flask filled to the charge, the
  percentage, whether it's charging, and the supply voltage the estimate
  comes from (see HelloWatch.Power).
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Pages, Palette}

  @size 454
  @bulb 132
  @low 20

  @doc """
  `battery` is `%{percent: 0..100, status: :battery | :charging | :full,
  volts: float() | nil}`, or `nil` when the watch can't tell.
  """
  def render(battery, page)

  def render(nil, page), do: Pages.render("Battery", ["No reading"], page)

  def render(%{percent: percent, status: status} = battery, page) do
    liquid =
      cond do
        status != :battery -> :lilac
        percent <= @low -> :rose
        percent <= 50 -> :candle
        true -> :moss
      end

    status_text =
      case status do
        :charging -> "Charging"
        :full -> "Full"
        :battery when percent <= @low -> "Low"
        :battery -> "On battery"
      end

    volts =
      if is_number(battery[:volts]),
        do: :erlang.float_to_binary(battery.volts, decimals: 2) <> " V",
        else: nil

    Pages.page(
      "Battery",
      column([width(px(@size)), padding_each(104, 0, 0, 0), spacing(14)], [
        flask(percent, liquid, status == :charging),
        el(
          [center_x(), Font.family("Macondo"), Font.size(40), Font.color(Palette.c(:bone))],
          text("#{percent}%")
        ),
        el(
          [
            center_x(),
            Font.family("Alegreya Sans"),
            Font.italic(),
            Font.size(17),
            Font.color(Palette.c(:lilac))
          ],
          text(Enum.join(Enum.reject([status_text, volts], &is_nil/1), " · "))
        )
      ]),
      page
    )
  end

  # Cork, neck and a bulb whose liquid level is the charge. The bulb's
  # rounding clips the liquid; bubbles rise in it while charging.
  defp flask(percent, liquid, bubbling?) do
    level = round(@bulb * Kernel.min(Kernel.max(percent, 0), 100) / 100)

    bubbles =
      if bubbling?,
        do:
          for(
            {x, y, size} <- [{48, 96, 9}, {74, 78, 6}, {60, 60, 5}],
            do: Nearby.in_front(bubble(x, y, size))
          ),
        else: []

    column([center_x(), spacing(0)], [
      el(
        [
          center_x(),
          width(px(34)),
          height(px(14)),
          Border.rounded(4),
          Background.color(Palette.c(:cork))
        ],
        none()
      ),
      el(
        [center_x(), width(px(28)), height(px(18)), Background.color(Palette.c(:dusk, 0.5))],
        none()
      ),
      el(
        [
          width(px(@bulb)),
          height(px(@bulb)),
          Border.rounded(@bulb / 2),
          Background.color(Palette.c(:shadow)),
          Border.width(3),
          Border.color(Palette.c(:dusk)),
          Border.glow(Palette.c(liquid, 0.35), 10),
          clip_nearby()
        ] ++ bubbles,
        el(
          [width(fill()), height(px(level)), align_bottom(), Background.color(Palette.c(liquid))],
          none()
        )
      )
    ])
  end

  defp bubble(x, y, size) do
    el(
      [
        width(px(size)),
        height(px(size)),
        Border.rounded(size / 2),
        Background.color(Palette.c(:bone, 0.7)),
        Transform.move_x(x),
        Transform.move_y(y)
      ],
      none()
    )
  end
end
