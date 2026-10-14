defmodule HelloWatch.Clock.ControlsTest do
  use ExUnit.Case, async: true
  alias HelloWatch.Clock.{Controls, Sky}

  # A fake /sys/class/rfkill: the real one on a host is the host's radios.
  setup do
    dir = Path.join(System.tmp_dir!(), "hello_watch_rfkill_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    for {name, type, soft} <- [{"rfkill0", "bluetooth", "1"}, {"rfkill1", "wlan", "0"}] do
      path = Path.join(dir, name)
      File.mkdir_p!(path)
      File.write!(Path.join(path, "type"), type <> "\n")
      File.write!(Path.join(path, "soft"), soft <> "\n")
    end

    %{
      opts: [
        rfkill: dir,
        tailscale: %{state: "Running", ip: "100.64.0.7"},
        nerves_hub: :connected
      ],
      dir: dir
    }
  end

  test "reads each switch", %{opts: opts} do
    assert [
             %{id: :wifi, on: true},
             %{id: :bluetooth, on: false, detail: "off"},
             %{id: :tailscale, on: true, detail: "100.64.0.7"},
             %{id: :nerves_hub, on: true, detail: "connected"}
           ] = Controls.read(opts)

    assert [_, _, _, %{on: nil}] = Controls.read(Keyword.put(opts, :nerves_hub, :unconfigured))
  end

  test "flips the radios with their rfkill soft blocks", %{opts: opts, dir: dir} do
    assert :ok = Controls.toggle(:bluetooth, opts)
    assert File.read!(Path.join(dir, "rfkill0/soft")) == "0"
    assert :ok = Controls.toggle(:wifi, opts)
    assert File.read!(Path.join(dir, "rfkill1/soft")) == "1"
  end

  test "asks for a login rather than starting a logged-out Tailscale", %{opts: opts} do
    assert Controls.toggle(:tailscale, Keyword.put(opts, :tailscale, %{state: "NeedsLogin"})) ==
             :login

    assert Controls.toggle(:wifi, rfkill: "/nonexistent") == {:error, :unavailable}
  end

  test "finds the star under a tap" do
    assert Sky.hit({142, 162}) == :wifi
    assert Sky.hit({300, 170}) == :bluetooth
    assert Sky.hit({320, 296}) == :nerves_hub
    assert Sky.hit({227, 430}) == nil
  end
end
