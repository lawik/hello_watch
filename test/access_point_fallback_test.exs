defmodule HelloWatch.AccessPoint.FallbackTest do
  use ExUnit.Case, async: true

  alias HelloWatch.AccessPoint.Fallback

  @opts [grace: 100, window: 1000]
  @fresh %{since: 0, ours: nil, stay: false}

  defp decide(state, wlan, now), do: Fallback.decide(state, wlan, now, @opts)

  test "no network configured: up at once, and it stays up" do
    assert {:start, state} = decide(@fresh, :unconfigured, 10)
    assert {:nothing, ^state} = decide(state, :ap, 10_000)
  end

  test "a network that never connects: up after the grace, back after the window" do
    assert {:nothing, state} = decide(@fresh, :trying, 50)
    assert {:start, state} = decide(state, :trying, 100)
    assert {:nothing, state} = decide(state, :ap, 1000)
    assert {:stop, state} = decide(state, :ap, 1100)
    # Another grace on the network before the next try.
    assert {:nothing, state} = decide(state, :trying, 1150)
    assert {:start, _state} = decide(state, :trying, 1200)
  end

  test "connecting, Wi-Fi off, or no wlan0 yet restart the grace" do
    for wlan <- [:connected, :blocked, :absent] do
      assert {:nothing, state} = decide(@fresh, wlan, 500)
      assert {:nothing, _state} = decide(state, :trying, 550)
    end
  end

  test "an access point started by hand is left alone" do
    assert {:nothing, state} = decide(@fresh, :connected, 10)
    assert {:nothing, ^state} = decide(state, :ap, 100_000)
  end

  test "a start that failed is tried again" do
    assert {:start, state} = decide(@fresh, :trying, 100)
    assert {:start, _state} = decide(state, :trying, 115)
  end
end
