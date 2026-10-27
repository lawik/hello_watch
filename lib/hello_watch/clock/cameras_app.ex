defmodule HelloWatch.Clock.CamerasApp do
  @moduledoc """
  The home cluster's cameras (see `HelloWatch.HomeVideo`), one at a time in
  large type: a tap on the left third of the panel goes to the previous
  camera, on the right third to the next, and in the middle shows it full
  screen until another tap. Video fills the round panel, cropped to its
  middle.

  The app's state, kept in the clock's:

    * `list` - the cameras (`HelloWatch.HomeVideo.cameras/0`), nil until read
    * `index` - the camera on screen
    * `showing` - the camera shown or being started, or nil
    * `status` - the stream's latest `{:home_video, ...}` news, or nil
    * `error` - why the last camera didn't start, or nil
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Arc, Pages, Palette}

  @size 454
  @target :home_video
  # The thirds of the panel a tap is read against.
  @left 151
  @right 303

  @doc "The app's state before anything is read."
  def new, do: %{list: nil, index: 0, showing: nil, status: nil, error: nil}

  @doc "The video element's target, for `HelloWatch.HomeVideo.Surface`."
  def target, do: @target

  @doc false
  def render(%{showing: nil} = cams) do
    Pages.page("Cameras", body(cams), :cameras, caption(cams))
  end

  def render(%{showing: {_node, id}} = cams) do
    device = Enum.find_value(cams.list || [], id, &(&1.ref == cams.showing && &1.device))

    el(
      [width(px(@size)), height(px(@size)), Background.color(color_rgb(0, 0, 0))] ++
        Enum.map(
          [
            video(
              [key(:camera), width(px(@size)), height(px(@size)), image_fit(:cover)],
              @target
            )
          ] ++
            status_line(cams.status) ++
            Arc.rim(
              "#{device} · #{id}",
              :bottom,
              font: :italic,
              size: 22,
              color: Palette.c(:bone),
              inset: 22
            ),
          &Nearby.in_front/1
        ),
      none()
    )
  end

  # Until the first frame, a line says what's happening.
  defp status_line(nil) do
    [
      el(
        [
          center_x(),
          center_y(),
          Font.family("Alegreya Sans"),
          Font.size(30),
          Font.color(Palette.c(:lilac))
        ],
        text("Connecting…")
      )
    ]
  end

  defp status_line(_news), do: []

  defp body(%{list: nil}), do: message("Looking…")
  defp body(%{list: []}), do: message("No cameras")

  defp body(%{list: list} = cams) do
    camera = Enum.at(list, index(cams))
    several? = length(list) > 1

    row(
      [width(px(@size)), height(px(@size))],
      [
        chevron("‹", several?),
        column([width(fill()), center_y(), spacing(6)], [
          el(
            [center_x(), Font.family("Macondo"), Font.size(44), Font.color(Palette.c(:bone))],
            text(camera.device)
          ),
          el(
            [
              center_x(),
              Font.family("Alegreya Sans"),
              Font.size(36),
              Font.color(Palette.c(:candle))
            ],
            text(camera.id)
          )
        ]),
        chevron("›", several?)
      ]
    )
  end

  defp chevron(mark, shown?) do
    el(
      [
        width(px(70)),
        center_y(),
        Font.family("Alegreya Sans"),
        Font.size(72),
        Font.color(Palette.c(:lilac, if(shown?, do: 0.9, else: 0)))
      ],
      el([center_x()], text(mark))
    )
  end

  defp message(line) do
    el(
      [width(px(@size)), height(px(@size))],
      el(
        [
          center_x(),
          center_y(),
          Font.family("Alegreya Sans"),
          Font.size(34),
          Font.color(Palette.c(:bone))
        ],
        text(line)
      )
    )
  end

  defp caption(%{error: error}) when error != nil, do: "Couldn't start it"

  defp caption(%{list: [_ | _] = list} = cams),
    do: "#{index(cams) + 1} of #{length(list)} · tap to watch"

  defp caption(_cams), do: nil

  # The list can shrink under the index between reads.
  defp index(%{list: list, index: index}), do: rem(index, Kernel.max(length(list), 1))

  @doc """
  What a tap at `{x, y}` asks for: `{:index, i}` to show another camera,
  `{:watch, ref}` to show the one on screen, `:stop` to stop showing one,
  or nil.
  """
  def tap(%{showing: showing}, _at) when showing != nil, do: :stop

  def tap(%{list: [_ | _] = list} = cams, {x, _y}) do
    count = length(list)

    cond do
      x < @left -> {:index, rem(index(cams) - 1 + count, count)}
      x > @right -> {:index, rem(index(cams) + 1, count)}
      true -> {:watch, Enum.at(list, index(cams)).ref}
    end
  end

  def tap(_cams, _at), do: nil
end
