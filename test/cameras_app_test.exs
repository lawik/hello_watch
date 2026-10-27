defmodule HelloWatch.Clock.CamerasAppTest do
  use ExUnit.Case, async: true

  alias HelloWatch.Clock.{CamerasApp, Pages}

  @phone :"home@100.117.24.92"
  @desk :"home@100.113.179.83"
  @list [
    %{ref: {@desk, "cam0"}, device: "monolith", id: "cam0"},
    %{ref: {@phone, "front"}, device: "nerves-6a3a", id: "front"},
    %{ref: {@phone, "rear"}, device: "nerves-6a3a", id: "rear"}
  ]

  # The middle of row `index` when `rows` are shown.
  defp row(rows, index) do
    {top, h} = Enum.at(Pages.spans(rows), index)
    {227, top + div(h, 2)}
  end

  test "a device with one camera shows it straight away" do
    cams = %{CamerasApp.new() | list: @list}
    assert CamerasApp.tap(cams, row(["monolith", "nerves-6a3a"], 0)) == {:watch, {@desk, "cam0"}}
  end

  test "a device with several lists them, and back goes to the devices" do
    cams = %{CamerasApp.new() | list: @list}
    assert CamerasApp.tap(cams, row(["monolith", "nerves-6a3a"], 1)) == {:device, "nerves-6a3a"}

    cams = %{cams | device: "nerves-6a3a"}
    rows = ["‹ All devices", "front", "rear"]
    assert CamerasApp.tap(cams, row(rows, 2)) == {:watch, {@phone, "rear"}}
    assert CamerasApp.tap(cams, row(rows, 0)) == :devices
  end

  test "a tap anywhere stops a camera being shown" do
    cams = %{CamerasApp.new() | list: @list, showing: {@phone, "rear"}}
    assert CamerasApp.tap(cams, {10, 10}) == :stop
  end

  test "taps off the rows, or before the list is read, do nothing" do
    assert CamerasApp.tap(%{CamerasApp.new() | list: @list}, {227, 20}) == nil
    assert CamerasApp.tap(CamerasApp.new(), {227, 227}) == nil
  end
end
