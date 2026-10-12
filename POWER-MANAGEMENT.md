# Power management on the TicWatch Pro 3

What the watch can do to save power, what it does today, and what is left to
do. Measured on 2026-10-12 on `nerves-0453` (TicWatch Pro 3 LTE, `mobvoi,rover`,
SDM429W), kernel `7.1.3-msm89x7`, system v0.2.0, ~13 min after boot, screen
off, on Wi-Fi, USB cable in. Everything here was read from sysfs and debugfs;
nothing was suspended or reconfigured.

Items marked **unverified** are inferences that still need a test on the watch.

## Priorities

1. ~~Fix or quiesce the nanohub.~~ **Done for failed hubs:**
   `HelloWatch.Nanohub.Guard` unloads the driver. See [Nanohub](#nanohub).
2. ~~Draw at minute resolution while nobody is looking, and lower the
   brightness.~~ **Done:** after 15 s idle the face dims to 50% and redraws
   once a minute. See [Display](#display-and-frame-rate).
3. ~~Suspend (s2idle) when the screen is off.~~ **Done:**
   `HelloWatch.Suspend`. A cycle works; see [Suspend](#suspend).
4. **Turn Wi-Fi off when it isn't needed.**
5. **System-side:** add the RPM stats node so deep SoC sleep can be checked,
   make the bottom button, touch and the hub wake sources, and blacklist
   `venus_core`.

## What is already good

- **CPU idle.** Cores reach `cpu-sleep-0` (core power collapse, 305 µs exit
  latency) and spend almost all their time there. PSCI runs in OS-initiated
  mode, so the cluster domain powers down too: it was idle 670 s of 764 s
  uptime.
- **CPU frequency.** `schedutil` over 960 MHz to 1.96 GHz. About 96% of the
  time was at the 960 MHz floor.
- **Display off is really off.** Blanking `/dev/fb0` puts the connector into
  DPMS Off, and the MDSS, the display controller and the DSI host are
  runtime-suspended.
- **GPU, camera, video and modem domains are off.** No remoteproc is running,
  so the LTE modem never boots.
- **BEAM** already runs with `-sbwt none -sbwtdcpu none -sbwtdio none`, so
  idle schedulers don't busy-wait.
- **The app** stops its 1 s tick and its sensor stream once the screen is
  dark. GPS is off until asked for.

## Nanohub

With the screen off, the SPI controller the hub sits on (`7af8000.spi`,
IRQ 32) fired **5,646 interrupts in 10 s (~565/s)**, and over a million since
boot. Every other interrupt source together was under 100/s. The hub driver is
in an error loop: `nanohub_kthread: kthread_err_cnt=N` every ~2 s, then
`hard reset due to consistent error`, 377 times in 13 min (this is the hub
failure from `ISSUE.md` §6).

`HelloWatch.Nanohub.Guard` handles this: 30 s after boot, and then once a
minute, it looks for `hard reset due to consistent error` in the kernel log
(a working hub never logs it) and unloads the driver. Measured with the
screen on: the SPI interrupts drop from ~564/s to none, and all interrupts
from ~950/s to ~240/s.

Once the hub works:

- Let the hub batch samples in its FIFO and wake the AP only for events.
  Streaming accel/gyro at 25 Hz is only reasonable while the sensors page is
  open, which is what the app does already.
- The hub can run wrist-raise and tap gestures on its own. Those are the
  natural wake sources for a watch (see [Suspend](#suspend)).
- The hub's battery samples are the only battery reading on this board (see
  [Measuring power](#measuring-power)).

## Display and frame rate

### No variable refresh rate, but refresh only happens on change

The AMOLED (RM69330 or ICNA3310, `panel-mobvoi-rover`) is a **DSI
command-mode** panel. The driver doesn't set `MIPI_DSI_MODE_VIDEO`, the
tearing-effect (TE) pin is wired, and the mode is 454×454 at a nominal 60 Hz.
The panel scans out from its own frame memory, and the MDSS only sends pixels
when a frame is committed. There is no VRR or LTPO, but there doesn't need to
be: **a static screen costs no DSI traffic and no SoC work.** The panel's own
self-refresh and the lit pixels are what's left.

So the frame rate is whatever the app commits:

| Cost | Driven by |
|---|---|
| CPU rendering, BEAM wakeups | how often we redraw |
| DSI transfer, MDSS powered | how often we commit (full 454×454 frame each time; upstream MSM does no partial updates) |
| AMOLED emission | number of lit pixels × brightness |

Today the face redraws and writes a full frame **every second**, plus a
10-frame fade on wake and on sleep. Brightness is never changed from 255.

Now: after 15 s without a touch or swipe the face dims to 50% brightness
(64/255, see `Display.dim/0`), drops the second hand and redraws on the
minute. Any touch brings back full brightness and the second hand. The
screen goes off after 2 min, as before.

What to do:

- **Redraw on change only.** Emerge already works this way: it renders only
  after `Viewport.rerender/1` and has no frame loop. Keep animations
  (fades, swipe transitions) short and rare.
- **Drop the second hand** when the wrist is down or after a few seconds
  without interaction, and update once a minute. That is 60× fewer commits.
- **Keep the face mostly black.** The background is already black, which is
  right for AMOLED. Avoid large filled areas and bright gradients.
- **Use brightness.** `/sys/class/backlight/1a94000.dsi.0/brightness` (0–255)
  sends a DCS brightness command to the panel. Dim it when idle, and maybe
  follow ambient light if the hub exposes an ALS.

### Always-on display (needs kernel work)

- **Panel idle mode** (DCS `enter_idle_mode` 0x38/0x39) is the standard AMOLED
  always-on mode: reduced colours and a lower internal refresh. The rover panel
  driver doesn't expose it. It would need a driver hook (a sysfs attribute or a
  low-power DPMS state), which is a system change. **Unverified** that the
  RM69330/ICNA3310 init sequences support it as-is.
- **The secondary FSTN layer** ("Essential mode" on stock) is not described
  in the device tree and has no driver. On stock it is likely driven by the
  MCU rather than Linux (**unverified**). It is the lowest-power way to show
  the time, so it's worth investigating together with the nanohub.

### Implications for the Emerge switch

- Render on demand, commit full frames, no `target_fps`.
- A frame is a 454×454 commit whether one digit or the whole face changed, so
  fewer commits matter more than smaller diffs.
- The framebuffer belongs to fbcon (`fb=62 allocated by [fbcon]`, XR24, pitch
  1920). Writing `/dev/fb0` goes through the fbdev emulation's damage
  handling. A KMS path (Emerge's DRM backend) would need libdrm/EGL/GBM,
  which the system doesn't ship.

## Suspend

### What the kernel offers

- `/sys/power/state`: `freeze mem`, but `mem_sleep` is only `[s2idle]`. PSCI
  `SYSTEM_SUSPEND` isn't available, so "mem" also means s2idle. There's no
  hibernation.
- `suspend_stats`: 0 successes, 0 failures. **Suspend has never been tried on
  this system.**
- Wake sources **enabled** today:

  | Source | Path |
  |---|---|
  | Power key | `pm8941_pwrkey` (PON) |
  | RTC alarm | `rtc-pm8xxx` / `alarmtimer` |
  | Charger | `pm660-charger` (plug, unplug, charge events) |

- **Not** wake sources: the other button (`gpio-keys`, labelled "Volume Up"),
  which has no `wakeup-source` in the DT; the Zinitix touchscreen (no runtime
  PM, no wake support); the nanohub IRQs; Wi-Fi's out-of-band IRQ; USB.

### Is s2idle worth it?

The cluster already powers down between wakeups while running, so s2idle
mostly brings two things:

1. **It freezes everything that wakes the CPU.** That's BEAM timers, the
   brcmfmac watchdog, kernel timers, and today the nanohub loop. With
   everything frozen, the only wakeups left are real events.
2. **It gives the RPM a chance at XO shutdown or VDD-min,** the SoC's deepest
   state. Whether it gets there is **unknown**: `qcom_stats` is built in but
   has no device-tree node, so there are no RPM sleep counters. Adding the
   rpm-stats node for SDM429/MSM8937 to the system DT is the way to find out.
   Clocks holding XO (`bi_tcxo`) right now: eMMC, and the USB PHY reference
   while the cable is in.

### Suggested flow

```
screen off ──(idle N s, nothing holding it)──> suspend
     ^                                            │
     └── power key / RTC alarm / charger <────────┘
```

- **Arm the RTC first, then suspend:** write `+<seconds>` to
  `/sys/class/rtc/rtc0/wakealarm` (relative form, see [RTC](#rtc)), then
  `freeze` to `/sys/power/state`. The write blocks until resume.
- **Avoid races** with the `/sys/power/wakeup_count` handshake: read it, do
  the last checks, write it back, and only suspend if that write succeeds.
- **Expect, after resume:**
  - `CLOCK_MONOTONIC` (and so Erlang monotonic time and `send_after`) doesn't
    advance during s2idle. Read wall-clock time again after resuming instead
    of trusting elapsed timers.
  - Wi-Fi: there's no WoWLAN, so the link may drop and reassociate. SSH and
    IEx sessions over Wi-Fi will probably die. **Unverified.**
  - USB gadget networking stops while suspended.
- **Wake by touch or wrist** needs system work: `wakeup-source` on the
  gpio-keys button, wake support in the Zinitix driver, and a working hub
  for wrist-raise. Until then, wake is power key, RTC or charger only.

### First test (2026-10-12)

One cycle over Wi-Fi with the screen on: `+15` to `wakealarm`, the
`wakeup_count` handshake, `freeze` to `/sys/power/state`.

- Entered and left cleanly: `success=1`, no failed devices or steps.
- The RTC alarm woke it (its IRQ count went 0 → 1) after 16 s by the RTC.
- Wall-clock time advanced 15 s across the cycle. `printk` time advanced
  only ~6 s, as expected for monotonic clocks.
- Wi-Fi survived: SSH reconnected straight after.
- `/sys/power/pm_wakeup_irq` doesn't exist on this kernel, so the wake
  reason has to come from IRQ counts or input events.

### What the app does

`HelloWatch.Suspend` suspends 10 s after the screen goes off, and again
10 s after each wake that doesn't turn the screen on. It holds the watch
awake while on USB power or while an SSH session is established (port 22 in
`/proc/net/tcp*`). The power key (`pm8941_pwrkey`, KEY_POWER) now toggles the
screen like the bottom button, so pressing it wakes the watch and turns the
screen on. There's no RTC wake yet: nothing needs scheduled work.

With the watch suspended on battery, it can't be reached over the network.
Press the power key, or plug it in, to get it back.

## RTC

- **Hardware:** the PM660's RTC (`rtc-pm8xxx`, `rtc0`), clocked from the
  32.768 kHz sleep clock. It keeps counting while the watch is off.
- **Read-only from Linux.** There's no `allow-set-time` or offset storage on
  this board, so `since_epoch` is the raw counter (around 2 days after the
  epoch right now). `HelloWatch.PmicRtc` keeps `utc − raw` on the data
  partition and adds it at boot. That covers timekeeping.
- **Alarm:** a single hardware alarm, with its IRQ (`pm8xxx_rtc_alarm`) set up
  as a wake source. It has never fired so far. The kernel's `alarmtimer`
  multiplexes many timers onto it.
- **Mind the offset when setting alarms.** An absolute `wakealarm` value is
  in raw-counter time, not UTC. Use the relative `+N` form, or subtract the
  `PmicRtc` offset.
- **What to use it for:**
  - waking from s2idle for scheduled work: an NTP sync, a minute update on an
    always-on face, a reminder;
  - time at boot (done);
  - powering on from off. The PMIC supports RTC power-on, but it needs
    bootloader support and isn't wired up. **Unverified,** low priority.

## Radios and other peripherals

- **Wi-Fi** (BCM43xx over SDIO, `brcmfmac`): power save is **on**
  (`CFG80211_DEFAULT_PS=y`). With the screen off it still adds ~10 mmc1
  IRQs/s and ~1 OOB IRQ/s, plus a watchdog thread. Bring the interface down,
  or use `rfkill`, when nothing needs the network. That is the biggest radio
  saving available.
- **Bluetooth** (`hci_uart`, `serial0`): loaded. Power state wasn't measured.
- **LTE modem:** never booted (no remoteproc, `md` domain off). Leave it so.
- **NFC** (`st_nci`): loaded. Power state wasn't measured.
- **Venus** (video codec): `venus_core` is loaded and `gcc_venus0_axi/ahb`
  clocks show enabled, even though its power domain is off. It's unused on a
  watch, so blacklist the module in the system. A minor saving.
- **GPS:** off unless `HelloWatch.GPS.start_stream/0` is called.

## Measuring power

There's no direct battery-current reading:

- The **fuel gauge is a hub sensor,** not a power-supply device. `nanohubctl
  stream battery` reports `percent` and `millivolts` only, and nothing while
  the hub is failing.
- `pm660-charger` reports `current_now` and `voltage_now` for the **USB
  input**, and only while plugged in (216 mA at 4.49 V while charging during
  this survey).

Practical options:

- **Charger input at 100%.** Once `status` reads `Full`, the input current is
  roughly the system's own draw. This is good for comparing before and after
  a change, for example screen-off steady state with and without the hub or
  Wi-Fi.
- **Drain over time on battery.** Use the change in hub `percent` (or
  `millivolts`) over an hour or more. Coarse, but it's real battery data.
- **On-device proxies:** IRQ rate (`/proc/interrupts` deltas), cpuidle and
  genpd residency, and later RPM sleep counters. These are cheap to log and
  show regressions quickly.

A "power meter" in the UI can show charger watts when plugged in, and drain
in %/h on battery.

## Commands used

All read-only, over `ssh nerves-0453.local` (IEx; use `System.cmd("sh", ...)`
for shell):

```sh
cat /sys/power/{state,mem_sleep}; ls /sys/power/suspend_stats
cat /sys/kernel/debug/wakeup_sources
cat /proc/driver/rtc; cat /sys/class/rtc/rtc0/{since_epoch,wakealarm}
grep . /sys/devices/system/cpu/cpu*/cpuidle/state*/{name,usage,time}
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary
cat /sys/kernel/debug/pm_genpd/power-domain-cluster/idle_states
cat /proc/interrupts            # twice, 10 s apart
cat /sys/kernel/debug/dri/*/state
cat /sys/kernel/debug/clk/clk_summary
cat /sys/kernel/debug/regulator/regulator_summary
cat /sys/class/power_supply/pm660-charger/{status,current_now,voltage_now}
```
