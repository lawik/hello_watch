defmodule HelloWatch.AccessPointTest do
  use ExUnit.Case, async: true
  alias HelloWatch.AccessPoint

  setup do
    dir = Path.join(System.tmp_dir!(), "hello_watch_ap_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "is named after the last four digits of the serial number, like the hostname" do
    assert AccessPoint.ssid("3051120453") == "watch-0453"
    assert AccessPoint.ssid("12") == "watch-0012"
  end

  test "makes up eight lowercase letters once and keeps them", %{dir: dir} do
    psk = AccessPoint.psk(dir)
    assert psk =~ ~r/\A[a-z]{8}\z/
    assert AccessPoint.psk(dir) == psk
    assert File.read!(Path.join(dir, "access_point_psk")) == psk <> "\n"
  end

  test "replaces a saved passphrase that isn't eight lowercase letters", %{dir: dir} do
    File.write!(Path.join(dir, "access_point_psk"), "Short1\n")
    assert AccessPoint.psk(dir) =~ ~r/\A[a-z]{8}\z/
  end

  test "serves wlan0 as an access point, keeping its MAC address" do
    previous = %{
      type: VintageNetWiFi,
      mac_address: {HelloWatch.WiFi, :stable_mac, []},
      vintage_net_wifi: %{networks: [%{ssid: "home", psk: "secret", key_mgmt: :wpa_psk}]},
      ipv4: %{method: :dhcp}
    }

    config = AccessPoint.config(previous, "watch-0453", "abcdefgh")

    assert %{
             type: VintageNetWiFi,
             mac_address: {HelloWatch.WiFi, :stable_mac, []},
             vintage_net_wifi: %{
               networks: [
                 %{
                   mode: :ap,
                   ssid: "watch-0453",
                   key_mgmt: :wpa_psk,
                   psk: "abcdefgh",
                   pairwise: "CCMP"
                 }
               ]
             },
             ipv4: %{method: :static, address: "192.168.24.1"},
             dhcpd: %{start: _, end: _}
           } = config
  end

  test "the Network app shows the name and passphrase while it's up" do
    assert [{"access point", "watch-0453"}, {"password", "abcdefgh"} | _interfaces] =
             HelloWatch.Clock.network_rows(%{ssid: "watch-0453", psk: "abcdefgh", clients: 0})

    refute Enum.any?(HelloWatch.Clock.network_rows(nil), &match?({"password", _}, &1))
  end

  test "is unavailable without VintageNet" do
    assert AccessPoint.info() == nil
    refute AccessPoint.up?()
    assert AccessPoint.start() == {:error, :unavailable}
  end
end
