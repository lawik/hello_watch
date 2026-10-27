defmodule HelloWatch.Clock.CamerasAppTest do
  use ExUnit.Case, async: true

  alias HelloWatch.Clock.CamerasApp

  @phone :"home@100.117.24.92"
  @desk :"home@100.113.179.83"
  @list [
    %{ref: {@desk, "cam0"}, device: "monolith", id: "cam0"},
    %{ref: {@phone, "front"}, device: "nerves-6a3a", id: "front"},
    %{ref: {@phone, "rear"}, device: "nerves-6a3a", id: "rear"}
  ]

  defp cams(index), do: %{CamerasApp.new() | list: @list, index: index}

  test "the middle of the panel shows the camera on screen" do
    assert CamerasApp.tap(cams(1), {227, 227}) == {:watch, {@phone, "front"}}
  end

  test "the left and right thirds step through the cameras, round the end" do
    assert CamerasApp.tap(cams(0), {400, 227}) == {:index, 1}
    assert CamerasApp.tap(cams(2), {400, 100}) == {:index, 0}
    assert CamerasApp.tap(cams(0), {40, 300}) == {:index, 2}
  end

  test "a list that shrank under the index still shows a camera" do
    assert CamerasApp.tap(cams(5), {227, 227}) == {:watch, {@phone, "rear"}}
  end

  test "a tap anywhere stops a camera being shown" do
    assert CamerasApp.tap(%{cams(0) | showing: {@phone, "rear"}}, {10, 10}) == :stop
  end

  test "before the list is read, or with no cameras, taps do nothing" do
    assert CamerasApp.tap(CamerasApp.new(), {227, 227}) == nil
    assert CamerasApp.tap(%{CamerasApp.new() | list: []}, {227, 227}) == nil
  end
end
