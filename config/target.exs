import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Errors and crash reports also go to /root/errors.log on the application
# partition: RingLogger only keeps them in memory, and a crash that takes the
# UI down is usually followed by a reboot. HelloWatch.Application adds it.
config :hello_watch, :logger, [
  {:handler, :error_file, :logger_std_h,
   %{level: :error, config: %{file: ~c"/root/errors.log", max_no_bytes: 262_144, max_no_files: 1}}}
]

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

# NervesHub. The product's shared secret comes from the environment (see
# .envrc.example); without it the watch doesn't connect.
nerves_hub_key = System.get_env("NH_PRODUCT_KEY")
nerves_hub_secret = System.get_env("NH_PRODUCT_SECRET")

if not public_image? and is_binary(nerves_hub_key) and is_binary(nerves_hub_secret) do
  config :nerves_hub_link,
    host: "devices.qa.nervescloud.biz",
    remote_iex: true,
    shared_secret: [product_key: nerves_hub_key, product_secret: nerves_hub_secret]
else
  config :nerves_hub_link, connect: false
end

# Not now: NervesHub's socket competes with video for the watch's thin Wi-Fi.
config :nerves_hub_link, connect: false

# Emerge's DRM backend with OpenGL ES, for the GPU system (Mesa freedreno,
# EGL and GBM; wip/gpu of nerves_system_tickwatch_pro3, passed as
# NERVES_SYSTEM until it's released). On the v0.2.0 system, which has no
# EGL or GBM, use `compiled_backends: []` (the minimal raster renderer) and
# `renderer: :framebuffer` below instead. See DISPLAY.md.
config :emerge, compiled_backends: [drm: [:opengl]]

# Local time for the watch face, as an IANA zone name so daylight saving is
# handled. Set this to wherever the watch actually is.
config :hello_watch, HelloWatch.Clock, time_zone: "Europe/Brussels", renderer: :drm

# The home cluster (HelloWatch.Home): the tailnet's devices tagged
# tag:homecluster, as home@<Tailscale address>, sharing one cookie.
config :hello_watch, :home,
  cookie: :"tag:homecluster",
  tag: "tag:homecluster",
  basename: "home",
  interface: "wlan0"

# What the watch lends the cluster: its mic and speaker (ALSA's default
# device, see rootfs_overlay/etc/asound.conf), opened only while a session
# holds them, and its screen for video (HelloWatch.HomeVideo.Display). Video
# is decoded by Venus, the SoC's codec, straight to DMA-BUFs Emerge draws.
config :home_base,
  capabilities: [
    %{
      id: "mic",
      kind: :audio_in,
      availability: :on_request,
      adapter: Home.Adapters.Audio.PortAudioIn,
      meta: %{channels: 1, rate: 48_000}
    },
    %{
      id: "speaker",
      kind: :audio_out,
      availability: :on_request,
      adapter: Home.Adapters.Audio.PortAudioOut
    },
    %{
      id: "watch_video",
      kind: :display,
      adapter: HelloWatch.HomeVideo.Display,
      meta: %{w: 454, h: 454, touch: false}
    }
  ],
  data_dir: "/root/home",
  media: [ports: 50_000..50_099],
  # Venus decodes, and says what it wants: the watch's Wi-Fi carries about
  # 1 Mbit/s at best on the office network, shared with Tailscale and the
  # cluster, and the panel is 454 pixels across. A session settles a stream
  # within these at the camera (Home.Media.Video), the phones' made smaller
  # by their own Venus. software: false, so a stream Venus can't take is an
  # error, not a slow picture.
  video: [
    decoders: [
      %{
        element: Membrane.V4L2.H264.Decoder,
        name: "Venus",
        profiles: [:constrained_baseline, :baseline, :main, :high],
        max_level: 40,
        max_size: {640, 480},
        max_fps: 15,
        max_bitrate: 300_000
      }
    ],
    software: false
  ]

# home_base's Membrane plugins link the system's FFmpeg, Opus and PortAudio
# rather than Bundlex's precompiled builds, which are hundreds of MB each.
config :bundlex, :disable_precompiled_os_deps, true

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
