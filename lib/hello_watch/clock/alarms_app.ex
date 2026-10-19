defmodule HelloWatch.Clock.AlarmsApp do
  @moduledoc """
  Alarms (HelloWatch.Alarms), in two views:

    * **The list:** up to four alarms, each with its weekdays and a switch.
      A tap on the switch turns the alarm on or off; anywhere else on it
      opens it for editing. `+ alarm` adds one at 07:00 and opens it.
    * **Editing:** the time with `+` and `–` over and under the hours and
      the minutes (minutes in fives), the weekdays it repeats on (none rings
      once), and delete and done.

  HelloWatch.Clock keeps which alarm is open, if any, as `editing`.
  """
  use Emerge.UI

  alias HelloWatch.Alarms
  alias HelloWatch.Clock.{Pages, Palette, Widgets}

  @max 4
  @weekdays ~w(M T W T F S S)

  @doc "The alarms, or none if the service isn't up."
  def alarms, do: Widgets.call(&Alarms.list/0, [])

  def render(alarms, editing, now) do
    case Enum.find(alarms, &(&1.id == editing)) do
      nil -> Pages.page("Alarms", Widgets.surface(list(alarms)), :alarms, next(alarms, now))
      alarm -> Pages.page("Alarm", Widgets.surface(editor(alarm)), :alarms, days(alarm.days))
    end
  end

  @doc "Acts on a tap at `at`, returning the alarm open for editing next."
  def tap(alarms, editing, at) do
    case Enum.find(alarms, &(&1.id == editing)) do
      nil -> act(Widgets.hit(list(alarms), at), nil)
      alarm -> act(Widgets.hit(editor(alarm), at), alarm)
    end
  end

  defp act(nil, alarm), do: alarm && alarm.id
  defp act({:edit, id}, nil), do: id

  defp act({:switch, alarm}, nil) do
    update(alarm.id, on: not alarm.on)
    nil
  end

  defp act(:add, nil), do: Widgets.call(fn -> Alarms.add(7, 0).id end, nil)

  defp act({:hour, step}, alarm) do
    update(alarm.id, hour: Integer.mod(alarm.hour + step, 24), on: true)
    alarm.id
  end

  defp act({:minute, step}, alarm) do
    minute = Integer.mod(div(alarm.minute, 5) * 5 + step, 60)
    update(alarm.id, minute: minute, on: true)
    alarm.id
  end

  defp act({:day, day}, alarm) do
    days = if day in alarm.days, do: alarm.days -- [day], else: Enum.sort([day | alarm.days])
    update(alarm.id, days: days, on: true)
    alarm.id
  end

  defp act(:delete, alarm) do
    Widgets.call(fn -> Alarms.delete(alarm.id) end, nil)
    nil
  end

  defp act(:done, _alarm), do: nil

  defp update(id, changes), do: Widgets.call(fn -> Alarms.update(id, changes) end, nil)

  defp list([]),
    do: [
      {nil, {77, 160, 300, 50}, Widgets.label("no alarms", 26, Palette.c(:dusk), italic: true)},
      {:add, {157, 226, 140, 50}, Widgets.pill("+ alarm", :candle)}
    ]

  defp list(alarms) do
    rows =
      alarms
      |> Enum.take(@max)
      |> Enum.with_index()
      |> Enum.flat_map(fn {alarm, i} ->
        y = 100 + i * 58

        [
          {{:switch, alarm}, {297, y, 80, 52}, nil},
          {{:edit, alarm.id}, {77, y, 220, 52}, nil},
          {nil, {77, y, 300, 52}, alarm_row(alarm)}
        ]
      end)

    add =
      if length(alarms) < @max,
        do: [
          {:add, {167, 100 + length(alarms) * 58 + 10, 120, 46}, Widgets.pill("+ alarm", :candle)}
        ],
        else: []

    rows ++ add
  end

  defp alarm_row(alarm) do
    tint = if alarm.on, do: Palette.c(:bone), else: Palette.c(:dusk)

    el(
      [
        width(fill()),
        height(fill()),
        Border.rounded(26),
        Background.color(Palette.c(:candle, if(alarm.on, do: 0.14, else: 0.05))),
        padding_each(0, 18, 0, 22)
      ],
      row([width(fill()), center_y(), spacing(12)], [
        Widgets.digits(time(alarm), 34, 18, tint, [center_y()]),
        el(
          [
            center_y(),
            Font.family("Alegreya Sans"),
            Font.italic(),
            Font.size(18),
            Font.color(Palette.c(:lilac))
          ],
          text(days(alarm.days))
        ),
        el([align_right(), center_y()], switch(alarm.on))
      ])
    )
  end

  defp switch(on) do
    el(
      [
        width(px(46)),
        height(px(26)),
        Border.rounded(13),
        Border.width(2),
        Border.color(Palette.c(:candle, if(on, do: 0.9, else: 0.4))),
        Background.color(Palette.c(:candle, if(on, do: 0.85, else: 0))),
        padding_each(0, 3, 0, 3)
      ],
      el(
        [
          width(px(16)),
          height(px(16)),
          center_y(),
          if(on, do: align_right(), else: align_left()),
          Border.rounded(8),
          Background.color(if(on, do: Palette.c(:abyss), else: Palette.c(:dusk)))
        ],
        none()
      )
    )
  end

  defp editor(alarm) do
    step = fn label, action, x, y ->
      {action, {x, y, 84, 48}, Widgets.pill(label, :candle, size: 30)}
    end

    digits = fn text, x ->
      {nil, {x, 150, 110, 92},
       el([center_x(), center_y()], Widgets.digits(text, 88, 46, Palette.c(:bone)))}
    end

    days =
      for {letter, i} <- Enum.with_index(@weekdays) do
        day = i + 1
        rect = {86 + i * 42, 302, 36, 36}

        {{:day, day}, rect,
         Widgets.pill(letter, :lilac, filled: day in alarm.days, size: 20, radius: 18)}
      end

    [
      step.("+", {:hour, 1}, 118, 96),
      step.("+", {:minute, 5}, 252, 96),
      digits.(Widgets.pad(alarm.hour), 105),
      {nil, {207, 150, 40, 92}, Widgets.label(":", 80, Palette.c(:lilac))},
      digits.(Widgets.pad(alarm.minute), 239),
      step.("–", {:hour, -1}, 118, 240),
      step.("–", {:minute, -5}, 252, 240)
    ] ++
      days ++
      [
        {:delete, {108, 352, 110, 44}, Widgets.pill("delete", :rose)},
        {:done, {236, 352, 110, 44}, Widgets.pill("done", :moss)}
      ]
  end

  defp time(alarm), do: "#{Widgets.pad(alarm.hour)}:#{Widgets.pad(alarm.minute)}"

  @doc "The weekdays an alarm repeats on, in words."
  def days([]), do: "once"
  def days([1, 2, 3, 4, 5, 6, 7]), do: "every day"
  def days([1, 2, 3, 4, 5]), do: "weekdays"
  def days([6, 7]), do: "weekends"
  def days(days), do: Enum.map_join(days, " ", &Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), &1 - 1))

  # How long until the soonest alarm that's on.
  defp next(alarms, now) do
    if Enum.any?(alarms, & &1.on) do
      case Widgets.call(&Alarms.next/0, nil) do
        nil ->
          nil

        due ->
          minutes = ceil(DateTime.diff(due, now) / 60)
          {h, m} = {div(minutes, 60), rem(minutes, 60)}
          "next in " <> if(h > 0, do: "#{h}h #{m}m", else: "#{m}m")
      end
    else
      if alarms == [], do: nil, else: "all off"
    end
  end
end
