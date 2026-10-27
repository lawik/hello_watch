defmodule HelloWatch.Clock.CamerasApp do
  @moduledoc """
  The home cluster's cameras (see `HelloWatch.HomeVideo`): the devices that
  have one, then a device's cameras, and a tap on one shows it full screen
  until another tap. Video fills the round panel, cropped to its middle.

  The app's state, kept in the clock's:

    * `list` - the cameras (`HelloWatch.HomeVideo.cameras/0`), nil until read
    * `device` - the device whose cameras are listed, or nil for the devices
    * `showing` - the camera shown or being started, or nil
    * `status` - the stream's latest `{:home_video, ...}` news, or nil
    * `error` - why the last camera didn't start, or nil
  """
  use Emerge.UI

  alias HelloWatch.Clock.{Arc, Pages, Palette}

  @size 454
  @target :home_video
  @back "‹ All devices"

  @doc "The app's state before anything is read."
  def new, do: %{list: nil, device: nil, showing: nil, status: nil, error: nil}

  @doc "The video element's target, for `HelloWatch.HomeVideo.Surface`."
  def target, do: @target

  @doc false
  def render(%{showing: nil} = cams),
    do: Pages.render("Cameras", rows(cams), :cameras, caption(cams))

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
  defp status_line({:started, _}), do: []
  defp status_line({:frames, _}), do: []

  defp status_line(_waiting) do
    [
      el(
        [
          center_x(),
          center_y(),
          Font.family("Alegreya Sans"),
          Font.size(26),
          Font.color(Palette.c(:lilac))
        ],
        text("Connecting…")
      )
    ]
  end

  defp caption(%{error: error}) when error != nil, do: "Couldn't start it"
  defp caption(%{list: [_ | _], device: nil}), do: "Tap a device"
  defp caption(%{list: [_ | _]}), do: "Tap a camera"
  defp caption(_cams), do: nil

  defp rows(%{list: nil}), do: ["Looking…"]
  defp rows(%{list: []}), do: ["No cameras", "in the home cluster"]
  defp rows(%{device: nil} = cams), do: devices(cams.list)
  defp rows(cams), do: [@back | Enum.map(cameras(cams.list, cams.device), & &1.id)]

  defp devices(list), do: list |> Enum.map(& &1.device) |> Enum.uniq()
  defp cameras(list, device), do: Enum.filter(list, &(&1.device == device))

  @doc """
  What a tap at `{x, y}` asks for: `{:device, device}` to list its cameras,
  `:devices` to go back, `{:watch, ref}` to show a camera, `:stop` to stop
  showing one, or nil.
  """
  def tap(%{showing: showing}, _at) when showing != nil, do: :stop

  def tap(%{list: [_ | _]} = cams, {_x, y}) do
    rows = rows(cams)

    case Enum.find_index(Pages.spans(rows), fn {top, h} -> y >= top - 4 and y < top + h + 4 end) do
      nil -> nil
      index -> pick(cams, Enum.at(rows, index))
    end
  end

  def tap(_cams, _at), do: nil

  defp pick(%{device: nil, list: list}, device) do
    case cameras(list, device) do
      # One camera: no need to choose.
      [camera] -> {:watch, camera.ref}
      _several -> {:device, device}
    end
  end

  defp pick(_cams, @back), do: :devices

  defp pick(cams, id) do
    camera = Enum.find(cameras(cams.list, cams.device), &(&1.id == id))
    if camera, do: {:watch, camera.ref}
  end
end
