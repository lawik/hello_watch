defmodule HelloWatch.AccessPoint do
  @moduledoc """
  Turns wlan0 into a Wi-Fi access point, so a phone or laptop can reach the
  watch with no network around. It's named `watch-XXXX` after the last four
  digits of the serial number, as the hostname is `nerves-XXXX`. The watch
  is 192.168.24.1 on it and hands out addresses by DHCP, so SSH and
  `mix upload` work as on any other network.

  The passphrase is eight lowercase letters, made up the first time and kept
  in `/root/access_point_psk` on the application partition, so a phone that
  joined once can join again. The Network app shows it while the access
  point is up.

  The access point isn't persisted: `stop/0`, or a reboot, puts wlan0 back on
  the configuration it had. While it's up the watch is on no other Wi-Fi
  network, so Tailscale and NervesHub drop until it stops. It also keeps
  the watch from suspending (see HelloWatch.Suspend), which would take it
  down.

  `ssid/1` and `psk/1` take the serial number and a directory, for tests.
  """

  require Logger

  @interface "wlan0"
  @address "192.168.24.1"
  @psk_dir "/root"
  @psk_file "access_point_psk"
  @psk_length 8
  # wlan0's configuration from before the access point, to go back to.
  @previous {__MODULE__, :previous}

  @type info :: %{ssid: String.t(), psk: String.t(), clients: non_neg_integer()}

  @doc "The access point's name: `watch-` and the last four of `serial`."
  @spec ssid(String.t()) :: String.t()
  def ssid(serial \\ serial_number()) do
    "watch-" <> (serial |> String.pad_leading(4, "0") |> String.slice(-4, 4))
  end

  @doc """
  The passphrase, read from `dir` or made up and saved there the first time:
  #{@psk_length} lowercase ASCII letters.
  """
  @spec psk(Path.t()) :: String.t()
  def psk(dir \\ @psk_dir) do
    path = Path.join(dir, @psk_file)

    case File.read(path) do
      {:ok, contents} ->
        psk = String.trim(contents)
        if valid_psk?(psk), do: psk, else: new_psk(path)

      {:error, _reason} ->
        new_psk(path)
    end
  end

  defp valid_psk?(psk), do: psk =~ ~r/\A[a-z]{#{@psk_length}}\z/

  defp new_psk(path) do
    psk = random_letters(@psk_length)

    case File.write(path, psk <> "\n") do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Could not save the access point passphrase: #{reason}")
    end

    psk
  end

  # Bytes past the last whole multiple of 26 are skipped, so every letter is
  # equally likely.
  defp random_letters(count, acc \\ [])
  defp random_letters(0, acc), do: List.to_string(acc)

  defp random_letters(count, acc) do
    case :crypto.strong_rand_bytes(1) do
      <<byte>> when byte < 234 -> random_letters(count - 1, [?a + rem(byte, 26) | acc])
      _ -> random_letters(count, acc)
    end
  end

  @doc "The name, passphrase and number of clients while the access point is up, else nil."
  @spec info() :: info() | nil
  def info do
    if up?() do
      clients = vintage_net(:get, [["interface", @interface, "wifi", "clients"]]) || []
      %{ssid: ssid(), psk: psk(), clients: length(clients)}
    end
  end

  @doc "Whether wlan0 is configured as an access point."
  @spec up?() :: boolean()
  def up? do
    match?(
      %{vintage_net_wifi: %{networks: [%{mode: :ap} | _]}},
      vintage_net(:get_configuration, [@interface])
    )
  end

  @doc "Brings the access point up in place of wlan0's usual network."
  @spec start() :: :ok | {:error, term()}
  def start do
    case vintage_net(:get_configuration, [@interface]) do
      nil ->
        {:error, :unavailable}

      %{vintage_net_wifi: %{networks: [%{mode: :ap} | _]}} ->
        :ok

      previous ->
        :persistent_term.put(@previous, previous)
        vintage_net(:configure, [@interface, config(previous, ssid(), psk()), [persist: false]])
    end
  end

  @doc "Takes the access point down and puts wlan0 back on its usual network."
  @spec stop() :: :ok | {:error, term()}
  def stop do
    case :persistent_term.get(@previous, nil) do
      nil ->
        vintage_net(:reset_to_defaults, [@interface])

      previous ->
        with :ok <- vintage_net(:configure, [@interface, previous, [persist: false]]) do
          :persistent_term.erase(@previous)
          :ok
        end
    end
  end

  @doc """
  wlan0's configuration as an access point, keeping the rest of `previous`
  (its MAC address in particular).
  """
  @spec config(map(), String.t(), String.t()) :: map()
  def config(previous, ssid, psk) do
    previous
    |> Map.take([:type, :mac_address])
    |> Map.merge(%{
      # CCMP only: left alone, it also offers TKIP. (VintageNetWiFi 0.12
      # doesn't pass `proto` on, so WPA1 with CCMP is still offered.)
      vintage_net_wifi: %{
        networks: [
          %{
            mode: :ap,
            ssid: ssid,
            key_mgmt: :wpa_psk,
            psk: psk,
            pairwise: "CCMP"
          }
        ]
      },
      ipv4: %{method: :static, address: @address, prefix_length: 24},
      dhcpd: %{
        start: "192.168.24.10",
        end: "192.168.24.100",
        options: %{subnet: "255.255.255.0", router: [@address]}
      }
    })
  end

  # VintageNet only exists on the watch.
  defp vintage_net(fun, args) do
    if Code.ensure_loaded?(VintageNet), do: apply(VintageNet, fun, args)
  end

  defp serial_number do
    Nerves.Runtime.serial_number()
  rescue
    _ -> "0000"
  end
end
