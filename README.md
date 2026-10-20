# HelloWatch

Example Nerves app for the Mobvoi TicWatch Pro 3, built on
[`nerves_system_tickwatch_pro3`](https://github.com/mlainez/nerves_system_tickwatch_pro3).
It shows an analog face with the moon's phases for hours, a sky of
switches above it, an inventory of apps below, and battery, network,
sensor, moon and Tailscale apps, drawn with [Emerge](https://hexdocs.pm/emerge).

## Try it without building

Put the watch in fastboot mode (power off, then hold the top button while
plugging in USB) and run:

```sh
git clone https://github.com/mlainez/nerves_system_tickwatch_pro3.git
nerves_system_tickwatch_pro3/flash.sh --unlock
```

This flashes the latest prebuilt image from this repository's releases.
`--unlock` **wipes the watch**. The prebuilt image has no Wi-Fi or SSH
configured; build it yourself for those.

## Build and flash

```sh
cp config/target.secret.exs.example config/target.secret.exs  # your Wi-Fi
export MIX_TARGET=ticwatch_pro3
mix deps.get
mix firmware.image

deps/nerves_system_tickwatch_pro3/flash.sh --unlock hello_watch.img    # first install
deps/nerves_system_tickwatch_pro3/flash.sh --app-only hello_watch.img  # reinstall
mix upload                                                             # over the network
```

Your `~/.ssh/id_*.pub` keys are authorized for SSH and `mix upload`. USB
networking (`usb0`) works without Wi-Fi. `mix test` runs the host tests.

`HELLO_WATCH_PUBLIC_IMAGE=1` builds the image published on releases,
without your SSH keys or Wi-Fi credentials.

## Using it

- **Bottom button** toggles the screen; a touch also wakes it. The screen
  fades off after 2 minutes idle.
- **Pull down** for the sky: the watch's switches as constellations. A
  bright star is on, a dim one off; tap it to switch Wi-Fi, Bluetooth,
  Tailscale, NervesHub or the access point. Push back up to return.
- The **access point** (the mast in the middle of the sky) turns Wi-Fi
  into a network of the watch's own, `watch-XXXX` after the last four digits
  of its serial number. The Network app shows its password, eight
  lowercase letters made up the first time and kept from then on. The
  watch is `192.168.24.1` on it, for SSH and `mix upload`. It leaves the
  watch's usual Wi-Fi network until it's switched off or the watch
  reboots, and keeps the watch from suspending meanwhile. It needs a
  system built with `BR2_PACKAGE_WPA_SUPPLICANT_AP_SUPPORT`.
- **Pull up** for the inventory: a dark circle with the apps in a ring
  (clock, battery, network, sensors, moon, Tailscale). Tap one to open it.
- **Drag sideways** to move through recently used apps: right goes back,
  left forward again. The app follows the finger and switches when let go
  past halfway. The face's glowing moon is tonight's real phase.
- The **battery** (faint behind the hands, and on its own page) is estimated from the supply
  voltage, since the fuel gauge sat behind the dead sensor hub. Expect it
  to be off by up to about 10%. It reads high while charging, and only
  shows 100% once the charger reports the cell full. See
  `HelloWatch.Power` and [POWER-MANAGEMENT.md](POWER-MANAGEMENT.md).
- From IEx: `HelloWatch.Clock.toggle()`, `HelloWatch.Clock.status()`.

## Tailscale

The firmware build downloads Tailscale's static arm64 build (version and
SHA-256 pinned in `mix.exs`) into the release. On first boot, swipe to the
Tailscale page and tap it: it shows a QR code to scan with a phone signed
in to Tailscale, and the watch joins as one of your devices. To join
unattended instead, set an auth key over ssh:

```elixir
Nerves.Runtime.KV.put("tailscale_authkey", "tskey-auth-...")
```

The node keeps its identity in `/root/tailscale` from then on.
`HelloWatch.Tailscale.info/0`, `stop/0` and `start/0` check and switch it
at runtime, and `autostart: false` in its config keeps it off at boot.
Running it costs battery: tailscaled wakes the watch for keepalives.

Set the time zone (IANA name, falls back to UTC) in `config/target.exs`:

```elixir
config :hello_watch, HelloWatch.Clock, time_zone: "Europe/Brussels"
```

## Notes

- **Display:** the UI is an Emerge viewport rendered on the CPU (Emerge's
  minimal raster build, which needs nothing from the system), and only
  when something on screen changes. `HelloWatch.Clock.Display` writes each
  frame to `/dev/fb0`, for both SimpleDRM (24 bpp) and the MSM driver
  (32 bpp, padded rows). Turning the screen off fades the panel
  brightness down and blanks the framebuffer, which powers the panel down
  with system v0.2.0 or later. Touch and buttons are read by the app, since
  a headless viewport gets no input. See [DISPLAY.md](DISPLAY.md).
- **Time:** `HelloWatch.PmicRtc` is a `NervesTime` RTC that keeps the clock
  across reboots by storing an offset to the PMIC counter, which Linux
  cannot set.
- **Wi-Fi MAC:** `HelloWatch.WiFi.stable_mac/0` derives a stable address
  from the eMMC CID.
- **GPS:** `HelloWatch.GPS.start_stream/0` and `subscribe/0` deliver
  `{:gps, map}` messages.

## Credits

Fonts in `priv/fonts`: [Macondo](https://fonts.google.com/specimen/Macondo)
and [Alegreya Sans](https://fonts.google.com/specimen/Alegreya+Sans), under
the SIL Open Font License (license files alongside).
