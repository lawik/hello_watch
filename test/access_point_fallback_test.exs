defmodule HelloWatch.AccessPoint.FallbackTest do
  use ExUnit.Case, async: true

  alias HelloWatch.AccessPoint.Fallback

  @opts [grace: 100, window: 1000]
  @fresh %{since: 0, idle: nil}

  defp decide(state, wlan, now), do: Fallback.decide(state, wlan, now, @opts)

  test "no network configured: up at once, and it stays up" do
    assert {:start, state} = decide(@fresh, :unconfigured, 10)
    assert {:nothing, state} = decide(state, :ap_only, 10_000)
    assert {:nothing, _state} = decide(state, :ap_only, 100_000)
  end

  test "a network that never connects: up after the grace, back once idle for the window" do
    assert {:nothing, state} = decide(@fresh, :trying, 50)
    assert {:start, state} = decide(state, :trying, 100)
    assert {:nothing, state} = decide(state, :ap_idle, 115)
    assert {:nothing, state} = decide(state, :ap_idle, 1000)
    assert {:stop, state} = decide(state, :ap_idle, 1115)
    # Another grace on the network before the next try.
    assert {:nothing, state} = decide(state, :trying, 1150)
    assert {:start, _state} = decide(state, :trying, 1215)
  end

  test "an access point in use stays up, and the window starts over once it's left" do
    assert {:nothing, state} = decide(@fresh, :ap_idle, 0)
    assert {:nothing, state} = decide(state, :ap_in_use, 900)
    assert {:nothing, state} = decide(state, :ap_idle, 5000)
    assert {:nothing, state} = decide(state, :ap_idle, 5900)
    assert {:stop, _state} = decide(state, :ap_idle, 6000)
  end

  test "an access point nobody remembers raising goes back once idle" do
    # As after this process restarted, or one started by hand.
    assert {:nothing, state} = decide(@fresh, :ap_idle, 50_000)
    assert {:stop, _state} = decide(state, :ap_idle, 51_000)
  end

  test "a stop that failed is tried again" do
    assert {:stop, state} = decide(%{@fresh | idle: 0}, :ap_idle, 1000)
    assert {:stop, _state} = decide(state, :ap_idle, 1015)
  end

  test "connecting, Wi-Fi off, or no wlan0 yet restart the grace" do
    for wlan <- [:connected, :blocked, :absent] do
      assert {:nothing, state} = decide(@fresh, wlan, 500)
      assert {:nothing, _state} = decide(state, :trying, 550)
    end
  end

  test "a start that failed is tried again" do
    assert {:start, state} = decide(@fresh, :trying, 100)
    assert {:start, _state} = decide(state, :trying, 115)
  end
end
