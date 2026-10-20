defmodule HelloWatch.Clock.Controls do
  @moduledoc """
  The watch's global switches, shown as constellations in the sky: Wi-Fi,
  Bluetooth, Tailscale, NervesHub and the Wi-Fi access point.

  Wi-Fi and Bluetooth are switched with their rfkill soft blocks, which the
  kernel keeps for the radio whatever the network configuration is. Turning
  Wi-Fi off drops SSH and Tailscale with it; turn it back on from the watch.
  Tailscale starts and stops tailscaled (see HelloWatch.Tailscale).
  NervesHub starts and stops the `:nerves_hub_link` application, and with it
  firmware updates and remote IEx; it starts again on every boot.
  The access point takes over wlan0 from its usual network until it's
  switched off or the watch reboots (see HelloWatch.AccessPoint).

  `read/1` and `toggle/2` take an `:rfkill` directory, and the Tailscale,
  NervesHub and access point states, for tests.
  """

  alias HelloWatch.{AccessPoint, Tailscale}

  @rfkill "/sys/class/rfkill"

  @type control :: %{
          id: :wifi | :bluetooth | :tailscale | :nerves_hub | :access_point,
          name: String.t(),
          on: boolean() | nil,
          detail: String.t()
        }

  @doc "Each switch's state, `on: nil` where it can't be read."
  @spec read(keyword()) :: [control()]
  def read(opts \\ []) do
    rfkill = Keyword.get(opts, :rfkill, @rfkill)
    tailscale = Keyword.get_lazy(opts, :tailscale, &tailscale_info/0)
    nerves_hub = Keyword.get_lazy(opts, :nerves_hub, &nerves_hub_info/0)
    access_point = Keyword.get_lazy(opts, :access_point, &access_point_info/0)

    [
      radio(:wifi, "Wi-Fi", rfkill, "wlan", &ssid/0),
      radio(:bluetooth, "Bluetooth", rfkill, "bluetooth", fn -> nil end),
      tailscale(tailscale),
      nerves_hub(nerves_hub),
      access_point(access_point)
    ]
  end

  @doc """
  Flips a switch. Returns `:login` for Tailscale when it needs logging in,
  which the caller does on the Tailscale view instead.
  """
  @spec toggle(atom(), keyword()) :: :ok | :login | {:error, term()}
  def toggle(id, opts \\ [])

  def toggle(:wifi, opts), do: flip(Keyword.get(opts, :rfkill, @rfkill), "wlan")
  def toggle(:bluetooth, opts), do: flip(Keyword.get(opts, :rfkill, @rfkill), "bluetooth")

  def toggle(:tailscale, opts) do
    case Keyword.get_lazy(opts, :tailscale, &tailscale_info/0) do
      %{state: "Off"} -> Tailscale.start()
      %{state: "NeedsLogin"} -> :login
      %{state: "Unavailable"} -> {:error, :unavailable}
      nil -> {:error, :unavailable}
      _running -> Tailscale.stop()
    end
  end

  def toggle(:nerves_hub, opts) do
    case Keyword.get_lazy(opts, :nerves_hub, &nerves_hub_info/0) do
      :unconfigured -> {:error, :unconfigured}
      :stopped -> start_nerves_hub()
      _running -> Application.stop(:nerves_hub_link)
    end
  end

  # The radio has to be on to serve the access point.
  def toggle(:access_point, opts) do
    case Keyword.get_lazy(opts, :access_point, &access_point_info/0) do
      :unavailable ->
        {:error, :unavailable}

      :off ->
        rfkill = Keyword.get(opts, :rfkill, @rfkill)

        with :ok <- unblock(rfkill, "wlan"),
             do: Keyword.get(opts, :start_access_point, &AccessPoint.start/0).()

      _up ->
        Keyword.get(opts, :stop_access_point, &AccessPoint.stop/0).()
    end
  end

  defp radio(id, name, rfkill, type, detail) do
    case soft_blocked(rfkill, type) do
      nil -> %{id: id, name: name, on: nil, detail: "unavailable"}
      {_path, true} -> %{id: id, name: name, on: false, detail: "off"}
      {_path, false} -> %{id: id, name: name, on: true, detail: detail.() || "on"}
    end
  end

  defp tailscale(%{state: "Running"} = info),
    do: %{id: :tailscale, name: "Tailscale", on: true, detail: info.ip || "connected"}

  defp tailscale(%{state: "Off"}),
    do: %{id: :tailscale, name: "Tailscale", on: false, detail: "off"}

  defp tailscale(%{state: "NeedsLogin"}),
    do: %{id: :tailscale, name: "Tailscale", on: false, detail: "tap to log in"}

  defp tailscale(%{state: "Unavailable"}),
    do: %{id: :tailscale, name: "Tailscale", on: nil, detail: "unavailable"}

  defp tailscale(%{state: state}),
    do: %{id: :tailscale, name: "Tailscale", on: true, detail: String.downcase(state)}

  defp tailscale(nil), do: %{id: :tailscale, name: "Tailscale", on: nil, detail: "…"}

  defp nerves_hub(:connected),
    do: %{id: :nerves_hub, name: "NervesHub", on: true, detail: "connected"}

  defp nerves_hub(:connecting),
    do: %{id: :nerves_hub, name: "NervesHub", on: true, detail: "connecting"}

  defp nerves_hub(:stopped), do: %{id: :nerves_hub, name: "NervesHub", on: false, detail: "off"}

  defp nerves_hub(:unconfigured),
    do: %{id: :nerves_hub, name: "NervesHub", on: nil, detail: "not configured"}

  defp access_point(%{ssid: ssid}),
    do: %{id: :access_point, name: "Access point", on: true, detail: ssid}

  defp access_point(:off),
    do: %{id: :access_point, name: "Access point", on: false, detail: "off"}

  defp access_point(:unavailable),
    do: %{id: :access_point, name: "Access point", on: nil, detail: "unavailable"}

  # The first rfkill switch of `type`, and whether it's soft blocked.
  defp soft_blocked(rfkill, type) do
    rfkill
    |> Path.join("rfkill*")
    |> Path.wildcard()
    |> Enum.find_value(fn path ->
      with {:ok, ^type} <- read_trimmed(Path.join(path, "type")),
           {:ok, soft} <- read_trimmed(Path.join(path, "soft")) do
        {path, soft == "1"}
      else
        _ -> nil
      end
    end)
  end

  defp flip(rfkill, type) do
    case soft_blocked(rfkill, type) do
      nil -> {:error, :unavailable}
      {path, blocked} -> File.write(Path.join(path, "soft"), if(blocked, do: "0", else: "1"))
    end
  end

  defp unblock(rfkill, type) do
    case soft_blocked(rfkill, type) do
      {path, true} -> File.write(Path.join(path, "soft"), "0")
      _ -> :ok
    end
  end

  defp read_trimmed(path) do
    with {:ok, value} <- File.read(path), do: {:ok, String.trim(value)}
  end

  # VintageNet only exists on the watch.
  defp ssid do
    if Code.ensure_loaded?(VintageNet) do
      case apply(VintageNet, :get, [["interface", "wlan0", "wifi", "current_ap"]]) do
        %{ssid: ssid} when ssid != "" -> ssid
        _ -> nil
      end
    end
  end

  # Built without credentials (see config/target.exs), it starts with nothing
  # to run. NervesHubLink only exists on the watch.
  defp nerves_hub_info do
    cond do
      Application.get_env(:nerves_hub_link, :connect, true) == false -> :unconfigured
      Process.whereis(NervesHubLink.Socket) == nil -> :stopped
      apply(NervesHubLink, :connected?, []) -> :connected
      true -> :connecting
    end
  catch
    :exit, _reason -> :connecting
  end

  defp start_nerves_hub do
    case Application.ensure_all_started(:nerves_hub_link) do
      {:ok, _apps} -> :ok
      error -> error
    end
  end

  # VintageNet only exists on the watch.
  defp access_point_info do
    cond do
      not Code.ensure_loaded?(VintageNet) -> :unavailable
      info = AccessPoint.info() -> info
      true -> :off
    end
  end

  defp tailscale_info do
    Tailscale.info()
  catch
    :exit, _reason -> nil
  end
end
