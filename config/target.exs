import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Enable the system startup guard to check that all OTP applications
# started. If they didn't and you're on a Nerves system that supports
# test runs of new firmware, the firmware will automatically roll
# back to the previous version. Delete this if implementing your own
# way of validating that firmware is good.
config :nerves_runtime, startup_guard_enabled: true

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit, update_clock: true

# Restore the clock at boot from the PMIC RTC plus an offset saved after NTP sync.
config :nerves_time, rtc: HelloWatch.PmicRtc

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

# HELLO_WATCH_PUBLIC_IMAGE=1 builds the image published on GitHub releases:
# no SSH keys and no Wi-Fi credentials from the build machine end up in it.
public_image? = System.get_env("HELLO_WATCH_PUBLIC_IMAGE") in ["1", "true"]

keys =
  if public_image? do
    []
  else
    System.user_home!()
    |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
    |> Path.wildcard()
  end

if keys == [] and not public_image?,
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

# /data is a plain directory on the read-only rootfs (the GPS stack bind-mounts
# over it), so the host key lives on the writable application partition.
config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1),
  system_dir: "/root/nerves_ssh"

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information

# Wi-Fi credentials are kept out of version control. Copy
# target.secret.exs.example to target.secret.exs (gitignored) and set your
# own network there. Without it, wlan0 has no configured network.
wifi_secrets_path = Path.join(__DIR__, "target.secret.exs")

wifi_networks =
  cond do
    public_image? ->
      []

    File.exists?(wifi_secrets_path) ->
      {networks, _bindings} = Code.eval_file(wifi_secrets_path)
      networks

    true ->
      IO.warn(
        "#{wifi_secrets_path} not found; wlan0 will have no configured network. " <>
          "Copy config/target.secret.exs.example to config/target.secret.exs " <>
          "and add your own Wi-Fi credentials."
      )

      []
  end

config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0",
     %{
       type: VintageNetWiFi,
       # Keep the address stable across brcmfmac probes and tell
       # wpa_supplicant not to randomize it while scanning.
       mac_address: {HelloWatch.WiFi, :stable_mac, []},
       vintage_net_wifi: %{networks: wifi_networks},
       ipv4: %{method: :dhcp}
     }}
  ]

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]

# Emerge's minimal raster renderer: Skia on the CPU with no EGL, GBM or
# desktop libraries, none of which the system ships. Frames are written to
# /dev/fb0 by HelloWatch.Clock.Display; see UI.md.
config :emerge, compiled_backends: []

# Local time for the watch face, as an IANA zone name so daylight saving is
# handled. Set this to wherever the watch actually is.
config :hello_watch, HelloWatch.Clock, time_zone: "Europe/Brussels"

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
